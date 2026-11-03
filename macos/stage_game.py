#!/usr/bin/env python3
"""Make a private normalized input view without editing the owned installation."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from inputs import ROOT, find_unique, validate_game


def stage_game(game_directory, output, unpacked_executable=None, directx_directory=None):
    game = Path(game_directory).resolve(strict=True)
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError(f"Preserving existing output: {output}")
    resolved_output = output.resolve(strict=False)
    if resolved_output.is_relative_to(game) or game.is_relative_to(resolved_output):
        raise ValueError("The private view must be separate from the original game installation")
    sources = {name: find_unique(game, name).resolve(strict=True)
               for name in ("TESV.exe", "binkw32.dll", "Data")}
    if unpacked_executable is None:
        sources["TESV_unpacked.exe"] = find_unique(game, "TESV_unpacked.exe").resolve(strict=True)
    else:
        sources["TESV_unpacked.exe"] = Path(unpacked_executable).resolve(strict=True)
    # First-run preferences read this preset from the normalized game directory.
    # It is optional, but multiple case variants must not be chosen arbitrarily.
    if any(p.name.casefold() == "low.ini" for p in game.iterdir()):
        sources["low.ini"] = find_unique(game, "low.ini").resolve(strict=True)
    for name in ("d3dx9_42.dll", "X3DAudio1_7.dll"):
        matches = [p for p in game.iterdir() if p.name.casefold() == name.casefold()]
        if matches:
            sources[name] = find_unique(game, name).resolve(strict=True)
        elif directx_directory is not None:
            sources[name] = find_unique(Path(directx_directory), name).resolve(strict=True)
        else:
            raise ValueError(f"Missing {name}; prepare the official DirectX inputs or provide --directx-dir")
    if not sources["Data"].is_dir() or any(not p.is_file() for n, p in sources.items() if n != "Data"):
        raise ValueError("Expected original executable/libraries and the complete Data directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".skyrim-input-view-", dir=output.parent))
    try:
        for name, source in sources.items():
            (staging / name).symlink_to(source, target_is_directory=name == "Data")
        validate_game(staging)
        (staging / "input-view.json").write_text(json.dumps({
            "scope": "private-normalized-owned-input-view", "source_directory": str(game),
            "sources": {name: str(path) for name, path in sources.items()},
            "original_files_changed": False}, indent=2) + "\n")
        if output.exists() or output.is_symlink():
            raise ValueError(f"Preserving output created while staging: {output}")
        os.rename(staging, output)
        return output
    finally:
        if staging.exists():
            # This directory contains only links created above and our receipt;
            # rmtree removes the links, never their original game-file targets.
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game_directory", type=Path)
    parser.add_argument("--unpacked-exe", type=Path)
    parser.add_argument("--directx-dir", type=Path, default=ROOT / "macos/build/directx/inputs")
    parser.add_argument("--output", type=Path, default=ROOT / "macos/build/owned-inputs")
    args = parser.parse_args()
    try:
        output = stage_game(args.game_directory, args.output, args.unpacked_exe, args.directx_dir)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"Validated private input view: {output}")


if __name__ == "__main__":
    main()
