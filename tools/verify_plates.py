"""Play the same two-person puzzle on Cocos, Godot and Unity with rotating hosts."""

import argparse
from contextlib import ExitStack
import json

from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from godot_build import GODOT_PROJECT, resolve_godot
from unity_build import UNITY_PLAYER
from verify_yard import BUILD, Process, require, values


def play(output, host, port, forecast=False):
    engines = ["cocos", "godot", "unity"]
    start = engines.index(host)
    engines = engines[start:] + engines[:start]
    with ExitStack() as stack:
        clients = {}
        for index, engine in enumerate(engines):
            args = [
                "--puzzle-host" if index == 0 else "--puzzle-join",
                "--puzzle-auto",
                "--port",
                str(port),
            ]
            if forecast:
                args.append("--forecast3d" if forecast == 3 else "--forecast")
            if engine == "cocos":
                exe = BUILD / "netcode-puzzle-cocos.exe"
                args = ["--headless", *args]
            elif engine == "unity":
                exe = UNITY_PLAYER
                args = ["-batchmode", "-nographics", "-logFile", "-", "--", *args]
            else:
                exe = resolve_godot()
                args = [
                    "--headless",
                    "--path",
                    str(GODOT_PROJECT),
                    "res://verification/physics/forecast3d.tscn" if forecast == 3 else "res://verification/physics/forecast.tscn" if forecast else "res://verification/plates/plates.tscn",
                    "--",
                    *args,
                ]
            client = Process(output, host + "-" + engine, exe, args)
            stack.callback(client.close)
            client.await_line(
                ("forecast_open" if forecast else "puzzle_open") + " engine=" + engine, seconds=40
            )
            clients[engine] = client
        if forecast:
            results = {
                engine: values(p.await_line("forecast_pass engine=" + engine, seconds=30))
                for engine, p in clients.items()
            }
            final = [v["final_mm"] for v in results.values()]
            require(min(final) > 8000 and max(final) - min(final) < 200, "proxy resting pose diverged")
            for index in range(4):
                points = {e: values(proc.await_line(f"forecast_point index={index} "))["x_mm"] for e,proc in clients.items()}
                for engine, position in points.items():
                    error = abs(position-points[host])
                    require(error < 750, f"{engine} trajectory diverged at sample {index}: {points}")
                    results[engine]["max_sample_error_mm"] = max(error,results[engine].get("max_sample_error_mm",0))
            if forecast == 3:
                for field,minimum,tolerance in (("depth_mm",2000,100),("heading_mrad",700,100)):
                    samples = [entry[field] for entry in results.values()]
                    require(min(samples)>minimum and max(samples)-min(samples)<tolerance, "3D axis or orientation divergence")
            return results
        results = {
            engine: values(p.await_line("puzzle_solved engine=" + engine, seconds=30))
            for engine, p in clients.items()
        }
        require({entry["player"] for entry in results.values()} == {1, 2, 3}, "missing participant")
        require(
            results[host]["player"] == 1
            and all(r["first"] == 2 and r["second"] == 3 for r in results.values()),
            "inconsistent writers",
        )
        for player, obj, value in ((2, 1, 3), (3, 2, 7)):
            clients[host].await_line(f"plate_action player={player} object={obj} value={value}")
        for engine, process in clients.items():
            for marker in ("map_mounted scene=1 generation=1 anchors=1", "map_cancel scene=2 generation=2",
                           "map_mounted scene=2 generation=4 anchors=1", "map_removed scene=2 generation=4"):
                process.await_line(marker)
                require(sum(marker in line for line in process.lines) == 1, "repeated map lifecycle callback")
            require(all("map_mounted scene=2 generation=2 " not in line for line in process.lines), "stale map mounted")
            if results[engine]["player"] != 1:
                process.await_line(f"plate_ack token={results[engine]['player']-1} player=1")
            process.await_line("charge_confirmed value=5")
            if results[engine]["player"] == 2:
                process.await_line("charge_predicted value=5")
                process.await_line("charge_ack sequence=1")
        timestamps = []
        for engine, p in clients.items():
            line = p.await_line("countdown_reached")
            clock = values(line)
            require(
                clock["deadline_ms"] == 3200 and 3200 <= clock["observed_ms"] < 3450,
                "clock missed deadline",
            )
            timestamps.append(p.timestamps[p.lines.index(line)])
        spread = round((max(timestamps) - min(timestamps)) * 1000)
        require(spread < 250, "engine countdowns did not fire together")
        return {"players": results, "deadline_ms": 3200, "wall_spread_ms": spread}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=43470)
    parser.add_argument("--host", choices=["all", "cocos", "godot", "unity"], default="all")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--forecast", action="store_true")
    modes.add_argument("--forecast3d", action="store_true")
    args = parser.parse_args()
    if not budget(ROOT, 32 * 1024**2)["allowed"]:
        raise RuntimeError("Insufficient artifact space")
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            hosts = ["cocos", "godot", "unity"] if args.host == "all" else [args.host]
            summary = {h: play(output, h, args.port + i, 3 if args.forecast3d else args.forecast) for i, h in enumerate(hosts)}
            content = json.dumps(summary, indent=2)
            (output / "metrics.json").write_text(content, encoding="utf-8")
            print(content)
            ok = True
        except Exception as e:
            (output / "failure.txt").write_text(str(e), encoding="utf-8")
            print(e)
    print("Run evidence", rotate_run(ROOT, ok))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
