#!/usr/bin/env python3
"""Run the real native decoder and compare private PCM to a local FFmpeg reference."""
import argparse
import array
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, default=ROOT / "macos/build/native/audio_codec_probe")
    args = parser.parse_args()
    corpus = ROOT / "macos/build/audio-audit"
    manifest = json.loads((corpus / "corpus-manifest.json").read_text())
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg: raise RuntimeError("This optional independent-reference comparison requires an existing ffmpeg tool")
    results = {"scope": "native-codec-public-and-authored-fixtures", "gameplay_tested": False,
        "probe_sha256": sha(args.probe), "reference_version": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0], "samples": {}}
    for name, record in manifest["samples"].items():
        sample = corpus / name
        if sha(sample) != record["sha256"]: raise RuntimeError(f"Audio sample changed: {name}")
        pcm = corpus / (name + ".native.pcm")
        result = subprocess.run([str(args.probe), str(sample), str(pcm)], capture_output=True, text=True, timeout=30)
        if result.returncode: raise RuntimeError(result.stdout + result.stderr)
        observed = json.loads(result.stdout.splitlines()[-1])
        reference = corpus / (name + ".reference.pcm")
        command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-threads", "1", "-i", str(sample), "-map", "0:a:0",
            "-acodec", "pcm_s16le", "-threads", "1", "-f", "s16le", "-y", str(reference)]
        subprocess.run(command, capture_output=True, check=True, timeout=30)
        native_samples, reference_samples = array.array("h"), array.array("h")
        native_samples.frombytes(pcm.read_bytes()); reference_samples.frombytes(reference.read_bytes())
        if len(native_samples) != len(reference_samples): raise RuntimeError(f"Native/reference decoded lengths differ: {name}")
        differences = [abs(a - b) for a, b in zip(native_samples, reference_samples)]
        maximum = max(differences)
        # Different FFmpeg versions and native float transforms may round by one
        # S16 unit. This bounds differences instead of claiming byte identity.
        if maximum > 2: raise RuntimeError(f"Native/reference PCM differs by {maximum} S16 units: {name}")
        results["samples"][name] = {"observed": observed, "sample_sha256": sha(sample),
            "native_pcm_sha256": sha(pcm), "reference_pcm_sha256": sha(reference),
            "samples": len(native_samples), "maximum_s16_difference": maximum,
            "mean_s16_difference": sum(differences) / len(differences), "reference_command": command,
            "probe_stderr": result.stderr}
    results["pass"] = True
    (corpus / "reference-validation.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps({"pass": True, "samples": len(results["samples"]), "receipt": str(corpus / "reference-validation.json")}))


if __name__ == "__main__":
    main()
