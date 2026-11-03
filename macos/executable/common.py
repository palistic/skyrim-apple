"""Private build-time Steamless preparation helpers (never game runtime code)."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "macos/build/steamless"
SOURCE = ROOT / "macos/deps/steamless/source"
COMMIT = "cd770bf9749d3e4f438d23ac643917ad1a804257"
SHARP_SHA256 = "6d3ce990cdf58da228697d25416d16d15994135c5f66571fe1e00e9c975bc2cf"
ORIGINAL_PREFIX = "f39aeceb"
# Steamless output bytes differ between Steamless versions (upstream's own launcher notes
# this). fed96638 is upstream's documented copy; the full SHA-1 is the pinned v3.1.0.5
# default output from the exact f39aeceb original, whose mapped sections and entry point
# match the --keepbind/--keepstub variants byte for byte. Both are exact identities.
UNPACKED_PREFIX = ("fed96638", "17ec1ef6d72781359860f103f600711dfc219182")
VARIANTS = ("10", "20", "21", "30", "31")


def digest(path: Path, algorithm: str = "sha256") -> str:
    h = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def file_record(path: Path) -> dict:
    return {"path": str(path.resolve()), "bytes": path.stat().st_size,
            "sha256": digest(path)}


def verify_record(record: dict) -> Path:
    path = Path(record["path"])
    if not path.is_file() or path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
        raise ValueError(f"File changed or missing: {path}")
    return path


def write_json(path: Path, value: dict) -> None:
    # Callers use a new private directory; refuse accidental replacement.
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def require_pe32(path: Path) -> None:
    """Read PE headers only. Never load or execute the input."""
    data = path.read_bytes()
    if len(data) < 64 or data[:2] != b"MZ":
        raise ValueError("Input is not a DOS/PE executable")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset + 26 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise ValueError("Invalid PE header")
    machine = struct.unpack_from("<H", data, offset + 4)[0]
    magic = struct.unpack_from("<H", data, offset + 24)[0]
    if machine != 0x14C or magic != 0x10B:
        raise ValueError("Expected original Windows x86 PE32, not PE32+/another architecture")


def load_tool(receipt_path: Path) -> tuple[dict, Path, Path]:
    document = json.loads(receipt_path.read_text())
    if document.get("kind") == "steamless-current-v1":
        receipt_path = verify_record(document["receipt"])
        document = json.loads(receipt_path.read_text())
    if document.get("kind") != "steamless-headless-build-v1":
        raise ValueError("Unknown converter receipt")
    if document.get("source_commit") != COMMIT:
        raise ValueError("Unexpected converter source revision")
    for record in document["inputs"] + document["outputs"]:
        verify_record(record)
    dotnet = verify_record(document["dotnet"])
    cli = Path(document["cli"]).resolve(strict=True)
    if str(cli) not in {r["path"] for r in document["outputs"]}:
        raise ValueError("CLI is not bound to converter receipt")
    return document, dotnet, cli
