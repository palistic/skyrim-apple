#!/usr/bin/env python3
"""Extract the static arm64 iphoneos MoltenVK slice and its headers from the official v1.4.2 iOS release.

With --sdk xros, the same release's MoltenVK-all.tar supplies the visionOS device slice
(static/MoltenVK.xcframework/xros-arm64) instead, into ipad/deps/MoltenVK-xros-v1.4.2; with
--sdk xrsimulator, its visionOS Simulator slice thinned to arm64, into MoltenVK-xrsimulator-v1.4.2.

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
# Per device SDK: release asset, its pinned SHA-256, the static slice, the Mach-O platform and the output folder.
VARIANTS = {
    "iphoneos": {"url": URL, "sha256": ARCHIVE_SHA256, "pin_basis": PIN_BASIS, "library": LIBRARY,
                 "platform": "2", "label": "iphoneos arm64", "release": "iOS", "out": OUT},
    "xros": {"url": f"https://github.com/KhronosGroup/MoltenVK/releases/download/v{VERSION}/MoltenVK-all.tar",
             "sha256": "562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276",
             "pin_basis": "Matches the GitHub release asset digest for MoltenVK-all.tar v1.4.2 (180,474,368 bytes), "
                          "checked 2026-11-07",
             "library": "MoltenVK/MoltenVK/static/MoltenVK.xcframework/xros-arm64/libMoltenVK.a",
             "platform": "11", "label": "xros arm64", "release": "all platforms", "out": DEPS / f"MoltenVK-xros-v{VERSION}"},
}
# The visionOS Simulator: the same MoltenVK-all.tar's arm64+x86_64 Simulator slice, thinned to arm64.
VARIANTS["xrsimulator"] = dict(VARIANTS["xros"], library=VARIANTS["xros"]["library"].replace(
    "xros-arm64/", "xros-arm64_x86_64-simulator/"), platform="12", label="xrsimulator arm64", thin="arm64",
    out=DEPS / f"MoltenVK-xrsimulator-v{VERSION}")


def build_lines(library):
    # vtool does not read archives; otool -l lists each member's LC_BUILD_VERSION.
    text = subprocess.run(["otool", "-l", str(library)], capture_output=True, text=True).stdout
    return [line.strip() for line in text.splitlines() if line.strip().startswith(("platform ", "minos ", "sdk "))]


def prepare(archive=None, out=None, opener=urllib.request.urlopen, sdk="iphoneos"):
    variant = VARIANTS[sdk]
    out = variant["out"] if out is None else out
    if sdk == "iphoneos":  # the module-level pins, read at call time
        variant = dict(variant, url=URL, sha256=ARCHIVE_SHA256, pin_basis=PIN_BASIS, library=LIBRARY)
    url, archive_sha256, library_member = variant["url"], variant["sha256"], variant["library"]
    receipt_path = out / "receipt.json"
    if receipt_path.exists():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("archive_sha256") != archive_sha256 or sha256(receipt["library"]) != receipt["library_sha256"]:
            raise ValueError(f"{out} differs from its receipt or the pinned release; preserve it and inspect")
        return receipt
    if out.exists() or out.is_symlink():
        raise ValueError(f"{out} exists without a receipt; preserve it and inspect")
    archive = obtain(url, archive_sha256, out.parent / PurePosixPath(url).name.replace(".tar", f"-v{VERSION}.tar"),
                     archive, opener)
    out.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".moltenvk-", dir=out.parent))
    try:
        with tarfile.open(archive) as tar:
            members = [m for m in tar.getmembers()
                       if m.name == library_member or (m.name.startswith(INCLUDE) and (m.isfile() or m.isdir()))]
            if not any(m.name == library_member and m.isfile() for m in members):
                raise ValueError(f"The archive has no static {variant['label']} MoltenVK slice")
            for m in members:
                rel = PurePosixPath(m.name)
                if ".." in rel.parts or rel.is_absolute():
                    raise ValueError(f"unsafe archive path {m.name}")
                target = stage / ("lib/libMoltenVK.a" if m.name == library_member else Path("include") / rel.relative_to(INCLUDE))
                if m.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(m) as source, open(target, "xb") as dest:
                    shutil.copyfileobj(source, dest)
        if variant.get("thin"):
            subprocess.run(["lipo", stage / "lib/libMoltenVK.a", "-thin", variant["thin"], "-output",
                            stage / "lib/libMoltenVK.thin.a"], check=True)
            os.replace(stage / "lib/libMoltenVK.thin.a", stage / "lib/libMoltenVK.a")
        lines = build_lines(stage / "lib/libMoltenVK.a")
        # platform 2 is iphoneos, 7 the iOS Simulator, 11 visionOS (xros), 12 the visionOS Simulator.
        found = {line.split()[1] for line in lines if line.startswith("platform ")}
        if found != {variant["platform"]}:
            raise ValueError(f"The MoltenVK slice is not purely an {variant['label']} (device) slice: platforms {sorted(found)}")
        library = out / "lib/libMoltenVK.a"
        receipt = {"schema": 1, "release": f"MoltenVK v{VERSION} {variant['release']} (official release archive)",
                   "url": url, "archive": str(archive), "archive_sha256": archive_sha256, "pin_basis": variant["pin_basis"],
                   "library": str(library), "library_sha256": sha256(stage / "lib/libMoltenVK.a"),
                   "platform": variant["label"], "otool_build": sorted(set(lines)), "include": str(out / "include")}
        (stage / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        os.rename(stage, out)
        return receipt
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="an existing local MoltenVK-ios.tar (read in place, never modified)")
    parser.add_argument("--sdk", choices=sorted(VARIANTS), default="iphoneos", help="device SDK (default: iphoneos)")
    args = parser.parse_args()
    url, archive_sha256 = VARIANTS[args.sdk]["url"], VARIANTS[args.sdk]["sha256"]
    try:
        receipt = prepare(args.archive, sdk=args.sdk)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(f"MoltenVK preparation failed: {error}\n"
                         f"Official asset: {url}\nPinned SHA-256: {archive_sha256}\n"
                         "A verified local copy can be given with --archive PATH.")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
