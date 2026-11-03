#!/bin/sh
# Installs the host service from this directory (inside the panel app bundle). Run as root:
# the panel calls it through sudo with the device password on stdin.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }
for f in uuremote-server frida-server com.uuremote.host.plist com.uuremote.frida.plist entitlements.plist; do
    [ -f "$DIR/$f" ] || { echo "missing $f"; exit 1; }
done
LDID=/var/jb/usr/bin/ldid
[ -x "$LDID" ] || LDID=$(command -v ldid) || { echo "ldid not found"; exit 1; }

echo "installing host"
mkdir -p /var/jb/usr/local/bin /var/jb/usr/sbin /var/jb/Library/LaunchDaemons
cp "$DIR/uuremote-server" /var/jb/usr/local/bin/uuremote-server.new
"$LDID" -S"$DIR/entitlements.plist" /var/jb/usr/local/bin/uuremote-server.new
chmod 755 /var/jb/usr/local/bin/uuremote-server.new
# A running binary cannot be overwritten in place.
mv -f /var/jb/usr/local/bin/uuremote-server.new /var/jb/usr/local/bin/uuremote-server

echo "installing frida-server"
cp "$DIR/frida-server" /var/jb/usr/sbin/frida-server.new
chmod 755 /var/jb/usr/sbin/frida-server.new
mv -f /var/jb/usr/sbin/frida-server.new /var/jb/usr/sbin/frida-server

echo "installing launch daemons"
install -m 644 "$DIR/com.uuremote.host.plist" /var/jb/Library/LaunchDaemons/com.uuremote.host.plist
install -m 644 "$DIR/com.uuremote.frida.plist" /var/jb/Library/LaunchDaemons/com.uuremote.frida.plist

for job in com.uuremote.host com.uuremote.frida; do
    launchctl bootout system/$job 2>/dev/null || true
    launchctl bootstrap system /var/jb/Library/LaunchDaemons/$job.plist 2>/dev/null \
        || launchctl load -w /var/jb/Library/LaunchDaemons/$job.plist 2>/dev/null || true
done
echo "service installed"
