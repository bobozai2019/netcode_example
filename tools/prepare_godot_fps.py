"""Install the verified Netcode addon and import the standalone FPS project."""
import argparse
import hashlib
from pathlib import Path
from zipfile import ZipFile

from artifacts import ROOT, budget, item_at
from godot_build import REPO, import_project, resolve_godot
from sdk_inputs import release_archive


SOURCE = REPO / "shiftline"


def prepare(project, godot, addon=None, import_assets=True):
    addon = addon or release_archive("godot")
    if not (project / "project.godot").is_file():
        raise FileNotFoundError(f"Missing Godot project: {project}")
    with addon.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = addon.parent / "SHA256SUMS.txt"
    if manifest.is_file() and [digest, addon.name] not in [line.split(maxsplit=1) for line in manifest.read_text(encoding="ascii").splitlines()]:
        raise ValueError(f"Addon SHA-256 mismatch: {addon}")
    with ZipFile(addon) as archive:
        if archive.testzip() is not None:
            raise ValueError(f"Addon CRC mismatch: {addon}")
        for member in archive.infolist():
            relative = Path(member.filename)
            if relative.parts[:2] != ("addons", "netcode") or len(relative.parts) < 3:
                raise ValueError(f"Unexpected addon entry: {member.filename}")
            item_at(project, relative)
        archive.extractall(project)
    if import_assets:
        import_project(godot, project)
    print(f"FPS project: {project} | addon SHA-256: {digest}", flush=True)
    return digest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=SOURCE)
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--addon", type=Path, default=None)
    parser.add_argument("--no-import", action="store_true", help="Install into a project with no imported assets")
    args = parser.parse_args()
    if not budget(ROOT, 64 * 1024**2)["allowed"]:
        raise SystemExit("Output budget exceeded")
    prepare(args.project.resolve(), resolve_godot(args.godot_exe), args.addon.resolve() if args.addon else None,
            import_assets=not args.no_import)
