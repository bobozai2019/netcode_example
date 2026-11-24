"""Run the Sync Lab DemoCheck with two real Godot processes and check both traces."""

import argparse
import json
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
from time import monotonic, sleep
from uuid import uuid4

from artifacts import ROOT, budget, create_job, job_lock, remove_owned
from prepare_godot_fps import prepare


LAB = ROOT.parent / "sync-lab"
AREA = re.compile(r"SYNC_LAB_AREA_SETTLED area=(\d+) visible=(\d+)")


def configure(work, godot, sdk, backend, cloud, baseline):
    for file in LAB.iterdir():
        if file.is_file():
            shutil.copy2(file, work)
    if baseline:
        source = baseline.read_text(encoding="utf-8")
        (work / "backend_netcode.gd").write_text(source + '''

func trace_state() -> Dictionary:
	if host: return {"aoi": 0}
	for current in [0, 1, 2]:
		var valid := true
		for i in orbs.size():
			if visible(i) != (i < Orb.GLOBAL_COUNT or current == 0 or current == 1 + i % 2):
				valid = false
				break
		if valid: return {"aoi": current}
	return {"aoi": -1}
''', encoding="utf-8")
    extensions = ["res://addons/netcode/netcode.gdextension"]
    if backend == "Fusion":
        fusion = LAB / "addons/fusion"
        target = work / "addons/fusion"
        (target / "bin").mkdir(parents=True)
        shutil.copy2(fusion / "fusion.gdextension", target)
        name = "libfusion.windows.editor.x86_64.release.dll"
        shutil.copy2(fusion / "bin" / name, target / "bin")
        extensions.append("res://addons/fusion/fusion.gdextension")
    if backend == "Fusion" and cloud:
        project = work / "project.godot"
        settings = project.read_text(encoding="utf-8")
        project.write_text(settings.replace("connection/mode=1", "connection/mode=0"), encoding="utf-8")
    (work / ".godot").mkdir()
    (work / ".godot/extension_list.cfg").write_text(
        "\n".join(extensions) + "\n", encoding="utf-8")
    if sdk.is_dir():
        shutil.copytree(sdk, work / "addons/netcode")
    else:
        prepare(work, godot, sdk)


def run(work, godot, backend, count, seconds):
    if backend == "Fusion":
        address = "lab-check-" + uuid4().hex[:12]
    else:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            address = f"127.0.0.1:{sock.getsockname()[1]}"
    ready = work / "host.ready"
    visibility = work / "visibility.txt"
    common = [str(godot), "--headless", "--path", str(work), "--max-fps", "60", "--quit-after",
              str(seconds * 60), "--", "--backend", backend, "--endpoint", address, "--objects", str(count),
              "--demo-check", "--trace", "--demo-visibility", str(visibility)]
    jobs = {}
    status = {}
    try:
        for role, extra in (("host", ["--host", "--host-ready", str(ready)]), ("guest", ["--join"])):
            with (work / f"{role}.log").open("wb") as log:
                jobs[role] = subprocess.Popen([*common, *extra], stdout=log, stderr=subprocess.STDOUT)
            if role == "host":
                deadline = monotonic() + 25
                while not ready.is_file() and jobs[role].poll() is None and monotonic() < deadline:
                    sleep(0.1)
                if not ready.is_file() or ready.read_text(encoding="utf-8").strip() != "ready":
                    raise RuntimeError("The host did not open a room")
        for role, process in jobs.items():
            status[role] = process.wait(timeout=seconds + 15)
    finally:
        for process in jobs.values():
            if process.poll() is None:
                process.kill()
                process.wait()
    return status


def check(work, statuses, count):
    output = {"objects": count, "exit_codes": statuses,
              "sdk_build_id": (work / "addons/netcode/build-id.txt").read_text().strip()}
    for role in ("host", "guest"):
        log = (work / f"{role}.log").read_text(encoding="utf-8", errors="replace")
        target = 1 if role == "host" else count - 1
        if statuses[role] or "SCRIPT ERROR" in log or f"SYNC_LAB_FIELDS {target}/{target}" not in log:
            raise RuntimeError(f"{role} field check failed\n{log[-3000:]}")
        traces = [json.loads(line.removeprefix("SYNC_LAB_TRACE ")) for line in log.splitlines()
                  if line.startswith("SYNC_LAB_TRACE ")]
        full = [row for row in traces if row["round"] and row["visible"] == count and row["wave"] >= 50]
        if len(full) < 8 or full[-1]["wave"] <= full[0]["wave"]:
            raise RuntimeError(f"{role} did not sustain eight full-view samples")
        advancing = [sum(group["advanced"] for group in row["remote_groups"].values()) for row in full]
        if sum(value > 0 for value in advancing) < 8:
            raise RuntimeError(f"{role} did not observe sustained remote version updates")
        output[role] = {"field_groups": target, "full_samples": len(full), "wave_first": full[0]["wave"],
                        "wave_last": full[-1]["wave"],
                        "physics_hz_median": round(statistics.median(row["physics_hz"] for row in full), 2),
                        "age_p95_ms_median": statistics.median(row["age_p95_ms"] for row in full),
                        "queued_bytes_peak": max(row["queued_bytes"] or 0 for row in traces),
                        "remote_advanced_median": statistics.median(advancing)}
        if role == "guest":
            areas = [tuple(map(int, item)) for item in AREA.findall(log)]
            group = (count + 24) // 2
            if areas != [(0, count), (1, group), (2, group), (0, count)]:
                raise RuntimeError(f"Guest AOI sequence differs: {areas}")
            output["guest"]["areas"] = areas
            for key in (1, 2):
                group_name = f"aoi{key}"
                if not any(row["aoi"] == key and row["visible"] == group and
                           row["remote_groups"][group_name]["advanced"] > 0 and
                           row["remote_groups"]["global"]["advanced"] > 0 for row in traces):
                    raise RuntimeError(f"Global and key {key} did not advance together")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("objects", type=int, choices=(128, 512))
    parser.add_argument("--sdk", type=Path, required=True, help="SDK ZIP or installed addons/netcode directory")
    parser.add_argument("--backend", choices=("Netcode", "Fusion"), default="Netcode")
    parser.add_argument("--cloud", action="store_true", help="Use Photon Cloud for the Fusion run")
    parser.add_argument("--seconds", type=int, default=33)
    parser.add_argument("--baseline-backend", type=Path, help="Replay an archived pre-migration TCP backend")
    args = parser.parse_args()
    if not budget(ROOT, 128 * 1024**2)["allowed"]:
        raise SystemExit("Output budget exceeded")
    godot = LAB / "runtime/godot-4.6.1/Godot_v4.6.1-stable_win64_console.exe"
    kind = "baseline" if args.baseline_backend else args.backend.lower()
    relative = Path(f"tmp/sync-lab-native-{kind}-{args.objects}")
    work = create_job(ROOT, relative, "temp")
    passed = False
    try:
        with job_lock(work, "temp"):
            configure(work, godot, args.sdk.resolve(), args.backend, args.cloud, args.baseline_backend)
            results = check(work, run(work, godot, args.backend, args.objects, args.seconds), args.objects)
            print(json.dumps(results, ensure_ascii=False), flush=True)
            passed = True
    finally:
        if passed:
            remove_owned(ROOT, work, "temp")
        else:
            print(f"Failed run logs: {work}")


if __name__ == "__main__":
    main()
