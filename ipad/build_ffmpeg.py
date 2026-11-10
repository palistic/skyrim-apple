#!/usr/bin/env python3
"""Build the pinned minimal WMA decoder libraries for the physical iPad (arm64 iphoneos) Vision Pro (--sdk xros)
or the visionOS Simulator (--sdk xrsimulator).

Same FFmpeg 7.1.2 source and configuration as macos/audio/build_ffmpeg.py, for the device
SDK. The official source archive is downloaded once into the ignored ipad/deps/, or read in
place with --source-archive, and accepted only with the pinned SHA-256. The extracted source,
build and install prefix stay in ignored ipad/ folders; build-manifest.json is the receipt.
An existing build whose receipt still verifies is reused.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ipad"))
sys.path.insert(0, str(ROOT / "macos/audio"))
from build_ffmpeg import SOURCE_SHA256, URL, VERSION, run  # noqa: E402
from pinned import obtain, sha256  # noqa: E402

TRIPLES = {"iphoneos": "arm64-apple-ios17.0", "xros": "arm64-apple-xros26.5",
           "xrsimulator": "arm64-apple-xros26.5-simulator"}
TRIPLE = TRIPLES["iphoneos"]
DEPS = ROOT / "ipad/deps"
PREFIX = DEPS / "ffmpeg-iphoneos"


def prefix_for(sdk):
    return DEPS / f"ffmpeg-{sdk}"


def verified_manifest(prefix=PREFIX, sdk="iphoneos"):
    """The existing device build's receipt if its pinned source and archives still match; None if absent."""
    path = prefix / "build-manifest.json"
    if not path.exists():
        return None
    manifest = json.loads(path.read_text())
    archives = manifest.get("archives", {})
    if (manifest.get("source_archive_sha256") != SOURCE_SHA256 or manifest.get("platform") != sdk
            or manifest.get("triple", TRIPLES[sdk]) != TRIPLES[sdk]
            or set(archives) != {"avcodec", "avutil"} or any(sha256(a["path"]) != a["sha256"] for a in archives.values())):
        raise ValueError(f"{prefix} differs from its build manifest or the pinned FFmpeg {VERSION}; preserve it and inspect")
    return manifest


def build_libraries(source_archive, jobs, sdk_name="iphoneos"):
    build, prefix = ROOT / f"ipad/build/ffmpeg-{sdk_name}", prefix_for(sdk_name)
    triple = TRIPLES[sdk_name]
    source = DEPS / f"ffmpeg-source/ffmpeg-{VERSION}"
    for path in (DEPS, build, prefix):
        if path.is_symlink():
            raise ValueError(f"{path} must not be a symlink")
    # A fresh clone has no ipad/deps yet, even when --source-archive skips the download.
    DEPS.mkdir(parents=True, exist_ok=True)
    archive = obtain(URL, SOURCE_SHA256, DEPS / f"ffmpeg-{VERSION}.tar.xz", source_archive)
    if not source.exists():
        stage = Path(tempfile.mkdtemp(prefix="ffmpeg-extract-", dir=DEPS))
        with tarfile.open(archive) as contents:
            contents.extractall(stage, filter="data")
        if not (stage / source.name / "configure").is_file():
            raise ValueError("Pinned source extraction is incomplete")
        source.parent.mkdir(exist_ok=True)
        (stage / source.name).rename(source)
        stage.rmdir()
    build.mkdir(parents=True, exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip()
    clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    flags = f"-target {triple} -isysroot {sdk}"
    configure = [str(source / "configure"), f"--prefix={prefix}", "--enable-cross-compile",
        "--arch=aarch64", "--target-os=darwin", f"--cc={clang}", f"--ld={clang}",
        "--ar=ar", "--ranlib=ranlib", f"--sysroot={sdk}",
        f"--extra-cflags={flags}", f"--extra-ldflags={flags}",
        "--enable-static", "--disable-shared", "--enable-pic", "--disable-programs",
        "--disable-doc", "--disable-debug", "--disable-network", "--disable-autodetect",
        "--disable-everything", "--disable-avdevice", "--disable-avfilter", "--disable-avformat",
        "--disable-postproc", "--disable-swscale", "--disable-swresample", "--disable-asm",
        "--enable-avcodec", "--enable-avutil", "--enable-decoder=wmav2,wmapro",
        "--disable-videotoolbox", "--disable-audiotoolbox", "--disable-securetransport",
        "--disable-gpl", "--disable-nonfree"]
    key = {"source_archive_sha256": SOURCE_SHA256, "platform": sdk_name, "triple": triple,
           "sdk": sdk, "configure": configure}
    state = build / "configuration.json"
    if state.exists() and json.loads(state.read_text()) != key:
        raise ValueError("Existing device FFmpeg build has a different configuration; choose a fresh directory")
    if not state.exists():
        run(configure, build / "configure.log", cwd=build)
        state.write_text(json.dumps(key, indent=2) + "\n")
    start = time.monotonic()
    run(["make", f"-j{jobs}"], build / "build.log", cwd=build)
    run(["make", "install"], build / "install.log", cwd=build)
    archives = {}
    for name in ("avcodec", "avutil"):
        path = prefix / f"lib/lib{name}.a"
        archives[name] = {"path": str(path), "sha256": sha256(path), "bytes": path.stat().st_size}
    manifest = dict(key, source_url=URL, source_archive=str(archive), version=VERSION, decoders=["wmav2", "wmapro"],
                    elapsed_seconds=round(time.monotonic() - start, 1), archives=archives,
                    network=False, shared=False, license="LGPL-2.1-or-later")
    (prefix / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    licenses = prefix / "share/licenses/ffmpeg"
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "COPYING.LGPLv2.1", licenses / "COPYING.LGPLv2.1")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-archive", type=Path,
                        help=f"an existing local ffmpeg-{VERSION}.tar.xz (read in place, never modified)")
    parser.add_argument("--jobs", type=int, choices=(1, 2), default=2)
    parser.add_argument("--sdk", choices=sorted(TRIPLES), default="iphoneos", help="device SDK (default: iphoneos)")
    args = parser.parse_args()
    prefix = prefix_for(args.sdk)
    try:
        manifest = verified_manifest(prefix, args.sdk)
        built = manifest is None
        if built:
            manifest = build_libraries(args.source_archive, args.jobs, args.sdk)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f"FFmpeg preparation failed: {error}\nOfficial source: {URL}\n"
                         f"Pinned SHA-256: {SOURCE_SHA256}\nA verified local copy can be given with --source-archive PATH.")
    print(json.dumps({"built": built, "platform": args.sdk, "prefix": str(prefix), "archives": manifest["archives"]}))


if __name__ == "__main__":
    main()
