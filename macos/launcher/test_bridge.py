"""Launcher gating tests with authored PE/data fixtures, never Skyrim files."""
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
import test_inputs as fixtures
import bridge


class LauncherBridgeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.InputsTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.root = self.fixture.root
        self.game = self.fixture.game
        self.log = io.StringIO()
        self.prefixes = patch.dict(bridge.inputs.EXPECTED, self.fixture.expected)
        self.prefixes.start()
        self.addCleanup(self.prefixes.stop)
        self.checkout = patch.object(bridge, "ROOT", self.root)
        self.checkout.start()
        self.addCleanup(self.checkout.stop)

    def binary(self):
        path = self.root / "macos/build/native/skyrim_macos"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"authored non-executable binary-presence fixture")
        return path

    def test_no_selection_never_prepares_or_enables_play(self):
        with patch.object(bridge.subprocess, "run") as run:
            answer = bridge.status(None, self.log)
        self.assertFalse(answer["isReady"])
        self.assertFalse(answer["canPrepare"])
        run.assert_not_called()

    def test_missing_required_files_does_not_touch_selected_folder(self):
        missing = self.root / "empty"
        missing.mkdir()
        marker = missing / "keep.txt"
        marker.write_text("preserve selected files")
        answer = bridge.status(missing, self.log)
        self.assertFalse(answer["isReady"])
        self.assertFalse(answer["canPrepare"])
        self.assertIn("TESV.exe", answer["detail"])
        self.assertEqual(marker.read_text(), "preserve selected files")
        self.assertEqual(list(missing.iterdir()), [marker])

    def test_binary_presence_does_not_enable_play(self):
        self.binary()
        answer = bridge.status(self.game, self.log)
        self.assertFalse(answer["isReady"])
        self.assertTrue(answer["canPrepare"])

    def test_existing_stage_generation_and_binary_still_require_seal(self):
        original = bridge.inspect_original(self.game)
        staged = bridge.staged_path(self.game, original)
        bridge.stage_game.stage_game(self.game, staged)
        self.fixture.generated()
        self.binary()
        answer = bridge.status(self.game, self.log)
        self.assertFalse(answer["isReady"])
        self.assertTrue(answer["canPrepare"])
        self.assertIn("Ready to finish", answer["headline"])

    def test_incompatible_generation_is_preserved_and_prevents_build(self):
        generated = self.fixture.generated()
        source = generated / "exe_00.c"
        source.write_text("/* deliberately stale authored fixture */\n")
        before = {p: p.read_bytes() for p in generated.iterdir()}
        game_before = {p: p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
        with patch.object(bridge, "run_command") as run:
            answer = bridge.status(self.game, self.log)
            self.assertFalse(answer["isReady"])
            self.assertFalse(answer["canPrepare"])
            with self.assertRaisesRegex(bridge.UserIssue, "preserved"):
                bridge.prepare(self.game, self.log)
            run.assert_not_called()
        self.assertEqual(before, {p: p.read_bytes() for p in generated.iterdir()})
        self.assertEqual(game_before, {p: p.read_bytes() for p in self.game.rglob("*") if p.is_file()})

    def test_compatible_preparation_reuses_helpers_and_preserves_sources(self):
        generated = self.fixture.generated()
        before = {p: p.read_bytes() for p in self.game.rglob("*") if p.is_file()}
        manifest = (generated / "input-manifest.json").read_bytes()
        python = self.root / "macos/.venv/bin/python"
        python.parent.mkdir(parents=True)
        python.write_text("authored never-executed interpreter marker")
        self.binary()
        with patch.object(bridge, "run_command") as run, patch.object(bridge.build_receipt, "verify", return_value={}) as verify:
            answer = bridge.prepare(self.game, self.log)
        self.assertTrue(answer["isReady"])
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0], ["/bin/sh", str(self.root / "macos/build.sh"), "--game"])
        verify.assert_called_once()
        self.assertEqual(before, {p: p.read_bytes() for p in self.game.rglob("*") if p.is_file()})
        self.assertEqual(manifest, (generated / "input-manifest.json").read_bytes())
        staged = Path(answer["stagedDirectory"])
        self.assertTrue((staged / "TESV.exe").is_symlink())
        self.assertNotEqual(staged, self.game)


if __name__ == "__main__":
    unittest.main()
