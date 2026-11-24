"""Exercise the default racing UI with two independent Godot processes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import socket
import subprocess

from artifacts import ROOT, budget, create_job, job_lock, remove_owned
from godot_build import REPO, import_project, resolve_godot
from prepare_godot_fps import prepare


def play(project, work):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    # Launch the ordinary project main scene. The probe only drives its buttons and input.
    command = [resolve_godot(), "--headless", "--path"]
    peers = {}
    readers = ThreadPoolExecutor(max_workers=2)
    try:
        outputs = {}
        for role in ("host", "guest"):
            peers[role] = subprocess.Popen([*command, project, "--log-file", work / (role + ".log")],
                env=dict(os.environ, NETCODE_RACING_ROLE=role, NETCODE_RACING_PORT=str(port)),
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), text=True, encoding="utf-8", errors="replace")
            if role == "host":
                def await_open():
                    for line in peers["host"].stdout:
                        print(line, end="", flush=True)
                        if line.startswith("racing_open role=host"): return
                    raise RuntimeError("Host exited before opening its room")
                readers.submit(await_open).result(timeout=15)
            outputs[role] = readers.submit(peers[role].stdout.read)
        failures = []
        for role, peer in peers.items():
            output = outputs[role].result(timeout=35)
            print(output, end="")
            if peer.wait(timeout=5) or "ERROR:" in output or "racing_pass " + role not in output:
                failures.append(role)
        if failures:
            raise RuntimeError("Racing verification failed on " + ", ".join(failures))
    finally:
        for peer in peers.values():
            if peer.poll() is None:
                peer.kill()
                peer.wait()
        readers.shutdown()



def verify(source, addon=None):
    if not budget(ROOT, 32 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    work = create_job(ROOT, "tmp/verify-racing", "temp")
    try:
        with job_lock(work, "temp"):
            project = work / "project"
            project.mkdir()
            shutil.copytree(source / "addons", project / "addons", ignore=shutil.ignore_patterns("netcode") if addon else None)
            shutil.copytree(source / "racing", project / "racing")
            shutil.copyfile(REPO / "tests/godot/racing_probe.gd", project / "probe.gd")
            settings = (source / "project.godot").read_text(encoding="utf-8")
            (project / "project.godot").write_text(settings + '\n[autoload]\nProbe="*res://probe.gd"\n', encoding="utf-8")
            if addon:
                prepare(project, resolve_godot(), addon)
            else:
                import_project(resolve_godot(), project)
            play(project, work)
    finally:
        remove_owned(ROOT, work, "temp")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=REPO / "yard/godot")
    parser.add_argument("--addon", type=Path, help="Verify a candidate addon ZIP in the isolated project")
    args = parser.parse_args()
    verify(args.project.resolve(), args.addon)
