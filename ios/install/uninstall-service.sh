#!/bin/sh
# Run as root (the panel supplies the sudo password over stdin). Keep account data and shared Frida.
set -e
[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }
command -v launchctl >/dev/null 2>&1 || { echo "launchctl not found"; exit 1; }

stop_job() {
    job="$1"
    plist="/var/jb/Library/LaunchDaemons/$job.plist"
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
rm -f /var/jb/Library/LaunchDaemons/com.uuremote.host.plist \
    /var/jb/Library/LaunchDaemons/com.uuremote.frida.plist \
    /var/jb/usr/local/bin/uuremote-server /var/jb/usr/local/bin/uuremote-server.new
# Clear live state and queued commands so the panel and a later reinstall cannot use stale data.
rm -f /private/var/tmp/uu-status.txt /private/var/tmp/uu-status.json \
    /private/var/tmp/uu-qr.png /private/var/tmp/uu-unlock.txt \
    /var/mobile/Library/UURemote/command
# frida-server may be used by other tools; never remove its binary or any unrelated launch job.
echo "service uninstalled"
