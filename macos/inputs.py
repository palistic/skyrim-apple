#!/usr/bin/env python3
"""Read-only owned-input checks and binding generated code to exact inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parent.parent
# Exact identities (str.startswith accepts a tuple). The unpacked entry mirrors
# macos/executable/common.py: upstream's copy, or the pinned Steamless v3.1.0.5 output.
EXPECTED = {"TESV.exe": "f39aeceb",
            "TESV_unpacked.exe": ("fed96638", "17ec1ef6d72781359860f103f600711dfc219182")}
MODULES = ("TESV.exe", "TESV_unpacked.exe", "d3dx9_42.dll", "binkw32.dll", "X3DAudio1_7.dll")
TOOLS = ("tools/discover.py", "tools/lift.py", "tools/peimg.py")


def digest(path, algorithm="sha256"):
    result = hashlib.new(algorithm)
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def find_unique(directory, name):
    matches = [p for p in directory.iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {name} in {directory}; found {len(matches)}")
    return matches[0]


def check_pe32(path):
    with path.open("rb") as source:
        header = source.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise ValueError(f"{path.name}: invalid DOS header")
        offset = struct.unpack_from("<I", header, 0x3c)[0]
        if offset > path.stat().st_size - 26:
            raise ValueError(f"{path.name}: PE offset outside file")
        source.seek(offset)
        pe = source.read(26)
    if len(pe) != 26 or pe[:4] != b"PE\0\0" or struct.unpack_from("<H", pe, 4)[0] != 0x14c:
        raise ValueError(f"{path.name}: expected 32-bit Windows x86 PE, not SE/AE or another platform")
    if struct.unpack_from("<H", pe, 24)[0] != 0x10b:
        raise ValueError(f"{path.name}: expected PE32 optional header")


def validate_game(directory):
    directory = Path(directory).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("Game input must be a complete installation directory")
    files = {}
    for name in MODULES:
        path = find_unique(directory, name)
        if not path.is_file():
            raise ValueError(f"{name} is not a regular file")
        check_pe32(path)
        sha1 = digest(path, "sha1")
        if name in EXPECTED and not sha1.startswith(EXPECTED[name]):
            raise ValueError(f"{name}: does not match the upstream-supported original Steam 1.9.32.0.8 input (SHA-1 prefix)")
        files[name] = {"path": str(path), "size": path.stat().st_size,
                       "sha1": sha1, "sha256": digest(path)}
    data = find_unique(directory, "Data")
    if not data.is_dir():
        raise ValueError("Data must be a directory")
    assets = {}
    for name in ("Skyrim.esm", "Update.esm"):
        path = find_unique(data, name)
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Data/{name} is absent or empty")
        assets[name] = {"path": str(path), "size": path.stat().st_size, "sha256": digest(path)}
    if not any(p.is_file() and p.suffix.casefold() == ".bsa" for p in data.iterdir()):
        raise ValueError("Data has no BSA archives; provide the complete installation")
    return {"schema": 1, "scope": "owned-original-windows-skyrim-1.9.32.0.8",
            "game_directory": str(directory), "modules": files, "essential_data": assets,
            "compatibility_basis": "upstream executable SHA-1 prefixes; full SHA-256 recorded for build binding"}


def verify_generated(directory, game_directory=None):
    directory = Path(directory).resolve(strict=True)
    receipt = json.loads((directory / "input-manifest.json").read_text())
    if receipt.get("schema") != 1 or receipt.get("scope") != "owned-original-windows-skyrim-1.9.32.0.8":
        raise ValueError("Generated code is not bound to the supported owned Windows game inputs")
    current = validate_game(game_directory or receipt["game_directory"])
    for name in MODULES:
        if receipt["modules"][name]["sha256"] != current["modules"][name]["sha256"]:
            raise ValueError(f"Game input changed since generation: {name}")
    for name, recorded in receipt.get("essential_data", {}).items():
        if recorded["sha256"] != current["essential_data"][name]["sha256"]:
            raise ValueError(f"Essential game data changed since generation: {name}")
    if set(receipt.get("essential_data", {})) != set(current["essential_data"]):
        raise ValueError("Generated code manifest lacks the essential game data binding")
    expected = receipt.get("generated", {})
    actual = {p.name for p in directory.iterdir() if p.suffix in (".c", ".h")}
    if not expected or actual != set(expected):
        raise ValueError("Generated source closure is missing, incomplete or contains extra files")
    for name, sha in expected.items():
        if Path(name).name != name or digest(directory / name) != sha:
            raise ValueError(f"Generated file changed: {name}")
    for family in ("exe", "d3dx9", "bink", "x3da"):
        if f"{family}_table.c" not in expected or not any(n.startswith(family + "_") and n.endswith(".c") and n != f"{family}_table.c" for n in expected):
            raise ValueError(f"Generated module missing: {family}")
    for name in TOOLS:
        if receipt.get("tools", {}).get(name) != digest(ROOT / name):
            raise ValueError(f"Recompiler changed; regenerate before building: {name}")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "verify-generated"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--game-dir", type=Path)
    args = parser.parse_args()
    try:
        result = validate_game(args.directory) if args.command == "check" else verify_generated(args.directory, args.game_dir)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Input check failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
