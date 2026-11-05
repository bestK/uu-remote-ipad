#!/bin/sh
# Restarts the host and its Frida job. Run as root (the panel supplies the sudo password over stdin).
# $1: jailbreak root, /var/jb (Dopamine) or roothide's /var/containers/Bundle/Application/.jbroot-*.
set -e
JB="${1:-/var/jb}"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }
command -v launchctl >/dev/null 2>&1 || { echo "launchctl not found"; exit 1; }

# Older installs created the logs 0600; the panel's log page reads them as mobile.
for log in "$JB/var/log/uuremote.log" "$JB/var/log/frida-server.log"; do
    [ ! -f "$log" ] || chmod 644 "$log"
done

# Frida first: the host waits for frida-server when it starts.
for job in com.uuremote.frida com.uuremote.host; do
    plist="$JB/Library/LaunchDaemons/$job.plist"
    [ -f "$plist" ] || { echo "not installed: $job"; exit 1; }
    if launchctl print "system/$job" >/dev/null 2>&1; then
        # -k kills a hung instance too; launchctl builds without kickstart reload the job instead.
        launchctl kickstart -k "system/$job" >/dev/null 2>&1 || {
            launchctl bootout "system/$job" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
            launchctl bootstrap system "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null \
                || { echo "could not restart $job"; exit 1; }
        }
    else
        launchctl bootstrap system "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null \
            || { echo "could not start $job"; exit 1; }
    fi
    echo "restarted $job"
done
echo "service restarted"
