#!/usr/bin/env python3
"""Local launcher operations. stdout is JSON; detailed helper output stays in a private log."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import traceback

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "macos"))
import build_receipt
import inputs
import stage_game


class UserIssue(ValueError):
    pass


def work_directory() -> Path:
    return ROOT / "macos/build/launcher"


def optional_file(directory: Path, name: str) -> Path | None:
    matches = [p for p in directory.iterdir() if p.name.casefold() == name.casefold()]
    if len(matches) > 1:
        raise UserIssue(f"More than one {name} was found. Choose an unambiguous installation.")
    return matches[0] if matches else None


def inspect_original(directory: Path) -> dict:
    directory = directory.resolve(strict=True)
    if not directory.is_dir():
        raise UserIssue("Choose the Skyrim installation folder.")
    selected = {}
    for name in ("TESV.exe", "binkw32.dll", "Data"):
        path = optional_file(directory, name)
        if path is None:
            raise UserIssue(f"This folder is missing {name}. Choose the complete original Windows installation.")
        selected[name] = path
    for name in ("TESV.exe", "binkw32.dll"):
        if not selected[name].is_file():
            raise UserIssue(f"{name} must be a file from the original installation.")
        inputs.check_pe32(selected[name])
    if not inputs.digest(selected["TESV.exe"], "sha1").startswith(inputs.EXPECTED["TESV.exe"]):
        raise UserIssue("This copy does not match the supported original Windows Skyrim 1.9.32.0.8 executable.")
    data = selected["Data"]
    if not data.is_dir():
        raise UserIssue("The installation's Data folder is missing.")
    for name in ("Skyrim.esm", "Update.esm"):
        path = optional_file(data, name)
        if path is None or not path.is_file() or path.stat().st_size == 0:
            raise UserIssue(f"The Data folder is missing {name}. Choose the complete installation.")
    if not any(p.is_file() and p.suffix.casefold() == ".bsa" for p in data.iterdir()):
        raise UserIssue("The Data folder has no Skyrim archives. Choose the complete installation.")
    selected["original_sha256"] = inputs.digest(selected["TESV.exe"])
    return selected


def staged_path(game: Path, original: dict) -> Path:
    identity = hashlib.sha256((str(game.resolve()) + "\0" + original["original_sha256"]).encode()).hexdigest()[:20]
    return work_directory() / "inputs" / identity


def check_stage(game: Path, staged: Path, original: dict) -> None:
    metadata = json.loads((staged / "input-view.json").read_text())
    if Path(metadata["source_directory"]).resolve() != game.resolve():
        raise UserIssue("Existing prepared inputs belong to another installation and were preserved.")
    if (staged / "TESV.exe").resolve() != original["TESV.exe"].resolve():
        raise UserIssue("Existing prepared inputs point to a different executable and were preserved.")
    inputs.validate_game(staged)


def check_existing_generation(original: dict, staged: Path | None = None) -> None:
    generated = ROOT / "gen"
    if not generated.exists() and not generated.is_symlink():
        return
    try:
        manifest = json.loads((generated / "input-manifest.json").read_text())
        if manifest["modules"]["TESV.exe"]["sha256"] != original["original_sha256"]:
            raise ValueError("different original executable")
        inputs.verify_generated(generated, staged) if staged is not None else inputs.verify_generated(generated)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise UserIssue("Existing prepared game files do not match this copy or the current tools. They were preserved; see the log.") from error


def result(headline: str, detail: str, *, ready: bool = False, prepare: bool = False,
           staged: Path | None = None, error: str | None = None, success: bool = True) -> dict:
    return {"success": success, "headline": headline, "detail": detail,
            "isReady": ready, "canPrepare": prepare,
            "stagedDirectory": str(staged) if staged else None, "error": error}


def status(game: Path | None, log) -> dict:
    if game is None:
        return result("Choose your Skyrim folder", "Select your original Windows Skyrim installation to get started.")
    try:
        original = inspect_original(game)
        staged = staged_path(game, original)
        available_stage = staged.exists() or staged.is_symlink()
        if available_stage:
            check_stage(game, staged, original)
        check_existing_generation(original, staged if available_stage else None)
    except (OSError, ValueError, KeyError, TypeError) as error:
        traceback.print_exc(file=log)
        message = str(error) if isinstance(error, UserIssue) else "The selected folder could not be validated. See the log for details."
        return result("Skyrim needs attention", message, error=message)
    binary = ROOT / "macos/build/native/skyrim_macos"
    if available_stage and binary.is_file() and (ROOT / "gen").is_dir():
        try:
            build_receipt.verify(ROOT / "gen", binary, binary.parent, staged)
            return result("Ready to play", "Your private macOS build is ready. Saves stay in a separate folder.", ready=True, prepare=True, staged=staged)
        except (OSError, ValueError, KeyError, TypeError):
            traceback.print_exc(file=log)
            return result("Ready to finish setup", "Your game files are available. Prepare Skyrim to build the current macOS version.", prepare=True, staged=staged)
    return result("Ready to prepare", "Build your private macOS copy from these original Windows game files.", prepare=True,
                  staged=staged if available_stage else None)


def run_command(arguments: list[str], log, *, timeout: int | None = None) -> str:
    print("\nRunning:", json.dumps(arguments), file=log, flush=True)
    # Keep expensive generation/build output off the app's stdout JSON channel.
    completed = subprocess.run(arguments, cwd=ROOT, env=os.environ | {"SKYRIM_BUILD_JOBS": "1"},
                               stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    log.flush()
    if completed.returncode:
        raise UserIssue("Preparation could not finish. Your original game files were preserved; open the log for details.")
    return ""


def converter_ready() -> bool:
    try:
        path = ROOT / "macos/executable/common.py"
        spec = importlib.util.spec_from_file_location("skyrim_launcher_converter_common", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.load_tool(ROOT / "macos/build/steamless/CURRENT.json")
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def prepare_generated(game: Path | None, log) -> Path:
    """Unpack, stage and generate the verified gen/ for this installation; returns the staged view.

    The macOS game build is separate (prepare); ipad/build.py prepare stops here.
    """
    if game is None:
        raise UserIssue("Choose your original Skyrim folder first.")
    original = inspect_original(game)
    staged = staged_path(game, original)
    # Refuse unrelated/incompatible generated code before conversion or compilation.
    check_existing_generation(original, staged if staged.exists() else None)
    python = ROOT / "macos/.venv/bin/python"
    if not python.is_file():
        raise UserIssue("The local Mac build tools are missing. Open the log for setup details.")
    if staged.exists() or staged.is_symlink():
        check_stage(game, staged, original)
    else:
        directx = ROOT / "macos/build/directx/inputs"
        if any(optional_file(game, name) is None and not (directx / name).is_file()
               for name in ("d3dx9_42.dll", "X3DAudio1_7.dll")):
            run_command([str(python), str(ROOT / "macos/directx/fetch.py")], log)
        unpacked = optional_file(game, "TESV_unpacked.exe")
        if unpacked is None:
            unpacked = optional_file(game, "TESV.exe.unpacked.exe")
        if unpacked is None:
            if not converter_ready():
                run_command([str(python), str(ROOT / "macos/executable/build.py")], log)
            print("\nPreparing a private executable copy.", file=log, flush=True)
            converted = subprocess.run([str(python), str(ROOT / "macos/executable/unpack.py"), str(original["TESV.exe"])],
                                       cwd=ROOT, stdout=subprocess.PIPE, stderr=log, text=True)
            print(converted.stdout, file=log, flush=True)
            if converted.returncode:
                raise UserIssue("This executable could not be prepared. The original was preserved; open the log for details.")
            unpacked = Path(converted.stdout.strip())
        inputs.check_pe32(unpacked)
        if not inputs.digest(unpacked, "sha1").startswith(inputs.EXPECTED["TESV_unpacked.exe"]):
            raise UserIssue("The prepared executable does not match this Skyrim build. Existing files were preserved.")
        stage_game.stage_game(game, staged, unpacked, directx)
    check_existing_generation(original, staged)
    if not (ROOT / "gen").exists():
        run_command([str(python), str(ROOT / "macos/prepare_game.py"), str(staged)], log)
    inputs.verify_generated(ROOT / "gen", staged)
    return staged


def prepare(game: Path | None, log) -> dict:
    prepare_generated(game, log)
    run_command(["/bin/sh", str(ROOT / "macos/build.sh"), "--game"], log)
    final = status(game, log)
    if not final["isReady"]:
        raise UserIssue("The build finished but could not be verified. Open the log for details.")
    return final


def launch(game: Path | None, saves: Path, log, events) -> dict:
    current = status(game, log)
    if not current["isReady"]:
        raise UserIssue("Prepare and verify Skyrim before playing.")
    saves.mkdir(parents=True, exist_ok=True)
    command = ["/bin/sh", str(ROOT / "macos/run.sh"), current["stagedDirectory"], str(saves)]
    print("\nLaunching:", json.dumps(command), file=log, flush=True)
    process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    print(json.dumps({"event": "processStarted", "processID": process.pid}), file=events, flush=True)
    code = process.wait()
    log.flush()
    final = status(game, log)
    if code:
        final.update(success=False, error="Skyrim closed unexpectedly. Open the log for details.",
                     headline="Skyrim closed", detail="Your saves are kept separately. The launch log has more information.")
    return final


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "prepare", "launch"))
    parser.add_argument("--game-dir", type=Path)
    parser.add_argument("--save-dir", type=Path, default=Path.home() / "Library/Application Support/Skyrim Jitless/Saves")
    args = parser.parse_args()
    directory = work_directory()
    directory.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=args.command + "-", suffix=".log", dir=directory)
    log_path = Path(name)
    output = sys.stdout
    with os.fdopen(descriptor, "w") as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        print("Skyrim launcher operation:", args.command, "\nGame directory:", args.game_dir, file=log, flush=True)
        try:
            if args.command == "status":
                answer = status(args.game_dir, log)
            elif args.command == "prepare":
                answer = prepare(args.game_dir, log)
            else:
                answer = launch(args.game_dir, args.save_dir, log, output)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            traceback.print_exc(file=log)
            message = str(error) if isinstance(error, UserIssue) else "The operation could not finish. Open the log for details."
            answer = result("Skyrim needs attention", message, error=message, success=False)
    answer["logPath"] = str(log_path)
    print(json.dumps(answer), file=output, flush=True)
    return 0 if answer["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
