#!/usr/bin/env python3
"""Build a pinned, genuine arm64 iOS Simulator MoltenVK slice locally."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "deps/MoltenVK-source"
COMMIT = "db66022459ffb663aa2b50f6b018bc2e124f5edf"


def run(command, name, cwd=SOURCE):
    log = ROOT / "build" / (name + ".log")
    log.parent.mkdir(parents=True, exist_ok=True)
    print("Running", name, "log:", log, flush=True)
    with log.open("w") as output:
        process = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
    if process.returncode:
        print(log.read_text()[-6000:])
        raise SystemExit(process.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1 or args.jobs > 2:
        parser.error("Use one or two compiler jobs to preserve other local work")
    ROOT.joinpath("deps").mkdir(exist_ok=True)
    if not SOURCE.exists():
        run(["git", "clone", "--depth", "1", "--branch", "v1.4.2",
             "https://github.com/KhronosGroup/MoltenVK.git", str(SOURCE)], "moltenvk-clone", ROOT)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=SOURCE, text=True).strip()
    if actual != COMMIT:
        raise SystemExit(f"Preserving unexpected MoltenVK checkout at {actual}; expected {COMMIT}")
    run(["./fetchDependencies", "--none", "--keep-cache"], "moltenvk-fetch")
    if args.fetch_only:
        return
    common = ["-destination", "generic/platform=iOS Simulator", "-configuration", "Release",
              "-jobs", str(args.jobs), "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO"]
    run(["xcodebuild", "-project", "ExternalDependencies.xcodeproj", "-scheme", "ExternalDependencies-iOS",
         "-derivedDataPath", str(ROOT / "build/moltenvk-dependency-derived"), *common, "build"], "moltenvk-dependencies")
    run(["xcodebuild", "-project", "MoltenVKPackaging.xcodeproj", "-scheme", "MoltenVK Package (iOS only)",
         "-derivedDataPath", str(ROOT / "build/moltenvk-derived"), *common, "build"], "moltenvk-build")
    framework = SOURCE / "Package/Latest/MoltenVK/static/MoltenVK.xcframework"
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    matches = [item for item in info["AvailableLibraries"] if item["SupportedPlatform"] == "ios"
               and item.get("SupportedPlatformVariant") == "simulator" and "arm64" in item["SupportedArchitectures"]]
    if len(matches) != 1:
        raise SystemExit("Build produced no unique genuine arm64 iOS Simulator slice")
    item = matches[0]
    library = framework / item["LibraryIdentifier"] / item["LibraryPath"]
    revisions = {}
    for revision in sorted((SOURCE / "ExternalRevisions").glob("*_repo_revision")):
        revisions[revision.name] = revision.read_text().strip()
    receipt = {"schema": 1, "source_commit": COMMIT, "platform": "ios-simulator", "architecture": "arm64",
               "library": str(library), "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
               "external_revisions": revisions, "jobs": args.jobs}
    (ROOT / "build/moltenvk-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
