"""Run a three-term game through public Unity C# and Godot script bindings on loopback."""
import argparse
from contextlib import ExitStack
import json
from artifacts import ROOT, budget, create_job, job_lock, rotate_run
from godot_build import GODOT_PROJECT, resolve_godot
from unity_build import UNITY_PLAYER
from verify_yard import Process, require, values


def chain(output, first, port):
    other = "unity" if first == "godot" else "godot"
    with ExitStack() as stack:
        peers = []
        for i, engine in enumerate((first, other, first), 1):
            args = ["--puzzle-host" if i == 1 else "--puzzle-join", "--script-handoff", "--port", str(port)]
            if engine == "unity":
                exe = UNITY_PLAYER
                args = ["-batchmode", "-nographics", "-logFile", "-", "--", *args]
            else:
                exe = resolve_godot()
                args = ["--headless", "--path", str(GODOT_PROJECT), "res://verification/handoff/handoff.tscn", "--", *args]
            peer = Process(output, f"{first}-{i}-{engine}", exe, args)
            stack.callback(peer.close)
            peer.await_line("handoff_open", seconds=40)
            peer.await_line(f"handoff_member player={i}", seconds=20)
            peers.append(peer)
        host, promoted, survivor = peers
        checkpoint = values(promoted.await_line("standby_current tick="))["tick"]
        survivor.await_line("first_value=77")
        host.proc.kill()
        host.proc.wait(timeout=5)
        promoted.await_line("restored=77 written=88")
        survivor.await_line("resumed_rpc=88")
        survivor.await_line("restored=89 written=90")
        promoted.await_line("handoff_retired")
        require(all(p.proc.wait(timeout=10) == 0 for p in peers[1:]), "surviving script process failed")
        return {"coordinators": [first, other, first], "checkpoint_tick": checkpoint, "values": [77,88,89,90]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=43610)
    args = parser.parse_args()
    if not budget(ROOT, 32 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            results = [chain(output, "unity", args.port), chain(output, "godot", args.port+3)]
            content = json.dumps(results, indent=2)
            (output / "metrics.json").write_text(content, encoding="utf-8")
            print(content)
            ok = True
        except Exception as exc:
            (output / "failure.txt").write_text(str(exc), encoding="utf-8")
            print(exc)
    print("Run evidence", rotate_run(ROOT, ok))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
