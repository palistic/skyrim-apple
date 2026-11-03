#!/usr/bin/env python3
"""Fetch only the pinned public macOS graphics dependency into ignored storage."""
from pathlib import Path
import hashlib
import json
import os
import tarfile
import urllib.request

VERSION = "1.4.2"
URL = f"https://github.com/KhronosGroup/MoltenVK/releases/download/v{VERSION}/MoltenVK-macos.tar"
SHA256 = "f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"


def safe_target(destination, relative):
    """Refuse pre-existing symlinks anywhere in a dependency output path."""
    destination = Path(destination)
    relative = Path(relative)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Unsafe dependency output path")
    if destination.is_symlink():
        raise ValueError(f"Refusing dependency directory symlink: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve(strict=True)
    target = destination
    for part in relative.parts:
        target = target / part
        if target.is_symlink():
            raise ValueError(f"Refusing dependency path symlink: {target}")
    if not target.resolve(strict=False).is_relative_to(root):
        raise ValueError("Dependency output escapes its private directory")
    return target


def main():
    destination = Path(__file__).resolve().parent.parent / "deps"
    archive = safe_target(destination, f"MoltenVK-macos-v{VERSION}.tar")
    if not archive.exists():
        temporary = safe_target(destination, archive.with_suffix(".download").name)
        with urllib.request.urlopen(URL, timeout=60) as response, temporary.open("wb") as output:
            while data := response.read(1024 * 1024):
                output.write(data)
        os.replace(temporary, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != SHA256:
        raise SystemExit(f"Refusing dependency with unexpected SHA256: {digest}")
    # Extract ordinary selected files only, retaining the package directory layout.
    # No archive links, device nodes, absolute paths or traversal are followed.
    with tarfile.open(archive) as source:
        for member in source:
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise SystemExit("Unsafe dependency archive path")
            selected = member.name.startswith("MoltenVK/MoltenVK/include/") or member.name in (
                "MoltenVK/LICENSE", "MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
            )
            if not selected or not member.isfile():
                continue
            target = safe_target(destination, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as input_file:
                content = input_file.read()
            # Keep mtimes stable on repeated bootstrap runs so installed headers
            # do not invalidate every graphics object when nothing changed.
            if not target.exists() or target.read_bytes() != content:
                target.write_bytes(content)
    receipt = {"version": VERSION, "url": URL, "sha256": digest, "bytes": archive.stat().st_size}
    safe_target(destination, "moltenvk-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
