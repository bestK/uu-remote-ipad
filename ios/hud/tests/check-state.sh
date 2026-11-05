#!/bin/sh
# Foundation-only state checks; no device, service, account or SpringBoard access.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/uu-indicator-state.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -I"$ROOT" \
    -framework Foundation -framework CoreFoundation \
    "$ROOT/indicator_state.m" "$ROOT/tests/indicator-state-check.m" -o "$OUT/check"
"$OUT/check"
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -I"$ROOT" -framework Foundation \
    "$ROOT/status_file.m" "$ROOT/tests/status-file-check.m" -o "$OUT/file-check"
"$OUT/file-check"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -isysroot "$SDK" \
    -fobjc-arc -Wall -Wextra -Werror -I"$ROOT" -c "$ROOT/indicator_state.m" -o "$OUT/state.o"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -isysroot "$SDK" \
    -fobjc-arc -Wall -Wextra -Werror -I"$ROOT" -c "$ROOT/status_file.m" -o "$OUT/file.o"
printf 'iOS arm64 indicator state compile: ok\n'
