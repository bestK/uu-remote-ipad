#!/bin/sh
# Installs the optional remote-session indicator daemon. Run as root.
# $1: jailbreak root, /var/jb (Dopamine) or roothide's /var/containers/Bundle/Application/.jbroot-*.
# $2: directory holding UUStatusHUD.app, hud-entitlements.plist and com.uuremote.indicator.plist.
set -e
JB="${1:-/var/jb}"
SRC="${2:-.}"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
[ -d "$JB" ] || { echo "jailbreak root not found"; exit 1; }
for f in UUStatusHUD.app/UUStatusHUD hud-entitlements.plist com.uuremote.indicator.plist; do
    [ -f "$SRC/$f" ] || { echo "missing $f"; exit 1; }
done
LDID="$JB/usr/bin/ldid"
[ -x "$LDID" ] || LDID=$(command -v ldid) || { echo "ldid not found"; exit 1; }

# UIKit reads CFBundleIdentifier from the Info.plist beside the executable, so the daemon runs
# from inside an .app bundle even though LaunchServices never registers it.
mkdir -p "$JB/usr/local/lib" "$JB/Library/LaunchDaemons" "$JB/var/log"
rm -rf "$JB/usr/local/lib/UUStatusHUD.app.new"
cp -R "$SRC/UUStatusHUD.app" "$JB/usr/local/lib/UUStatusHUD.app.new"
"$LDID" -S"$SRC/hud-entitlements.plist" "$JB/usr/local/lib/UUStatusHUD.app.new/UUStatusHUD"
chmod 755 "$JB/usr/local/lib/UUStatusHUD.app.new/UUStatusHUD"
rm -rf "$JB/usr/local/lib/UUStatusHUD.app"
mv "$JB/usr/local/lib/UUStatusHUD.app.new" "$JB/usr/local/lib/UUStatusHUD.app"

touch "$JB/var/log/uu-indicator.log"
chmod 644 "$JB/var/log/uu-indicator.log"
# The plist names /var/jb; launchd needs the real root on roothide.
sed "s#/var/jb#$JB#g" "$SRC/com.uuremote.indicator.plist" > "$JB/Library/LaunchDaemons/com.uuremote.indicator.plist"
chmod 644 "$JB/Library/LaunchDaemons/com.uuremote.indicator.plist"

launchctl bootout system/com.uuremote.indicator 2>/dev/null || true
launchctl bootstrap system "$JB/Library/LaunchDaemons/com.uuremote.indicator.plist" 2>/dev/null \
    || launchctl load -w "$JB/Library/LaunchDaemons/com.uuremote.indicator.plist"
echo "indicator installed"
