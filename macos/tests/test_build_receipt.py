#!/usr/bin/env python3
"""Mutation tests of local build receipts using authored data, never game code."""
import json
import contextlib
import io
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_receipt
import inputs
import test_inputs as fixtures


class BuildReceiptTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.InputsTest()
        self.fixture.setUp()
        self.generated = self.fixture.generated()
        self.build = self.fixture.root / "build"
        self.build.mkdir()
        (self.build / "CMakeCache.txt").write_text("CMAKE_BUILD_TYPE:STRING=Release\n")
        (self.build / "compile_commands.json").write_text("[]\n")
        self.binary = self.build / "skyrim_macos"
        # Authored Mach-O header for metadata checks; this file is never executed.
        self.binary.write_bytes(struct.pack("<IIII", 0xfeedfacf, 0x0100000c, 0, 2) + b"authored test payload")
        self.source = self.fixture.root / "source"
        for name in build_receipt.SOURCE_DIRECTORIES:
            directory = self.source / name
            directory.mkdir(parents=True)
            (directory / "authored.c").write_text("/* authored source identity fixture */\n")
        (self.source / "macos").mkdir()
        (self.source / "macos/CMakeLists.txt").write_text("# authored configuration fixture\n")
        self.dependencies = {}
        for name in build_receipt.DEPENDENCIES:
            path = self.build / f"lib{name}.dylib"
            path.write_bytes(b"authored dependency fixture\n")
            self.dependencies[name] = path
        self.prefixes = patch.dict(inputs.EXPECTED, self.fixture.expected)
        self.prefixes.start()

    def tearDown(self):
        self.prefixes.stop()
        self.fixture.tearDown()

    def begin(self):
        return build_receipt.begin(self.generated, self.binary, self.build, source_root=self.source)

    def seal(self):
        return build_receipt.seal(self.generated, self.binary, self.build, self.dependencies, source_root=self.source)

    def verify(self):
        return build_receipt.verify(self.generated, self.binary, self.build, source_root=self.source)

    def prepare(self):
        self.begin()
        self.seal()

    def test_begin_then_seal_and_verify(self):
        self.prepare()
        receipt = self.verify()
        self.assertEqual(receipt["binary_sha256"], inputs.digest(self.binary))

    def test_refuses_seal_without_precompile_identity(self):
        with self.assertRaises(FileNotFoundError):
            self.seal()

    def test_rejects_runtime_source_change_during_build(self):
        self.begin()
        (self.source / "runtime/authored.c").write_text("/* changed while compiling */\n")
        with self.assertRaisesRegex(ValueError, "changed during compilation"):
            self.seal()

    def test_rejects_configuration_change_during_build(self):
        self.begin()
        (self.build / "compile_commands.json").write_text('[{"command":"changed"}]\n')
        with self.assertRaisesRegex(ValueError, "changed during compilation"):
            self.seal()

    def test_rejects_changed_binary(self):
        self.prepare()
        with self.binary.open("ab") as output:
            output.write(b"unreceipted change")
        with self.assertRaisesRegex(ValueError, "executable changed"):
            self.verify()

    def test_rejects_manifest_replaced_without_relink(self):
        self.prepare()
        manifest_path = self.generated / "input-manifest.json"
        receipt = json.loads(manifest_path.read_text())
        receipt["regeneration_marker"] = "a new source generation must relink"
        manifest_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "executable is stale"):
            self.verify()

    def test_rejects_new_valid_input_generation_without_relink(self):
        self.prepare()
        with (self.fixture.game / "binkw32.dll").open("ab") as output:
            output.write(b"different valid PE32 input library")
        manifest_path = self.generated / "input-manifest.json"
        recorded = json.loads(manifest_path.read_text())
        recorded["modules"] = self.fixture.validate()["modules"]
        manifest_path.write_text(json.dumps(recorded))
        # The new generation is internally consistent, but the old binary is stale.
        inputs.verify_generated(self.generated)
        with self.assertRaisesRegex(ValueError, "executable is stale"):
            self.verify()

    def test_rejects_source_changed_after_seal(self):
        self.prepare()
        (self.source / "runtime/authored.c").write_text("/* changed since build */\n")
        with self.assertRaisesRegex(ValueError, "executable is stale"):
            self.verify()

    def test_rejects_source_added_after_seal(self):
        self.prepare()
        (self.source / "runtime/new_header.h").write_text("/* newly added */\n")
        with self.assertRaisesRegex(ValueError, "executable is stale"):
            self.verify()

    def test_rejects_configuration_changed_after_seal(self):
        self.prepare()
        (self.build / "CMakeCache.txt").write_text("CMAKE_BUILD_TYPE:STRING=Debug\n")
        with self.assertRaisesRegex(ValueError, "executable is stale"):
            self.verify()

    def test_rejects_non_arm64_or_library_artifact(self):
        self.begin()
        self.binary.write_bytes(struct.pack("<IIII", 0xfeedfacf, 0x0100000c, 0, 6))
        with self.assertRaisesRegex(ValueError, "thin ARM64 Mach-O executable"):
            self.seal()

    def test_unchanged_begin_preserves_snapshot_mtime(self):
        self.begin()
        start, _receipt = build_receipt._paths(self.binary)
        first = start.stat().st_mtime_ns
        self.begin()
        self.assertEqual(first, start.stat().st_mtime_ns)

    def test_rejects_changed_runtime_library(self):
        self.prepare()
        self.dependencies["dxvk"].write_bytes(b"changed compiled renderer")
        with self.assertRaisesRegex(ValueError, "runtime dependency changed"):
            self.verify()

    def test_rejects_runtime_library_symlink_retarget(self):
        real = self.dependencies["sdl2"]
        link = self.build / "sdl2-link.dylib"
        link.symlink_to(real.name)
        self.dependencies["sdl2"] = link
        self.prepare()
        replacement = self.build / "other-sdl2.dylib"
        replacement.write_bytes(real.read_bytes())
        link.unlink()
        link.symlink_to(replacement.name)
        with self.assertRaisesRegex(ValueError, "runtime dependency changed"):
            self.verify()

    def test_rejects_missing_runtime_library(self):
        self.prepare()
        self.dependencies["moltenvk"].unlink()
        with self.assertRaises(FileNotFoundError):
            self.verify()

    def test_seal_requires_all_runtime_libraries(self):
        self.begin()
        self.dependencies.pop("dxvk")
        with self.assertRaisesRegex(ValueError, "Seal exactly"):
            self.seal()

    def test_verify_cli_prints_only_verified_moltenvk_path(self):
        self.prepare()
        output = io.StringIO()
        arguments = ["build_receipt.py", "verify", "--gen-dir", str(self.generated),
                     "--binary", str(self.binary), "--build-dir", str(self.build),
                     "--print-dependency", "moltenvk"]
        # Only the source fixture root is injected; production CLI has no override.
        with patch.object(sys, "argv", arguments), patch.object(build_receipt, "_source_identity",
                return_value=build_receipt._source_identity(self.source)), contextlib.redirect_stdout(output):
            self.assertEqual(build_receipt.main(), 0)
        self.assertEqual(output.getvalue(), str(self.dependencies["moltenvk"]) + "\n")


if __name__ == "__main__":
    unittest.main()
