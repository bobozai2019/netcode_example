"""Summarize recorded LAN replays and, when supplied, their role-swapped run."""
import argparse
from collections import defaultdict
import csv
import json
from pathlib import Path
from statistics import median
import sys

from run import LEDGER_FIELDS

ROLES = ("host", "guest")
FEEDBACK = ("move_ms", "attack_ms", "hit_effect_ms")
CASE_FIELDS = ("scenario", "size", "delay", "seconds", "warmup", "windowed", "simple")
CAPACITY_WARMUP_SECONDS = 10
CAPACITY_CAPTURE_SECONDS = 30
CAPACITY_REPEATS = 3


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_archive(folder):
    header = read_json(folder / "machines.json")
    cases = read_json(folder / "summary.json")
    if not cases:
        raise ValueError(f"No completed replay cases in {folder}")
    identities = tuple(header[role]["machine_id_sha256"] for role in ROLES)
    if header["topology"] == "two-windows-installations" and identities[0] == identities[1]:
        raise ValueError(f"Identical Windows installation IDs in {folder}")
    return header, cases, identities


def setting(case):
    return tuple(case[field] for field in CASE_FIELDS)


def replay_key(case):
    return (*setting(case), case["mode"], case["rep"])


def number(value, digits=1):
    return "—" if value is None else f"{value:.{digits}f}"


def stats(endpoint, key, p="p95"):
    return endpoint.get(key, {}).get(p)


