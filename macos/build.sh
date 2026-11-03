#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GAME=OFF
if [ "${1:-}" = --game ]; then GAME=ON; shift; fi
if [ "$#" -ne 0 ]; then echo "usage: macos/build.sh [--game]" >&2; exit 2; fi
cmake -S "$ROOT/macos" -B "$ROOT/macos/build/native" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DLB_STRICT_ORDER=ON -DSKYRIM_BUILD_GAME="$GAME"
cmake --build "$ROOT/macos/build/native" --parallel "${SKYRIM_BUILD_JOBS:-2}"
