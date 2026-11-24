"""Export, smoke-test and rotate the Windows x64 Shiftline package."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
from zipfile import ZipFile

from artifacts import ROOT, budget, create_job, job_lock, remove_owned
from godot_build import console_godot, resolve_godot
from package_godot import godot_command
from package_yard import archive_payload, publish, slot_digest
from prepare_godot_fps import SOURCE, prepare


SLOT = Path("packages/godot-fps-win-x64")
PACKAGE = "shiftline-win-x64.zip"
GAME = "Shiftline.exe"


def assemble(work, godot):
    project = work / "project"
    shutil.copytree(SOURCE, project, ignore=shutil.ignore_patterns(
        ".godot", "addons", "source", "Barrier_Fixed_Fence.png*", "arms_arm_albedo_pale.png*"))
    prepare(project, godot)
    version = godot_command(console_godot(godot), work, "--version").splitlines()[0]
    release = re.match(r"(4\.\d+(?:\.\d+)?)\.stable\.", version)
    if not release:
        raise RuntimeError(f"Use a stable Godot editor with matching Windows export templates: {version}")
    payload = work / "payload"
    payload.mkdir()
    godot_command(console_godot(godot), project, "--headless", "--path", project,
                  "--export-release", "Windows Desktop", payload / GAME)
    for name in (GAME, "netcode_godot.dll"):
        if not (payload / name).is_file():
            raise FileNotFoundError(f"Missing Windows export member: {name}")
    shutil.copyfile(SOURCE / "README.md", payload / "README.md")
    shutil.copyfile(SOURCE / "assets/sources.json", payload / "asset-sources.json")
    licenses = payload / "licenses"
    shutil.copytree(SOURCE / "assets/licenses", licenses)
    shutil.copyfile(project / "addons/netcode/LICENSE.godot-cpp.txt", licenses / "godot-cpp-LICENSE.txt")
    upstream = f"https://raw.githubusercontent.com/godotengine/godot/{release[1]}-stable"
    for name in ("LICENSE.txt", "COPYRIGHT.txt"):
        subprocess.run(["curl.exe", "-fLsS", "--retry", "2", "--max-time", "45",
                        f"{upstream}/{name}", "-o", licenses / f"Godot-{name}"], check=True)
    return archive_payload(work, payload, PACKAGE)


def smoke(staged, work):
    unpack = work / "unpacked"
    with ZipFile(staged / PACKAGE) as archive:
        if archive.testzip() is not None:
            raise ValueError("Windows package CRC mismatch")
        archive.extractall(unpack)
    log = unpack / "smoke.log"
    subprocess.run([unpack / GAME, "--headless", "--log-file", log, "--", "--smoke"],
                   cwd=unpack, timeout=30, check=True, creationflags=subprocess.CREATE_NO_WINDOW)
    output = log.read_text(encoding="utf-8", errors="replace")
    print(output, end="", flush=True)
    if "shiftline_smoke lobby ready" not in output or "ERROR:" in output:
        raise RuntimeError("The unpacked Windows executable did not reach the lobby")


def package(godot):
    if not budget(ROOT, 512 * 1024**2)["allowed"]:
        raise RuntimeError("Output budget exceeded")
    work = create_job(ROOT, "tmp/package-godot-fps", "temp")
    published = False
    try:
        with job_lock(work, "temp"):
            staged = assemble(work, godot)
            digest = slot_digest(ROOT, staged, PACKAGE)
            smoke(staged, work)
            changed = publish(ROOT, work, staged, slot=SLOT, package=PACKAGE)
            published = True
            print(f"{'Published' if changed else 'Unchanged'} {ROOT / SLOT / 'current' / PACKAGE} {digest}")
    finally:
        if published or not (work / "rollback-previous").exists():
            remove_owned(ROOT, work, "temp")
        else:
            print(f"Retained package recovery at {work / 'rollback-previous'}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot-exe", type=Path)
    args = parser.parse_args()
    package(resolve_godot(args.godot_exe))
