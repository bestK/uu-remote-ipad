#!/bin/sh
# Builds UURemotePanel.app (and UURemotePanel.ipa) for the iPad. The IPA carries the host service
# too, so another user only installs the IPA and installs the service from the panel's first screen.
set -e
cd "$(dirname "$0")"
OUT="${1:-build}"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
APP=$OUT/UURemotePanel.app
SERVICE=$APP/service
ROOT=$(cd ../.. && pwd)
# An explicit host artifact keeps panel-only builds independent of other local Cargo builds.
HOST=${UU_IPAD_HOST:-$ROOT/target/aarch64-apple-ios/release/uuremote-server}
# One version for the panel and the host it carries: the release tag, else the commit.
# The host must be built with the same UU_IPAD_VERSION (the panel flags a mismatch).
VERSION=${UU_IPAD_VERSION:-dev-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}

[ -f "$HOST" ] || {
    echo "missing $HOST" >&2
    echo "build it first: IPHONEOS_DEPLOYMENT_TARGET=16.0 SDKROOT=\$(xcrun --sdk iphoneos --show-sdk-path) UU_NO_GTK=1 cargo build --release --target aarch64-apple-ios --bin uuremote-server" >&2
    exit 1
}

# Both server and agent are needed: the server can enumerate processes without its agent,
# but cannot attach. Extracted together by ios/frida/fetch-server.sh (git-ignored).
FRIDA=$ROOT/ios/frida/frida-server
AGENT=$ROOT/ios/frida/frida-agent.dylib
if [ ! -f "$FRIDA" ] || [ ! -f "$AGENT" ]; then
    echo "missing frida-server or frida-agent.dylib" >&2
    echo "fetch it first: ios/frida/fetch-server.sh" >&2
    exit 1
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
rm -rf "$APP" "$OUT/Payload"
mkdir -p "$APP" "$SERVICE"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 \
    -isysroot "$SDK" -framework UIKit -framework Foundation -framework QuartzCore \
    -o "$APP/UURemotePanel" main.m
cp Info.plist "$APP/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Info.plist"
grep -qF "$VERSION" "$HOST" || echo "warning: $HOST was not built with UU_IPAD_VERSION=$VERSION" >&2
# Icon from the locally installed official app (no NetEase artwork in the repo).
python3 make-icon.py "$APP"

cp "$HOST" "$SERVICE/uuremote-server"
cp "$FRIDA" "$SERVICE/frida-server"
cp "$AGENT" "$SERVICE/frida-agent.dylib"
chmod 755 "$SERVICE/frida-agent.dylib"
cp ../install/com.uuremote.host.plist ../install/com.uuremote.frida.plist \
   ../install/com.uuremote.indicator.plist \
   ../install/entitlements.plist ../install/install-service.sh ../install/uninstall-service.sh \
   ../install/restart-service.sh ../install/diagnose-service.sh ../install/clear-log.sh \
   ../install/install-indicator.sh ../install/uninstall-indicator.sh "$SERVICE/"
chmod 755 "$SERVICE/uuremote-server" "$SERVICE/frida-server" "$SERVICE/install-service.sh" "$SERVICE/uninstall-service.sh" \
    "$SERVICE/restart-service.sh" "$SERVICE/diagnose-service.sh" "$SERVICE/clear-log.sh" \
    "$SERVICE/install-indicator.sh" "$SERVICE/uninstall-indicator.sh"
chmod 644 "$SERVICE"/*.plist

# Optional remote-session indicator: a separate process with its own entitlements. It ships inside
# the IPA so one install covers everything; a failure here never blocks the host service.
HUD=$ROOT/ios/hud
mkdir -p "$SERVICE/UUStatusHUD.app"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 \
    -isysroot "$SDK" -framework UIKit -framework Foundation -framework CoreFoundation -framework QuartzCore \
    -I"$HUD" -o "$SERVICE/UUStatusHUD.app/UUStatusHUD" \
    "$HUD/main.m" "$HUD/indicator_state.m" "$HUD/indicator_view.m" "$HUD/status_file.m"
cp "$HUD/Info.plist" "$SERVICE/UUStatusHUD.app/Info.plist"
cp "$HUD/NOTICE.TrollSpeed" "$SERVICE/UUStatusHUD.app/NOTICE.TrollSpeed"
cp "$HUD/entitlements.plist" "$SERVICE/hud-entitlements.plist"
chmod 644 "$SERVICE/hud-entitlements.plist"

# TrollStore keeps the entitlements a binary already carries, so the panel must be signed here:
# unsigned it would run sandboxed and could not read the host status or run the service scripts.
# The host is signed on the device by install-service.sh (Homebrew ldid chokes on that binary).
command -v ldid >/dev/null || { echo "ldid not found (brew install ldid)" >&2; exit 1; }
ldid -Sentitlements.plist "$APP/UURemotePanel"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
rm -f "$OUT/UURemotePanel.ipa"
(cd "$OUT" && zip -qry UURemotePanel.ipa Payload)
echo "built: $APP and $OUT/UURemotePanel.ipa ($(du -sh "$OUT/UURemotePanel.ipa" | cut -f1))"
