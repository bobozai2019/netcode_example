
"""Run reproducible native TCP Godot pairs and capture per-end measurements."""
import argparse
import asyncio
import itertools
import json
from math import isfinite
from pathlib import Path
import socket
import subprocess
import sys
from time import monotonic, time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from launch import PROJECT, game_godot, prepare
from artifacts import ROOT, budget
from godot_build import console_godot

CASES = ("rules", "before", "after", "win", "down", "timeout", "natural", "capacity", "pickup-queue")
SCENES = ("split", "merge", "burst")
DENSITIES = (128, 256, 512, 1024)
LEDGER_FIELDS = ("alive", "xp", "xp_version", "deaths", "hits", "hp_digest", "boss_hp", "result")
PICKUP_LEDGER_FIELDS = ("collected", "xp", "xp_version", "guest_build", "upgrades")


def open_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


class Relay:
    """Delay each TCP stream independently and count its application stream bytes."""

    def __init__(self, target, delay_ms, peer=None, *, downlink_kib=0, downlink_window=None,
                 uplink_kib=0, uplink_window=None):
        self.target = target
        self.peer = peer
        self.delay = delay_ms / 2000
        self.transferred = [0, 0]
        self.pairs = set()
        self.listener = None
        self.bytes_per_sec = (uplink_kib * 1024, downlink_kib * 1024)
        self.windows = (uplink_window, downlink_window)
        self.throttled_bytes = [0, 0]

    async def start(self, address="127.0.0.1", port=0):
        read_limit = 4096 if self.bytes_per_sec[0] else 64 * 1024
        self.listener = await asyncio.start_server(self.attach, address, port, limit=read_limit)
        return self.listener.sockets[0].getsockname()[1]

    async def attach(self, guest_in, guest_out):
        if self.peer and guest_out.get_extra_info("peername")[0] != self.peer:
            guest_out.close()
            return
        task = asyncio.current_task()
        self.pairs.add(task)
        host_out = None
        jobs = []
        try:
            if self.bytes_per_sec[0]:
                guest_out.get_extra_info("socket").setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            host_in, host_out = await self.connect_host()
            jobs = [asyncio.create_task(self.forward(guest_in, host_out, 0)),
                    asyncio.create_task(self.forward(host_in, guest_out, 1))]
            await asyncio.wait(jobs, return_when=asyncio.FIRST_COMPLETED)
        except OSError:
            pass
        finally:
            for job in jobs:
                job.cancel()
            await asyncio.gather(*jobs, return_exceptions=True)
            for writer in (guest_out, host_out):
                if writer is not None:
                    writer.close()
            self.pairs.discard(task)

    async def connect_host(self):
        if not self.bytes_per_sec[1]:
            return await asyncio.open_connection("127.0.0.1", self.target)
        upstream = socket.socket()
        try:
            upstream.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            upstream.setblocking(False)
            await asyncio.get_running_loop().sock_connect(upstream, ("127.0.0.1", self.target))
            return await asyncio.open_connection(sock=upstream, limit=4096)
        except BaseException:
            upstream.close()
            raise

    async def forward(self, reader, writer, direction):
        window = self.windows[direction]
        bytes_per_sec = self.bytes_per_sec[direction]
        started = monotonic()
        queue = asyncio.Queue(maxsize=256)

        async def read():
            try:
                while True:
                    elapsed = monotonic() - started
                    limited = window and window[0] <= elapsed < window[1]
                    data = await reader.read(512 if limited else 64 * 1024)
                    if not data:
                        break
                    if limited:
                        remaining = max(0, started + window[1] - monotonic())
                        await asyncio.sleep(min(len(data) / bytes_per_sec, remaining))
                        self.throttled_bytes[direction] += len(data)
                    await queue.put((monotonic() + self.delay, data))
            except (ConnectionError, OSError):
                pass
            await queue.put((0, None))

        producer = asyncio.create_task(read())
        try:
            while True:
                due, data = await queue.get()
                if data is None:
                    return
                left = due - monotonic()
                if left > 0:
                    await asyncio.sleep(left)
                writer.write(data)
                await writer.drain()
                self.transferred[direction] += len(data)
        except (ConnectionError, OSError):
            return
        finally:
            producer.cancel()
            await asyncio.gather(producer, return_exceptions=True)

    async def close(self):
        self.listener.close()
        pairs = tuple(self.pairs)
        for task in pairs:
            task.cancel()
        await asyncio.gather(*pairs, return_exceptions=True)
        await self.listener.wait_closed()


