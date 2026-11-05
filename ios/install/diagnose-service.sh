#!/bin/sh
# Read-only service diagnostics. Never emit launchctl output, process arguments or credentials.
set -e
JB="${1:-/var/jb}"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
[ "$(id -u)" = 0 ] || { printf 'must run as root\n'; exit 1; }
command -v launchctl >/dev/null 2>&1 || { printf 'launchctl not found\n'; exit 1; }
for job in com.uuremote.host com.uuremote.frida; do
    if info=$(launchctl print "system/$job" 2>/dev/null); then
        # Numeric fields and a short state only; do not export paths, arguments, or environment.
        printf '%s\n' "$info" | awk -v job="$job" '
            /^[[:space:]]*state = / { state=$3 }
            /^[[:space:]]*pid = / && $3 ~ /^[0-9]+$/ { pid=$3 }
            /^[[:space:]]*runs = / && $3 ~ /^[0-9]+$/ { runs=$3 }
            /^[[:space:]]*last exit code = / && $5 ~ /^-?[0-9]+$/ { exitcode=$5 }
            END {
                if (state !~ /^(running|waiting|exited|spawn scheduled|not running)$/) state="unknown";
                printf "%s loaded=yes state=%s pid=%s runs=%s exit=%s\n", job, state, (pid != "" ? pid : "-"), (runs != "" ? runs : "-"), (exitcode != "" ? exitcode : "-");
            }'
    else
        printf '%s loaded=unknown\n' "$job"
    fi
done
if [ -f "$JB/usr/lib/frida-1.0/frida-agent.dylib" ]; then
    printf 'frida-agent present=yes\n'
else
    printf 'frida-agent present=no\n'
fi
if [ -f "$JB/usr/lib/frida-agent.dylib" ]; then
    printf 'frida-agent-direct present=yes\n'
else
    printf 'frida-agent-direct present=no\n'
fi
if processes=$(ps -A -o comm= 2>/dev/null); then
    printf '%s\n' "$processes" | awk '{ name=$0; sub(/^.*\//, "", name); if (name == "frida-server") n++ } END { printf "frida-server processes=%d\n", n }'
else
    printf 'frida-server processes=unknown\n'
fi
