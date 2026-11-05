#!/bin/sh
# Build only; never deploy, register or start the experimental HUD.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd)
[ "$#" = 1 ] || { printf 'usage: sh build-experiment.sh NEW_OUTPUT_DIRECTORY\n' >&2; exit 2; }
OUT=$1
[ ! -e "$OUT" ] || { printf 'output already exists; choose a new directory\n' >&2; exit 1; }
mkdir -p "$OUT/UUStatusHUD.app"
OUT=$(CDPATH= cd "$OUT" && pwd)
APP="$OUT/UUStatusHUD.app"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -isysroot "$SDK" \
    -fobjc-arc -Wall -Wextra -Werror -O2 -I"$ROOT" \
    -framework UIKit -framework Foundation -framework CoreFoundation -framework QuartzCore \
    "$ROOT/main.m" "$ROOT/indicator_state.m" "$ROOT/indicator_view.m" "$ROOT/status_file.m" -o "$APP/UUStatusHUD"
cp "$ROOT/Info.plist" "$APP/Info.plist"
cp "$ROOT/NOTICE.TrollSpeed" "$APP/NOTICE.TrollSpeed"
command -v ldid >/dev/null || { printf 'ldid not found\n' >&2; exit 1; }
ldid -S"$ROOT/entitlements.plist" "$APP/UUStatusHUD"
printf 'built experimental HUD: %s\n' "$APP"
