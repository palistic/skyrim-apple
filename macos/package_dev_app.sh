#!/bin/sh
# Wrap the sealed native game executable in a development .app so LaunchServices
# can identify the real game process and window. The sealed build is only read:
# the bundle holds a separate, byte-identical copy (APFS clone or plain copy),
# never a hard link, and nothing here re-signs or rewrites the sealed binary.
#
#   macos/package_dev_app.sh GAME_DIRECTORY [SEPARATE_SAVE_DIRECTORY]
#   macos/package_dev_app.sh --check      validate the bundle without launching it
#
# Launch with the command written to Contents/Resources/launch-args.txt:
#   open -n "macos/build/dev-app/Skyrim Native (Dev).app" --args GAME_DIR SAVE_DIR
# (absolute paths; the app is not started from a shell, so its cwd is /).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NATIVE="$ROOT/macos/build/native/skyrim_macos"
RECEIPT="$NATIVE.build-receipt.json"
OUT="$ROOT/macos/build/dev-app"
NAME="Skyrim Native (Dev)"
APP="$OUT/$NAME.app"
BUNDLE_ID=dev.zschwendi.skyrim.native.dev
MARKER=Contents/Resources/launch-args.txt
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() { echo "package_dev_app: $*" >&2; exit 2; }
sha() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
value() { plutil -extract "$2" raw -o - "$1"; }
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The same receipt check macos/run.sh makes; prints the sealed MoltenVK path.
verify_receipt() {
    if [ -n "$1" ]; then
        "$ROOT/macos/.venv/bin/python" "$ROOT/macos/build_receipt.py" verify \
            --gen-dir "$ROOT/gen" --binary "$NATIVE" --build-dir "$ROOT/macos/build/native" \
            --game-dir "$1" --print-dependency moltenvk
    else
        "$ROOT/macos/.venv/bin/python" "$ROOT/macos/build_receipt.py" verify \
            --gen-dir "$ROOT/gen" --binary "$NATIVE" --build-dir "$ROOT/macos/build/native" \
            --print-dependency moltenvk
    fi
}