def player(godot, folder, role, port, options, case, mode, size, scene, address="127.0.0.1", side_by_side=True):
    flags = ["--max-fps", "60", "--disable-vsync"]
    if options.windowed:
        position = "900,90" if role == "guest" and side_by_side else "45,90"
        flags += ["--resolution", "840x472", "--position", position]
    else:
        flags.insert(0, "--headless")
    path = folder / role
    arguments = [str(godot), *flags, "--path", str(PROJECT)]
    if case == "pickup-queue":
        arguments += ["--script", "res://benchmark/pickup_queue.gd", "--", role, str(port), address, str(path)]
    else:
        arguments += ["--", f"--role={role}", f"--port={port}", f"--address={address}",
                      f"--case={case}", f"--mode={mode}", f"--size={size}", f"--scenario={scene}",
                      f"--seconds={options.seconds}", f"--warmup={options.warmup}", f"--output={path}"]
    if options.simple:
        arguments.append("--simple")
    if options.capture is not None:
        arguments.append(f"--capture={options.capture}")
    if getattr(options, "raw_enemies", False):
        arguments.append("--raw-enemies")
    if getattr(options, "netcode_smoothing", False):
        arguments.append("--netcode-smoothing")
    if getattr(options, "debug", False):
        arguments.append("--debug")
    with path.with_suffix(".log").open("w", encoding="utf-8") as log:
        return subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT)


def case_results(folder, exits, case, history, shared_clock=True):
    rows = {}
    failures = []
    ledger_fields = PICKUP_LEDGER_FIELDS if case == "pickup-queue" else LEDGER_FIELDS
    for role, exit_code in exits.items():
        if exit_code != 0:
            failures.append(f"{role} exited {exit_code}")
        path = folder / f"{role}.json"
        log = folder / f"{role}.log"
        if not log.is_file():
            failures.append(f"{role} log missing")
        elif "SCRIPT ERROR:" in log.read_text(encoding="utf-8", errors="replace"):
            failures.append(f"{role} reported a script error")
        if path.is_file():
            try:
                summary = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(summary, dict) or any(key not in summary for key in ledger_fields):
                    raise ValueError("Incomplete ledger")
                rows[role] = summary
            except ValueError:
                failures.append(f"{role} summary invalid")
        elif role == "host" or case not in ("before", "after"):
            failures.append(f"{role} summary missing")
    for role, stats in rows.items():
        # A remote guest can have a different wall clock. The host's measured
        # window is on the same clock as the relay and applies to both streams.
        window = stats if shared_clock else rows.get("host", {})
        if window.get("epoch_end", 0) <= window.get("epoch_start", 0):
            continue
        samples = [entry for entry in history if window["epoch_start"] <= entry[0] <= window["epoch_end"]]
        if len(samples) >= 2:
            first, last = samples[0], samples[-1]
            interval = last[0] - first[0]
            up, down = ((last[i] - first[i]) / interval for i in (1, 2))
            stats["tcp_tx_bytes_s"] = down if role == "host" else up
            stats["tcp_rx_bytes_s"] = up if role == "host" else down
    if len(rows) == 2:
        for key in ledger_fields:
            if rows["host"][key] != rows["guest"][key]:
                failures.append(f"{key} differs: {rows['host'][key]} vs {rows['guest'][key]}")
    return rows, failures


async def pair(godot, folder, options, case, mode, size, scene, delay):
    folder.mkdir(parents=True, exist_ok=True)
    host_port = open_port()
    uplink_kib = getattr(options, "slow_uplink_kib", 0)
    uplink_window = getattr(options, "slow_uplink_window", None)
    relay = Relay(host_port, delay, downlink_kib=options.slow_downlink_kib,
                  downlink_window=options.slow_downlink_window, uplink_kib=uplink_kib,
                  uplink_window=uplink_window)
    guest_port = await relay.start()
    host = player(godot, folder, "host", host_port, options, case, mode, size, scene)
    guest = None
    try:
        await asyncio.sleep(1.0)
        guest = player(godot, folder, "guest", guest_port, options, case, mode, size, scene)
        began = monotonic()
        history = []
        while host.poll() is None or guest.poll() is None:
            elapsed = monotonic() - began
            history.append((time(), *relay.transferred))
            if elapsed > (395 if case == "natural" else max(46, options.seconds + options.warmup + 28)):
                break
            await asyncio.sleep(0.2)
        (folder / "tcp.json").write_text(json.dumps({
            "added_rtt_ms": delay, "guest_to_host": relay.transferred[0],
            "host_to_guest": relay.transferred[1], "samples_epoch_up_down": history,
            "downlink_kib": options.slow_downlink_kib, "downlink_window_s": options.slow_downlink_window,
            "uplink_kib": uplink_kib, "uplink_window_s": uplink_window,
            "throttled_bytes": sum(relay.throttled_bytes),
            "uplink_throttled_bytes": relay.throttled_bytes[0],
            "downlink_throttled_bytes": relay.throttled_bytes[1],
        }), encoding="utf-8")
    finally:
        await relay.close()
        for process in (host, guest):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(3)
    exits = {"host": host.returncode, "guest": guest.returncode}
    rows, failures = case_results(folder, exits, case, history)
    if case == "pickup-queue" and uplink_kib and not relay.throttled_bytes[0]:
        failures.append("No uplink bytes observed during the limit window")
    result = {"folder": str(folder), "case": case, "mode": mode, "size": size, "scenario": scene,
              "added_rtt_ms": delay, "failures": failures, "ends": rows}
    print(json.dumps({key: value for key, value in result.items() if key != "ends"}, ensure_ascii=False), flush=True)
    return result


