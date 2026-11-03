#!/usr/bin/env python3
"""Check the native build-time converter using an authored, non-SteamStub PE fixture."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from common import WORK, digest, file_record, load_tool, write_json
from test_prepare import authored_pe32


def check(tool_receipt: Path) -> Path:
    tool, dotnet, cli = load_tool(tool_receipt)
    result_dir = Path(tempfile.mkdtemp(prefix="readiness-", dir=WORK))
    fixture = result_dir / "authored-non-steamstub.exe"
    fixture.write_bytes(authored_pe32())
    before = digest(fixture)
    help_result = subprocess.run([str(dotnet), str(cli), "--help"], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, timeout=30)
    (result_dir / "help.log").write_text(help_result.stdout)
    if help_result.returncode != 1 or "Usage:" not in help_result.stdout:
        raise ValueError("Native CLI help failed")
    rejected = subprocess.run([str(dotnet), str(cli), str(fixture)], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True, timeout=30)
    (result_dir / "reject.log").write_text(rejected.stdout)
    loaded = [line for line in rejected.stdout.splitlines() if "Loaded plugin:" in line]
    if rejected.returncode != 1 or "All unpackers failed to unpack file." not in rejected.stdout or len(loaded) != 5:
        raise ValueError(f"Native CLI did not load all five plugins and reject fixture; see {result_dir / 'reject.log'}")
    if digest(fixture) != before or Path(str(fixture) + ".unpacked.exe").exists():
        raise ValueError("Rejection changed the authored input or created an unexpected result")
    probe = cli.parent / "HostProbe.dll"
    probed = subprocess.run([str(dotnet), str(probe), str(fixture)], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=30)
    (result_dir / "host-probe.log").write_text(probed.stdout)
    if probed.returncode:
        raise ValueError(f"Native host helper probe failed; see {result_dir / 'host-probe.log'}")
    host_checks = json.loads(probed.stdout)
    load_tool(tool_receipt)
    receipt = {"kind": "steamless-native-host-readiness-v1", "tool_receipt": file_record(tool_receipt),
               "source_commit": tool["source_commit"], "fixture": file_record(fixture),
               "fixture_is_authored_non_steamstub": True, "fixture_preserved": True,
               "help_exit_code": help_result.returncode, "rejection_exit_code": rejected.returncode,
               "plugins_loaded": loaded, "host_checks": host_checks,
               "real_skyrim_unpacking_verified": False,
               "logs": [file_record(p) for p in sorted(result_dir.glob("*.log"))]}
    receipt_path = result_dir / "receipt.json"
    write_json(receipt_path, receipt)
    return receipt_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool-receipt", type=Path, default=WORK / "CURRENT.json")
    args = parser.parse_args()
    try:
        print(check(args.tool_receipt))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
