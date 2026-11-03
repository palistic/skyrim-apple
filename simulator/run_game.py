#!/usr/bin/env python3
"""Stage the private game into the dedicated iPad Simulator app container and launch it.

For the parent, after `simulator/build.sh --game --audio`. Every identity check
(build receipt, generated-code binding, app resource, owned game view) runs
read-only BEFORE any simctl command. `--preflight-only` stops there.

Game files are APFS-cloned (clonefile(2), never copied, never linked) from the
verified private view into <app data container>/Documents/Skyrim, so the app
sees ordinary container files as on an iPad, the originals cannot be modified
through the clones, and the clones cost almost no disk space. clonefile fails
instead of falling back to a copy. An existing Documents/Skyrim is verified,
never replaced. Saves stay in Documents/SkyrimSaves. Only the recorded
`Skyrim JITless iPad` simulator is used; no debugger, no automatic restart.
"""
import argparse
import ctypes
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess
import sys
import time

import run_probe

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
BUNDLE = "dev.zschwendi.skyrim.jitless"
GAME_ARTIFACTS = {
    "SkyrimJitless.app/SkyrimJitless",
    "SkyrimJitless.app/Frameworks/libSDL2-2.0.0.dylib",
    "SkyrimJitless.app/Frameworks/libdxvk_d3d9.dylib",
}
MODULES = ("TESV.exe", "TESV_unpacked.exe", "d3dx9_42.dll", "binkw32.dll", "X3DAudio1_7.dll")
ESSENTIAL = ("Skyrim.esm", "Update.esm")
VIEW_METADATA = {"input-view.json"}  # the private view's own receipt, not a game file
ENV_PREFIX = "SIMCTL_CHILD_"

file_sha256 = run_probe.file_sha256


def unique_child(directory, name):
    """Case-insensitive unique entry, as the app's validator resolves it."""
    matches = [p for p in Path(directory).iterdir() if p.name.lower() == name.lower()]
    return matches[0] if len(matches) == 1 else None


def verify_game_build(root=ROOT, repo=REPO):
    """Read-only: the sealed game app, its frameworks and gen/ binding."""
    receipt, receipt_sha = run_probe.verify_build_receipt(root)  # sources + all artifacts
    if receipt.get("game_built") is not True or not GAME_ARTIFACTS <= receipt["artifacts"].keys():
        raise ValueError("The build receipt has no game app; run simulator/build.sh --game --audio")
    generated = file_sha256(Path(repo) / "gen/input-manifest.json")
    if receipt.get("generated_manifest_sha256") != generated:
        raise ValueError("The game app was not built from the current verified gen/; rebuild")
    resource = Path(root) / "build/native/SkyrimJitless.app/game-input-manifest.json"
    if file_sha256(resource) != receipt.get("game_input_resource_sha256"):
        raise ValueError("The app's bundled game input identity changed since its build")
    identity = json.loads(resource.read_text())
    if identity.get("schema") != 1 or identity.get("generated_manifest_sha256") != generated:
        raise ValueError("The app's bundled input identity is not bound to the current gen/")
    return receipt, receipt_sha, identity


def verify_game_view(game_dir, identity):
    """Read-only: exact modules and essential data the app will demand."""
    game_dir = Path(game_dir)
    hashes = {}
    for name in MODULES:
        path = unique_child(game_dir, name)
        if not path or file_sha256(path) != identity["modules"].get(name):
            raise ValueError(f"{name} in {game_dir} does not match this app's build inputs")
        hashes[name] = identity["modules"][name]
    data = unique_child(game_dir, "Data")
    for name in ESSENTIAL:
        path = unique_child(data, name) if data else None
        if not path or file_sha256(path) != identity["essential_data"].get(name):
            raise ValueError(f"Data/{name} in {game_dir} does not match this app's build inputs")
        hashes["Data/" + name] = identity["essential_data"][name]
    if not any(p.suffix.lower() == ".bsa" for p in data.iterdir()):
        raise ValueError("The game view's Data directory has no BSA archives")
    return hashes


def clone_plan(game_dir):
    """Every regular file of the view (symlinks resolved), as relative paths."""
    game_dir = Path(game_dir)
    plan = []
    for directory, subdirectories, names in os.walk(game_dir, followlinks=True):
        subdirectories.sort()
        for name in sorted(names):
            relative = (Path(directory) / name).relative_to(game_dir)
            if relative.as_posix() in VIEW_METADATA:
                continue
            source = (Path(directory) / name).resolve(strict=True)
            if not source.is_file():
                raise ValueError(f"Not a regular game file: {relative}")
            plan.append((relative, source))
    if not plan:
        raise ValueError(f"No game files under {game_dir}")
    return plan


_LIBC = ctypes.CDLL(None, use_errno=True)
_LIBC.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
_LIBC.clonefile.restype = ctypes.c_int


def clone_file(source, destination):
    if _LIBC.clonefile(os.fsencode(source), os.fsencode(destination), 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, f"clonefile refused ({os.strerror(error)}); nothing is copied instead", str(destination))


