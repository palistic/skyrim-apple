#!/usr/bin/env python3
"""Authored tests for run_game.py; never invoke simctl or touch game files."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_game


class GameViewTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="skyrim-simulator-game-view-")
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.owned = base / "owned"          # stands in for depots/unpacked/DirectX files
        (self.owned / "Data").mkdir(parents=True)
        self.view = base / "view"            # stands in for the staged view of links
        (self.view / "Data").mkdir(parents=True)
        identity = {"schema": 1, "modules": {}, "essential_data": {}}
        for name in run_game.MODULES:
            path = self.owned / name
            path.write_bytes(b"authored module " + name.encode())
            (self.view / name).symlink_to(path)
            identity["modules"][name] = run_game.file_sha256(path)
        for name in run_game.ESSENTIAL + ("Authored - Misc.bsa",):
            path = self.owned / "Data" / name
            path.write_bytes(b"authored data " + name.encode())
            (self.view / "Data" / name).symlink_to(path)
            if name in run_game.ESSENTIAL:
                identity["essential_data"][name] = run_game.file_sha256(path)
        (self.view / "input-view.json").write_text("{}\n")
        self.identity = identity

    def test_view_hashes_accepted(self):
        hashes = run_game.verify_game_view(self.view, self.identity)
        self.assertEqual(set(hashes), set(run_game.MODULES) | {"Data/Skyrim.esm", "Data/Update.esm"})

    def test_mismatched_module_rejected(self):
        self.identity["modules"]["TESV_unpacked.exe"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "TESV_unpacked.exe"):
            run_game.verify_game_view(self.view, self.identity)

    def test_missing_archives_rejected(self):
        (self.view / "Data/Authored - Misc.bsa").unlink()
        with self.assertRaisesRegex(ValueError, "BSA"):
            run_game.verify_game_view(self.view, self.identity)

    def test_clone_makes_independent_regular_files(self):
        target = Path(self.temp.name) / "container/Documents/Skyrim"
        target.parent.mkdir(parents=True)
        summary = run_game.clone_view(self.view, target)
        self.assertEqual(summary["files"], len(run_game.MODULES) + 3)
        self.assertFalse((target / "input-view.json").exists())
        for path in target.rglob("*"):
            self.assertFalse(path.is_symlink(), path)
        clone = target / "Data/Skyrim.esm"
        original = self.owned / "Data/Skyrim.esm"
        self.assertNotEqual(clone.stat().st_ino, original.stat().st_ino)
        clone.write_bytes(b"changed only in the container")
        self.assertEqual(original.read_bytes(), b"authored data Skyrim.esm")
        (target / "Data/Skyrim.esm").write_bytes(original.read_bytes())
        run_game.verify_game_view(target, self.identity)

    def test_existing_destination_never_replaced(self):
        target = Path(self.temp.name) / "Documents/Skyrim"
        target.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "Refusing"):
            run_game.clone_view(self.view, target)

    def test_preflight_failure_never_calls_simctl(self):
        with patch.object(run_game, "verify_game_build", side_effect=ValueError("no game app")), \
             patch.object(run_game, "simctl") as simctl, \
             patch("sys.argv", ["run_game.py"]):
            with self.assertRaises(SystemExit):
                run_game.main()
        simctl.assert_not_called()


if __name__ == "__main__":
    unittest.main()
