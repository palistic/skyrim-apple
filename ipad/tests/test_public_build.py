#!/usr/bin/env python3
"""Fresh-clone entrypoints: actionable failures, generated-code binding, signing overrides and pinned
dependencies. Authored fixtures only: no game files, no network, no builds. Real local dependency
archives are read in place only when SKYRIM_TEST_MOLTENVK_ARCHIVE / SKYRIM_TEST_FFMPEG_ARCHIVE name them.
"""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "macos/tests"))
sys.path.insert(0, str(ROOT / "ipad"))
import test_inputs as fixtures  # noqa: E402
import pinned  # noqa: E402


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load("ipad_build", ROOT / "ipad/build.py")
moltenvk = load("ipad_prepare_moltenvk", ROOT / "ipad/prepare_moltenvk.py")
ffmpeg = load("ipad_build_ffmpeg", ROOT / "ipad/build_ffmpeg.py")


def cli(*arguments, env=None):
    return subprocess.run([sys.executable, str(ROOT / "ipad/build.py"), *arguments], capture_output=True, text=True,
                          env={**os.environ, **(env or {})}, cwd=ROOT, timeout=60)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Response(io.BytesIO):
    def __init__(self, data, url):
        super().__init__(data)
        self.url = url

    def geturl(self):
        return self.url


class Temporary(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="skyrim-public-build-")
        self.addCleanup(self.temporary.cleanup)
        self.tmp = Path(self.temporary.name)


class ActionableFailures(Temporary):
    def assertActionable(self, result, *needles):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Traceback", result.stderr)
        for needle in needles:
            self.assertIn(needle, result.stderr)

    def test_missing_generated_code_says_what_to_obtain(self):
        self.assertActionable(cli("check", "--gen-dir", str(self.tmp / "absent")), "input-manifest.json is missing",
                              "1.9.32.0.8", "download_depot 72850 72852", "ipad/build.py prepare --depots")
        self.assertActionable(cli("engine", env={"SKYRIM_GEN_DIR": str(self.tmp / "absent")}), "download_depot 72850 72851")

    def test_foreign_manifest_is_refused(self):
        gen = self.tmp / "gen"
        gen.mkdir()
        (gen / "input-manifest.json").write_text(json.dumps({"schema": 1, "scope": "owned-skyrim-special-edition"}))
        self.assertActionable(cli("check", "--gen-dir", str(gen)), "not bound to the supported", "--game-dir")

    def test_signing_needs_own_team_and_app_id(self):
        self.assertActionable(cli("app", "--signed"), "paid Apple Developer Program", "--team TEAMID")
        self.assertActionable(cli("app", "--signed", env={"SKYRIM_DEVELOPMENT_TEAM": "ABCDE12345"}), "--bundle-id")
        self.assertActionable(cli("app", "--signed", "--team", "abc", "--bundle-id", "com.example.skyrim"),
                              "not a 10-character Apple Team ID")

    def test_prepare_without_inputs_or_with_foreign_executable(self):
        ready = subprocess.CompletedProcess([], 0)
        with patch.object(build.subprocess, "run", return_value=ready), patch.object(build, "VENV_PYTHON", Path(sys.executable)):
            with self.assertRaisesRegex(SystemExit, "download_depot 72850 72853"):
                build.main(["prepare"])
            game = self.tmp / "se"
            (game / "Data").mkdir(parents=True)
            (game / "TESV.exe").write_bytes(fixtures.pe32(machine=0x8664, magic=0x20b))
            (game / "binkw32.dll").write_bytes(fixtures.pe32())
            with self.assertRaisesRegex(SystemExit, "not SE/AE"):
                build.main(["prepare", "--game-dir", str(game)])


class SupportedInputs(unittest.TestCase):
    def test_production_pins_cover_every_input_exactly(self):
        self.assertEqual(set(build.SUPPORTED), set(build.inputs.MODULES) | {"Skyrim.esm", "Update.esm"})
        self.assertTrue(all(re.fullmatch("[0-9a-f]{64}", sha) for sha in build.SUPPORTED.values()))
        directx = (ROOT / "macos/directx/fetch.py").read_text()
        self.assertIn(build.SUPPORTED["d3dx9_42.dll"], directx)
        self.assertIn(build.SUPPORTED["X3DAudio1_7.dll"], directx)


