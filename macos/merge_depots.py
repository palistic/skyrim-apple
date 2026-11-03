#!/usr/bin/env python3
"""Join Steam `download_depot` folders into one private link view of an installation.

The Steam console writes each depot (for example 72851 base content and 72853 English
content) to its own `depot_<id>` folder, while staging expects one installation. This
builds a separate tree of real directories and per-file links. Depot files are never
moved, copied or changed. A path present in two depots must be byte-identical.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from inputs import ROOT, digest


def merge_depots(depots, output):
    roots = [Path(depot).resolve(strict=True) for depot in depots]
    if not roots or any(not root.is_dir() for root in roots):
        raise ValueError("Provide one or more depot directories")
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError(f"Preserving existing output: {output}")
    resolved_output = output.resolve(strict=False)
    for root in roots:
        if resolved_output.is_relative_to(root) or root.is_relative_to(resolved_output):
            raise ValueError("The merged view must be separate from every depot directory")
    # Windows paths are case-insensitive: key by casefolded parts and keep the first spelling.
    files = {}
    spellings = {}
    for root in roots:
        for directory, subdirectories, names in os.walk(root):
            base = Path(directory)
            for name in subdirectories:
                if (base / name).is_symlink():
                    raise ValueError(f"Unexpected link inside a depot: {base / name}")
            for name in names:
                source = base / name
                if source.is_symlink() or not source.is_file():
                    raise ValueError(f"Unexpected non-file inside a depot: {source}")
                relative = source.relative_to(root)
                key = tuple(part.casefold() for part in relative.parts)
                for depth in range(1, len(key) + 1):
                    spellings.setdefault(key[:depth], relative.parts[depth - 1])
                if key in files:
                    existing = files[key]
                    if existing.stat().st_size != source.stat().st_size or digest(existing) != digest(source):
                        raise ValueError(f"Depots disagree on {relative}; refusing to choose one")
                    continue
                files[key] = source
    if not files:
        raise ValueError("The depot directories contain no files")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".skyrim-depot-view-", dir=output.parent))
    try:
        for key, source in sorted(files.items()):
            target = staging.joinpath(*(spellings[key[:depth]] for depth in range(1, len(key) + 1)))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(source)
        (staging / "depot-view.json").write_text(json.dumps({
            "scope": "private-merged-steam-depot-view", "depots": [str(root) for root in roots],
            "linked_files": len(files), "original_files_changed": False}, indent=2) + "\n")
        if output.exists() or output.is_symlink():
            raise ValueError(f"Preserving output created while merging: {output}")
        os.rename(staging, output)
        return output
    finally:
        if staging.exists():
            # Only links and our receipt live here; rmtree never follows them to depot files.
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("depots", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, default=ROOT / "macos/build/steam-72850-view")
    args = parser.parse_args()
    try:
        output = merge_depots(args.depots, args.output)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(f"Merged depot view: {output}")


if __name__ == "__main__":
    main()
