#!/bin/sh
# Downloads the frida-core devkit the iPad host links against (libfrida-core.a is ~200 MB, not in git).
set -e
cd "$(dirname "$0")"
VERSION=17.25.0
SHA256=42f5122707d35a882862f8ca2f15bc4cb2ed1b3e9e027368eaa36746cd4db1b6
[ -f libfrida-core.a ] && [ -f frida-core.h ] && { echo "devkit already present"; exit 0; }
curl -fL -o devkit.tar.xz "https://github.com/frida/frida/releases/download/$VERSION/frida-core-devkit-$VERSION-ios-arm64.tar.xz"
echo "$SHA256  devkit.tar.xz" | shasum -a 256 -c -
tar -xJf devkit.tar.xz
echo "frida-core devkit $VERSION ready in $(pwd)"
