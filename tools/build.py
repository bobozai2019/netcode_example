"""Build the independent Windows x64 core and optional car yard platforms."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from zipfile import ZipFile
import zlib

from artifacts import GIB, ROOT, budget, create_job, item_at, job_lock, owned
from godot_build import GODOT_PROJECT, import_project, resolve_godot, sdk_sources
from prepare_godot_yard import sync
from sdk_inputs import LOCK, release_archive
from unity_build import build_unity_player, resolve_unity


REPO = ROOT.parent
ARCHIVE = "metal-support-22.zip"
ARCHIVE_URL = ("https://codeload.github.com/cocos2d/cocos2d-x-3rd-party-libs-bin/"
               "zip/refs/tags/metal-support-22")
ARCHIVE_HASH = "721c0588f10c7e445d4b4103efcf3869203fffa9bf7836deb3c6bb51b2f8a764"
SOURCE_ROOT = "cocos2d-x-3rd-party-libs-bin-metal-support-22"
SOURCE_LIBS = {"tinyxml2", "xxhash", "xxtea", "clipper", "edtaa3func", "ConvertUTF",
               "poly2tri", "md5", "unzip", "json", "rapidxml", "tinydir"}
TRIPLET = "x64-windows-static"


def run(*command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, cwd=REPO, **kwargs)


def visual_studio():
    where = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
    path = subprocess.check_output(
        [where, "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
         "-property", "installationPath"],
        text=True,
    ).strip()
    if not path:
        raise RuntimeError("Install the Visual Studio Desktop development with C++ workload")
    return Path(path)


def verify_archive(path):
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != ARCHIVE_HASH:
            raise ValueError(f"Unexpected SHA-256 for {path}")


def vendor_sources(build):
    vendor = build / "vendor"
    vendor.mkdir(exist_ok=True)
    archive = vendor / ARCHIVE
    if not archive.exists():
        partial = archive.with_suffix(".partial")
        run("curl.exe", "-fLsS", "--retry", 2, "--max-time", 240, ARCHIVE_URL, "-o", partial)
        verify_archive(partial)
        partial.replace(archive)
    verify_archive(archive)
    with ZipFile(archive) as zip_file:
        for member in zip_file.infolist():
            parts = member.filename.split("/")
            if len(parts) > 2 and parts[0] == SOURCE_ROOT and parts[1] in SOURCE_LIBS:
                target = item_at(vendor, Path(*parts))
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                elif not target.is_file() or zlib.crc32(target.read_bytes()) != member.CRC:
                    zip_file.extract(member, vendor)
    return vendor / SOURCE_ROOT


def install_dependencies(build, vcpkg):
    env = os.environ.copy()
    downloads = build / "downloads"
    cache = build / "binary-cache"
    for folder in (downloads, cache):
        folder.mkdir(exist_ok=True)
    env.update(VCPKG_DOWNLOADS=str(downloads), VCPKG_BINARY_SOURCES="clear",
               VCPKG_DEFAULT_BINARY_CACHE=str(cache))
    run(vcpkg, "install", "--triplet", TRIPLET,
        f"--x-manifest-root={REPO / 'yard/cocos2dx'}",
        f"--x-install-root={build / 'vcpkg-installed'}",
        f"--x-buildtrees-root={build / 'vcpkg-buildtrees'}",
        f"--x-packages-root={build / 'vcpkg-packages'}", env=env)


def cocos_sdk_prefixes(installed, build):
    core, cocos = (installed / product for product in ("core", "cocos"))
    core_config = core / "lib/cmake/NetcodeCore/NetcodeCoreConfig.cmake"
    cocos_config = cocos / "lib/cmake/NetcodeCocos/NetcodeCocosConfig.cmake"
    if core_config.is_file() and cocos_config.is_file():
        core_id = re.search(r'set\(NetcodeCore_BUILD_ID "([^"]+)"\)', core_config.read_text(encoding="utf-8"))
        required_id = re.search(r'if\(NOT NetcodeCore_BUILD_ID STREQUAL "([^"]+)"\)',
                                cocos_config.read_text(encoding="utf-8"))
        if not core_id or not required_id or core_id[1] == required_id[1]:
            return core, cocos

    archives = {product: release_archive(product) for product in ("core", "cocos")}
    prefixes = {}
    for product, archive in archives.items():
        checksum = LOCK["packages"][product]["sha256"]
        prefix = item_at(build, Path("sdk") / product / checksum)
        ready = prefix / ".extracted"
        if not ready.is_file():
            with ZipFile(archive) as package:
                package.extractall(prefix)
            ready.touch()
        prefixes[product] = prefix
    print("Using the locked Release Core and Cocos SDKs", flush=True)
    return prefixes["core"], prefixes["cocos"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cocos", action="store_true")
    parser.add_argument("--chipmunk-root", type=Path, help="Chipmunk 7.0.1 sources for native Cocos rigid bodies")
    parser.add_argument("--bullet-root", type=Path, help="Bullet x64 installation for Cocos 3D physics")
    parser.add_argument("--godot", action="store_true")
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--unity", action="store_true")
    parser.add_argument("--unity-exe", type=Path)
    parser.add_argument("--steam-sdk", type=Path, help="Build Steam P2P using this unpacked Steamworks SDK")
    parser.add_argument("--cocos-root", type=Path, default=REPO.parent / "cocos2d-x-4")
    parser.add_argument("--parallel", type=int, default=3)
    parser.add_argument("--cmake", type=Path)
    parser.add_argument("--vcpkg", type=Path)
    parser.add_argument("--fresh", action="store_true", help="Recreate CMake's configure cache")
    parser.add_argument("--sdk-root", type=Path,
                        help="Directory containing Release/core, Release/cocos, Release/godot, Release/unity")
    local_sdk = REPO.parent / "netcode/out"
    legacy = local_sdk / "build/win-x64/Release"
    shared_cache = legacy if (legacy / "vendor" / ARCHIVE).is_file() else (local_sdk if local_sdk.is_dir() else ROOT) / "cache"
    parser.add_argument("--deps-cache", type=Path, default=Path(os.environ.get("NETCODE_DEPS_CACHE", shared_cache)), help="Reusable third-party sources and vcpkg cache")
    args = parser.parse_args()
    if args.parallel < 1:
        parser.error("Parallel jobs must be positive")
    expected = (4 * GIB if args.cocos else GIB if args.godot else 128 * 1024 ** 2) + (GIB if args.unity else 0)
    result = budget(ROOT, expected)
    print(json.dumps(result), flush=True)
    if not result["allowed"]:
        return 1

    vs = visual_studio()
    bin_dir = vs / "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"
    cmake = args.cmake or bin_dir / "cmake.exe"
    if not cmake.is_file():
        cmake = Path(shutil.which("cmake") or cmake)
    ctest = cmake.with_name("ctest.exe")
    car_yard = args.cocos or args.godot or args.unity or args.steam_sdk is not None
    config = "Release" if car_yard else "Debug"
    relative = Path("build/win-x64") / config
    build = item_at(ROOT, relative)
    if build.exists():
        owned(ROOT, build, "build")
    else:
        build = create_job(ROOT, relative, "build")
    with job_lock(build, "build"):
        source = REPO
        sdk_root = args.sdk_root or REPO.parent / "netcode/out/install/win-x64-msvc-mt"
        config_sdk = sdk_root.resolve() / config
        core_sdk = config_sdk / "core"
        cocos_sdk = config_sdk / "cocos"
        if args.cocos and args.sdk_root is None and args.steam_sdk is None:
            core_sdk, cocos_sdk = cocos_sdk_prefixes(config_sdk, build)
        if not (core_sdk / "lib/cmake/NetcodeCore/NetcodeCoreConfig.cmake").is_file():
            parser.error(f"Missing installed {config} Core SDK at {core_sdk}. Build or supply --sdk-root.")
        deps = args.deps_cache.resolve()
        deps.mkdir(parents=True, exist_ok=True)
        options = ["--fresh"] if args.fresh else []
        options += [f"-DNETCODE_STEAM={'ON' if args.steam_sdk else 'OFF'}"]
        options += [
                f"-DNETCODE_COCOS={'ON' if args.cocos else 'OFF'}",
                f"-DNETCODE_GODOT={'ON' if args.godot else 'OFF'}",
                f"-DNETCODE_UNITY={'ON' if args.unity else 'OFF'}",
                f"-DCMAKE_MSVC_RUNTIME_LIBRARY={'MultiThreadedDebug' if config=='Debug' else 'MultiThreaded'}",
                f"-DCMAKE_CONFIGURATION_TYPES={config}",
                f"-DNetcodeCore_DIR={core_sdk}/lib/cmake/NetcodeCore",
                f"-DNetcodeCocos_DIR={cocos_sdk}/lib/cmake/NetcodeCocos",
                f"-DNETCODE_GODOT_SDK={config_sdk}/godot",
            ]
        if args.steam_sdk:
            options += [f"-DNETCODE_STEAMWORKS_ROOT={args.steam_sdk.resolve()}"]
        if args.bullet_root and not args.cocos:
            parser.error("--bullet-root requires --cocos")
        if args.chipmunk_root and not args.cocos:
            parser.error("--chipmunk-root requires --cocos")
        if args.cocos:
            options += [f"-DNETCODE_BULLET={args.bullet_root.resolve() if args.bullet_root else ''}"]
            options += [f"-DNETCODE_CHIPMUNK={args.chipmunk_root.resolve() if args.chipmunk_root else ''}"]
            vcpkg = args.vcpkg or vs / "VC/vcpkg/vcpkg.exe"
            dependencies = vendor_sources(deps)
            install_dependencies(deps, vcpkg)
            remaining = budget(ROOT, 1024 ** 3)
            print(json.dumps(remaining), flush=True)
            if not remaining["allowed"]:
                return 1
            options += [
                f"-DCOCOS2DX_ROOT={args.cocos_root.resolve()}",
                f"-DNETCODE_COCOS_EXTERNAL={dependencies}",
                f"-DCMAKE_TOOLCHAIN_FILE={vcpkg.parent / 'scripts/buildsystems/vcpkg.cmake'}",
                "-DVCPKG_MANIFEST_MODE=OFF",
                f"-DVCPKG_TARGET_TRIPLET={TRIPLET}",
                f"-DVCPKG_INSTALLED_DIR={deps / 'vcpkg-installed'}",
            ]
        if args.godot:
            godot = resolve_godot(args.godot_exe)
            options += [f"-DNETCODE_GODOT_CPP={sdk_sources(deps)}", "-DGODOTCPP_TARGET=template_release"]
        run(cmake, "-S", source, "-B", build, "-G", "Visual Studio 18 2026", "-A", "x64", *(o.replace(chr(92), "/") for o in options))
        run(cmake, "--build", build, "--config", config, "--parallel", args.parallel)
        run(ctest, "--test-dir", build, "-C", config, "--output-on-failure")
        if args.godot:
            import_project(godot, GODOT_PROJECT)
            sync(GODOT_PROJECT, REPO / "yard/godot")
            import_project(godot, REPO / "yard/godot")
        if args.unity:
            build_unity_player(resolve_unity(args.unity_exe), build, args.steam_sdk, config_sdk / "unity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
