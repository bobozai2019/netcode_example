"""Install the local Fusion Preview SDK's Windows extension for Sync Lab."""

import hashlib
import os
from pathlib import Path
import shutil
import sys


PROJECT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT.parent / "tools"))
from artifacts import item_at

DEFAULT = PROJECT.parents[1] / "references/photon/photon-fusion-godot-starter-kit-racing_3.0.0/addons/fusion"
FILES = (
    "fusion.gdextension",
    "fusion.gdextension.uid",
    "LICENSE.txt",
    "THIRD_PARTY_NOTICES.txt",
    "bin/libfusion.windows.editor.x86_64.release.dll",
    "bin/libfusion.windows.template_debug.x86_64.release.dll",
    "bin/libfusion.windows.template_release.x86_64.release.dll",
)


def install():
    source = Path(os.environ.get("NETCODE_FUSION_ADDON") or DEFAULT)
    for name in FILES:
        if not (source / name).is_file():
            raise FileNotFoundError(f"Missing Fusion SDK file {name}. Set NETCODE_FUSION_ADDON to the SDK's fusion folder.")
    for name in FILES:
        original = source / name
        destination = item_at(PROJECT, Path("addons/fusion") / name)
        data = original.read_bytes()
        if destination.is_file() and destination.read_bytes() == data:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, destination)
        if hashlib.sha256(destination.read_bytes()).digest() != hashlib.sha256(data).digest():
            raise OSError(f"Fusion file verification failed: {name}")
    print(PROJECT / "addons/fusion/fusion.gdextension", flush=True)


if __name__ == "__main__":
    install()
