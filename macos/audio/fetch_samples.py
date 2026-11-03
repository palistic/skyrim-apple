#!/usr/bin/env python3
"""Prepare pinned public codec test media in ignored private build output."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
MS_COMMIT = "07e3eaa10e7dd026ec9d95fe326db2d5c4227e1b"
SAMPLES = {
    "musicmono_xwma.wav": (f"https://raw.githubusercontent.com/microsoft/DirectX-SDK-Samples/{MS_COMMIT}/Media/Wavs/musicmono_xwma.wav", "2baaaf89c6a949f9eec61a167fe953097e09dbffd7c5685d0162fa2a9eafa0a1"),
    "musicsurround_xwma.wav": (f"https://raw.githubusercontent.com/microsoft/DirectX-SDK-Samples/{MS_COMMIT}/Media/Wavs/musicsurround_xwma.wav", "12ea6a97c00ca43c54aaa0c7d804bed635df4d0c36f2a99a74d1effc7c3258c3"),
    "ergon.xwma": ("https://fate-suite.ffmpeg.org/xwma/ergon.xwma", "3e25391489c17b134f4cf908def2a6b8932d973137aaf7a56445d57d89798237"),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authored", action="store_true", help="Also encode an authored sine using an existing ffmpeg tool (never install one)")
    args = parser.parse_args()
    output = ROOT / "macos/build/audio-audit"
    for parent in (ROOT / "macos", ROOT / "macos/build", output):
        if parent.is_symlink(): raise RuntimeError(f"Refusing private output symlink: {parent}")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"scope": "public-non-game-codec-test-corpus", "redistribute_media": False, "samples": {}}
    for name, (url, expected) in SAMPLES.items():
        path = output / name
        if path.is_symlink(): raise RuntimeError(f"Refusing sample symlink: {path}")
        if not path.exists():
            with urllib.request.urlopen(url, timeout=60) as source:
                contents = source.read()
            if hashlib.sha256(contents).hexdigest() != expected:
                raise RuntimeError(f"Pinned public audio sample mismatch: {name}")
            with path.open("xb") as target: target.write(contents)
        if sha(path) != expected: raise RuntimeError(f"Existing public audio fixture changed: {name}")
        manifest["samples"][name] = {"url": url, "sha256": expected, "bytes": path.stat().st_size}
    if args.authored:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg: raise RuntimeError("An existing ffmpeg encoder is required only for --authored")
        with tempfile.TemporaryDirectory(prefix="authored-wma-", dir=output) as directory:
            wave = Path(directory) / "authored.wav"
            command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-filter_threads", "1", "-f", "lavfi", "-i",
                "sine=frequency=440:sample_rate=44100:duration=0.25", "-ac", "2", "-c:a", "wmav2", "-b:a", "128k",
                "-threads", "1", "-f", "wav", str(wave)]
            subprocess.run(command, check=True)
            encoded = wave.read_bytes()
        fmt = data = None
        offset = 12
        while offset + 8 <= len(encoded):
            tag, size = struct.unpack_from("<4sI", encoded, offset)
            if offset + 8 + size > len(encoded): raise RuntimeError("Authored WAV chunk is truncated")
            chunk = encoded[offset + 8:offset + 8 + size]
            if tag == b"fmt ": fmt = chunk
            if tag == b"data": data = chunk
            offset += 8 + size + (size & 1)
        if fmt is None or data is None: raise RuntimeError("Authored WMAv2 output lacks format/data")
        tag, channels, rate, avg, block, bits, extra = struct.unpack_from("<HHIIHHH", fmt)
        if tag != 0x161 or not block or len(data) % block: raise RuntimeError("Unexpected authored WMAv2 encoding")
        count = len(data) // block
        # FFmpeg's ordinary WMAv2 encoder uses fixed 2048-sample frames and
        # retains codec extradata. This exercises that path, not normal xWMA's
        # missing-extradata flags31. The pinned Microsoft corpus covers flags31.
        dpds = struct.pack("<" + "I" * count, *[(n + 1) * 2048 * channels * 2 for n in range(count)])
        def chunk(tag, contents):
            return tag + struct.pack("<I", len(contents)) + contents + b"\0" * (len(contents) & 1)
        body = b"XWMA" + chunk(b"fmt ", fmt) + chunk(b"dpds", dpds) + chunk(b"data", data)
        path = output / "authored-wmav2.xwma"
        if path.is_symlink(): raise RuntimeError("Refusing authored fixture symlink")
        path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
        manifest["samples"][path.name] = {"authored": True, "command": command,
            "encoder_version": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
            "sha256": sha(path), "bytes": path.stat().st_size,
            "scope": "authored sine WMAv2 with retained extradata; not an official xWMA encoder"}
    (output / "corpus-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"corpus": str(output), "samples": list(manifest["samples"])}))


if __name__ == "__main__":
    main()
