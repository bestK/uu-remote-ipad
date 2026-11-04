#!/bin/sh
# Builds UURemotePanel.app (and UURemotePanel.ipa) for the iPad. The IPA carries the host service
# too, so another user only installs the IPA and installs the service from the panel's first screen.
set -e
cd "$(dirname "$0")"
OUT="${1:-build}"
APP=$OUT/UURemotePanel.app
SERVICE=$APP/service
ROOT=$(cd ../.. && pwd)
HOST=$ROOT/target/aarch64-apple-ios/release/uuremote-server

[ -f "$HOST" ] || {
    echo "missing $HOST" >&2
    echo "build it first: IPHONEOS_DEPLOYMENT_TARGET=16.0 SDKROOT=\$(xcrun --sdk iphoneos --show-sdk-path) UU_NO_GTK=1 cargo build --release --target aarch64-apple-ios --bin uuremote-server" >&2
    exit 1
}

# frida-server is ~18 MB and ships inside the IPA. Frida publishes no iOS server binary, so it is
# copied once from a jailbroken device (ios/frida/* is git-ignored) or built from frida's source.
FRIDA=$ROOT/ios/frida/frida-server
if [ ! -f "$FRIDA" ]; then
    echo "missing $FRIDA" >&2
    echo "copy it from a jailbroken iPad: ssh mobile@<ipad> 'sudo cat /var/jb/usr/sbin/frida-server' > ios/frida/frida-server" >&2
    exit 1
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
rm -rf "$APP" "$OUT/Payload"
mkdir -p "$APP" "$SERVICE"
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 \
    -isysroot "$SDK" -framework UIKit -framework Foundation -framework QuartzCore \
    -o "$APP/UURemotePanel" main.m
cp Info.plist "$APP/Info.plist"
# Icon from the locally installed official app (no NetEase artwork in the repo).
python3 make-icon.py "$APP"

cp "$HOST" "$SERVICE/uuremote-server"
cp "$FRIDA" "$SERVICE/frida-server"
cp ../install/com.uuremote.host.plist ../install/com.uuremote.frida.plist \
   ../install/entitlements.plist ../install/install-service.sh ../install/uninstall-service.sh "$SERVICE/"
chmod 755 "$SERVICE/uuremote-server" "$SERVICE/frida-server" "$SERVICE/install-service.sh" "$SERVICE/uninstall-service.sh"
chmod 644 "$SERVICE"/*.plist

# Signing happens on the device (Homebrew ldid chokes on this binary): ldid -S entitlements.plist
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
rm -f "$OUT/UURemotePanel.ipa"
(cd "$OUT" && zip -qry UURemotePanel.ipa Payload)
echo "built: $(pwd)/$APP and $OUT/UURemotePanel.ipa ($(du -sh "$OUT/UURemotePanel.ipa" | cut -f1))"
