"""Run the car yard's two-player or four-player acceptance scenario."""

import argparse
from contextlib import ExitStack
from ipaddress import IPv4Address
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from godot_build import GODOT_PROJECT, resolve_godot
from unity_build import UNITY_PLAYER


WINDOWS = os.name == "nt"
BUILD = ROOT / ("build/win-x64/Release/bin/Release" if WINDOWS else "build/linux-x64/Release/bin")
PLATFORMS = {
    "cocos2dx": ("cocos", "Netcode Car Yard"),
    "godot": ("godot", "Netcode Godot Car Yard"),
    "unity": ("unity", "Netcode Unity Car Yard"),
}


class Process:
    def __init__(self, output, name, executable, args, *, interactive=False, display=True):
        self.name = name
        self.lines = []
        self.timestamps = []
        env = os.environ.copy()
        if not display:
            env.pop("DISPLAY", None)
            env.pop("WAYLAND_DISPLAY", None)
        self.proc = subprocess.Popen(
            [executable, *args], cwd=executable.parent, text=True, encoding="utf-8",
            errors="replace", stdin=subprocess.PIPE if interactive else None,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), env=env,
        )
        self.thread = threading.Thread(target=self.read, args=(output,), daemon=True)
        self.thread.start()

    def read(self, output):
        folder = output / self.name
        folder.mkdir()
        with (folder / "stdout.log").open("w", encoding="utf-8") as log:
            for line in self.proc.stdout:
                if len(self.lines) < 8000 and len(line) <= 4096:
                    self.timestamps.append(time.monotonic())
                    self.lines.append(line.strip())
                    log.write(line)
                    log.flush()
                else:
                    log.write("Detailed output reached the line cap. Further output was discarded.\n")
                    for _ in self.proc.stdout:
                        pass
                    break

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        try:
            self.proc.wait(timeout=6)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=30)
        self.thread.join(timeout=6)
        self.proc.stdout.close()
        if self.proc.stdin is not None:
            self.proc.stdin.close()

    def get_line(self, needle):
        return next((line for line in self.lines if needle in line), None)

    def await_line(self, needle, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            line = self.get_line(needle)
            if line is not None:
                return line
            if self.proc.poll() is not None and not self.thread.is_alive():
                break
            time.sleep(0.025)
        raise RuntimeError(f"{self.name} missed {needle!r} (exit={self.proc.poll()}): {self.lines[-5:]}")


def stat_sample(processes):
    if not WINDOWS:
        return linux_stats(processes)
    pids = ",".join(str(p.proc.pid) for p in processes)
    query = (
        f"Get-Process -Id {pids} -ErrorAction SilentlyContinue | "
        "Select-Object Id,CPU,WorkingSet64,PeakWorkingSet64,PrivateMemorySize64,MainWindowTitle | "
        "ConvertTo-Json -Compress"
    )
    raw = subprocess.check_output(
        ["powershell.exe", "-NoProfile", "-Command", query], text=True, encoding="utf-8",
        errors="replace", creationflags=subprocess.CREATE_NO_WINDOW,
    )
    records = json.loads(raw) if raw.strip() else []
    if isinstance(records, dict):
        records = [records]
    return {row["Id"]: row for row in records}


def linux_stats(processes):
    records = {}
    divisor = os.sysconf("SC_CLK_TCK")
    for process in processes:
        pid = process.proc.pid
        directory = Path(f"/proc/{pid}")
        try:
            stat = (directory / "stat").read_text().rsplit(")", 1)[1].split()
            status = (directory / "status").read_text()
            memory = (directory / "smaps_rollup").read_text()
        except (FileNotFoundError, ProcessLookupError):
            continue
        sizes = {key: int(amount) * 1024 for key, amount in re.findall(r"(?m)^(\w+):\s+(\d+) kB$", status + memory)}
        records[pid] = {"CPU": (int(stat[11]) + int(stat[12])) / divisor,
                        "WorkingSet64": sizes["VmRSS"], "PeakWorkingSet64": sizes["VmHWM"],
                        "PrivateMemorySize64": sizes["Private_Clean"] + sizes["Private_Dirty"],
                        "MainWindowTitle": None}
    return records


def values(line):
    return {key: int(value) for key, value in re.findall(r"([a-z_]+)=(\d+)", line)}


def require(condition, explanation):
    if not condition:
        raise RuntimeError(explanation)


def execute(args, output, *, join_address=None):
    join_address = join_address or args.local_address
    host_server = getattr(args, "host_server", None)
    headless_host = getattr(args, "host_headless", False) or host_server is not None
    require(not headless_host or args.platform == "cocos2dx", "Headless host requires the Cocos2d-x platform")
    with ExitStack() as stack:
        processes = []
        flags = ["--scenario", args.mode, "--port", str(args.port), "--seconds", str(args.seconds), "--trace"]
        delegated = getattr(args, "authority", False)
        send_hz = getattr(args, "send_hz", 20)
        if getattr(args, "typed_profile", False):
            flags.append("--typed-profile")
        if send_hz != 20:
            flags += ["--send-hz", str(send_hz)]
        if delegated:
            flags += ["--client-authority", "2"]
            if args.mode == "stress":
                flags += ["--client-authority", "3"]
        if args.fault:
            flags.append("--fault")

        guest_platform = args.guest_platform or args.platform
        guest_name = f"{PLATFORMS[guest_platform][0]}-guest"

        def launch(name, platform, connection):
            capture = ["--capture", str(output / "yard.png")] if args.capture and name == guest_name else []
            if name == "host" and host_server is not None:
                executable, engine_args = host_server, []
            elif platform == "godot" and args.godot_export:
                executable, engine_args = args.godot_export, ["--"]
            elif platform == "godot":
                executable, engine_args = resolve_godot(args.godot_exe), ["--path", str(args.godot_project), "--"]
            elif platform == "unity":
                executable = args.unity_player
                engine_args = ["-logFile", "-", "-screen-fullscreen", "0", "-force-d3d11", "--"]
            else:
                program = "netcode-guest" if platform == "light" else "netcode-yard"
                executable = args.bin / (program + (".exe" if WINDOWS else ""))
                engine_args = []
            process = Process(output, name, executable, [*engine_args, *connection, *flags, *capture],
                              display=name != "host" or not headless_host)
            stack.callback(process.close)
            processes.append(process)
            return process

        host_flags = ["--host", "--bind", str(args.local_address)]
        if headless_host and host_server is None:
            host_flags.append("--headless")
        if getattr(args, "host_assets", None) is not None:
            host_flags += ["--assets", str(args.host_assets)]
        host = launch("host", args.platform, host_flags)
        host.await_line("listening", 60 if args.platform == "unity" else 15)
        join = ["--join", str(join_address)]
        guest = launch(guest_name, guest_platform, join)
        if args.mode == "stress":
            guest.await_line("waiting player=2")
            light_one = launch("light-guest-1", "light", join)
            light_one.await_line("waiting player=3")
            launch("light-guest-2", "light", join)
        host.await_line("measurement_begin", 60 if guest_platform == "unity" else 15)
        measured_from = time.monotonic()
        before = stat_sample(processes)
        require(all(p.proc.pid in before for p in processes), "Process died before measurement")
        freeze_line = host.await_line("measurement_frozen", args.seconds + 8)
        after = stat_sample(processes)
        measured_seconds = time.monotonic() - measured_from
        require(len(after) == len(processes), "Process died during measurement")
        for process, platform in ((host, args.platform), (guest, guest_platform)):
            title = after[process.proc.pid]["MainWindowTitle"]
            if process is host and headless_host:
                host.await_line("renderer=Headless")
                require(not title and not before[process.proc.pid]["MainWindowTitle"], "Headless host created a window")
            elif WINDOWS:
                require(PLATFORMS[platform][1] in title, f"Missing window on {process.name}")
            elif platform == "cocos2dx":
                require("renderer=Headless" not in process.await_line("renderer="), f"Missing graphics on {process.name}")
            for error in ("failed to link program", "SCRIPT ERROR"):
                require(not process.get_line(error), f"{error} on {process.name}")
            if platform == "unity":
                process.await_line("unity_scene_ready version=")
                process.await_line("unity_beacon_applied id=")
                process.await_line("unity_heading_applied car=")

        observed = values(freeze_line)
        result = {"scenario": args.mode, "faults": args.fault, "endpoint": f"{join_address}:{args.port}",
                  "host_platform": args.platform, "host_headless": headless_host,
                  "guest_platform": guest_platform, "host_interval": observed, "peers": {}}
        digests = set()
        for p in processes:
            summary = values(p.await_line("summary"))
            pid = p.proc.pid
            summary["pid"] = pid
            summary["cpu_seconds"] = round(after[pid]["CPU"] - before[pid]["CPU"], 3)
            summary["cpu_one_core_pct"] = round(100 * summary["cpu_seconds"] / measured_seconds, 2)
            summary["working_set_bytes"] = after[pid]["WorkingSet64"]
            summary["peak_working_set_bytes"] = after[pid]["PeakWorkingSet64"]
            summary["private_bytes"] = after[pid]["PrivateMemorySize64"]
            summary["window"] = after[pid]["MainWindowTitle"]
            result["peers"][p.name] = summary
            digests.add(summary["digest"])
            unity_process = (p is host and args.platform == "unity") or (p is guest and guest_platform == "unity")
            require(p.proc.wait(timeout=45 if unity_process else 8) == 0, f"{p.name} returned an error")
        require(len(digests) == 1, "Final object/field digest mismatch")
        require(len({r["player"] for r in result["peers"].values()}) == len(processes), "Player identity collision")
        peers = result["peers"].values()
        require(all(row["tcp_rx"] and row["tcp_tx"] and row["udp_rx"] and row["udp_tx"] for row in peers),
                "Every process must use both the TCP and UDP channels")
        if args.fault:
            require(all(any(row[key] for row in peers) for key in ("udp_drop", "udp_dup", "udp_reorder")),
                    "Fault test must deliver drops, duplicates and reordering")
        if not delegated or args.mode == "play":
            guest.await_line("visual id=")
        if not delegated:
            result["prediction"] = {"local_node": guest.await_line("visual prediction_local"),
                                    "remote_node": guest.await_line("visual id=")}
        if getattr(args, "typed_profile", False):
            for process in (host, guest):
                process.await_line("typed_profile applied")
                process.await_line("typed_profile updated")
            result["typed_profile"] = ["initial", "updated"]
        if delegated:
            guest.await_line("visual authority_local")
            car = result["peers"][guest_name]["car"]
            lost = host.await_line("peer_lost player=2")
            restored = values(guest.await_line("recovered player=2"))
            require(restored["car"] == car, "Delegated car changed identity on rejoin")
            expected = [2, 1, 2, 1, 2, 1] if args.mode == "play" else [2, 1, 2, 1]
            prefix = f"authority_grant object={car} "
            host_grants = [(i, values(line)) for i, line in enumerate(host.lines) if line.startswith(prefix)]
            require([g["writer"] for _, g in host_grants] == expected and
                    [g["epoch"] for _, g in host_grants] == list(range(1, len(expected) + 1)),
                    f"Unexpected writer/epoch sequence: {host_grants}")
            require(host_grants[-3][0] < host.lines.index(lost) < host_grants[-2][0],
                    "Expected host takeover on disconnect before new grant")
            require("baseline_ack player=2" in host.lines[host.lines.index(lost) + 1:host_grants[-2][0]],
                    "Client was granted write access before acknowledging its reconnect baseline")
            require(any(line.startswith(f"authority_accept object={car} writer=2 ")
                        for line in host.lines[host_grants[-2][0] + 1:host_grants[-1][0]]),
                    "Reconnected writer did not publish any state")
            handoffs = []
            for i, g in host_grants:
                token = f"{prefix}writer={g['writer']} epoch={g['epoch']} "
                observed_at = next((j for j, line in enumerate(guest.lines) if line.startswith(token)), None)
                if observed_at is not None:
                    handoffs.append({"epoch": g["epoch"], "writer": g["writer"], "step": g["step"],
                                     "observed_ms": round(1000 * (guest.timestamps[observed_at] -
                                                                  host.timestamps[i]))})
            require({1, len(expected) - 1, len(expected)} <= {h["epoch"] for h in handoffs},
                    "Guest did not observe grant, reconnect grant and final revoke")
            if args.mode == "play":
                require(2 in {h["epoch"] for h in handoffs}, "Guest did not observe the live revoke")
            else:
                third = result["peers"]["light-guest-1"]
                require(third["submitted"] > 0 and result["peers"]["light-guest-2"]["submitted"] == 0,
                        "Expected a mixture of client and host writers")
                host.await_line(f"authority_accept object={third['car']} writer=3 ")
            submitted = sum(row["submitted"] for row in peers)
            accepted = result["peers"]["host"]["accepted"]
            require(0 < accepted <= submitted and result["peers"][guest_name]["submitted"] > 0,
                    "Missing state acceptance and submission metrics")
            result["authority"] = {"send_hz": send_hz, "submissions": submitted, "acceptances": accepted,
                                   "handoffs": handoffs, "reconnect_ms": restored["ms"]}
        if args.capture:
            guest.await_line("render_capture_ok")
            require((output / "yard.png").is_file(), "Missing rendered image")
        if args.mode == "stress":
            host.await_line("door_open player=2")
            for p in processes:
                p.await_line("The yard gate is open")
            require(all(row["objects"] == 100 for row in result["peers"].values()), "Expected 100 objects per peer")
        else:
            if not delegated:
                host.await_line("input player=2")
            host.await_line("net_input_x=0.750000")
            guest.await_line("net_input_x=0.750000")
            guest.await_line("public_rpc rejected")
            host.await_line("door_open player=2")
            guest.await_line("The gate is already open")
            barrier = values(host.await_line("barrier_removed object="))["object"]
            guest.await_line(f"replica_removed object={barrier}")
            if guest_platform in {"godot", "unity"}:
                guest.await_line(f"visual_created object={barrier}")
                guest.await_line(f"visual_removed object={barrier}")
            lost = host.await_line("peer_lost player=2")
            initial = values(guest.await_line("ready player=2 car="))
            restored = values(guest.await_line("recovered player=2"))
            require(initial["car"] == restored["car"], "Expected the original car after recovery")
            host.await_line("net_input_x=-0.500000")
            guest.await_line("net_input_x=-0.500000")
            require(result["peers"][guest_name]["recovery_ms"] > 0, "Missing reconnect measurement")
            if "unity" in (args.platform, guest_platform):
                offline = host.lines[host.lines.index(lost) + 1:]
                removed = [values(line)["object"] for line in offline if "barrier_removed object=" in line]
                spawned = [values(line)["object"] for line in offline if "barrier_spawn object=" in line]
                require(len(removed) == 1 and len(spawned) == 2 and spawned[0] == removed[0],
                        "Expected the host to create, remove and replace a barrier during the disconnection")
                transient, surviving = removed[0], spawned[1]
                require(transient != surviving, "Expected a surviving object distinct from the offline removal")
                if guest_platform == "unity":
                    guest.await_line(f"visual_created object={surviving}")
                    require(not guest.get_line(f"visual_created object={transient}"),
                            "Unity recreated an object removed while offline")
                result["rejoin"] = {"player": restored["player"], "car": restored["car"],
                                    "removed_while_offline": transient, "surviving_object": surviving}
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("play", "stress"))
    parser.add_argument("--bin", type=Path, default=BUILD)
    parser.add_argument("--port", type=int, default=43220)
    parser.add_argument("--local-address", type=IPv4Address, default="127.0.0.1",
                        help="Local IPv4 used by both the listener and the test guests")
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--fault", action="store_true")
    parser.add_argument("--authority", action="store_true", help="Exercise client state writing and handoff")
    parser.add_argument("--typed-profile", action="store_true", help="Verify native typed fields on both engine nodes")
    parser.add_argument("--send-hz", type=int, choices=range(5, 61), metavar="5..60", default=20)
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--platform", choices=PLATFORMS, default="cocos2dx")
    parser.add_argument("--host-headless", action="store_true", help="Run the Cocos2d-x host without a window")
    parser.add_argument("--host-server", type=Path, help="Run an already built dedicated server without a mode flag")
    parser.add_argument("--host-assets", type=Path, help="Use a separate host resource directory")
    parser.add_argument("--guest-platform", choices=PLATFORMS)
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--godot-project", type=Path, default=GODOT_PROJECT)
    parser.add_argument("--godot-export", type=Path)
    parser.add_argument("--unity-player", type=Path, default=UNITY_PLAYER)
    args = parser.parse_args()
    if (args.host_headless or args.host_server) and args.platform != "cocos2dx":
        parser.error("The headless host requires --platform cocos2dx")
    if not WINDOWS and {args.platform, args.guest_platform} - {"cocos2dx", None}:
        parser.error("Linux verification currently uses the Cocos2d-x platform")
    args.bin = args.bin.resolve()
    if args.host_server:
        args.host_server = args.host_server.resolve()
    if args.host_assets:
        args.host_assets = args.host_assets.resolve()
    args.godot_project = args.godot_project.resolve()
    args.unity_player = args.unity_player.resolve()
    if args.godot_export:
        args.godot_export = args.godot_export.resolve()
    if not budget(ROOT, 256 * 1024 ** 2)["allowed"]:
        print("Output budget exceeded")
        return 1
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            metrics = execute(args, output)
            (output / "metrics.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")
            print(json.dumps(metrics, indent=2))
            ok = True
        except Exception as error:
            print(error)
            (output / "failure.txt").write_text(str(error), encoding="utf-8")
    print(f"run evidence {rotate_run(ROOT, ok)}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
