#!/usr/bin/env python3
"""Privately extract two x86 DLLs from Microsoft's pinned public DirectX redist.

No Windows installer is executed. No game files or global installation paths
are accessed. All downloads and extracted Microsoft content remain ignored.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request

import pefile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "macos/build/directx"
SOURCE_PAGE = "https://www.microsoft.com/en-us/download/details.aspx?id=8109"
URL = "https://download.microsoft.com/download/8/4/a/84a35bf1-dafe-4ae8-82af-ad2ae20b6b14/directx_Jun2010_redist.exe"
ARCHIVE_SHA256 = "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"
MODULES = {
    "d3dx9_42.dll": {
        "cabinet": "Aug2009_d3dx9_42_x86.cab", "family": "d3dx9", "base": "08000000",
        "sha256": "f8b9cfab7fffbc8f98e41aa439d72921dc180634a1febca2a9d41a0df35d3472",
    },
    "X3DAudio1_7.dll": {
        "cabinet": "Feb2010_X3DAudio_x86.cab", "family": "x3da", "base": "0A000000",
        "sha256": "288c701bdedf1d45c63dd0b7d424a752f8819f90feb5088c582f76bc98970ba3",
    },
}


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def private_path(path):
    """Refuse pre-existing symlinks before mkdir or publishing private files."""
    path = Path(path).absolute()
    path.relative_to(OUTPUT)
    for ancestor in reversed((path, *path.parents)):
        if ancestor == ROOT or ROOT in ancestor.parents:
            if ancestor.is_symlink():
                raise ValueError(f"Refusing private output symlink: {ancestor}")
    if not path.resolve().is_relative_to(OUTPUT.resolve()):
        raise ValueError("Private dependency path escaped its output directory")
    return path


def publish(source, destination):
    destination = private_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256(source) != sha256(destination):
            raise ValueError(f"Unexpected existing private file was preserved: {destination}")
        return
    shutil.copyfile(source, destination)


class OfficialRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme != "https" or parsed.hostname != "download.microsoft.com":
            raise ValueError(f"Refusing redirect outside Microsoft's HTTPS download host: {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def extract_one(cabextract, archive, member, destination):
    subprocess.run([cabextract, "-q", "-F", member, "-d", str(destination), str(archive)], check=True)
    path = destination / member
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"Expected selected cabinet member was not extracted: {member}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cabextract", default=shutil.which("cabextract"))
    args = parser.parse_args()
    if not args.cabextract:
        parser.error("cabextract is required; this script never runs a Windows installer")
    private_path(OUTPUT).mkdir(parents=True, exist_ok=True)
    archive = private_path(OUTPUT / "directx_Jun2010_redist.exe")
    if not archive.exists():
        with tempfile.NamedTemporaryFile(prefix="directx-download-", dir=OUTPUT, delete=False) as output:
            temporary = Path(output.name)
            try:
                opener = urllib.request.build_opener(OfficialRedirect())
                with opener.open(URL, timeout=60) as response:
                    if urllib.parse.urlparse(response.geturl()).hostname != "download.microsoft.com":
                        raise ValueError("Unexpected Microsoft download origin")
                    while data := response.read(1024 * 1024):
                        output.write(data)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        if sha256(temporary) != ARCHIVE_SHA256:
            temporary.unlink(missing_ok=True)
            raise ValueError("Official download bytes do not match the locally pinned release")
        os.replace(temporary, archive)
    if sha256(archive) != ARCHIVE_SHA256:
        raise ValueError("Existing private DirectX redist differs from the pinned release")
    receipt = {"schema": 1, "scope": "official-directx-x86-private-preparation",
               "source_page": SOURCE_PAGE, "url": URL, "archive_sha256": ARCHIVE_SHA256,
               "archive_bytes": archive.stat().st_size,
               "pin_basis": "observed official Microsoft HTTPS download; not a published Microsoft checksum",
               "modules": {}}
    with tempfile.TemporaryDirectory(prefix="extract-", dir=OUTPUT) as temporary:
        stage = Path(temporary)
        for name, settings in MODULES.items():
            cabinet = extract_one(args.cabextract, archive, settings["cabinet"], stage / "cabs")
            module = extract_one(args.cabextract, cabinet, name, stage / "inputs")
            if sha256(module) != settings["sha256"]:
                raise ValueError(f"Unexpected DLL bytes: {name}")
            pe = pefile.PE(str(module))
            if pe.FILE_HEADER.Machine != 0x14c or pe.OPTIONAL_HEADER.Magic != 0x10b:
                raise ValueError(f"Expected x86 PE32 Microsoft dependency: {name}")
            publish(cabinet, OUTPUT / "cabs" / settings["cabinet"])
            publish(module, OUTPUT / "inputs" / name)
            receipt["modules"][name] = {**settings, "path": str(OUTPUT / "inputs" / name),
                "bytes": module.stat().st_size, "machine": "i386", "optional_header": "PE32",
                "export_count": len(pe.DIRECTORY_ENTRY_EXPORT.symbols)}
    private_path(OUTPUT / "fetch-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
