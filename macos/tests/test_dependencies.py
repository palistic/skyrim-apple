#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("fetch_dependencies", Path(__file__).resolve().parents[1] / "graphics/fetch_dependencies.py")
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class DependencyPaths(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="skyrim-dependency-paths-")
        self.root = Path(self.temporary.name)
        self.deps = self.root / "deps"
        self.external = self.root / "preserve"
        self.external.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_regular_nested_path(self):
        self.assertEqual(fetcher.safe_target(self.deps, "MoltenVK/include/vulkan.h"), self.deps / "MoltenVK/include/vulkan.h")

    def test_refuses_ancestor_symlink(self):
        self.deps.mkdir()
        (self.deps / "MoltenVK").symlink_to(self.external, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            fetcher.safe_target(self.deps, "MoltenVK/include/vulkan.h")
        self.assertEqual(list(self.external.iterdir()), [])

    def test_refuses_leaf_symlink(self):
        self.deps.mkdir()
        (self.deps / "archive.tar").symlink_to(self.external / "not-created")
        with self.assertRaisesRegex(ValueError, "symlink"):
            fetcher.safe_target(self.deps, "archive.tar")

    def test_refuses_destination_symlink(self):
        self.deps.symlink_to(self.external, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            fetcher.safe_target(self.deps, "archive.tar")

    def test_refuses_traversal(self):
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            fetcher.safe_target(self.deps, "../preserve/file")


if __name__ == "__main__":
    unittest.main()
