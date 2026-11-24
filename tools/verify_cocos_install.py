"""Build a new client with relocated SDK archives and an existing Windows Cocos host engine."""
import argparse
from contextlib import ExitStack
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from sdk_inputs import EXAMPLES, release_archive
from verify_yard import Process


def verify(engine_build):
    cache = {}
    for line in (engine_build / "CMakeCache.txt").read_text(encoding="utf-8").splitlines():
        if ":" in line and "=" in line:
            key, value = line.split("=", 1)
            cache[key.split(":")[0]] = value
    cmake = cache["CMAKE_COMMAND"]
    with TemporaryDirectory(prefix="netcode-cocos-consumer-") as tmp:
        work = Path(tmp)
        for name in ("core", "cocos"):
            with ZipFile(release_archive(name)) as z:
                z.extractall(work / "SDK" / name)
        src = work / "app"
        src.mkdir()
        for file in (EXAMPLES / "puzzle").iterdir():
            if file.name == "cocos_main.cpp" or file.suffix == ".hpp" or file.name == "components.cfg":
                shutil.copy2(file, src)
        shutil.copy2(EXAMPLES / "tests/consumers/CocosConsumer.cmake", src / "CMakeLists.txt")
        build = work / "build"
        subprocess.run([cmake, "-S", src, "-B", build, "-G", "Visual Studio 18 2026", "-A", "x64",
                        "-DCMAKE_CONFIGURATION_TYPES=Release", "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
                        f"-DCMAKE_TOOLCHAIN_FILE={cache['CMAKE_TOOLCHAIN_FILE']}",
                        f"-DVCPKG_INSTALLED_DIR={cache['VCPKG_INSTALLED_DIR']}", "-DVCPKG_TARGET_TRIPLET=x64-windows-static",
                        f"-DNETCODE_HOST_TARGETS={(engine_build/'CocosHostTargets.cmake').as_posix()}",
                        f"-DNetcodeCocos_DIR={(work/'SDK/cocos/lib/cmake/NetcodeCocos').as_posix()}",
                        f"-DNetcodeCore_DIR={(work/'SDK/core/lib/cmake/NetcodeCore').as_posix()}"], check=True)
        subprocess.run([cmake, "--build", build, "--config", "Release"], check=True)
        expected = (work / "SDK/cocos/build-id.txt").read_text().strip()
        with ExitStack() as stack:
            peers = []
            for role in ("host", "guest"):
                peer = Process(work, role, build / "Release/consumer.exe",
                               ["--headless", "--puzzle-" + role, "--components", "--port", "43808"])
                stack.callback(peer.close)
                peers.append(peer)
                peer.await_line("sdk_build_id=" + expected, seconds=30)
                peer.await_line("components_open")
            for peer in peers:
                peer.await_line(f"components_pass role={peer.name} score=42 fields=8", seconds=35)
                if peer.proc.wait(timeout=15) != 0:
                    raise RuntimeError("Child exited unsuccessfully")
        print("PASS external Cocos client, two players, fields and RPC; build", expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-build", type=Path, default=EXAMPLES / "out/build/win-x64/Release")
    verify(parser.parse_args().engine_build.resolve())