def clone_view(game_dir, destination):
    """Clone the view into a NEW destination directory; returns a summary."""
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"Refusing to replace existing {destination}")
    plan = clone_plan(game_dir)
    free_before = shutil.disk_usage(destination.parent).free
    staging = destination.with_name(destination.name + ".staging")
    if staging.exists():
        raise ValueError(f"A previous interrupted staging directory exists: {staging}; inspect it")
    staging.mkdir()
    logical = 0
    for relative, source in plan:
        target = staging / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        clone_file(source, target)
        logical += source.stat().st_size
    staging.rename(destination)
    return {"files": len(plan), "logical_bytes": logical,
            "free_bytes_before": free_before, "free_bytes_after": shutil.disk_usage(destination.parent).free}


def simctl(*args, env=None):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, env=env).strip()


def dedicated_device():
    record = json.loads((ROOT / "build/simulator-device.json").read_text())
    devices = json.loads(simctl("list", "devices", "available", "-j"))["devices"]
    matches = [d for group in devices.values() for d in group
               if d["udid"] == record["udid"] and d["name"] == run_probe.NAME]
    if len(matches) != 1:
        raise SystemExit("The recorded dedicated simulator is missing or renamed; inspect simulator/build/simulator-device.json")
    return record, matches[0]["state"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game-dir", type=Path, help="Verified private game view (default: the one gen/ was generated from)")
    parser.add_argument("--preflight-only", action="store_true", help="Run only the read-only identity checks")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE",
                        help="Launch environment for the game, e.g. LB_SHOT=3000,9000 or LB_LOG=1 (repeatable)")
    parser.add_argument("--watch-seconds", type=float, default=120.0, help="Report whether the process stays alive this long")
    args = parser.parse_args()
    try:
        receipt, receipt_sha, identity = verify_game_build()
        game_dir = args.game_dir or Path(json.loads((REPO / "gen/input-manifest.json").read_text())["game_directory"])
        view_hashes = verify_game_view(game_dir, identity)
        clone_plan(game_dir)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"Game preflight failed (no simulator state touched): {error}") from error
    launch_env = {}
    for item in args.env:
        key, separator, value = item.partition("=")
        if not separator or not key.replace("_", "").isalnum():
            parser.error(f"Invalid --env {item!r}")
        launch_env[key] = value
    print(json.dumps({"preflight": "passed", "game_dir": str(game_dir), "build_receipt_sha256": receipt_sha,
                      "executable_sha256": receipt["artifacts"]["SkyrimJitless.app/SkyrimJitless"]["sha256"]}, indent=2))
    if args.preflight_only:
        return
    app = ROOT / "build/native/SkyrimJitless.app"
    subprocess.check_call(["codesign", "--verify", "--deep", "--strict", str(app)])
    device, state = dedicated_device()
    udid = device["udid"]
    if state == "Shutdown":
        simctl("boot", udid)
    elif state != "Booted":
        raise SystemExit(f"Dedicated simulator has state {state}; inspect before booting")
    subprocess.check_call(["xcrun", "simctl", "bootstatus", udid, "-b"])
    simctl("install", udid, str(app))
    container = Path(simctl("get_app_container", udid, BUNDLE, "data"))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    target = documents / "Skyrim"
    if target.exists():
        staged = {"reused": True, "hashes": verify_game_view(target, identity)}
    else:
        staged = {"reused": False, **clone_view(game_dir, target), "hashes": verify_game_view(target, identity)}
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    stdout, stderr = evidence / f"game-{stamp}.stdout.log", evidence / f"game-{stamp}.stderr.log"
    env = dict(os.environ, **{ENV_PREFIX + key: value for key, value in launch_env.items()})
    launch = simctl("launch", "--terminate-running-process", "--stdout=" + str(stdout), "--stderr=" + str(stderr),
                    udid, BUNDLE, env=env)
    pid = int(launch.rsplit(":", 1)[1].strip())
    deadline, alive = time.monotonic() + args.watch_seconds, True
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            alive = False
            break
        time.sleep(1)
    _current, current_sha = run_probe.verify_build_receipt(ROOT)
    launch_receipt = {"schema": 1, "scope": "private-skyrim-ipad-simulator-game-launch", "device": device,
                      "launch": launch, "pid": pid, "alive_after_seconds": args.watch_seconds if alive else None,
                      "exited_early": not alive, "build_receipt_sha256": receipt_sha,
                      "build_receipt_unchanged": current_sha == receipt_sha,
                      "executable_sha256": receipt["artifacts"]["SkyrimJitless.app/SkyrimJitless"]["sha256"],
                      "generated_manifest_sha256": receipt["generated_manifest_sha256"],
                      "game_view": str(game_dir), "view_hashes": view_hashes, "container_stage": staged,
                      "launch_env": launch_env, "stdout": str(stdout), "stderr": str(stderr),
                      "debugger": False, "gameplay_verified": False, "physical_device_tested": False}
    (evidence / f"game-launch-{stamp}.json").write_text(json.dumps(launch_receipt, indent=2) + "\n")
    print(json.dumps(launch_receipt, indent=2))
    if not alive:
        raise SystemExit(f"Game process {pid} exited within {args.watch_seconds:.0f}s; inspect {stderr}. No automatic restart.")


if __name__ == "__main__":
    sys.exit(main())
