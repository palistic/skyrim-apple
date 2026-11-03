#!/usr/bin/env python3
"""Extract the static arm64 iphoneos MoltenVK slice and its headers from the official v1.4.2 iOS release.

The release archive (MoltenVK-ios.tar) is downloaded once into the ignored ipad/deps/, or read in
place with --archive, and accepted only with the pinned SHA-256. Only
MoltenVK/MoltenVK/include/** and static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a are
extracted, into ignored ipad/deps/MoltenVK-ios-v1.4.2, which is published only after the slice
proves to be purely iphoneos. The Mac build uses the same v1.4.2 release (macOS slice); the
Simulator needs a source build only because the release has no Simulator slice.
"""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pinned import obtain, sha256  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.4.2"
URL = f"https://github.com/KhronosGroup/MoltenVK/releases/download/v{VERSION}/MoltenVK-ios.tar"
ARCHIVE_SHA256 = "b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1"
PIN_BASIS = "Matches the GitHub release asset digest for MoltenVK-ios.tar v1.4.2 (34,535,424 bytes), checked 2026-11-03"
DEPS = ROOT / "ipad/deps"
OUT = DEPS / f"MoltenVK-ios-v{VERSION}"
LIBRARY = "MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a"
INCLUDE = "MoltenVK/MoltenVK/include/"


def build_lines(library):
    # vtool does not read archives; otool -l lists each member's LC_BUILD_VERSION.
    text = subprocess.run(["otool", "-l", str(library)], capture_output=True, text=True).stdout
    return [line.strip() for line in text.splitlines() if line.strip().startswith(("platform ", "minos ", "sdk "))]


def prepare(archive=None, out=OUT, opener=urllib.request.urlopen):
    receipt_path = out / "receipt.json"
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("archive_sha256") != ARCHIVE_SHA256 or sha256(receipt["library"]) != receipt["library_sha256"]:
            raise ValueError(f"{out} differs from its receipt or the pinned release; preserve it and inspect")
        return receipt
    if out.exists() or out.is_symlink():
        raise ValueError(f"{out} exists without a receipt; preserve it and inspect")
    archive = obtain(URL, ARCHIVE_SHA256, out.parent / f"MoltenVK-ios-v{VERSION}.tar", archive, opener)
    out.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".moltenvk-", dir=out.parent))
    try:
        with tarfile.open(archive) as tar:
            members = [m for m in tar.getmembers()
                       if m.name == LIBRARY or (m.name.startswith(INCLUDE) and (m.isfile() or m.isdir()))]
            if not any(m.name == LIBRARY and m.isfile() for m in members):
                raise ValueError("The archive has no static ios-arm64 MoltenVK slice")
            for m in members:
                rel = PurePosixPath(m.name)
                if ".." in rel.parts or rel.is_absolute():
                    raise ValueError(f"unsafe archive path {m.name}")
                target = stage / ("lib/libMoltenVK.a" if m.name == LIBRARY else Path("include") / rel.relative_to(INCLUDE))
                if m.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(m) as source, open(target, "xb") as dest:
                    shutil.copyfileobj(source, dest)
        lines = build_lines(stage / "lib/libMoltenVK.a")
        # platform 2 is iphoneos, 7 the iOS Simulator.
        found = {line.split()[1] for line in lines if line.startswith("platform ")}
        if found != {"2"}:
            raise ValueError(f"The MoltenVK slice is not purely an iphoneos (device) slice: platforms {sorted(found)}")
        library = out / "lib/libMoltenVK.a"
        receipt = {"schema": 1, "release": f"MoltenVK v{VERSION} iOS (official release archive)", "url": URL,
                   "archive": str(archive), "archive_sha256": ARCHIVE_SHA256, "pin_basis": PIN_BASIS,
                   "library": str(library), "library_sha256": sha256(stage / "lib/libMoltenVK.a"),
                   "platform": "iphoneos arm64", "otool_build": sorted(set(lines)), "include": str(out / "include")}
        (stage / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        os.rename(stage, out)
        return receipt
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="an existing local MoltenVK-ios.tar (read in place, never modified)")
    args = parser.parse_args()
    try:
        receipt = prepare(args.archive)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(f"MoltenVK preparation failed: {error}\n"
                         f"Official asset: {URL}\nPinned SHA-256: {ARCHIVE_SHA256}\n"
                         "A verified local copy can be given with --archive PATH.")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
