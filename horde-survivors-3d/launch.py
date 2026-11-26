
"""Prepare the bundled Godot SDK and project assets, then open the lobby."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent
EXAMPLES = PROJECT.parent
sys.path.insert(0, str(EXAMPLES / "tools"))

from artifacts import ROOT, budget
from godot_build import import_project, resolve_godot

SDK_FILES = (
    "build-id.txt", "netcode.gdextension", "LICENSE.godot-cpp.txt",
    "bin/netcode_godot.dll", "bin/netcode_transport_tcp.dll",
)

def game_godot(requested=None):
    bundled = EXAMPLES / "sync-lab/runtime/godot-4.6.1/Godot_v4.6.1-stable_win64.exe"
    location = requested or os.environ.get("NETCODE_GODOT_EXE")
    return resolve_godot(location or (bundled if bundled.is_file() else None))


def prepare(godot, sdk=None):
    if not budget(ROOT, 96 * 1024**2)["allowed"]:
        raise RuntimeError("Example output budget exceeded")
    addon = PROJECT / "addons/netcode"
    if sdk is not None or not all((addon / name).is_file() for name in SDK_FILES):
        installed = EXAMPLES.parent / "netcode/out/install/win-x64-msvc-mt/Release/godot/addons/netcode"
        source = sdk or (installed if installed.is_dir() else EXAMPLES / "sync-lab/addons/netcode")
        missing = next((source / name for name in SDK_FILES if not (source / name).is_file()), None)
        if missing is not None:
            raise FileNotFoundError(f"SDK file missing: {missing}. Pass --sdk with the native addons/netcode directory.")
        for name in SDK_FILES:
            origin = source / name
            target = addon / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or target.read_bytes() != origin.read_bytes():
                shutil.copy2(origin, target)
    asset = json.loads((PROJECT / "assets/sources.json").read_text(encoding="utf-8"))["files"][0]
    model_path = PROJECT / "assets" / asset["file"]
    # Git can check out the glTF JSON with CRLF on Windows.
    model = model_path.read_bytes().replace(b"\r\n", b"\n")
    if hashlib.sha256(model).hexdigest() != asset["sha256"]:
        raise ValueError(f"Unexpected bundled asset SHA-256: {model_path}")
    import_project(godot, PROJECT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--pair", action="store_true", help="Open two independent lobby windows")
    args = parser.parse_args()
    godot = game_godot(args.godot_exe)
    prepare(godot, args.sdk)
    if args.prepare_only:
        return
    for index in range(2 if args.pair else 1):
        window = ["--resolution", "840x472", "--position", f"{45 + index * 850},95"] if args.pair else []
        subprocess.Popen([str(godot), "--path", str(PROJECT), *window])


if __name__ == "__main__":
    main()
