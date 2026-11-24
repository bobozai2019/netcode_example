"""Assemble the Unity car yard project and build its Windows player."""

import os
from pathlib import Path
import shutil
import subprocess

from artifacts import ROOT, item_at


REPO = ROOT.parent
UNITY_VERSION = "6000.4.0f1"
UNITY_PLAYER = ROOT / "build/win-x64/Release/bin/Release/unity/netcode-unity.exe"


def resolve_unity(requested=None):
    default = Path(os.environ["ProgramFiles"]) / f"Unity/Hub/Editor/{UNITY_VERSION}/Editor/Unity.exe"
    location = Path(requested or os.environ.get("NETCODE_UNITY_EXE") or shutil.which("Unity") or default).resolve()
    if not location.is_file():
        raise FileNotFoundError("Set NETCODE_UNITY_EXE or use --unity-exe with the Windows Unity Editor")
    return location


def build_unity_player(editor, build, steam_sdk=None, unity_sdk=None):
    source = REPO / "yard/unity"
    project = item_at(build, "unity-project")
    project.mkdir(exist_ok=True)
    for directory in ("Assets", "Packages"):
        shutil.copytree(source / directory, project / directory, dirs_exist_ok=True)
    import json
    manifest_path = project / "Packages/manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["dependencies"]["com.netcode.runtime"] = "file:" + Path(unity_sdk).resolve().as_posix()
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    for directory in ("Assets/Plugins/x86_64", "Assets/StreamingAssets", "Assets/Resources", "ProjectSettings"):
        item_at(project, directory).mkdir(parents=True, exist_ok=True)
    if not (project / "ProjectSettings/ProjectVersion.txt").exists():
        (project / "ProjectSettings/ProjectVersion.txt").write_text(
            f"m_EditorVersion: {UNITY_VERSION}\n", encoding="utf-8"
        )
    plugin = item_at(project, "Assets/Plugins/x86_64/netcode_yard_unity.dll")
    shutil.copy2(item_at(build, "bin/Release/netcode_yard_unity.dll"), plugin)
    steam_dll = item_at(project, "Assets/Plugins/x86_64/steam_api64.dll")
    if steam_sdk:
        shutil.copy2(item_at(build, "bin/Release/steam_api64.dll"), steam_dll)
    else:
        steam_dll.unlink(missing_ok=True)
        steam_dll.with_suffix(".dll.meta").unlink(missing_ok=True)
    shutil.copy2(REPO / "yard/shared/replicators.cfg", project / "Assets/StreamingAssets/replicators.cfg")
    shutil.copy2(REPO / "puzzle/components.cfg", project / "Assets/StreamingAssets/components.cfg")
    shutil.copy2(REPO / "puzzle/island.cfg", project / "Assets/StreamingAssets/island.cfg")
    shutil.copy2(REPO / "puzzle/body3d.cfg", project / "Assets/StreamingAssets/body3d.cfg")
    shutil.copy2(REPO / "puzzle/body.cfg", project / "Assets/StreamingAssets/body.cfg")
    shutil.copy2(REPO / "puzzle/plates.cfg", project / "Assets/StreamingAssets/plates.cfg")
    shutil.copy2(REPO / "yard/shared/beacon.obj", project / "Assets/Resources/beacon.obj")

    player = item_at(build, "bin/Release/unity/netcode-unity.exe")
    log = item_at(build, "unity-editor.log")
    print(f"Building Unity Windows player. Editor log: {log}", flush=True)
    outcome = subprocess.run(
        [editor, "-batchmode", "-nographics", "-quit", "-projectPath", project,
         "-buildTarget", "Win64", "-executeMethod", "YardBuild.Windows", "-yardOutput", player, "-logFile", log],
        cwd=REPO, timeout=900, creationflags=subprocess.CREATE_NO_WINDOW,
    )
    content = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
    if outcome.returncode or "netcode_unity_build_ok" not in content or not player.is_file():
        print("\n".join(content.splitlines()[-75:]), flush=True)
        raise RuntimeError(f"Unity player build failed (exit {outcome.returncode}). See {log}")
    print(f"Unity Windows player: {player}", flush=True)
