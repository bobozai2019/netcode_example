"""Check typed gameplay fields, named RPCs and mounted replicas in two real players per engine."""
import argparse
from contextlib import ExitStack
import json
import re
from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from godot_build import GODOT_PROJECT, resolve_godot
from unity_build import UNITY_PLAYER
from verify_yard import BUILD, Process, require


def play(output, engine, port):
    with ExitStack() as stack:
        peers = {}
        for role in ("host", "guest"):
            args = ["--puzzle-host" if role == "host" else "--puzzle-join", "--components", "--port", str(port)]
            if engine == "godot":
                exe = resolve_godot()
                args = ["--headless", "--path", str(GODOT_PROJECT), "res://verification/components/components.tscn", "--", *args]
            elif engine == "unity":
                exe = UNITY_PLAYER
                args = ["-batchmode", "-nographics", "-logFile", "-", "--", *args]
            else:
                exe = BUILD / "netcode-puzzle-cocos.exe"
                args = ["--headless", *args]
            peer = Process(output, f"{engine}-{role}", exe, args)
            stack.callback(peer.close)
            peer.await_line("components_open", seconds=40)
            peers[role] = peer
        result = {}
        for role, peer in peers.items():
            line = peer.await_line(f"components_pass role={role}", seconds=25)
            row = {key: int(value) for key, value in re.findall(r"\b([a-z][a-z0-9_]*)=(\d+)\b", line)}
            expected = {"score": 42, "fields": 8, "body": 1, "body3d": 1, "reference": 1, "typed": 1}
            require(all(row.get(key) == value for key, value in expected.items()), "Incomplete component results")
            result[role] = row
        for peer in peers.values():
            require(peer.proc.wait(timeout=10) == 0, "Player failed")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=["all", "godot", "unity", "cocos"], default="all")
    parser.add_argument("--port", type=int, default=43710)
    args = parser.parse_args()
    if not budget(ROOT, 32 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            engines = ["godot", "unity", "cocos"] if args.engine == "all" else [args.engine]
            results = {engine: play(output, engine, args.port + i) for i, engine in enumerate(engines)}
            content = json.dumps(results, indent=2)
            (output / "metrics.json").write_text(content, encoding="utf-8")
            print(content)
            ok = True
        except Exception as exc:
            (output / "failure.txt").write_text(str(exc), encoding="utf-8")
            print(exc)
    print("Run evidence",rotate_run(ROOT, ok))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
