#!/usr/bin/env python3
"""Install this diagnostic on a dedicated iPad Simulator, without a debugger."""
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent
BUNDLE = "dev.zschwendi.skyrim.jitless.probe"
NAME = "Skyrim JITless iPad"
TYPE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
PROBE_ARTIFACTS = {
    "SkyrimRuntimeProbe.app/SkyrimRuntimeProbe",
    "SkyrimRuntimeProbe.app/Frameworks/libSDL2-2.0.0.dylib",
    "SkyrimRuntimeProbe.app/Frameworks/libdxvk_d3d9.dylib",
}


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_build_receipt(root):
    """Read-only consistency check; run before touching any Simulator state."""
    root = Path(root)
    receipt_bytes = (root / "build/app-build-receipt.json").read_bytes()
    receipt = json.loads(receipt_bytes)
    if not isinstance(receipt, dict) or receipt.get("schema") != 1:
        raise ValueError("Missing or unsupported diagnostic build receipt; rebuild with simulator/build.sh")
    sources, artifacts = receipt.get("sources"), receipt.get("artifacts")
    if not isinstance(sources, dict) or not sources or not isinstance(artifacts, dict) or not PROBE_ARTIFACTS <= artifacts.keys():
        raise ValueError("Diagnostic build receipt lacks source or executable/framework identities; rebuild")
    if not isinstance(receipt.get("audio_enabled"), bool):
        raise ValueError("Diagnostic build receipt lacks the audio configuration; rebuild")
    for name, expected in sources.items():
        path = Path(name)
        if not path.is_file() or file_sha256(path) != expected:
            raise ValueError(f"Diagnostic source changed since its build: {name}; rebuild")
    build = (root / "build/native").resolve()
    for name, recorded in artifacts.items():
        path = (build / name).resolve()
        if not path.is_relative_to(build) or not isinstance(recorded, dict):
            raise ValueError(f"Invalid diagnostic artifact identity: {name}")
        if not path.is_file() or file_sha256(path) != recorded.get("sha256"):
            raise ValueError(f"Diagnostic executable or framework changed since its build: {name}; rebuild")
        if "IOSSIMULATOR" not in recorded.get("platform", ""):
            raise ValueError(f"Diagnostic artifact lacks its iOS Simulator platform identity: {name}")
    return receipt, hashlib.sha256(receipt_bytes).hexdigest()


def command(*args, capture=True):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True).strip() if capture else subprocess.check_call(["xcrun", "simctl", *args])


def main():
    try:
        build_receipt, build_receipt_sha = verify_build_receipt(ROOT)
    except (OSError, ValueError, TypeError) as error:
        raise SystemExit(f"Diagnostic build preflight failed: {error}") from error
    app = ROOT / "build/native/SkyrimRuntimeProbe.app"
    if not app.is_dir():
        raise SystemExit("Build the diagnostic app with simulator/build.sh first")
    subprocess.check_call(["codesign","--verify","--deep","--strict",str(app)])
    device_record = ROOT / "build/simulator-device.json"
    inventory = json.loads(command("list", "devices", "available", "-j"))["devices"]
    existing = [item for devices in inventory.values() for item in devices]
    if device_record.exists():
        device = json.loads(device_record.read_text())
        matches = [item for item in existing if item["udid"] == device["udid"] and item["name"] == NAME]
        if len(matches) != 1:
            raise SystemExit("Recorded dedicated simulator is missing or renamed; preserve other simulators and inspect the record")
        udid = device["udid"]
        state = matches[0]["state"]
    else:
        udid = command("create", NAME, TYPE, RUNTIME)
        state = "Shutdown"
        device = {"udid": udid, "name": NAME, "device_type": TYPE, "runtime": RUNTIME}
        device_record.write_text(json.dumps(device, indent=2) + "\n")
    if state == "Shutdown":
        command("boot", udid)
    elif state != "Booted":
        raise SystemExit(f"Dedicated simulator has state {state}; inspect before booting")
    command("bootstatus", udid, "-b", capture=False)
    command("install", udid, str(app))
    container = Path(command("get_app_container", udid, BUNDLE, "data"))
    result_path = container / "Documents/RuntimeProbe/diagnostic-result.json"
    if result_path.exists():
        result_path.unlink()  # Only this diagnostic's previous result, never game saves.
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    stamp=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    stdout, stderr = evidence / (stamp+".stdout.log"), evidence / (stamp+".stderr.log")
    launch = command("launch", "--terminate-running-process", "--stdout=" + str(stdout), "--stderr=" + str(stderr), udid, BUNDLE)
    print(launch, flush=True)
    pid = int(launch.rsplit(":",1)[1].strip())
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline and not result_path.exists():
        try:
            os.kill(pid,0)
        except ProcessLookupError:
            raise SystemExit(f"Diagnostic process {pid} exited before publishing its CPU/GPU result. Inspect {stderr}; no automatic restart attempted.")
        time.sleep(0.25)
    if not result_path.exists():
        raise SystemExit(f"No diagnostic result; inspect {stderr} and the live simulator process. No automatic restart attempted.")
    result = json.loads(result_path.read_text())
    if result.get("scope") != "game-free-ipad-simulator" or not result.get("gpu_readback_pass") or not result.get("guest_dxt1_bridge_pass") or not result.get("aot_total") or result.get("aot_passed") != result.get("aot_total"):
        raise SystemExit("Diagnostic did not pass all real CPU/GPU checks")
    if build_receipt.get("audio_enabled") and (result.get("native_xwma_decode_checks", 0) == 0 or result.get("wmav2_mono_frames", 0) == 0 or result.get("wmapro_surround_frames", 0) == 0):
        raise SystemExit("The audio-enabled diagnostic did not pass real native codec checks")
    try:
        _current, current_receipt_sha = verify_build_receipt(ROOT)
        if current_receipt_sha != build_receipt_sha:
            raise ValueError("Diagnostic build receipt changed during launch")
    except (OSError, ValueError, TypeError) as error:
        raise SystemExit(f"Diagnostic build changed during launch: {error}") from error
    (evidence / "diagnostic-result.json").write_text(json.dumps(result, indent=2) + "\n")
    command("io", udid, "screenshot", str(evidence / "probe.png"), capture=False)
    receipt = {"schema": 1, "device": device, "launch": launch,
               "build_receipt_sha256": build_receipt_sha,
               "stdout":str(stdout),"stderr":str(stderr),
               "executable_sha256": build_receipt["artifacts"]["SkyrimRuntimeProbe.app/SkyrimRuntimeProbe"]["sha256"],
               "result": result, "gameplay_tested": False,
               "simulator_left_running": True, "physical_device_tested": False}
    (evidence / "launch-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
