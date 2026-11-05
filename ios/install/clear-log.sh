#!/bin/sh
# Truncate one allowlisted daemon log in place, keeping launchd's open descriptor valid.
set -e
JB="${1:-/var/jb}"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
[ "$(id -u)" = 0 ] || { printf 'must run as root\n'; exit 1; }
case "${2:-}" in
    host) name=uuremote.log ;;
    frida) name=frida-server.log ;;
    *) printf 'invalid log selection\n'; exit 1 ;;
esac
log="$JB/var/log/$name"
[ ! -L "$JB/var/log" ] && [ ! -L "$log" ] || { printf 'refusing symlink\n'; exit 1; }
# No file is already empty; never create missing directories or remove log files.
[ -e "$log" ] || { printf 'log already absent\n'; exit 0; }
[ -f "$log" ] || { printf 'not a regular log\n'; exit 1; }
: > "$log"
printf 'log cleared\n'
