#!/usr/bin/env python3
"""Build pinned, minimal native WMA decoder libraries in private project storage."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
VERSION = "7.1.2"
URL = f"https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz"
SOURCE_SHA256 = "089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304"


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def run(arguments, log, *, cwd=None):
    with log.open("w") as output:
        result = subprocess.run([str(a) for a in arguments], cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{log.read_text()[-3000:]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "simulator"))
    parser.add_argument("--source-archive", type=Path, help="Reuse an existing public source archive after verifying its pinned checksum")
    parser.add_argument("--configure-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 2:
        parser.error("Use one or two compiler jobs to preserve concurrent local work")
    deps = ROOT / "macos/deps"
    if deps.is_symlink():
        parser.error("Private dependency directory must not be a symlink")
    deps.mkdir(parents=True, exist_ok=True)
    archive = deps / f"ffmpeg-{VERSION}.tar.xz"
    if archive.is_symlink(): parser.error("Source archive must not be a symlink")
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        if temporary.exists() or temporary.is_symlink(): parser.error("Preserve unexpected existing source download before retrying")
        if args.source_archive:
            shutil.copyfile(args.source_archive, temporary)
        else:
            with urllib.request.urlopen(URL, timeout=60) as source, temporary.open("xb") as output:
                shutil.copyfileobj(source, output)
        if sha256(temporary) != SOURCE_SHA256:
            raise RuntimeError("Pinned FFmpeg source archive checksum mismatch; download was preserved")
        temporary.rename(archive)
    if sha256(archive) != SOURCE_SHA256:
        raise RuntimeError("Existing FFmpeg source archive does not match the pinned release")
    source_parent = deps / "ffmpeg-source"
    source = source_parent / f"ffmpeg-{VERSION}"
    if source_parent.is_symlink() or source.is_symlink():
        raise RuntimeError("Source directories must not be symlinks")
    if not source.exists():
        stage = Path(tempfile.mkdtemp(prefix="ffmpeg-extract-", dir=deps))
        with tarfile.open(archive) as contents:
            contents.extractall(stage, filter="data")
        if not (stage / source.name / "configure").is_file():
            raise RuntimeError("Pinned source extraction is incomplete")
        source_parent.mkdir(exist_ok=True)
        (stage / source.name).rename(source)
        stage.rmdir()
    build = ROOT / f"macos/build/ffmpeg-{args.platform}"
    prefix = deps / f"ffmpeg-{args.platform}"
    if build.is_symlink() or prefix.is_symlink():
        raise RuntimeError("Build and install directories must not be symlinks")
    build.mkdir(parents=True, exist_ok=True)
    sdk_name = "macosx" if args.platform == "macos" else "iphonesimulator"
    sdk = subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip()
    triple = "arm64-apple-macos13.0" if args.platform == "macos" else "arm64-apple-ios16.0-simulator"
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
    key = {"source_archive_sha256": SOURCE_SHA256, "platform": args.platform, "triple": triple,
           "sdk": sdk, "configure": configure}
    state = build / "configuration.json"
    if state.exists() and json.loads(state.read_text()) != key:
        raise RuntimeError("Existing FFmpeg build has a different configuration; preserve it and choose a fresh build directory")
    if not state.exists():
        run(configure, build / "configure.log", cwd=build)
        state.write_text(json.dumps(key, indent=2) + "\n")
    if args.configure_only:
        print(json.dumps({"configured": True, "platform": args.platform, "build": str(build), "prefix": str(prefix)}))
        return
    start = time.monotonic()
    run(["make", f"-j{args.jobs}"], build / "build.log", cwd=build)
    run(["make", "install"], build / "install.log", cwd=build)
    archives = {}
    for name in ("avcodec", "avutil"):
        path = prefix / f"lib/lib{name}.a"
        archives[name] = {"path": str(path), "sha256": sha256(path), "bytes": path.stat().st_size}
    manifest = dict(key, source_url=URL, version=VERSION, decoders=["wmav2", "wmapro"],
        elapsed_seconds=time.monotonic() - start, archives=archives,
        gameplay_tested=False, network=False, shared=False, license="LGPL-2.1-or-later")
    manifest_path = prefix / "build-manifest.json"
    # Re-running bootstrap must not invalidate an identical dependency receipt
    # merely because the no-op build took a different amount of wall time.
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        stable_previous = {k: v for k, v in previous.items() if k != "elapsed_seconds"}
        stable_current = {k: v for k, v in manifest.items() if k != "elapsed_seconds"}
        if stable_previous == stable_current:
            manifest = previous
    serialized = json.dumps(manifest, indent=2) + "\n"
    if not manifest_path.exists() or manifest_path.read_text() != serialized:
        manifest_path.write_text(serialized)
    licenses = prefix / "share/licenses/ffmpeg"
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "COPYING.LGPLv2.1", licenses / "COPYING.LGPLv2.1")
    print(json.dumps({"built": True, "platform": args.platform, "prefix": str(prefix), "archives": archives}))


if __name__ == "__main__":
    main()
