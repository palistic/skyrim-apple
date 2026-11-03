#!/usr/bin/env python3
"""Authored metadata tests; never invoke simctl, codesign or game code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_probe


class RunProbePreflightTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="skyrim-simulator-preflight-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "simulator"
        self.build = self.root / "build/native"
        self.source = Path(self.temp.name) / "runtime/authored.c"
        self.source.parent.mkdir()
        self.source.write_text("/* authored fixture, never compiled */\n")
        self.artifacts = {}
        for name in sorted(run_probe.PROBE_ARTIFACTS):
            path = self.build / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("authored artifact metadata: " + name).encode())
            self.artifacts[name] = {"sha256": run_probe.file_sha256(path),
                                    "platform": "platform IOSSIMULATOR\nminos 17.0\n"}
        self.receipt = {"schema": 1, "game_built": False, "audio_enabled": True,
                        "sources": {str(self.source): run_probe.file_sha256(self.source)},
                        "artifacts": self.artifacts}
        self.receipt_path = self.root / "build/app-build-receipt.json"
        self.write_receipt()

    def write_receipt(self):
        self.receipt_path.write_text(json.dumps(self.receipt, indent=2) + "\n")

    def assert_rejected_before_external_commands(self, message):
        with patch.object(run_probe, "ROOT", self.root), \
             patch.object(run_probe, "command") as simctl, \
             patch.object(run_probe.subprocess, "check_call") as external_call, \
             patch.object(run_probe.subprocess, "check_output") as external_output:
            with self.assertRaisesRegex(SystemExit, message):
                run_probe.main()
            simctl.assert_not_called()
            external_call.assert_not_called()
            external_output.assert_not_called()
        self.assertFalse((self.root / "build/simulator-device.json").exists())
        self.assertFalse((self.root / "evidence").exists())

    def test_matching_authored_receipt_passes_read_only(self):
        receipt, digest = run_probe.verify_build_receipt(self.root)
        self.assertEqual(receipt, self.receipt)
        self.assertEqual(digest, hashlib.sha256(self.receipt_path.read_bytes()).hexdigest())

    def test_stale_executable_is_rejected_before_simulator_mutation(self):
        (self.build / "SkyrimRuntimeProbe.app/SkyrimRuntimeProbe").write_bytes(b"changed executable")
        self.assert_rejected_before_external_commands("executable or framework changed")

    def test_missing_executable_is_rejected_before_simulator_mutation(self):
        (self.build / "SkyrimRuntimeProbe.app/SkyrimRuntimeProbe").unlink()
        self.assert_rejected_before_external_commands("executable or framework changed")

    def test_stale_source_is_rejected_before_simulator_mutation(self):
        self.source.write_text("/* edited after the recorded build */\n")
        self.assert_rejected_before_external_commands("source changed")

    def test_missing_source_is_rejected_before_simulator_mutation(self):
        self.source.unlink()
        self.assert_rejected_before_external_commands("source changed")

    def test_each_stale_framework_is_rejected_before_simulator_mutation(self):
        for name in sorted(run_probe.PROBE_ARTIFACTS):
            if "/Frameworks/" not in name:
                continue
            with self.subTest(framework=name):
                path = self.build / name
                original = path.read_bytes()
                path.write_bytes(b"changed framework")
                self.assert_rejected_before_external_commands("executable or framework changed")
                path.write_bytes(original)

    def test_receipt_missing_framework_identity_is_rejected(self):
        del self.receipt["artifacts"]["SkyrimRuntimeProbe.app/Frameworks/libdxvk_d3d9.dylib"]
        self.write_receipt()
        self.assert_rejected_before_external_commands("lacks source or executable/framework identities")

    def test_missing_receipt_is_rejected_before_simulator_mutation(self):
        self.receipt_path.unlink()
        self.assert_rejected_before_external_commands("preflight failed")

    def test_invalid_receipt_schema_is_rejected_before_simulator_mutation(self):
        self.receipt["schema"] = 99
        self.write_receipt()
        self.assert_rejected_before_external_commands("unsupported diagnostic build receipt")

    def test_wrong_platform_receipt_is_rejected_before_simulator_mutation(self):
        self.receipt["artifacts"]["SkyrimRuntimeProbe.app/SkyrimRuntimeProbe"]["platform"] = "platform MACOS"
        self.write_receipt()
        self.assert_rejected_before_external_commands("iOS Simulator platform identity")


if __name__ == "__main__":
    unittest.main()