def pending_quarters(path):
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as csv_file:
        points = [(int(row["step"]), int(row["pending_hits"])) for row in csv.DictReader(csv_file)]
    if len(points) < 4 or points[-1][0] <= points[0][0]:
        return []
    first, span = points[0][0], points[-1][0] - points[0][0] + 1
    quarters = [[] for _ in range(4)]
    for step, pending in points:
        quarters[min(3, (step - first) * 4 // span)].append(pending)
    return [median(period) if period else None for period in quarters]


def failures(case, endpoint, pending):
    issues = list(case.get("failures", []))
    issues.extend(endpoint.get("errors", []))
    if not endpoint:
        return [*issues, "summary missing"]
    frame = stats(endpoint, "frame_ms")
    if frame is None or frame > 20:
        issues.append("frame sample missing" if frame is None else "frame P95 > 20 ms")
    elapsed = endpoint.get("seconds")
    # The first and last rendered samples can each trim a frame from the capture.
    trim = 2 * (stats(endpoint, "frame_ms", "p50") or 0) / 1000
    if elapsed is None or elapsed + trim < case["seconds"]:
        issues.append("capture missing or short")
    if case["mode"] in ("B", "C"):
        visible_feedback = FEEDBACK if case["windowed"] and not case["simple"] else FEEDBACK[:2]
        for metric in visible_feedback:
            value = stats(endpoint, metric)
            if value is None:
                issues.append(f"{metric} missing")
            elif value > 33:
                issues.append(f"{metric} P95 > 33 ms")
    if endpoint.get("pending_hits") != 0 or endpoint.get("rpc_backlog") != 0:
        issues.append("final queue pending or unknown")
    if len(pending) != 4 or any(value is None for value in pending):
        issues.append("queue samples missing")
    else:
        changes = [later - earlier for earlier, later in zip(pending, pending[1:])]
        if min(changes) >= 0 and sum(change > 0 for change in changes) >= 2:
            issues.append("increasing queue medians")
    return list(dict.fromkeys(issues))


def paired_feedback(ends):
    for metric in FEEDBACK:
        first, second = (stats(ends.get(role, {}), metric) for role in ROLES)
        if first is not None and second is not None and abs(first - second) > 1000 / 60:
            return False
    return True


def per_case(folder, cases, display_name):
    print(f"\n### {display_name}\n")
    print("| Mode / scene / target | Added RTT ms | Repeat | End | Measured RTT P50 ms | Seconds | Live / visible / owned P50 | Frame P50 / P95 / P99 ms | Move / attack / hit P95 ms | Local / remote receipt P95 ms | Pending quarter medians | TX / RX KiB/s | Observations |")
    print("| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    screened = defaultdict(dict)
    for case in cases:
        name = case["folder"]
        if name in (".", "..") or Path(name).name != name:
            raise ValueError(f"Invalid replay folder name: {name}")
        ends = case["ends"]
        complete = all(all(key in ends.get(role, {}) for key in LEDGER_FIELDS) for role in ROLES)
        ledger = complete and all(ends["host"][key] == ends["guest"][key] for key in LEDGER_FIELDS)
        feedback_gap = case["mode"] in ("B", "C") and not paired_feedback(ends)
        passed = True
        for role in ROLES:
            endpoint = ends.get(role, {})
            pending = pending_quarters(folder / name / f"{role}.csv")
            issues = failures(case, endpoint, pending)
            if not ledger:
                issues.append("ledger missing or divergent")
            if feedback_gap:
                issues.append("paired feedback gap > one frame")
            passed = passed and not issues
            metrics = (
                " / ".join(number(stats(endpoint, key, "p50"), 0) for key in ("population", "visible", "owned")),
                " / ".join(number(stats(endpoint, "frame_ms", p)) for p in ("p50", "p95", "p99")),
                " / ".join(number(stats(endpoint, key)) for key in FEEDBACK),
                " / ".join(number(stats(endpoint, key)) for key in ("local_confirmation_ms", "remote_confirmation_ms")),
                " / ".join(number(value) for value in pending) or "—",
                " / ".join(number(endpoint[key] / 1024 if key in endpoint else None)
                           for key in ("tcp_tx_bytes_s", "tcp_rx_bytes_s")),
            )
            rtt = number(stats(endpoint, "rtt_ms", "p50")) if role == "guest" else "—"
            print(f'| {case["mode"]} / {case["scenario"]} / {case["size"]} | {case["delay"]} | {case["rep"]} | {role} '
                  f'| {rtt} | {number(endpoint.get("seconds"))} '
                  f'| {" | ".join(metrics)} | {", ".join(issues) or "within endpoint budgets"} |')
        if case["mode"] in ("B", "C"):
            key = (*setting(case), case["mode"])
            live = [stats(ends.get(role, {}), "population", "p50") for role in ROLES]
            paired_live = min(live) if all(value is not None for value in live) else None
            screened[key][case["rep"]] = (passed, paired_live)
    print("\n#### Paired windowed budget screen\n")
    groups = defaultdict(dict)
    for (*config, mode), results in screened.items():
        scene, size, delay, seconds, warmup, windowed, simple = config
        if windowed and not simple:
            groups[(mode, scene, delay, seconds, warmup)][size] = results
    if not groups:
        print("No B/C case with full windowed rendering.")
        return
    print("| Mode / scenario | Added RTT ms | Warm-up / capture s | Highest repeated passing target / minimum recorded live P50 | Passing / observed by target |")
    print("| --- | ---: | ---: | ---: | --- |")
    for (mode, scene, delay, seconds, warmup), by_size in sorted(groups.items()):
        sustained = seconds >= CAPACITY_CAPTURE_SECONDS and warmup >= CAPACITY_WARMUP_SECONDS
        passed_sizes = [size for size, runs in by_size.items() if sustained and len(runs) >= CAPACITY_REPEATS
                        and all(passed and live is not None for passed, live in runs.values())]
        counts = ", ".join(f"{size}: {sum(passed and live is not None for passed, live in runs.values())}/{len(runs)}"
                           for size, runs in sorted(by_size.items()))
        highest = "—"
        if passed_sizes:
            size = max(passed_sizes)
            highest = f"{size} / {number(min(live for _, live in by_size[size].values()), 0)}"
        print(f"| {mode} / {scene} | {delay} | {warmup} / {seconds} | {highest} | {counts} |")


def comparison(cases):
    by_setting = defaultdict(lambda: defaultdict(list))
    for case in cases:
        if not case["failures"] and all(role in case["ends"] for role in ROLES):
            by_setting[setting(case)][case["mode"]].append(case["ends"])
    items = [(key, modes) for key, modes in sorted(by_setting.items()) if len(modes) >= 2]
    if not items:
        return
    print("\n#### Matched mode deltas per direction\n")
    print("| Scene / target | Added RTT ms | Warm-up / capture s | Display | A → B guest move P95 ms | B → C host AI ms/s | B → C guest AI ms/s | B → C guest TX KiB/s | B → C guest remote receipt P95 ms |")
    print("| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |")
    for (scene, size, delay, seconds, warmup, windowed, simple), modes in items:
        def delta(first, second, side, metric, stat=None, divisor=1):
            samples = []
            for mode in (first, second):
                values = [stats(ends[side], metric, stat) if stat else ends[side].get(metric)
                          for ends in modes.get(mode, [])]
                values = [value for value in values if value is not None]
                if not values:
                    return "—"
                samples.append(median(values))
            return f"{(samples[1] - samples[0]) / divisor:+.1f}"
        values = [delta("A", "B", "guest", "move_ms", "p95"),
                  delta("B", "C", "host", "ai_per_sec", divisor=1000),
                  delta("B", "C", "guest", "ai_per_sec", divisor=1000),
                  delta("B", "C", "guest", "tcp_tx_bytes_s", divisor=1024),
                  delta("B", "C", "guest", "remote_confirmation_ms", "p95")]
        display = "headless" if not windowed else ("simple" if simple else "full")
        print(f"| {scene} / {size} | {delay} | {warmup} / {seconds} | {display} | {' | '.join(values)} |")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("archive", type=Path, help="LAN host output directory")
    cli.add_argument("swapped", nargs="?", type=Path, help="Host output directory after swapping machines")
    args = cli.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    folders = [folder.resolve() for folder in (args.archive, args.swapped) if folder is not None]
    try:
        archives = [load_archive(folder) for folder in folders]
        keys = [{replay_key(case) for case in archive[1]} for archive in archives]
        for folder, archive, unique in zip(folders, archives, keys, strict=True):
            if len(unique) != len(archive[1]):
                raise ValueError(f"Duplicate replay configuration and repeat number in {folder}")
        if len(archives) == 2:
            first, second = archives
            if (first[0]["topology"] != "two-windows-installations"
                    or second[0]["topology"] != "two-windows-installations" or first[2] != second[2][::-1]):
                raise ValueError("The reports must be from the same two distinct installations with reversed roles")
            if first[0]["build"] != second[0]["build"]:
                raise ValueError("Role-swapped reports have different builds")
    except (KeyError, OSError, ValueError) as error:
        cli.error(str(error))
    print("# LAN capacity evidence\n")
    print(f"A repeated passing target requires at least {CAPACITY_REPEATS} distinct passing repetitions, "
          f"{CAPACITY_WARMUP_SECONDS} s warm-up, and {CAPACITY_CAPTURE_SECONDS} s capture. "
          "The table retains gaps and short runs for inspection. "
          "Pending medians use four equal simulation-time bins. Mode deltas use per-replay medians "
          "and should be checked against live density in the underlying endpoints. B/C screening also requires "
          "the two feedback P95 values for each measured metric to be within one 60 Hz frame.\n")
    if len(keys) == 2:
        forward, reverse = keys
        print(f"Role-swap coverage: {len(forward & reverse)} shared replay settings/repetitions, "
              f"{len(forward - reverse)} only in {folders[0].name}, "
              f"{len(reverse - forward)} only in {folders[1].name}.\n")
    for folder, (header, cases, _) in zip(folders, archives, strict=True):
        host, guest = (header[role]["label"] for role in ROLES)
        print(f'## {folder.name}\n\n{header["topology"]} · {host} (host) / {guest} (guest)')
        for role in ROLES:
            hardware = header[role]
            sample = next((case["ends"][role] for case in cases if role in case["ends"]), {})
            print(f'- {role} · {hardware["cpu"]} · {sample.get("adapter") or "GPU not recorded"} · {hardware["os"]}')
        print(f'- Build: Godot {header["build"]["godot"]} · SDK {header["build"]["sdk"]}')
        displays = {(
            endpoint.get("display"), endpoint.get("renderer"), tuple(endpoint.get("window_size", [])),
            endpoint.get("max_fps"), endpoint.get("physics_hz"),
        ) for case in cases for endpoint in case["ends"].values() if endpoint.get("display")}
        for display, renderer, size, fps, physics in sorted(displays):
            viewport = "×".join(map(str, size)) if size else "size missing"
            print(f"- Display: {display} · {renderer} · {viewport} · {fps} FPS cap · physics {physics} Hz")
        per_case(folder, cases, "Per-replay measurements")
        comparison(cases)


if __name__ == "__main__":
    main()