def configurations(opts):
    configurations = itertools.product(opts.cases, opts.sizes, opts.scenes, opts.delay, range(1, opts.repeats + 1))
    for index, (case, size, scene, delay, repeat) in enumerate(configurations):
        rotation = index % len(opts.modes)
        for mode in opts.modes[rotation:] + opts.modes[:rotation]:
            yield case, mode, size, scene, delay, repeat


def case_name(case, mode, size, scene, delay, repeat):
    return f"{case}-{mode}-{size}-{scene}-{delay}ms-r{repeat}"


async def run(godot, opts, root):
    results = []
    for case, mode, size, scene, delay, repeat in configurations(opts):
        key = case_name(case, mode, size, scene, delay, repeat)
        results.append(await pair(godot, root / key, opts, case, mode, size, scene, delay))
        (root / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    return any(item["failures"] for item in results)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--godot-exe", type=Path)
    cli.add_argument("--sdk", type=Path)
    cli.add_argument("--skip-prepare", action="store_true")
    cli.add_argument("--cases", choices=CASES, nargs="+", default=["rules"])
    cli.add_argument("--modes", choices=["A", "B", "C"], nargs="+", default=["B"])
    cli.add_argument("--sizes", type=int, choices=DENSITIES, nargs="+", default=[128])
    cli.add_argument("--scenes", choices=SCENES, nargs="+", default=["split"])
    cli.add_argument("--delay", type=int, nargs="+", default=[0], help="Added total RTT in ms")
    cli.add_argument("--slow-downlink-kib", type=int, default=0, help="Host-to-guest limit in KiB/s")
    cli.add_argument("--slow-downlink-window", type=float, nargs=2, metavar=("START", "END"),
                     help="Apply the downlink limit between these seconds after the relay connects")
    cli.add_argument("--slow-uplink-kib", type=int, default=0, help="Guest-to-host limit in KiB/s")
    cli.add_argument("--slow-uplink-window", type=float, nargs=2, metavar=("START", "END"),
                     help="Apply the uplink limit between these seconds after the relay connects")
    cli.add_argument("--repeats", type=int, default=1)
    cli.add_argument("--seconds", type=float, default=30)
    cli.add_argument("--warmup", type=float, default=10)
    cli.add_argument("--windowed", action="store_true")
    cli.add_argument("--simple", action="store_true")
    smoothing = cli.add_mutually_exclusive_group()
    smoothing.add_argument("--raw-enemies", action="store_true", help="Use received monster positions directly for motion comparison")
    smoothing.add_argument("--netcode-smoothing", action="store_true", help="Apply SDK smooth_properties to monster position and facing")
    cli.add_argument("--debug", action="store_true", help="Show the in-game diagnostic panel")
    cli.add_argument("--capture", type=int, help="Save one gameplay screenshot per end at this simulation step")
    cli.add_argument("--label", default="latest")
    opts = cli.parse_args()
    if not opts.label.replace("-", "").replace("_", "").isalnum():
        cli.error("--label must be alphanumeric with optional hyphens and underscores")
    if opts.repeats < 1 or min(opts.seconds, opts.warmup, *opts.delay) < 0:
        cli.error("Durations/delay must be nonnegative, with at least one repeat")
    for direction in ("downlink", "uplink"):
        rate = getattr(opts, f"slow_{direction}_kib")
        window = getattr(opts, f"slow_{direction}_window")
        if rate < 0 or bool(rate) != bool(window):
            cli.error(f"Use a positive --slow-{direction}-kib together with --slow-{direction}-window")
        if window and not (0 <= window[0] < window[1] and isfinite(window[1])):
            cli.error(f"The {direction} window requires 0 <= START < END with a finite end")
    if "pickup-queue" in opts.cases and (opts.modes != ["C"] or opts.sizes != [1024] or opts.scenes != ["split"]):
        cli.error("pickup-queue uses --modes C --sizes 1024 --scenes split")
    if not budget(ROOT, 128 * 1024**2)["allowed"]:
        cli.error("Example output budget exceeded")
    godot = game_godot(opts.godot_exe)
    if not opts.skip_prepare:
        prepare(godot, opts.sdk)
    root = ROOT / "horde-survivors-3d" / opts.label
    try:
        root.mkdir(parents=True)
    except FileExistsError:
        cli.error(f"Output already exists: {root}. Pick a new --label.")
    return asyncio.run(run(console_godot(godot), opts, root))


if __name__ == "__main__":
    raise SystemExit(main())
