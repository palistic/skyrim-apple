#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON="$ROOT/macos/.venv/bin/python"
exec "$PYTHON" "$ROOT/simulator/build.py" "$@"
