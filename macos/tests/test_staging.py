#!/usr/bin/env python3
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import inputs
from stage_game import stage_game
from test_inputs import pe32


class PrivateView(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="skyrim-view-test-")
        self.root = Path(self.temp.name)
        self.game = self.root / "original"
        self.game.mkdir()
        for name in ("TESV.exe", "TESV_unpacked.exe", "binkw32.dll"):
            (self.game / name).write_bytes(pe32())
        (self.game / "Data").mkdir()
        for name in ("Skyrim.esm", "Update.esm", "Skyrim - Meshes.bsa"):
            (self.game / "Data" / name).write_bytes(b"authored fixture")
        self.directx = self.root / "directx"
        self.directx.mkdir()
        for name in ("d3dx9_42.dll", "X3DAudio1_7.dll"):
            (self.directx / name).write_bytes(pe32())
        self.prefixes = {name: inputs.digest(self.game / name, "sha1")[:8] for name in inputs.EXPECTED}
        self.before = {str(p.relative_to(self.game)): inputs.digest(p) for p in self.game.rglob("*") if p.is_file()}

    def tearDown(self):
        self.temp.cleanup()

    def stage(self, output):
        with patch.dict(inputs.EXPECTED, self.prefixes):
            return stage_game(self.game, output, directx_directory=self.directx)

    def test_validated_view_preserves_originals_and_uses_directx_fallback(self):
        output = self.stage(self.root / "view")
        self.assertTrue((output / "Data").is_symlink())
        self.assertEqual((output / "d3dx9_42.dll").resolve(), (self.directx / "d3dx9_42.dll").resolve())
        self.assertEqual(self.before, {str(p.relative_to(self.game)): inputs.digest(p) for p in self.game.rglob("*") if p.is_file()})

    def test_optional_low_ini_is_preserved_under_canonical_name(self):
        preset = b"[Display]\niShadowMapResolution=512\n[Grass]\nfGrassStartFadeDistance=1000\n"
        for index, name in enumerate(("low.ini", "LoW.INI")):
            with self.subTest(original_name=name):
                original = self.game / name
                original.write_bytes(preset)
                before = {str(p.relative_to(self.game)): inputs.digest(p)
                          for p in self.game.rglob("*") if p.is_file()}
                output = self.stage(self.root / f"view-{index}")
                staged = output / "low.ini"
                self.assertTrue(staged.is_symlink())
                self.assertEqual(staged.resolve(), original.resolve())
                self.assertEqual(staged.read_bytes(), preset)
                self.assertEqual([p.name for p in output.iterdir() if p.name.casefold() == "low.ini"], ["low.ini"])
                metadata = json.loads((output / "input-view.json").read_text())
                self.assertEqual(metadata["sources"]["low.ini"], str(original.resolve()))
                self.assertEqual(before, {str(p.relative_to(self.game)): inputs.digest(p)
                                          for p in self.game.rglob("*") if p.is_file()})
                original.unlink()

    def test_optional_low_ini_may_be_missing(self):
        output = self.stage(self.root / "view")
        self.assertFalse((output / "low.ini").exists())
        self.assertFalse((output / "low.ini").is_symlink())
        self.assertNotIn("low.ini", json.loads((output / "input-view.json").read_text())["sources"])
        self.assertEqual(self.before, {str(p.relative_to(self.game)): inputs.digest(p)
                                      for p in self.game.rglob("*") if p.is_file()})

    def test_ambiguous_low_ini_preserves_originals_and_creates_no_view(self):
        original = self.game / "low.ini"
        original.write_bytes(b"[Display]\niShadowMapResolution=512\n")
        before = {str(p.relative_to(self.game)): inputs.digest(p)
                  for p in self.game.rglob("*") if p.is_file()}
        real_iterdir = Path.iterdir

        def case_sensitive_inventory(path):
            entries = list(real_iterdir(path))
            if path.resolve() == self.game.resolve():
                # Model a case-sensitive volume even when the test host cannot
                # store distinct low.ini and LOW.INI directory entries.
                entries.append(self.game / "LOW.INI")
            return iter(entries)

        output = self.root / "view"
        with patch.object(Path, "iterdir", case_sensitive_inventory):
            with self.assertRaisesRegex(ValueError, r"exactly one low\.ini.*found 2"):
                self.stage(output)
        self.assertFalse(output.exists())
        self.assertEqual(list(self.root.glob(".skyrim-input-view-*")), [])
        self.assertEqual(before, {str(p.relative_to(self.game)): inputs.digest(p)
                                  for p in self.game.rglob("*") if p.is_file()})

    def test_existing_output_is_preserved(self):
        output = self.root / "view"
        output.mkdir()
        (output / "preserve.txt").write_text("existing")
        with self.assertRaisesRegex(ValueError, "Preserving existing"):
            self.stage(output)
        self.assertEqual((output / "preserve.txt").read_text(), "existing")

    def test_refuses_view_inside_original_install(self):
        with self.assertRaisesRegex(ValueError, "separate"):
            self.stage(self.game / "view")

    def test_failed_validation_removes_only_private_staging(self):
        (self.game / "Data/Update.esm").unlink()
        output = self.root / "view"
        with self.assertRaisesRegex(ValueError, "Update.esm"):
            self.stage(output)
        self.assertFalse(output.exists())
        self.assertTrue((self.game / "TESV.exe").is_file())
        self.assertEqual(list(self.root.glob(".skyrim-input-view-*")), [])


if __name__ == "__main__":
    unittest.main()
