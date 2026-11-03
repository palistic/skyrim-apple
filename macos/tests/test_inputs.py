#!/usr/bin/env python3
"""Exercise fail-closed input binding with authored PE headers, never game files."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import inputs


def pe32(machine=0x14c, magic=0x10b):
    data = bytearray(512)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3c, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x84, machine)
    struct.pack_into("<H", data, 0x98, magic)
    return data


class InputsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="skyrim-owned-input-fixtures-")
        self.root = Path(self.temporary.name)
        self.game = self.root / "game"
        self.game.mkdir()
        for name in inputs.MODULES:
            (self.game / name).write_bytes(pe32())
        data = self.game / "Data"
        data.mkdir()
        for name in ("Skyrim.esm", "Update.esm", "Skyrim - Meshes.bsa"):
            (data / name).write_bytes(b"authored non-game fixture\n")
        # Only tests replace compatibility prefixes with hashes of authored data.
        # The production CLI keeps the upstream's original-game prefixes.
        self.expected = {name: inputs.digest(self.game / name, "sha1")[:8] for name in inputs.EXPECTED}

    def tearDown(self):
        self.temporary.cleanup()

    def validate(self):
        with patch.dict(inputs.EXPECTED, self.expected):
            return inputs.validate_game(self.game)

    def generated(self):
        gen = self.root / "gen"
        gen.mkdir()
        receipt = self.validate()
        for family in ("exe", "d3dx9", "bink", "x3da"):
            for suffix in ("table", "00"):
                (gen / f"{family}_{suffix}.c").write_text("/* authored fixture */\n")
        receipt["generated"] = {p.name: inputs.digest(p) for p in gen.iterdir()}
        receipt["tools"] = {name: inputs.digest(inputs.ROOT / name) for name in inputs.TOOLS}
        (gen / "input-manifest.json").write_text(json.dumps(receipt))
        return gen

    def verify(self, gen):
        with patch.dict(inputs.EXPECTED, self.expected):
            return inputs.verify_generated(gen)

    def test_production_rejects_synthetic_executable(self):
        with self.assertRaisesRegex(ValueError, "upstream-supported"):
            inputs.validate_game(self.game)

    def test_unpacked_gate_accepts_only_listed_exact_identities(self):
        actual = inputs.digest(self.game / "TESV_unpacked.exe", "sha1")
        production = inputs.EXPECTED["TESV_unpacked.exe"]
        self.assertEqual(production[0], "fed96638")
        self.assertEqual(len(production[1]), 40)
        with patch.dict(inputs.EXPECTED, {**self.expected, "TESV_unpacked.exe": ("fed96638", actual)}):
            self.assertIn("TESV_unpacked.exe", inputs.validate_game(self.game)["modules"])
        with patch.dict(inputs.EXPECTED, {**self.expected, "TESV_unpacked.exe": production}):
            with self.assertRaisesRegex(ValueError, "TESV_unpacked.exe: does not match"):
                inputs.validate_game(self.game)

    def test_complete_fixture_binds_hashes(self):
        receipt = self.validate()
        self.assertEqual(len(receipt["modules"]), 5)
        self.assertEqual(len(receipt["modules"]["TESV.exe"]["sha256"]), 64)

    def test_rejects_special_edition_architecture(self):
        (self.game / "TESV.exe").write_bytes(pe32(machine=0x8664, magic=0x20b))
        with self.assertRaisesRegex(ValueError, "32-bit Windows"):
            self.validate()

    def test_rejects_truncated_pe(self):
        (self.game / "binkw32.dll").write_bytes(b"MZ")
        with self.assertRaisesRegex(ValueError, "DOS header"):
            self.validate()

    def test_rejects_incomplete_data(self):
        (self.game / "Data" / "Update.esm").unlink()
        with self.assertRaisesRegex(ValueError, "Update.esm"):
            self.validate()

    def test_accepts_bound_generated_closure(self):
        self.verify(self.generated())

    def test_rejects_changed_generated_source(self):
        gen = self.generated()
        (gen / "exe_00.c").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "Generated file changed"):
            self.verify(gen)

    def test_rejects_extra_generated_source(self):
        gen = self.generated()
        (gen / "untracked.c").write_text("extra\n")
        with self.assertRaisesRegex(ValueError, "closure"):
            self.verify(gen)

    def test_rejects_changed_input_library(self):
        gen = self.generated()
        with (self.game / "binkw32.dll").open("ab") as out:
            out.write(b"changed")
        with self.assertRaisesRegex(ValueError, "Game input changed"):
            self.verify(gen)

    def test_rejects_changed_essential_game_data(self):
        gen = self.generated()
        (self.game / "Data" / "Update.esm").write_bytes(b"different authored fixture")
        with self.assertRaisesRegex(ValueError, "Essential game data changed"):
            self.verify(gen)

    def test_rejects_absent_manifest(self):
        gen = self.root / "gen"
        gen.mkdir()
        with self.assertRaises(FileNotFoundError):
            self.verify(gen)


if __name__ == "__main__":
    unittest.main()
