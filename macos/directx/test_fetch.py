#!/usr/bin/env python3
"""Local path/preservation tests; never downloads or executes Microsoft files."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fetch


class FetchPathTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="directx-fetch-fixtures-")
        self.root = Path(self.temporary.name).resolve()
        self.output = self.root / "macos/build/directx"
        self.output.mkdir(parents=True)
        self.patches = [patch.object(fetch, "ROOT", self.root), patch.object(fetch, "OUTPUT", self.output)]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def test_refuses_outside_destination(self):
        with self.assertRaises(ValueError):
            fetch.private_path(self.root / "elsewhere.dll")

    def test_refuses_ancestor_symlink(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.output / "inputs").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            fetch.private_path(self.output / "inputs/dependency.dll")
        self.assertEqual(list(outside.iterdir()), [])

    def test_refuses_leaf_symlink(self):
        target = self.root / "outside.dll"
        target.write_bytes(b"preserve")
        destination = self.output / "library.dll"
        destination.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            fetch.private_path(destination)
        self.assertEqual(target.read_bytes(), b"preserve")

    def test_publish_preserves_unexpected_existing_file(self):
        source = self.root / "source.bin"
        source.write_bytes(b"expected")
        destination = self.output / "library.dll"
        destination.write_bytes(b"preserve")
        with self.assertRaisesRegex(ValueError, "preserved"):
            fetch.publish(source, destination)
        self.assertEqual(destination.read_bytes(), b"preserve")

    def test_publish_unchanged_keeps_mtime(self):
        source = self.root / "source.bin"
        source.write_bytes(b"same")
        destination = self.output / "inputs/library.dll"
        fetch.publish(source, destination)
        before = destination.stat().st_mtime_ns
        fetch.publish(source, destination)
        self.assertEqual(destination.stat().st_mtime_ns, before)

    def test_rejects_non_microsoft_or_non_https_redirect(self):
        redirect = fetch.OfficialRedirect()
        for url in ("https://example.com/file.exe", "http://download.microsoft.com/file.exe"):
            with self.assertRaisesRegex(ValueError, "Refusing redirect"):
                redirect.redirect_request(None, None, 302, "Found", None, url)


if __name__ == "__main__":
    unittest.main()
