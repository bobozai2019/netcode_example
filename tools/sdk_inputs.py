"""Resolve the example repository's pinned release archives."""
import hashlib
import json
import os
from pathlib import Path

EXAMPLES = Path(__file__).resolve().parents[1]
LOCK = json.loads((EXAMPLES / "sdk-lock.json").read_text(encoding="utf-8"))
PACKAGES = Path(os.environ.get("NETCODE_PACKAGES", EXAMPLES.parent / "netcode/out/packages"))


def release_archive(product):
    entry = LOCK["packages"][product]
    for directory in (PACKAGES, PACKAGES / f"{product}-win-x64/current", PACKAGES / f"{product}-win-x64/previous"):
        archive = directory / entry["archive"]
        if archive.is_file():
            with archive.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() == entry["sha256"]:
                    return archive
    raise FileNotFoundError(f"Supply {entry['archive']} with SHA-256 {entry['sha256']} via NETCODE_PACKAGES")