# Structure, plist and hash relation only; never launches the game.
check_bundle() {
    [ -d "$APP" ] && [ ! -L "$APP" ] || fail "no development bundle at $APP"
    plist="$APP/Contents/Info.plist"
    exe="$APP/Contents/MacOS/skyrim_macos"
    plutil -lint "$plist" >/dev/null || fail "Info.plist does not lint"
    for pair in "CFBundleIdentifier=$BUNDLE_ID" "CFBundleName=$NAME" "CFBundleDisplayName=$NAME" \
            CFBundleExecutable=skyrim_macos CFBundlePackageType=APPL LSMinimumSystemVersion=13.0 \
            NSHighResolutionCapable=true LSEnvironment.LB_LOG=1 \
            "LSEnvironment.DXVK_CONFIG_FILE=$ROOT/macos/runtime.conf"; do
        key=${pair%%=*}; want=${pair#*=}
        [ "$(value "$plist" "$key" 2>/dev/null)" = "$want" ] || fail "Info.plist $key is not $want"
    done
    moltenvk=$(verify_receipt "") || fail "the sealed build no longer verifies; the bundle copy is stale"
    [ "$(value "$plist" LSEnvironment.SDL_VULKAN_LIBRARY)" = "$moltenvk" ] || fail "SDL_VULKAN_LIBRARY is not the sealed MoltenVK"
    cache=$(value "$plist" LSEnvironment.DXVK_STATE_CACHE_PATH)
    [ -d "$cache" ] && [ "$(value "$plist" LSEnvironment.DXVK_LOG_PATH)" = "$cache" ] || fail "DXVK cache/log paths are not one existing save directory"
    [ -f "$APP/$MARKER" ] && [ -f "$APP/Contents/PkgInfo" ] || fail "bundle resources are incomplete"
    [ -f "$exe" ] && [ ! -L "$exe" ] && [ -x "$exe" ] || fail "bundle executable is missing"
    [ "$(stat -f %l "$exe")" = 1 ] && [ "$(stat -f %i "$exe")" != "$(stat -f %i "$NATIVE")" ] || fail "bundle executable is linked to the sealed file"
    sealed=$(value "$RECEIPT" binary_sha256)
    [ "$(sha "$NATIVE")" = "$sealed" ] || fail "sealed executable differs from its receipt"
    [ "$(value "$plist" SkyrimNativeSealedSHA256)" = "$sealed" ] || fail "bundle was packaged from a different sealed build"
    [ "$(sha "$exe")" = "$sealed" ] || fail "bundle executable is not byte-identical to the sealed executable"
    echo "OK: $APP"
    echo "    $BUNDLE_ID; Contents/MacOS/skyrim_macos SHA-256 $sealed = sealed receipt = $NATIVE"
}

if [ "$#" -eq 1 ] && [ "$1" = "--check" ]; then
    check_bundle; exit 0
fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: macos/package_dev_app.sh GAME_DIRECTORY [SEPARATE_SAVE_DIRECTORY] | --check" >&2; exit 2
fi
GAME_DIR=$(CDPATH= cd -- "$1" && pwd)
SAVE_DIR=${2:-"$ROOT/macos/build/saves"}
if [ ! -x "$NATIVE" ]; then
    echo "No native game executable. Run macos/build.sh --game after preparing your inputs." >&2; exit 2
fi
MOLTENVK_LIBRARY=$(verify_receipt "$GAME_DIR") || fail "build receipt verification failed; refusing to package"
SEALED=$(value "$RECEIPT" binary_sha256)
[ "$(sha "$NATIVE")" = "$SEALED" ] || fail "sealed executable differs from its receipt"
mkdir -p "$SAVE_DIR"
SAVE_DIR=$(CDPATH= cd -- "$SAVE_DIR" && pwd)

# Replace only this script's own previous bundle, and never while it runs.
if [ -e "$APP" ] || [ -L "$APP" ]; then
    [ -d "$APP" ] && [ ! -L "$APP" ] && [ -f "$APP/$MARKER" ] &&
        [ "$(value "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)" = "$BUNDLE_ID" ] ||
        fail "$APP exists but is not this script's development bundle; refusing to overwrite it"
    if ps -axww -o comm= | grep -Fqx "$APP/Contents/MacOS/skyrim_macos"; then
        fail "the development app is running; quit it before repackaging"
    fi
fi
mkdir -p "$OUT"
STAGE=$(mktemp -d "$OUT/.staging.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/$NAME.app"
EXE="$NEW/Contents/MacOS/skyrim_macos"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
# Copy-on-write clone where APFS allows it, else a plain copy: either way a
# separate file, so later writes to it (e.g. signing) cannot reach the original.
cp -c "$NATIVE" "$EXE" 2>/dev/null || { rm -f "$EXE"; cp "$NATIVE" "$EXE"; }
chmod 755 "$EXE"
[ "$(stat -f %i "$EXE")" != "$(stat -f %i "$NATIVE")" ] || fail "copy shares the sealed file"
[ "$(sha "$EXE")" = "$SEALED" ] || fail "copied executable does not match the sealed SHA-256"
printf 'APPL????' > "$NEW/Contents/PkgInfo"

PLIST="$NEW/Contents/Info.plist"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict/></plist>' > "$PLIST"
put() { plutil -insert "$1" "$2" "$3" "$PLIST"; }
put CFBundleIdentifier -string "$BUNDLE_ID"
put CFBundleName -string "$NAME"
put CFBundleDisplayName -string "$NAME"
put CFBundleExecutable -string skyrim_macos
put CFBundlePackageType -string APPL
put CFBundleInfoDictionaryVersion -string 6.0
put CFBundleShortVersionString -string 0.0.0
put CFBundleVersion -string 0
put LSMinimumSystemVersion -string 13.0
put NSHighResolutionCapable -bool YES
put SkyrimNativeSealedSHA256 -string "$SEALED"
plutil -insert LSEnvironment -dictionary "$PLIST"
put LSEnvironment.SDL_VULKAN_LIBRARY -string "$MOLTENVK_LIBRARY"
put LSEnvironment.DXVK_STATE_CACHE_PATH -string "$SAVE_DIR"
put LSEnvironment.DXVK_LOG_PATH -string "$SAVE_DIR"
put LSEnvironment.DXVK_CONFIG_FILE -string "$ROOT/macos/runtime.conf"
put LSEnvironment.LB_LOG -string 1
plutil -lint "$PLIST" >/dev/null

{
    echo "# $NAME: development bundle around the sealed native game executable."
    echo "# Written by macos/package_dev_app.sh $(date -u +%Y-%m-%dT%H:%M:%SZ); local build product."
    echo "# Contents/MacOS/skyrim_macos is byte-identical to $NATIVE"
    echo "# (SHA-256 $SEALED, unsigned by this script)."
    echo "# Info.plist LSEnvironment carries the macos/run.sh environment plus LB_LOG=1."
    echo "# Launch a new instance (absolute paths only):"
    echo "open -n $(quote "$APP") --args $(quote "$GAME_DIR") $(quote "$SAVE_DIR")"
    echo "# Automated runs may add, before --args: --env LB_MOUSE_CAPTURE=0 --env LB_SHOT=1500"
    echo "#   --stderr $(quote "$SAVE_DIR/dev-app-stderr.log")   (LB_LOG output; otherwise discarded)"
    echo "# Quit with Cmd-Q in the game window, or kill -TERM <pid> after confirming"
    echo "#   ps -o comm= -p <pid> is $APP/Contents/MacOS/skyrim_macos"
    echo "# Recheck without launching: macos/package_dev_app.sh --check"
} > "$NEW/$MARKER"

if [ -e "$APP" ]; then rm -rf "$APP"; fi
mv "$NEW" "$APP"
# Refresh LaunchServices' cached Info.plist (LSEnvironment) for this path.
if [ -x "$LSREGISTER" ]; then "$LSREGISTER" -f "$APP" || echo "warning: lsregister failed" >&2; fi
check_bundle
echo "Launch: $(sed -n '/^open /p' "$APP/$MARKER")"
