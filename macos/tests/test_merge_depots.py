#!/usr/bin/env python3
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import inputs
from merge_depots import merge_depots
from stage_game import stage_game
from test_inputs import pe32


class MergedDepotView(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="skyrim-depot-test-")
        self.root = Path(self.temp.name)
        self.base = self.root / "depot_72851"
        self.english = self.root / "depot_72853"
        (self.base / "Data").mkdir(parents=True)
        (self.english / "Data").mkdir(parents=True)
        for name in ("TESV.exe", "binkw32.dll"):
            (self.base / name).write_bytes(pe32())
        for name in ("Skyrim.esm", "Update.esm", "Skyrim - Meshes.bsa"):
            (self.base / "Data" / name).write_bytes(b"base " + name.encode())
        (self.english / "Data" / "Skyrim - Voices.bsa").write_bytes(b"english voices")

    def tearDown(self):
        self.temp.cleanup()

    def snapshot(self):
        return {str(p.relative_to(self.root)): inputs.digest(p)
                for p in self.root.rglob("*") if p.is_file() and not p.is_symlink()
                and "view" not in p.relative_to(self.root).parts[0]}

    def test_depots_join_into_one_linked_installation(self):
        before = self.snapshot()
        view = merge_depots([self.base, self.english], self.root / "view")
        self.assertTrue((view / "Data").is_dir() and not (view / "Data").is_symlink())
        self.assertEqual((view / "Data" / "Skyrim - Voices.bsa").resolve(),
                         (self.english / "Data" / "Skyrim - Voices.bsa").resolve())
        self.assertEqual((view / "TESV.exe").resolve(), (self.base / "TESV.exe").resolve())
        self.assertEqual(before, self.snapshot())

    def test_merged_view_stages_with_unpacked_copy(self):
        view = merge_depots([self.base, self.english], self.root / "view")
        unpacked = self.root / "TESV_unpacked.exe"
        unpacked.write_bytes(pe32())
        directx = self.root / "directx"
        directx.mkdir()
        for name in ("d3dx9_42.dll", "X3DAudio1_7.dll"):
            (directx / name).write_bytes(pe32())
        prefixes = {"TESV.exe": inputs.digest(self.base / "TESV.exe", "sha1")[:8],
                    "TESV_unpacked.exe": inputs.digest(unpacked, "sha1")[:8]}
        with patch.dict(inputs.EXPECTED, prefixes):
            staged = stage_game(view, self.root / "staged-view", unpacked, directx)
        self.assertTrue((staged / "Data" / "Skyrim - Voices.bsa").is_file())

    def test_identical_duplicates_are_accepted_and_case_variants_merge(self):
        (self.english / "Data").rename(self.english / "DATA")
        (self.english / "DATA" / "update.esm").write_bytes(b"base Update.esm")
        view = merge_depots([self.base, self.english], self.root / "view")
        self.assertEqual([p.name for p in view.iterdir() if p.name.casefold() == "data"], ["Data"])
        self.assertEqual(len([p for p in (view / "Data").iterdir() if p.name.casefold() == "update.esm"]), 1)

    def test_conflicting_duplicates_refuse_and_create_no_view(self):
        (self.english / "Data" / "Update.esm").write_bytes(b"different update")
        with self.assertRaisesRegex(ValueError, "disagree"):
            merge_depots([self.base, self.english], self.root / "view")
        self.assertFalse((self.root / "view").exists())
        self.assertEqual([p.name for p in self.root.iterdir() if p.name.startswith(".skyrim-depot-view-")], [])

    def test_links_inside_depots_are_refused(self):
        (self.english / "Data" / "escape.bsa").symlink_to(self.root / "elsewhere")
        with self.assertRaisesRegex(ValueError, "non-file"):
            merge_depots([self.base, self.english], self.root / "view")

    def test_existing_output_and_nested_output_are_preserved(self):
        (self.root / "view").mkdir()
        with self.assertRaisesRegex(ValueError, "Preserving"):
            merge_depots([self.base], self.root / "view")
        with self.assertRaisesRegex(ValueError, "separate"):
            merge_depots([self.base], self.base / "view")


if __name__ == "__main__":
    unittest.main()
