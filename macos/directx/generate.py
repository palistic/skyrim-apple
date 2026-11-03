#!/usr/bin/env python3
"""Run the real scanner/lifter on the two private Microsoft x86 DLLs.

The generated C is derived from Microsoft binaries and remains only under the
ignored macos/build/directx tree. This does not prepare Skyrim or binkw32.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from fetch import MODULES, OUTPUT, ROOT, private_path, sha256

TOOLS = ("tools/discover.py", "tools/lift.py", "tools/peimg.py")


def hashes():
    return {name: sha256(ROOT / name) for name in TOOLS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", action="append", choices=[item["family"] for item in MODULES.values()])
    args = parser.parse_args()
    selected = args.module or [item["family"] for item in MODULES.values()]
    private_path(OUTPUT).mkdir(parents=True, exist_ok=True)
    before_tools = hashes()
    run = Path(tempfile.mkdtemp(prefix="aot-", dir=OUTPUT))
    analysis = run / "analysis"
    generated = run / "gen"
    analysis.mkdir()
    generated.mkdir()
    env = dict(os.environ, LIFT_GAME="skyrim", PYTHONUNBUFFERED="1")
    receipt = {"schema": 1, "scope": "official-directx-x86-static-recompilation",
               "game_files_used": False, "tools": before_tools, "modules": {}}
    for filename, settings in MODULES.items():
        family = settings["family"]
        if family not in selected:
            continue
        module = private_path(OUTPUT / "inputs" / filename)
        if sha256(module) != settings["sha256"]:
            parser.error(f"Run fetch.py first; module differs from the pinned official bytes: {filename}")
        functions = analysis / f"functions_{family}.json"
        commands = [
            [sys.executable, str(ROOT / "tools/discover.py"), str(module), str(functions), settings["base"]],
            [sys.executable, str(ROOT / "tools/lift.py"), str(module), str(functions), str(generated), family, settings["base"]],
        ]
        for step, command in zip(("discover", "lift"), commands):
            print(f"{family}: {step}; private log {run / (family + '-' + step + '.log')}", flush=True)
            with (run / f"{family}-{step}.log").open("w") as log:
                subprocess.run(command, cwd=ROOT / "tools", env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        discovered = json.loads(functions.read_text())
        rejected = json.loads((generated / f"{family}_rejected.json").read_text())
        table = (generated / f"{family}_table.c").read_text()
        lifted_count = int(re.search(r"g_fn_count_\w+ = (\d+);", table).group(1))
        receipt["modules"][filename] = {"sha256": settings["sha256"], "base": settings["base"],
            "family": family, "discovered_functions": len(discovered["functions"]),
            "lifted_functions": lifted_count, "rejected_functions": len(rejected),
            "unresolved_indirect_jumps": len(discovered["indirect_jumps"]),
            "analysis_sha256": sha256(functions), "exports": discovered["exports"]}
        if sha256(module) != settings["sha256"]:
            raise RuntimeError(f"DLL changed while generating: {filename}")
    if hashes() != before_tools:
        raise RuntimeError(f"Recompiler changed during generation; private run retained without a success receipt: {run}")
    receipt["generated"] = {path.name: sha256(path) for path in sorted(generated.iterdir())}
    receipt["generated_bytes"] = sum(path.stat().st_size for path in generated.iterdir())
    receipt["limitations"] = ["No native DLL call or whole-module correctness proof is implied by generation.",
                              "Rejected roots and unresolved indirect jumps require runtime-path validation."]
    (run / "generation-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    summary = {name: {key: value for key, value in item.items() if key != "exports"}
               for name, item in receipt["modules"].items()}
    print(json.dumps({"run": str(run), "modules": summary,
                      "generated_bytes": receipt["generated_bytes"]}, indent=2), flush=True)


if __name__ == "__main__":
    main()
