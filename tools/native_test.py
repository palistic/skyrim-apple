"""Checks the native replacements in runtime/skyrim_native.c against the guest functions they replace.

Usage: native_test.py TESV_unpacked.exe functions.json workdir [runs=20000]

For every address in lift.HOST_OVERRIDES_SKYRIM["exe"], lifts the guest body (plain x87 model) and runs it and the
native function on the same random CPU and memory states, using x87cache_test.py's harness: the whole CPU struct,
the scratch memory and what callees saw must match on every run.
"""
import os
import re
import subprocess
import sys

RUNS = sys.argv[4] if len(sys.argv) > 4 else "20000"
sys.argv = sys.argv[:4]
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import x87cache_test as t  # noqa: E402  (also imports lift with these arguments)

lift = t.lift


def main():
    funcs = {int(k, 16): [tuple(b) for b in v] for k, v in lift.data["functions"].items()}
    picked = sorted(lift.HOST_OVERRIDES_SKYRIM.get("exe", ()))
    rt = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runtime")
    guest = {fa: t.lift_one(fa, funcs[fa], set(funcs), False) for fa in picked}
    native = {fa: ["static void t_%X(CPU *c) { f_%X(c); }" % (fa, fa)] for fa in picked}
    first = sorted(native)[0]
    native[first] = ["#define GAME_SKYRIM 1", '#include "skyrim_native.c"'] + native[first]
    image = os.path.join(t.WORK, "image.bin")
    os.makedirs(t.WORK, exist_ok=True)
    with open(image, "wb") as f:
        f.write(lift.BASE.to_bytes(4, "little") + bytes(lift.img))
    out = {}
    for name, variants in (("guest", guest), ("native", native)):
        exe = t.build(name, picked, variants, rt)
        out[name] = subprocess.run([exe, image, RUNS], capture_output=True, text=True).stdout.splitlines()
    bad = [(a, b) for a, b in zip(out["guest"], out["native"]) if a != b]
    traps = sum("TRAP" in a for a in out["guest"])
    print("functions", len(picked), "runs", len(out["guest"]), "trapped", traps, "different",
          len(bad) + abs(len(out["guest"]) - len(out["native"])))
    for a, b in bad[:10]:
        print("  guest ", a)
        print("  native", b)
    sys.exit(1 if bad or len(out["guest"]) != len(out["native"]) or not out["guest"] else 0)


main()