class GeneratedBinding(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.InputsTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        expected = patch.dict(build.inputs.EXPECTED, self.fixture.expected)
        expected.start()
        self.addCleanup(expected.stop)
        self.gen = self.fixture.generated()
        # Only tests pin the authored fixture files; production SUPPORTED holds the original game's hashes.
        recorded = json.loads((self.gen / "input-manifest.json").read_text())
        supported = patch.dict(build.SUPPORTED, {name: value["sha256"] for name, value in
                                                 {**recorded["modules"], **recorded["essential_data"]}.items()})
        supported.start()
        self.addCleanup(supported.stop)

    def regenerate(self):
        shutil.rmtree(self.gen)
        self.gen = self.fixture.generated()
        build.inputs.verify_generated(self.gen)  # self-consistent: the manifest alone would accept it

    def test_modded_dll_is_refused_even_when_self_consistent(self):
        (self.fixture.game / "d3dx9_42.dll").write_bytes(bytes(fixtures.pe32()) + b"preloader")
        self.regenerate()
        with self.assertRaisesRegex(SystemExit, "d3dx9_42.dll: not the exact supported original Skyrim 1.9.32.0.8"):
            build.verified_generation(self.gen)

    def test_edited_esm_is_refused_even_when_self_consistent(self):
        (self.fixture.game / "Data/Update.esm").write_bytes(b"cleaned master file")
        self.regenerate()
        with self.assertRaisesRegex(SystemExit, "Update.esm: not the exact supported.*macos/build/gen-previous"):
            build.verified_generation(self.gen)

    def test_upstream_unpacked_copy_is_accepted_by_its_sha1_prefix(self):
        with patch.dict(build.SUPPORTED, {"TESV_unpacked.exe": "0" * 64}):
            with self.assertRaisesRegex(SystemExit, "TESV_unpacked.exe: not the exact supported"):
                build.verified_generation(self.gen)
            prefix = build.inputs.digest(self.fixture.game / "TESV_unpacked.exe", "sha1")[:8]
            with patch.object(build, "UPSTREAM_UNPACKED_SHA1", prefix):
                build.verified_generation(self.gen)

    def test_users_own_manifest_is_verified_and_hashed(self):
        sha, receipt = build.verified_generation(self.gen)
        self.assertEqual(sha, digest((self.gen / "input-manifest.json").read_bytes()))
        self.assertNotEqual(sha, "a40988a81c55c69f1f777be3861d80d51f3a6d85bdf37ac9a1ce234ca7e79d95")
        self.assertEqual(receipt["scope"], "owned-original-windows-skyrim-1.9.32.0.8")

    def test_changed_game_input_is_refused(self):
        with (self.fixture.game / "binkw32.dll").open("ab") as out:
            out.write(b"changed")
        with self.assertRaisesRegex(SystemExit, "Game input changed since generation: binkw32.dll"):
            build.verified_generation(self.gen)

    def test_changed_generated_source_is_refused(self):
        (self.gen / "exe_00.c").write_text("/* changed */\n")
        with self.assertRaisesRegex(SystemExit, "Generated file changed"):
            build.verified_generation(self.gen)

    def test_moved_game_needs_game_dir_and_still_matches_exactly(self):
        moved = self.fixture.root / "moved"
        self.fixture.game.rename(moved)
        with self.assertRaisesRegex(SystemExit, "complete prepared game folder.*export writes.*gen-previous"):
            build.verified_generation(self.gen)
        self.assertEqual(build.verified_generation(self.gen, moved)[1]["scope"], "owned-original-windows-skyrim-1.9.32.0.8")
        (moved / "Data/Skyrim.esm").write_bytes(b"another game's master file")
        with self.assertRaisesRegex(SystemExit, "Essential game data changed"):
            build.verified_generation(self.gen, moved)


    def test_export_follows_links_and_verifies_the_copy(self):
        view = self.fixture.root / "view"
        view.mkdir()
        for item in self.fixture.game.iterdir():
            (view / item.name).symlink_to(item, target_is_directory=item.is_dir())
        (view / "input-view.json").write_text("{}")
        output = self.fixture.root / "out/Skyrim"
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            build.main(["export", "--gen-dir", str(self.gen), "--game-dir", str(view), "--output", str(output)])
        self.assertIn("Documents", printed.getvalue())
        copied = [p for p in output.rglob("*")]
        self.assertTrue(copied and not any(p.is_symlink() for p in copied))
        self.assertEqual({p.name for p in output.iterdir()}, {p.name for p in self.fixture.game.iterdir()})
        with self.assertRaisesRegex(SystemExit, "already exists"):
            build.main(["export", "--gen-dir", str(self.gen), "--game-dir", str(view), "--output", str(output)])


class Signing(unittest.TestCase):
    def settings(self, **values):
        defaults = {"signed": True, "team": "ABCDE12345", "bundle_id": "com.example.skyrim",
                    "cloud": False, "icloud_container": None}
        return build.signing_settings(argparse.Namespace(**{**defaults, **values}))

    def test_overrides_go_to_xcodebuild_not_project(self):
        self.assertEqual(self.settings(), (["DEVELOPMENT_TEAM=ABCDE12345", "PRODUCT_BUNDLE_IDENTIFIER=com.example.skyrim"], None))
        settings, container = self.settings(cloud=True)
        self.assertEqual(container, "iCloud.com.example.skyrim")
        self.assertIn("SKYRIM_ICLOUD_CONTAINER=iCloud.com.example.skyrim", settings)
        self.assertEqual(self.settings(cloud=True, icloud_container="iCloud.org.example.saves")[1], "iCloud.org.example.saves")
        self.assertEqual(self.settings(signed=False, team=None, bundle_id=None), ([], None))
        for bad in ({"bundle_id": "com example"}, {"cloud": True, "icloud_container": "com.example.saves"}):
            with self.assertRaises(SystemExit):
                self.settings(**bad)
        with self.assertRaisesRegex(SystemExit, "--cloud needs your own iCloud container"):
            self.settings(signed=False, team=None, bundle_id=None, cloud=True)

    def test_no_plist_dictionary_key_needs_a_build_setting(self):
        # Xcode expands build settings in Info.plist values only, never in dictionary keys.
        import plistlib
        def keys(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    yield key
                    yield from keys(value)
            elif isinstance(node, list):
                for value in node:
                    yield from keys(value)
        for plist in sorted((ROOT / "apple").glob("Info-*.plist")):
            bad = [key for key in keys(plistlib.loads(plist.read_bytes())) if "$(" in key]
            self.assertEqual(bad, [], plist.name)

    def test_built_containers_must_match_the_request(self):
        mine = "iCloud.com.example.skyrim"
        info = {"SkyrimICloudContainerIdentifier": mine}
        signed = {**{key: True for key in build.MEMORY}, **{key: [mine] for key in build.CONTAINER_ENTITLEMENTS}}
        build.check_containers(info, signed, mine)
        build.check_containers(info, None, mine)
        owner = {**info, "SkyrimICloudContainerIdentifier": "iCloud.dev.zschwendi.skyrim.launcher"}
        with self.assertRaisesRegex(SystemExit, "SkyrimICloudContainerIdentifier doesn't name"):
            build.check_containers(owner, signed, mine)
        with self.assertRaisesRegex(SystemExit, "icloud-container-identifiers"):
            build.check_containers(info, {**signed, build.CONTAINER_ENTITLEMENTS[0]: ["iCloud.other"]}, mine)
        unexpanded = {**info, "NSUbiquitousContainers": {"$(SKYRIM_ICLOUD_CONTAINER)": {}}}
        with self.assertRaisesRegex(SystemExit, "unexpanded"):
            build.check_containers(unexpanded, None, mine)
        local = {key: True for key in build.MEMORY}
        build.check_containers(info, local, None)
        with self.assertRaisesRegex(SystemExit, "Local build"):
            build.check_containers(info, signed, None)

    def test_local_entitlements_are_memory_only_and_cloud_uses_override(self):
        local = plistlib.loads((ROOT / "apple/Native-iOS-Local.entitlements").read_bytes())
        self.assertEqual(local, {key: True for key in build.MEMORY})
        cloud = plistlib.loads((ROOT / "apple/Native-iOS-Cloud.entitlements").read_bytes())
        self.assertTrue(all(cloud[key] is True for key in build.MEMORY))
        self.assertEqual(cloud["com.apple.developer.icloud-container-identifiers"], ["$(SKYRIM_ICLOUD_CONTAINER)"])
        self.assertFalse(any("jit" in key or "dynamic-codesigning" in key for key in {**local, **cloud}))

    def test_signed_app_must_carry_memory_capabilities_and_no_jit(self):
        def signed(values):
            result = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps(values))
            with patch.object(build.subprocess, "run", return_value=result):
                return build.signed_entitlements(Path("Skyrim.app"))
        memory = {key: True for key in build.MEMORY}
        self.assertEqual(signed(memory), memory)
        with self.assertRaisesRegex(SystemExit, "increased-memory-limit"):
            signed({build.MEMORY[0]: True})
        with self.assertRaisesRegex(SystemExit, "JIT"):
            signed({**memory, "dynamic-codesigning": True})


class PinnedArchives(Temporary):
    def test_local_copy_is_read_in_place_only_with_pinned_hash(self):
        archive = self.tmp / "local.tar"
        archive.write_bytes(b"authored archive")
        self.assertEqual(pinned.obtain("https://example.invalid/a", digest(b"authored archive"), self.tmp / "d", archive), archive)
        self.assertFalse((self.tmp / "d").exists())
        with self.assertRaisesRegex(ValueError, "not the pinned"):
            pinned.obtain("https://example.invalid/a", "0" * 64, self.tmp / "d", archive)

    def test_download_is_published_only_after_verification(self):
        destination = self.tmp / "deps/archive.tar"
        opener = lambda url, timeout: Response(b"payload", url)  # noqa: E731
        with self.assertRaisesRegex(ValueError, "discarded"):
            pinned.obtain("https://example.invalid/a", "0" * 64, destination, opener=opener)
        self.assertEqual(list(destination.parent.iterdir()), [])
        insecure = lambda url, timeout: Response(b"payload", "http://example.invalid/a")  # noqa: E731
        with self.assertRaisesRegex(ValueError, "non-HTTPS"):
            pinned.obtain("https://example.invalid/a", digest(b"payload"), destination, opener=insecure)
        self.assertEqual(list(destination.parent.iterdir()), [])
        self.assertEqual(pinned.obtain("https://example.invalid/a", digest(b"payload"), destination, opener=opener), destination)
        self.assertEqual(destination.read_bytes(), b"payload")
        destination.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "preserved"):
            pinned.obtain("https://example.invalid/a", digest(b"payload"), destination, opener=opener)
        self.assertEqual(destination.read_bytes(), b"tampered")


