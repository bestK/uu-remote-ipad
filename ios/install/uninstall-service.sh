#!/bin/sh
# Run as root (the panel supplies the sudo password over stdin). Keep account data and shared Frida.
# $1: jailbreak root, /var/jb (Dopamine) or roothide's /var/containers/Bundle/Application/.jbroot-*.
set -e
JB="${1:-/var/jb}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }
command -v launchctl >/dev/null 2>&1 || { echo "launchctl not found"; exit 1; }

# Stop the optional indicator first: it only reads the host's status file.
if [ -f "$DIR/uninstall-indicator.sh" ]; then
    echo "stopping indicator"
    sh "$DIR/uninstall-indicator.sh" "$JB" || echo "warning: indicator not removed"
elif launchctl print system/com.uuremote.indicator >/dev/null 2>&1; then
    launchctl bootout system/com.uuremote.indicator 2>/dev/null || true
    rm -f "$JB/Library/LaunchDaemons/com.uuremote.indicator.plist"
fi

stop_job() {
    job="$1"
    plist="$JB/Library/LaunchDaemons/$job.plist"
    if ! launchctl bootout "system/$job" 2>/dev/null; then
        # Already absent is fine; a loaded job must stop before any of its files are removed.
        if launchctl print "system/$job" >/dev/null 2>&1; then
            launchctl unload "$plist" 2>/dev/null || { echo "could not stop $job"; return 1; }
        fi
    fi
    if launchctl print "system/$job" >/dev/null 2>&1; then
        echo "still loaded: $job"
        return 1
    fi
}

echo "stopping host"
stop_job com.uuremote.host
echo "stopping host Frida job"
stop_job com.uuremote.frida

echo "removing host service"
rm -f "$JB/Library/LaunchDaemons/com.uuremote.host.plist" \
    "$JB/Library/LaunchDaemons/com.uuremote.frida.plist" \
    "$JB/usr/local/bin/uuremote-server" "$JB/usr/local/bin/uuremote-server.new"
# Clear live state and queued commands so the panel and a later reinstall cannot use stale data.
rm -f /private/var/tmp/uu-status.txt /private/var/tmp/uu-status.json \
    /private/var/tmp/uu-qr.png /private/var/tmp/uu-unlock.txt \
    /var/mobile/Library/UURemote/command
# frida-server may be used by other tools; never remove its binary or any unrelated launch job.
echo "service uninstalled"
