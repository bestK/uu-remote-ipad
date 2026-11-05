#!/bin/sh
# Removes the optional remote-session indicator daemon. Run as root. Leaves the host service alone.
# $1: jailbreak root, /var/jb or roothide's .jbroot-*.
set -e
JB="${1:-/var/jb}"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
command -v launchctl >/dev/null 2>&1 || { echo "launchctl not found"; exit 1; }

plist="$JB/Library/LaunchDaemons/com.uuremote.indicator.plist"
if ! launchctl bootout system/com.uuremote.indicator 2>/dev/null; then
    if launchctl print system/com.uuremote.indicator >/dev/null 2>&1; then
        launchctl unload "$plist" 2>/dev/null || { echo "could not stop com.uuremote.indicator"; exit 1; }
    fi
fi
if launchctl print system/com.uuremote.indicator >/dev/null 2>&1; then
    echo "still loaded: com.uuremote.indicator"
    exit 1
fi
rm -f "$plist"
rm -rf "$JB/usr/local/lib/UUStatusHUD.app" "$JB/usr/local/lib/UUStatusHUD.app.new"
rm -f "$JB/usr/local/bin/uu-status-hud" "$JB/usr/local/bin/uu-status-hud.new"
echo "indicator uninstalled"
