"""Run a Godot host, a claimant and a late joiner using declarative scene replication."""
import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import shutil

from artifacts import ROOT, budget, create_job, job_lock, remove_owned, rotate_run
from godot_build import GODOT_PROJECT, REPO, resolve_godot
from prepare_godot_fps import prepare
from verify_yard import Process, require, values


def play(output, port, project):
    with ExitStack() as stack:
        peers = []
        for player in (1, 2, 3):
            if player == 3:
                peers[0].await_line("scene_seeded", seconds=15)
            args = ["--headless", "--path", str(project), "res://verification/sync/scene_controls.tscn",
                    "--", "--host" if player == 1 else "--join", "--port", str(port)]
            peer = Process(output, f"godot-{player}", resolve_godot(), args)
            stack.callback(peer.close)
            peer.await_line("scene_open", seconds=20)
            peers.append(peer)
        results = []
        for player, peer in enumerate(peers, 1):
            row = values(peer.await_line("scene_pass", seconds=35))
            require(row == {"player": player, "score": 42}, f"Unexpected final state {row}")
            require(peer.proc.wait(timeout=6) == 0, "Godot player failed")
            peer.thread.join(timeout=2)
            require(not any("ERROR:" in line for line in peer.lines), f"Godot reported an error for player {player}")
            results.append(row)
        return results


def verify(output, port, addon):
    if not addon:
        return play(output, port, GODOT_PROJECT)
    project = create_job(ROOT, "tmp/verify-scene-addon", "temp")
    try:
        with job_lock(project, "temp"):
            shutil.copytree(REPO / "puzzle/godot/sync", project / "verification/sync")
            (project / "sync").mkdir()
            shutil.copy2(REPO / "yard/godot/sync/panel_stats.gd", project / "sync")
            (project / "project.godot").write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
            prepare(project, resolve_godot(), addon)
            return play(output, port, project)
    finally:
        remove_owned(ROOT, project, "temp")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=43780)
    parser.add_argument("--addon", type=Path, help="Verify a candidate addon ZIP in an isolated puzzle project")
    args = parser.parse_args()
    if not budget(ROOT, 32 * 1024**2)["allowed"]:
        raise RuntimeError("Run output budget exceeded")
    output = create_job(ROOT, "runs/current", "run")
    ok = False
    with job_lock(output, "run"):
        try:
            result = json.dumps(verify(output, args.port, args.addon), indent=2)
            (output / "metrics.json").write_text(result, encoding="utf-8")
            print(result)
            ok = True
        except Exception as exc:
            (output / "failure.txt").write_text(str(exc), encoding="utf-8")
            print(exc)
    print("Run evidence", rotate_run(ROOT, ok))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
