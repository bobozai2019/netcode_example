"""Coordinate the capacity replay with one Godot process per Windows machine."""
import argparse
import asyncio
import hashlib
from ipaddress import IPv4Address
import json
from pathlib import Path
import platform
import subprocess
from time import monotonic, time
from types import SimpleNamespace
import winreg

from run import (
    DENSITIES, SCENES, PROJECT, ROOT, Relay, budget, case_name, case_results,
    configurations, console_godot, game_godot, open_port, player, prepare,
)

MODES = ("A", "B", "C")
REPORTS = ("guest.json", "guest.csv", "guest.log", "guest.png")
FILE_LIMIT = 8 * 1024 * 1024
CHUNK_SIZE = 64 * 1024
POLL_SECONDS = 0.2


def file_hash(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def registry(path, name):
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
        return winreg.QueryValueEx(key, name)[0]


def build_info(godot):
    sdk = PROJECT / "addons/netcode"
    source_folders = ("actors", "arena", "benchmark", "combat", "effects", "net", "ui")
    sources = sorted(path for folder in source_folders for path in (PROJECT / folder).rglob("*")
                     if path.suffix in (".gd", ".tscn", ".tres") or path.name in ("run.py", "lan.py"))
    sources += [PROJECT / "project.godot", PROJECT / "assets/quaternius/Character_Soldier.gltf",
                PROJECT / "assets/quaternius/Character_Soldier.gltf.import"]
    digest = hashlib.sha256()
    for path in sources:
        digest.update(path.relative_to(PROJECT).as_posix().encode("utf-8"))
        content = path.read_bytes()
        if path.suffix != ".gltf":
            content = content.replace(b"\r\n", b"\n")
        digest.update(hashlib.sha256(content).digest())
    return {
        "godot": subprocess.check_output([str(godot), "--version"], text=True).strip(),
        "godot_sha256": file_hash(godot),
        "sdk": (sdk / "build-id.txt").read_text().strip(),
        "sdk_sha256": {name: file_hash(sdk / name) for name in (
            "netcode.gdextension", "bin/netcode_godot.dll", "bin/netcode_transport_tcp.dll",
        )},
        "replay_sha256": digest.hexdigest(),
    }


def machine_info():
    identity = registry(r"SOFTWARE\Microsoft\Cryptography", "MachineGuid")
    return {
        "label": platform.node(),
        "cpu": registry(r"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString").strip(),
        "os": platform.platform(),
        "machine_id_sha256": hashlib.sha256(identity.strip().lower().encode("utf-8")).hexdigest(),
    }


async def send(writer, packet):
    writer.write(json.dumps(packet).encode("utf-8") + b"\n")
    await writer.drain()


async def receive(reader):
    line = await reader.readline()
    if not line:
        raise ConnectionError("The peer closed the control connection")
    packet = json.loads(line)
    if not isinstance(packet, dict):
        raise ValueError("Invalid control message")
    return packet


def save_json(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


async def stop(process):
    if process.poll() is None:
        process.kill()
        await asyncio.to_thread(process.wait, 5)


async def receive_reports(reader, folder):
    response = await receive(reader)
    files = response.get("files")
    if response.get("type") != "result" or not isinstance(files, dict) or type(response.get("exit")) is not int:
        raise ValueError("Invalid guest result")
    for name, length in files.items():
        if name not in REPORTS or type(length) is not int or not 0 <= length <= FILE_LIMIT:
            raise ValueError("Invalid guest report")
        with (folder / name).open("wb") as output:
            while length:
                block = await reader.readexactly(min(length, CHUNK_SIZE))
                output.write(block)
                length -= len(block)
    return response["exit"]


async def send_reports(writer, folder, code):
    files = {}
    for name in REPORTS:
        path = folder / name
        if path.exists():
            length = path.stat().st_size
            if length > FILE_LIMIT:
                raise ValueError(f"Report is too large: {path}")
            files[name] = length
    await send(writer, {"type": "result", "exit": code, "files": files})
    for name in files:
        with (folder / name).open("rb") as source:
            while block := source.read(CHUNK_SIZE):
                writer.write(block)
                await writer.drain()


def validate_case(data):
    if data.get("type") != "capacity" or data.get("mode") not in MODES:
        raise ValueError("Invalid replay mode")
    if data.get("size") not in DENSITIES or data.get("scenario") not in SCENES:
        raise ValueError("Invalid replay load")
    for key, lower, upper in (("port", 1024, 65535), ("index", 1, 10000), ("rep", 1, 100),
                              ("delay", 0, 5000), ("seconds", 1, 600), ("warmup", 2, 600)):
        value = data.get(key)
        if type(value) is not int or not lower <= value <= upper:
            raise ValueError(f"Invalid replay {key}")
    if not all(type(data.get(key)) is bool for key in ("windowed", "simple")):
        raise ValueError("Invalid replay display settings")
    return data


def test_folder(root, data):
    key = case_name("capacity", data["mode"], data["size"], data["scenario"], data["delay"], data["rep"])
    path = root / key
    path.mkdir()
    return path


def launch(godot, folder, data, role, port, address):
    options = SimpleNamespace(windowed=data["windowed"], simple=data["simple"], capture=None,
                              seconds=data["seconds"], warmup=data["warmup"])
    return player(godot, folder, role, port, options, "capacity", data["mode"], data["size"], data["scenario"],
                  address=address, side_by_side=False)


def case_timeout(data):
    return data["seconds"] + data["warmup"] + 45


async def coordinator_case(godot, root, options, reader, writer, data):
    folder = test_folder(root, data)
    host_port = open_port()
    host = launch(godot, folder, data, "host", host_port, "127.0.0.1")
    relay = Relay(host_port, data["delay"], options.peer)
    began = monotonic()
    history = []
    remote = None
    try:
        await relay.start(options.bind, data["port"])
        await asyncio.sleep(1.0)
        await send(writer, data)
        remote = asyncio.create_task(receive_reports(reader, folder))
        while host.poll() is None or not remote.done():
            history.append((time(), *relay.transferred))
            if monotonic() - began > case_timeout(data):
                raise TimeoutError(f"Timed out collecting {folder.name}")
            if remote.done() and remote.exception() is not None:
                remote.result()
            await asyncio.sleep(POLL_SECONDS)
        guest_code = await remote
    finally:
        if remote is not None and not remote.done():
            remote.cancel()
            await asyncio.gather(remote, return_exceptions=True)
        await stop(host)
        if relay.listener is not None:
            await relay.close()
        save_json(folder / "tcp.json", {
            "added_rtt_ms": data["delay"], "guest_to_host": relay.transferred[0],
            "host_to_guest": relay.transferred[1], "samples_epoch_up_down": history,
            "rate_reference": "host measurement window on the relay machine",
        })
    ends, failures = case_results(folder, {"host": host.returncode, "guest": guest_code}, "capacity",
                                  history, shared_clock=False)
    result = {**data, "folder": folder.name, "failures": failures, "ends": ends}
    print(f"{folder.name}: {'; '.join(failures) if failures else 'ledger converged'}", flush=True)
    return result


async def coordinate(godot, root, options, hello):
    connection = asyncio.get_running_loop().create_future()

    def accept(reader, writer):
        if writer.get_extra_info("peername")[0] != options.peer or connection.done():
            writer.close()
        else:
            connection.set_result((reader, writer))

    listener = await asyncio.start_server(accept, options.bind, options.port)
    try:
        print(f"Waiting on {options.bind}:{options.port} for {options.peer}", flush=True)
        reader, writer = await asyncio.wait_for(connection, options.wait)
    except TimeoutError:
        raise TimeoutError(f"No guest connected to {options.bind}:{options.port}") from None
    finally:
        listener.close()
        if not connection.done() or connection.cancelled():
            await listener.wait_closed()
    try:
        guest = await asyncio.wait_for(receive(reader), 15)
        if guest.get("type") != "hello" or guest.get("build") != hello["build"]:
            await send(writer, {"type": "error", "reason": "Godot, SDK, or replay build mismatch"})
            raise ValueError("Godot, SDK, or replay build mismatch")
        machine = guest.get("machine", {})
        identity = machine.get("machine_id_sha256") if isinstance(machine, dict) else None
        independent = identity != hello["machine"]["machine_id_sha256"]
        if not identity or (not independent and not options.loopback_smoke):
            await send(writer, {"type": "error", "reason": "A distinct Windows machine is required"})
            raise ValueError("A distinct Windows machine is required")
        topology = "loopback-smoke" if options.loopback_smoke else "two-windows-installations"
        save_json(root / "machines.json", {"topology": topology, "host": hello["machine"], "guest": machine,
                                           "build": hello["build"]})
        options.cases = ("capacity",)
        results = []
        await send(writer, {"type": "accepted", "topology": topology})
        for index, (_, mode, size, scene, delay, repeat) in enumerate(configurations(options), 1):
            data = validate_case({"type": "capacity", "mode": mode, "size": size, "scenario": scene,
                                  "port": options.game_port, "index": index, "rep": repeat, "delay": delay,
                                  "seconds": options.seconds, "warmup": options.warmup,
                                  "windowed": not options.headless, "simple": options.simple})
            results.append(await coordinator_case(godot, root, options, reader, writer, data))
            save_json(root / "summary.json", results)
        failed = any(result["failures"] for result in results)
        await send(writer, {"type": "done", "failed": failed})
        return int(failed)
    finally:
        writer.close()
        await writer.wait_closed()
        await listener.wait_closed()


async def work(godot, root, options, hello):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(options.connect, options.port), options.wait)
    try:
        await send(writer, hello)
        response = await asyncio.wait_for(receive(reader), 15)
        if response.get("type") != "accepted":
            raise ValueError(response.get("reason", "Host declined the run"))
        save_json(root / "machine.json", {**hello, "topology": response["topology"]})
        while True:
            data = await asyncio.wait_for(receive(reader), 90)
            if data.get("type") == "done":
                return int(data["failed"])
            validate_case(data)
            folder = test_folder(root, data)
            process = launch(godot, folder, data, "guest", data["port"], options.connect)
            try:
                await asyncio.wait_for(asyncio.to_thread(process.wait), case_timeout(data))
            finally:
                await stop(process)
            await send_reports(writer, folder, process.returncode)
    finally:
        writer.close()
        await writer.wait_closed()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    roles = parser.add_subparsers(dest="role", required=True)
    host = roles.add_parser("host")
    guest = roles.add_parser("guest")
    for cli in (host, guest):
        cli.add_argument("--label", required=True)
        cli.add_argument("--port", type=int, default=43400, help="Coordination TCP port")
        cli.add_argument("--wait", type=int, default=120, help="Connection timeout in seconds")
        cli.add_argument("--godot-exe", type=Path)
        cli.add_argument("--sdk", type=Path)
        cli.add_argument("--skip-prepare", action="store_true")
    host.add_argument("--bind", required=True, type=lambda addr: str(IPv4Address(addr)))
    host.add_argument("--peer", required=True, type=lambda addr: str(IPv4Address(addr)))
    host.add_argument("--game-port", type=int, default=43401, help="Game relay TCP port")
    host.add_argument("--modes", choices=MODES, nargs="+", default=list(MODES))
    host.add_argument("--sizes", choices=DENSITIES, type=int, nargs="+", default=list(DENSITIES))
    host.add_argument("--scenes", choices=SCENES, nargs="+", default=list(SCENES))
    host.add_argument("--delay", type=int, nargs="+", default=[0])
    host.add_argument("--seconds", type=int, default=30)
    host.add_argument("--warmup", type=int, default=10)
    host.add_argument("--repeats", type=int, default=3)
    host.add_argument("--headless", action="store_true")
    host.add_argument("--simple", action="store_true")
    host.add_argument("--loopback-smoke", action="store_true", help="Verify coordination on this PC only")
    guest.add_argument("--connect", required=True, type=lambda addr: str(IPv4Address(addr)))
    options = parser.parse_args()
    if not options.label.replace("-", "").replace("_", "").isalnum():
        parser.error("Labels may contain letters, digits, hyphens and underscores")
    if not 1024 <= options.port <= 65535 or options.wait <= 0:
        parser.error("Invalid coordination port or timeout")
    if options.role == "host":
        if options.bind == "0.0.0.0" or options.peer == "0.0.0.0":
            parser.error("Specify the local and guest IPv4 addresses explicitly")
        if options.loopback_smoke != (options.bind == options.peer == "127.0.0.1"):
            parser.error("Loopback smoke requires both addresses to be 127.0.0.1")
        if not 1024 <= options.game_port <= 65535 or options.game_port == options.port:
            parser.error("The relay requires a distinct TCP port")
        if not 1 <= options.repeats <= 100 or not 1 <= options.seconds <= 600 or not 2 <= options.warmup <= 600:
            parser.error("Invalid repeat count or sample duration")
        if any(not 0 <= delay <= 5000 for delay in options.delay):
            parser.error("Invalid added RTT")
    if not budget(ROOT, 128 * 1024**2)["allowed"]:
        parser.error("Example output budget exceeded")
    godot = game_godot(options.godot_exe)
    if not options.skip_prepare:
        prepare(godot, options.sdk)
    hello = {"type": "hello", "machine": machine_info(), "build": build_info(godot)}
    root = ROOT / "horde-survivors-3d" / f"lan-{options.label}-{options.role}"
    try:
        root.mkdir(parents=True)
    except FileExistsError:
        parser.error(f"Output already exists: {root}")
    role = coordinate if options.role == "host" else work
    try:
        return asyncio.run(role(console_godot(godot), root, options, hello))
    except (OSError, ValueError) as error:
        print(f"LAN replay stopped: {error or type(error).__name__}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