class MoltenVK(Temporary):
    def fake_release(self):
        archive = self.tmp / "MoltenVK-ios.tar"
        with tarfile.open(archive, "w") as tar:
            for name, data in ((moltenvk.LIBRARY, b"not a Mach-O archive"), (moltenvk.INCLUDE + "vulkan/vulkan.h", b"/* h */")):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        return archive

    def test_pin_is_the_official_ios_release_asset(self):
        self.assertEqual(moltenvk.URL, "https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar")
        self.assertEqual(moltenvk.ARCHIVE_SHA256, "b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1")

    def test_unpinned_archive_is_never_extracted(self):
        out = self.tmp / "deps/MoltenVK-ios-v1.4.2"
        with self.assertRaisesRegex(ValueError, "not the pinned"):
            moltenvk.prepare(self.fake_release(), out)
        self.assertFalse(out.parent.exists() and any(out.parent.iterdir()))

    def test_non_device_slice_is_not_published(self):
        archive = self.fake_release()
        out = self.tmp / "deps/MoltenVK-ios-v1.4.2"
        # The fake archive is not a Mach-O library. Supply the platform metadata directly so
        # this logic test remains runnable on Linux, where Apple's otool utility is unavailable.
        with patch.object(moltenvk, "ARCHIVE_SHA256", pinned.sha256(archive)), \
                patch.object(moltenvk, "build_lines", return_value=["platform 7", "minos 17.0", "sdk 18.5"]):
            with self.assertRaisesRegex(ValueError, "not purely an iphoneos"):
                moltenvk.prepare(archive, out)
        self.assertEqual(list(out.parent.iterdir()), [])

    @unittest.skipUnless(os.environ.get("SKYRIM_TEST_MOLTENVK_ARCHIVE"), "set SKYRIM_TEST_MOLTENVK_ARCHIVE to a local MoltenVK-ios.tar")
    def test_real_release_extracts_device_slice_with_receipt(self):
        archive = Path(os.environ["SKYRIM_TEST_MOLTENVK_ARCHIVE"])
        before = (archive.stat().st_size, archive.stat().st_mtime_ns)
        out = self.tmp / "deps/MoltenVK-ios-v1.4.2"
        receipt = moltenvk.prepare(archive, out)
        self.assertEqual((receipt["archive_sha256"], receipt["platform"]), (moltenvk.ARCHIVE_SHA256, "iphoneos arm64"))
        self.assertIn("platform 2", receipt["otool_build"])
        self.assertEqual(pinned.sha256(out / "lib/libMoltenVK.a"), receipt["library_sha256"])
        self.assertTrue((out / "include/vulkan/vulkan.h").is_file())
        self.assertEqual(moltenvk.prepare(None, out), receipt)
        self.assertEqual(before, (archive.stat().st_size, archive.stat().st_mtime_ns))
        with (out / "lib/libMoltenVK.a").open("ab") as library:
            library.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "differs from its receipt"):
            moltenvk.prepare(None, out)


