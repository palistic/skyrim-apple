#!/usr/bin/env python3
"""Prepare a private copy of an owned original TESV.exe using the verified Mac host tool."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from common import ORIGINAL_PREFIX, UNPACKED_PREFIX, WORK, digest, file_record, load_tool, require_pe32, write_json


def convert(input_file: Path, tool_receipt: Path, output_directory: Path | None = None) -> Path:
    input_file = input_file.resolve(strict=True)
    require_pe32(input_file)
    original = file_record(input_file)
    original_sha1 = digest(input_file, "sha1")
    if not original_sha1.startswith(ORIGINAL_PREFIX):
        raise ValueError(f"Unsupported original TESV.exe SHA1: {original_sha1}; expected {ORIGINAL_PREFIX}…")
    _, dotnet, cli = load_tool(tool_receipt)
    parent = WORK / "unpacked"
    parent.mkdir(parents=True, exist_ok=True)
    if output_directory is None:
        output_directory = Path(tempfile.mkdtemp(prefix="tesv-", dir=parent))
    else:
        output_directory = output_directory.resolve()
        output_directory.mkdir(parents=True, exist_ok=False)
    copied = output_directory / "TESV.exe"
    shutil.copyfile(input_file, copied)
    if digest(copied) != original["sha256"]:
        raise ValueError("Input changed while creating private conversion copy")
    receipt = {"kind": "steamless-owned-conversion-v1", "input": original,
               "input_sha1": original_sha1, "tool_receipt": file_record(tool_receipt),
               "copy": str(copied), "expected_output_sha1_prefix": UNPACKED_PREFIX,
               "status": "failed"}
    try:
        # No arbitrary upstream switches: Windows imagehlp checksum is never requested.
        result = subprocess.run([str(dotnet), str(cli), str(copied)], cwd=output_directory,
                                env=os.environ | {"DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1"},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        (output_directory / "converter.log").write_text(result.stdout)
        receipt["exit_code"] = result.returncode
        output = Path(str(copied) + ".unpacked.exe")
        if result.returncode != 0 or not output.is_file():
            raise ValueError(f"Converter did not produce an unpacked executable; see {output_directory / 'converter.log'}")
        require_pe32(output)
        receipt["output_sha1"] = digest(output, "sha1")
        if not receipt["output_sha1"].startswith(UNPACKED_PREFIX):
            raise ValueError("Unpacked SHA1 matches none of this port's known outputs: "
                             + ", ".join(UNPACKED_PREFIX))
        if digest(copied) != original["sha256"]:
            raise ValueError("Converter modified its input copy unexpectedly")
        if digest(input_file) != original["sha256"]:
            raise ValueError("Original input changed during conversion")
        # Verify all build/source/library bindings again before accepting the result.
        load_tool(tool_receipt)
        final = output_directory / "TESV_unpacked.exe"
        if final.exists():
            raise ValueError("Refusing to overwrite an existing unpacked result")
        output.rename(final)
        receipt.update(status="verified", output=file_record(final))
        return final
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        receipt["error"] = str(error)
        raise
    finally:
        receipt["original_preserved"] = input_file.is_file() and digest(input_file) == original["sha256"]
        write_json(output_directory / "receipt.json", receipt)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Owned original Windows TESV.exe (never executed)")
    parser.add_argument("--tool-receipt", type=Path, default=WORK / "CURRENT.json")
    parser.add_argument("--output-directory", type=Path, help="A new directory; existing paths are refused")
    arguments = parser.parse_args()
    try:
        print(convert(arguments.input, arguments.tool_receipt, arguments.output_directory))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
