#!/bin/sh
# Builds UURemotePanel.app (and UURemotePanel.ipa) for the iPad.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
rm -rf build && mkdir -p build/UURemotePanel.app
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc -O2 \
    -isysroot "$SDK" -framework UIKit -framework Foundation -framework QuartzCore \
    -o build/UURemotePanel.app/UURemotePanel main.m
cp Info.plist build/UURemotePanel.app/Info.plist
# Signing happens on the device (Homebrew ldid chokes on this binary): ldid -S entitlements.plist
rm -rf build/Payload && mkdir -p build/Payload
cp -R build/UURemotePanel.app build/Payload/
(cd build && zip -qry UURemotePanel.ipa Payload)
echo "built: $(pwd)/build/UURemotePanel.app and UURemotePanel.ipa"
