#!/bin/sh
# Run on the iPad as root: install.sh [/path/to/uuremote-server]
set -e
BIN="${1:-/var/jb/usr/local/bin/uuremote-server}"
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /var/jb/var/log
install -Dm755 "$BIN" /var/jb/usr/local/bin/uuremote-server 2>/dev/null || true
install -Dm644 "$DIR/com.uuremote.host.plist" /var/jb/Library/LaunchDaemons/com.uuremote.host.plist
install -Dm644 "$DIR/com.uuremote.frida.plist" /var/jb/Library/LaunchDaemons/com.uuremote.frida.plist
/var/jb/usr/bin/ldid -S"$DIR/entitlements.plist" /var/jb/usr/local/bin/uuremote-server
for job in com.uuremote.host com.uuremote.frida; do
    /bin/launchctl bootout system/$job 2>/dev/null || true
    /bin/launchctl bootstrap system /var/jb/Library/LaunchDaemons/$job.plist 2>/dev/null || true
done
echo "installed; log: /var/jb/var/log/uuremote.log"
