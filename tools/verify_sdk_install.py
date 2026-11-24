"""Install a pinned Godot or Unity release into a temporary external project, export it and run two players."""
import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from godot_build import console_godot, import_project, resolve_godot
from sdk_inputs import EXAMPLES, release_archive
from unity_build import resolve_unity, UNITY_VERSION
from verify_yard import Process


def godot_project(work, archive):
    project = work / "project"
    project.mkdir()
    with ZipFile(archive) as z:
        z.extractall(project)
    expected = (project / "addons/netcode/build-id.txt").read_text().strip()
    sources = EXAMPLES / "puzzle/godot/components"
    shutil.copytree(sources, project / "verification/components")
    shutil.copy2(EXAMPLES / "puzzle/components.cfg", project / "components.cfg")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="SDK Consumer"\n'
        'run/main_scene="res://verification/components/components.tscn"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8")
    preset = (EXAMPLES / "yard/godot/export_presets.cfg").read_text(encoding="utf-8")
    (project / "export_presets.cfg").write_text(preset.replace('include_filter="replicators.cfg"', 'include_filter="components.cfg"'), encoding="utf-8")
    editor = resolve_godot()
    import_project(editor, project)
    player = work / "player/Consumer.exe"
    player.parent.mkdir()
    subprocess.run([console_godot(editor), "--headless", "--path", project, "--export-release", "Windows Desktop", player], check=True, timeout=180)
    return player, ["--headless", "--"], expected


def unity_project(work, archive):
    project = work / "project"
    assets = project / "Assets"
    for folder in (assets / "Editor", assets / "StreamingAssets", project / "Packages", project / "ProjectSettings"):
        folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(EXAMPLES / "yard/unity/Assets/GameplayComponents.cs", assets)
    shutil.copy2(EXAMPLES / "tests/consumers/UnitySdkBuild.cs", assets / "Editor")
    shutil.copy2(EXAMPLES / "puzzle/components.cfg", assets / "StreamingAssets")
    local = work / archive.name
    shutil.copy2(archive, local)
    with tarfile.open(local) as t:
        expected = t.extractfile("package/build-id.txt").read().decode().strip()
    manifest = json.loads((EXAMPLES / "yard/unity/Packages/manifest.json").read_text(encoding="utf-8"))
    manifest["dependencies"]["com.netcode.runtime"] = "file:" + local.as_posix()
    (project / "Packages/manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    (project / "ProjectSettings/ProjectVersion.txt").write_text(f"m_EditorVersion: {UNITY_VERSION}\n", encoding="utf-8")
    player = work / "player/Consumer.exe"
    player.parent.mkdir()
    log = work / "editor.log"
    result = subprocess.run([resolve_unity(), "-batchmode", "-nographics", "-quit", "-projectPath", project,
                             "-buildTarget", "Win64", "-executeMethod", "UnitySdkBuild.Export",
                             "-sdkOutput", player, "-logFile", log], timeout=900)
    if result.returncode or not player.is_file():
        print(log.read_text(encoding="utf-8", errors="replace")[-9000:])
        raise RuntimeError(f"Unity export failed ({result.returncode})")
    return player, ["-batchmode", "-nographics", "-logFile", "-", "--"], expected


def test(engine, work, archive=None):
    archive = archive or release_archive(engine)
    player, args, expected = (godot_project if engine == "godot" else unity_project)(work, archive)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with ExitStack() as clean:
        players = []
        for role in ("host", "guest"):
            peer = Process(work, role, player, [*args, "--puzzle-" + role, "--components", "--port", str(port)])
            clean.callback(peer.close)
            players.append(peer)
            peer.await_line("sdk_build_id=" + expected, seconds=45)
            peer.await_line("components_open", seconds=20)
        for role, peer in zip(("host", "guest"), players):
            peer.await_line(f"components_pass role={role} score=42 fields=8", seconds=40)
            if peer.proc.wait(timeout=15) != 0:
                raise RuntimeError(f"{role} exited unsuccessfully")
    print(f"PASS {engine} exported players: {expected}, score=42, fields=8, bidirectional RPC", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", choices=["godot", "unity"])
    parser.add_argument("--archive", type=Path, help="Verify this candidate package before updating the SDK lock")
    args = parser.parse_args()
    with TemporaryDirectory(prefix=f"netcode-consumer-{args.engine}-", ignore_cleanup_errors=True) as scratch:
        test(args.engine, Path(scratch), args.archive)
