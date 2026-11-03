"""Authored PE fixtures only. No game code or real unpacking is exercised here."""
from __future__ import annotations

import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import common
import unpack


def authored_pe32() -> bytes:
    data = bytearray(1024)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 132, 0x14C, 1, 0, 0, 0, 224, 0x102)
    optional = 152
    struct.pack_into("<H", data, optional, 0x10B)
    struct.pack_into("<III", data, optional + 16, 0x1000, 0x1000, 0)
    struct.pack_into("<III", data, optional + 28, 0x400000, 0x1000, 0x200)
    struct.pack_into("<III", data, optional + 56, 0x2000, 0x200, 0)
    struct.pack_into("<HH", data, optional + 68, 3, 0)
    struct.pack_into("<IIIIII", data, optional + 72, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    section = optional + 224
    data[section:section + 8] = b".text\0\0\0"
    struct.pack_into("<IIII", data, section + 8, 1, 0x1000, 512, 512)
    struct.pack_into("<I", data, section + 36, 0x60000020)
    data[512] = 0xC3  # Authored ret byte; never executed.
    return bytes(data)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.input = self.root / "authored.exe"
        self.input.write_bytes(authored_pe32())
        self.input_hash = common.digest(self.input)
        self.sha1 = common.digest(self.input, "sha1")
        self.dotnet = self.root / "dotnet"
        self.dotnet.write_text("authored host marker")
        self.cli = self.root / "cli.dll"
        self.cli.write_text("authored managed marker")
        self.source = self.root / "source.cs"
        self.source.write_text("authored source marker")
        self.receipt = self.root / "tool.json"
        common.write_json(self.receipt, {"kind": "steamless-headless-build-v1", "source_commit": common.COMMIT,
                                        "dotnet": common.file_record(self.dotnet), "cli": str(self.cli),
                                        "inputs": [common.file_record(self.source)], "outputs": [common.file_record(self.cli)]})

    def fake_success(self, arguments, **_):
        copied = Path(arguments[-1])
        Path(str(copied) + ".unpacked.exe").write_bytes(authored_pe32())
        return subprocess.CompletedProcess(arguments, 0, "authored converter test double")

    def convert(self, **kwargs):
        with patch.object(unpack, "ORIGINAL_PREFIX", self.sha1[:8]), patch.object(unpack, "UNPACKED_PREFIX", self.sha1[:8]):
            with patch.object(unpack.subprocess, "run", self.fake_success):
                return unpack.convert(self.input, self.receipt, self.root / "result", **kwargs)

    def test_private_copy_preserves_original_and_records_output(self):
        output = self.convert()
        self.assertEqual(common.digest(self.input), self.input_hash)
        self.assertNotEqual(output.parent, self.input.parent)
        receipt = json.loads((output.parent / "receipt.json").read_text())
        self.assertEqual(receipt["status"], "verified")
        self.assertTrue(receipt["original_preserved"])
        self.assertEqual(receipt["output"]["sha256"], self.input_hash)

    def test_unknown_input_rejected_before_process_or_output(self):
        with patch.object(unpack.subprocess, "run") as process:
            with self.assertRaisesRegex(ValueError, "Unsupported original"):
                unpack.convert(self.input, self.receipt, self.root / "result")
            process.assert_not_called()
        self.assertFalse((self.root / "result").exists())

    def test_existing_output_directory_refused(self):
        (self.root / "result").mkdir()
        with self.assertRaises(FileExistsError):
            self.convert()
        self.assertEqual(common.digest(self.input), self.input_hash)

    def test_stale_tool_binary_and_source_refused(self):
        for path in (self.cli, self.source, self.dotnet):
            old = path.read_bytes()
            path.write_bytes(old + b"changed")
            with self.assertRaisesRegex(ValueError, "changed or missing"):
                self.convert()
            path.write_bytes(old)

    def test_incorrect_unpacked_hash_retains_failed_receipt(self):
        with patch.object(unpack, "ORIGINAL_PREFIX", self.sha1[:8]):
            with patch.object(unpack.subprocess, "run", self.fake_success):
                with self.assertRaisesRegex(ValueError, "Unpacked SHA1"):
                    unpack.convert(self.input, self.receipt, self.root / "result")
        receipt = json.loads((self.root / "result/receipt.json").read_text())
        self.assertEqual(receipt["status"], "failed")
        self.assertTrue(receipt["original_preserved"])
        self.assertFalse((self.root / "result/TESV_unpacked.exe").exists())

    def test_failed_converter_preserves_original(self):
        with patch.object(unpack, "ORIGINAL_PREFIX", self.sha1[:8]):
            with patch.object(unpack.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "authored rejection")):
                with self.assertRaisesRegex(ValueError, "did not produce"):
                    unpack.convert(self.input, self.receipt, self.root / "result")
        self.assertEqual(common.digest(self.input), self.input_hash)
        self.assertTrue(json.loads((self.root / "result/receipt.json").read_text())["original_preserved"])

    def test_architecture_rejected(self):
        data = bytearray(authored_pe32())
        struct.pack_into("<H", data, 132, 0x8664)
        self.input.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "x86 PE32"):
            common.require_pe32(self.input)


if __name__ == "__main__":
    unittest.main()
