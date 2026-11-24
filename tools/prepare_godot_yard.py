"""Refresh the two installed addons in the editable Godot yard from its build."""
import argparse
import hashlib
from pathlib import Path
import shutil

from godot_build import GODOT_PROJECT, REPO, import_project, resolve_godot


def sync(source, destination):
    for name in ("netcode", "yard"):
        src = source / "addons" / name
        if not src.is_dir() or not any((src / "bin").glob("*.dll")):
            raise FileNotFoundError(f"Build the Godot yard first. Missing {src}")
        for file in src.rglob("*"):
            if not file.is_file() or file.name.startswith("~"):
                continue
            target = destination / "addons" / name / file.relative_to(src)
            if target.is_file() and hashlib.sha256(target.read_bytes()).digest() == hashlib.sha256(file.read_bytes()).digest():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-project", type=Path, default=GODOT_PROJECT)
    args = parser.parse_args()
    project = REPO / "yard/godot"
    sync(args.build_project, project)
    import_project(resolve_godot(), project)
