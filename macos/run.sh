#!/bin/sh
# Run only the user's privately generated native game build, with separate saves.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: macos/run.sh GAME_DIRECTORY [SEPARATE_SAVE_DIRECTORY]" >&2; exit 2
fi
GAME_DIR=$(CDPATH= cd -- "$1" && pwd)
SAVE_DIR=${2:-"$ROOT/macos/build/saves"}
if [ ! -x "$ROOT/macos/build/native/skyrim_macos" ]; then
    echo "No native game executable. Run macos/build.sh --game after preparing your inputs." >&2; exit 2
fi
MOLTENVK_LIBRARY=$("$ROOT/macos/.venv/bin/python" "$ROOT/macos/build_receipt.py" verify \
    --gen-dir "$ROOT/gen" --binary "$ROOT/macos/build/native/skyrim_macos" \
    --build-dir "$ROOT/macos/build/native" --game-dir "$GAME_DIR" --print-dependency moltenvk)
mkdir -p "$SAVE_DIR"
SAVE_DIR=$(CDPATH= cd -- "$SAVE_DIR" && pwd)
export SDL_VULKAN_LIBRARY="$MOLTENVK_LIBRARY"
export DXVK_STATE_CACHE_PATH="$SAVE_DIR"
export DXVK_LOG_PATH="$SAVE_DIR"
export DXVK_CONFIG_FILE="$ROOT/macos/runtime.conf"
exec "$ROOT/macos/build/native/skyrim_macos" "$GAME_DIR" "$SAVE_DIR"
