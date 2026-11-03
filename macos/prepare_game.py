#!/usr/bin/env python3
"""Generate private ARM64-buildable C from owned Windows Skyrim inputs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from inputs import ROOT, TOOLS, digest, validate_game


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game_directory", type=Path)
    args = parser.parse_args()
    target = ROOT / "gen"
    if target.exists():
        parser.error("gen already exists; preserve it before generating a new private source set")
    try:
        receipt = validate_game(args.game_directory)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    build = ROOT / "macos" / "build"
    build.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix="private-generation-", dir=build))
    generated = stage / "gen"
    generated.mkdir()
    tool_hashes = {name: digest(ROOT / name) for name in TOOLS}
    env = dict(os.environ, LIFT_GAME="skyrim")
    specs = (("TESV_unpacked.exe", "exe", None), ("d3dx9_42.dll", "d3dx9", "08000000"),
             ("binkw32.dll", "bink", "09000000"), ("X3DAudio1_7.dll", "x3da", "0A000000"))
    for name, family, base in specs:
        path = receipt["modules"][name]["path"]
        functions = stage / f"functions_{family}.json"
        extra = [base] if base else []
        subprocess.run([sys.executable, str(ROOT / "tools/discover.py"), path, str(functions), *extra],
                       cwd=ROOT / "tools", env=env, check=True)
        subprocess.run([sys.executable, str(ROOT / "tools/lift.py"), path, str(functions),
                        str(generated), family, *extra], cwd=ROOT, env=env, check=True)
    # Bind source output to inputs actually present after the long generation.
    after = validate_game(args.game_directory)
    if receipt != after:
        raise RuntimeError("Owned input files changed during generation; staged output was not published")
    if tool_hashes != {name: digest(ROOT / name) for name in TOOLS}:
        raise RuntimeError("Recompiler source changed during generation; staged output was not published")
    receipt["tools"] = tool_hashes
    receipt["generated"] = {p.name: digest(p) for p in sorted(generated.iterdir()) if p.suffix in (".c", ".h")}
    (generated / "input-manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
    generated.rename(target)
    print(f"Private generated source ready at {target}; no game files were changed.")


if __name__ == "__main__":
    main()