class FFmpeg(Temporary):
    def test_fresh_clone_with_local_archive_extracts_and_configures(self):
        clone, archive = self.tmp / "clone", self.tmp / "ffmpeg-7.1.2.tar.xz"
        with tarfile.open(archive, "w:xz") as tar:
            for name, data in (("ffmpeg-7.1.2/configure", b"#!/bin/sh\n"), ("ffmpeg-7.1.2/COPYING.LGPLv2.1", b"LGPL\n")):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        deps, commands = clone / "ipad/deps", []

        def make(arguments, log, cwd=None):
            commands.append([str(a) for a in arguments])
            if commands[-1][:2] == ["make", "install"]:
                for name in ("avcodec", "avutil"):
                    library = deps / f"ffmpeg-iphoneos/lib/lib{name}.a"
                    library.parent.mkdir(parents=True, exist_ok=True)
                    library.write_bytes(name.encode())
        with patch.multiple(ffmpeg, ROOT=clone, DEPS=deps, PREFIX=deps / "ffmpeg-iphoneos",
                            SOURCE_SHA256=pinned.sha256(archive), run=make), \
                patch.object(ffmpeg.subprocess, "check_output", return_value="/sdk\n"):
            manifest = ffmpeg.build_libraries(archive, 1)
            self.assertEqual(ffmpeg.verified_manifest(deps / "ffmpeg-iphoneos"), manifest)
        self.assertTrue((deps / "ffmpeg-source/ffmpeg-7.1.2/configure").is_file())
        self.assertFalse((deps / "ffmpeg-7.1.2.tar.xz").exists())
        self.assertEqual(manifest["source_archive"], str(archive))
        self.assertEqual([c[:2] for c in commands[1:]], [["make", "-j1"], ["make", "install"]])
        self.assertTrue(commands[0][0].endswith("ffmpeg-7.1.2/configure") and "--sysroot=/sdk" in commands[0])

    def test_same_pin_as_the_mac_build(self):
        mac = load("macos_build_ffmpeg", ROOT / "macos/audio/build_ffmpeg.py")
        self.assertEqual((ffmpeg.URL, ffmpeg.SOURCE_SHA256), (mac.URL, mac.SOURCE_SHA256))
        self.assertEqual(ffmpeg.URL, "https://ffmpeg.org/releases/ffmpeg-7.1.2.tar.xz")

    def test_build_manifest_is_the_receipt(self):
        prefix = self.tmp / "ffmpeg-iphoneos"
        self.assertIsNone(ffmpeg.verified_manifest(prefix))
        archives = {}
        for name in ("avcodec", "avutil"):
            path = prefix / f"lib/lib{name}.a"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            archives[name] = {"path": str(path), "sha256": pinned.sha256(path)}
        manifest = {"source_archive_sha256": ffmpeg.SOURCE_SHA256, "platform": "iphoneos", "archives": archives}
        (prefix / "build-manifest.json").write_text(json.dumps(manifest))
        self.assertEqual(ffmpeg.verified_manifest(prefix), manifest)
        for changed in ({**manifest, "platform": "iphonesimulator"}, {**manifest, "source_archive_sha256": "0" * 64}):
            (prefix / "build-manifest.json").write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, "preserve it"):
                ffmpeg.verified_manifest(prefix)
        (prefix / "build-manifest.json").write_text(json.dumps(manifest))
        (prefix / "lib/libavutil.a").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "preserve it"):
            ffmpeg.verified_manifest(prefix)

    @unittest.skipUnless(os.environ.get("SKYRIM_TEST_FFMPEG_ARCHIVE"), "set SKYRIM_TEST_FFMPEG_ARCHIVE to a local ffmpeg-7.1.2.tar.xz")
    def test_real_source_archive_is_accepted_in_place(self):
        archive = Path(os.environ["SKYRIM_TEST_FFMPEG_ARCHIVE"])
        destination = self.tmp / "deps/ffmpeg-7.1.2.tar.xz"
        self.assertEqual(pinned.obtain(ffmpeg.URL, ffmpeg.SOURCE_SHA256, destination, archive), archive)
        self.assertFalse(destination.exists())
        corrupt = self.tmp / "corrupt.tar.xz"
        shutil.copyfile(archive, corrupt)
        with corrupt.open("ab") as out:
            out.write(b"\0")
        with self.assertRaisesRegex(ValueError, "not the pinned"):
            pinned.obtain(ffmpeg.URL, ffmpeg.SOURCE_SHA256, destination, corrupt)


if __name__ == "__main__":
    unittest.main()
