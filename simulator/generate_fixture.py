#!/usr/bin/env python3
"""Ahead-of-time compile authored x86 fixture input, never Skyrim game code."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    module_spec = importlib.util.spec_from_file_location("authored_aot_fixture", ROOT / "tests/aot/run.py")
    authored = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(authored)
    pe = output / "synthetic-pe32.exe"
    data = authored.write_pe(pe, authored.cases())
    symbols = data.pop("symbols")
    functions = output / "functions.json"
    functions.write_text(json.dumps(data, indent=2) + "\n")
    (output / "fixture_addresses.h").write_text("#pragma once\n" + "".join(
        f"#define FIX_{name.upper()} 0x{address:X}u\n" for name, address in symbols.items()))
    env = dict(os.environ, LIFT_GAME="skyrim", LIFT_FILES="2", LIFT_TSO="1")
    subprocess.run([sys.executable, str(ROOT / "tools/lift.py"), str(pe), str(functions),
                    str(output / "generated"), "fixture"], env=env, check=True, cwd=ROOT)
    # The genuine runtime/modules.c keeps its normal module layout. Only the EXE
    # table in this separate diagnostic is populated by our authored test input.
    declarations = "".join(f"void f_{address:X}(CPU *);\n" for address in symbols.values())
    entries = "".join(f"  {{0x{address:X}u, f_{address:X}}},\n" for address in sorted(symbols.values()))
    source = '#include "rt_table.h"\n' + declarations
    source += "const FnEntry g_fn_table_exe[] = {\n" + entries + "};\n"
    source += f"const unsigned g_fn_count_exe = {len(symbols)};\n"
    for family in ("d3dx9", "bink", "x3da"):
        source += f"const FnEntry g_fn_table_{family}[] = {{{{0, 0}}}};\nconst unsigned g_fn_count_{family} = 0;\n"
    (output / "fixture_modules.c").write_text(source)
    print(f"Generated authored Simulator fixture at {output}")


if __name__ == "__main__":
    main()
