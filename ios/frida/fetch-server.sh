#!/bin/sh
# Extracts frida-server for the IPA from Frida's own iphoneos-arm64 package (rootless /var/jb layout).
# Frida ships no bare iOS server binary; the .deb is the official release asset. Not kept in git.
set -e
cd "$(dirname "$0")"
VERSION=17.25.0
SHA256=06db01720470d334f7bf4c61687c157d029e42d0ef0e75bded89dd3c0b90914a
[ -f frida-server ] && { echo "frida-server already present"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fL -o "$work/frida.deb" "https://github.com/frida/frida/releases/download/$VERSION/frida_${VERSION}_iphoneos-arm64.deb"
echo "$SHA256  $work/frida.deb" | shasum -a 256 -c -
(cd "$work" && ar x frida.deb && mkdir data && tar -xf data.tar.* -C data)
install -m 755 "$work/data/var/jb/usr/sbin/frida-server" frida-server
echo "frida-server $VERSION ready in $(pwd)"
