"""Pinned public dependency archives: a local copy or one official HTTPS download, accepted by SHA-256 only."""
import hashlib
import os
from pathlib import Path
import shutil
import urllib.parse
import urllib.request


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def obtain(url, expected, destination, archive=None, opener=urllib.request.urlopen):
    """Return a verified archive: `archive` read in place, else `destination`, downloaded once if absent.

    Nothing with a different SHA-256 is ever returned; a mismatching download is discarded and an
    existing mismatching file is preserved for inspection.
    """
    if archive is not None:
        archive = Path(archive)
        if not archive.is_file():
            raise ValueError(f"{archive} is not a file")
        actual = sha256(archive)
        if actual != expected:
            raise ValueError(f"{archive} has SHA-256 {actual}, not the pinned {expected} ({url})")
        return archive
    destination = Path(destination)
    if destination.is_symlink() or destination.parent.is_symlink():
        raise ValueError(f"Refusing a symlinked dependency path: {destination}")
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial = destination.with_name(destination.name + ".download")
        if partial.exists() or partial.is_symlink():
            raise ValueError(f"An earlier partial download was preserved at {partial}; remove it to retry")
        try:
            with opener(url, timeout=60) as response, partial.open("xb") as output:
                if urllib.parse.urlparse(response.geturl()).scheme != "https":
                    raise ValueError(f"Refusing a non-HTTPS download location for {url}")
                shutil.copyfileobj(response, output, 1 << 20)
            actual = sha256(partial)
            if actual != expected:
                raise ValueError(f"The download of {url} has SHA-256 {actual}, not the pinned {expected}; it was discarded")
        except BaseException:
            partial.unlink(missing_ok=True)
            raise
        os.replace(partial, destination)
    actual = sha256(destination)
    if actual != expected:
        raise ValueError(f"{destination} has SHA-256 {actual}, not the pinned {expected}; it was preserved for inspection")
    return destination
