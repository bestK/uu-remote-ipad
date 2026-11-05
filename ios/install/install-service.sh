#!/bin/sh
# Installs the host service from this directory (inside the panel app bundle). Run as root:
# the panel calls it through sudo with the device password on stdin.
# $1: jailbreak root, /var/jb (Dopamine) or roothide's /var/containers/Bundle/Application/.jbroot-*.
set -e
JB="${1:-/var/jb}"
PATH="$JB/usr/local/bin:$JB/usr/bin:$JB/bin:$JB/usr/sbin:$JB/sbin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }
[ -d "$JB" ] || { echo "jailbreak root not found"; exit 1; }
for f in uuremote-server frida-server frida-agent.dylib com.uuremote.host.plist com.uuremote.frida.plist entitlements.plist; do
    [ -f "$DIR/$f" ] || { echo "missing $f"; exit 1; }
done
LDID="$JB/usr/bin/ldid"
[ -x "$LDID" ] || LDID=$(command -v ldid) || { echo "ldid not found"; exit 1; }

AGENT="$JB/usr/lib/frida-1.0/frida-agent.dylib"
DIRECT_AGENT="$JB/usr/lib/frida-agent.dylib"
direct_action=create
if [ -L "$DIRECT_AGENT" ]; then
    case $(readlink "$DIRECT_AGENT") in
        frida-1.0/frida-agent.dylib|"$AGENT") direct_action=keep ;;
        *)
            if [ -f "$DIRECT_AGENT" ] && cmp -s "$DIRECT_AGENT" "$DIR/frida-agent.dylib"; then
                direct_action=keep
            else
                echo "different Frida agent at alternate path; not overwriting"
                exit 1
            fi ;;
    esac
elif [ -e "$DIRECT_AGENT" ]; then
    if [ -f "$DIRECT_AGENT" ] && [ -f "$AGENT" ] && [ "$DIRECT_AGENT" -ef "$AGENT" ]; then
        direct_action=replace
    elif [ -f "$DIRECT_AGENT" ] && cmp -s "$DIRECT_AGENT" "$DIR/frida-agent.dylib"; then
        direct_action=keep
    elif [ -f "$DIRECT_AGENT" ] && [ -f "$AGENT" ] && cmp -s "$DIRECT_AGENT" "$AGENT"; then
        # Both paths hold the same older agent, i.e. the pair this script installed before.
        # Replacing it is an upgrade, not a clobber of another tool's file.
        direct_action=replace
    else
        echo "different Frida agent at alternate path; not overwriting"
        exit 1
    fi
fi

echo "installing host"
mkdir -p "$JB/usr/local/bin" "$JB/usr/sbin" "$JB/Library/LaunchDaemons" "$JB/var/log"
cp "$DIR/uuremote-server" "$JB/usr/local/bin/uuremote-server.new"
"$LDID" -S"$DIR/entitlements.plist" "$JB/usr/local/bin/uuremote-server.new"
chmod 755 "$JB/usr/local/bin/uuremote-server.new"
# A running binary cannot be overwritten in place.
mv -f "$JB/usr/local/bin/uuremote-server.new" "$JB/usr/local/bin/uuremote-server"

echo "installing Frida agent"
# The official package uses frida-1.0, but Frida 17.25 on iPhone X/roothide looked for
# usr/lib/frida-agent.dylib instead. A hard link serves both without changing its signature.
mkdir -p "$JB/usr/lib/frida-1.0"
cp "$DIR/frida-agent.dylib" "$AGENT.new"
chmod 755 "$AGENT.new"
mv -f "$AGENT.new" "$AGENT"
case "$direct_action" in
    create) ln "$AGENT" "$DIRECT_AGENT" ;;
    replace)
        # Replace only our previous hard link, not another tool's independently installed agent.
        direct_new="$DIRECT_AGENT.uuremote-$$"
        ln "$AGENT" "$direct_new"
        if ! mv -f "$direct_new" "$DIRECT_AGENT"; then
            rm -f "$direct_new"
            exit 1
        fi ;;
esac

echo "installing frida-server"
cp "$DIR/frida-server" "$JB/usr/sbin/frida-server.new"
chmod 755 "$JB/usr/sbin/frida-server.new"
mv -f "$JB/usr/sbin/frida-server.new" "$JB/usr/sbin/frida-server"

# The panel's log page reads these as mobile; they hold no credentials.
touch "$JB/var/log/uuremote.log" "$JB/var/log/frida-server.log"
chmod 644 "$JB/var/log/uuremote.log" "$JB/var/log/frida-server.log"

echo "installing launch daemons"
# The plists name /var/jb; launchd needs the real root on roothide.
for job in com.uuremote.host com.uuremote.frida; do
    sed "s#/var/jb#$JB#g" "$DIR/$job.plist" > "$JB/Library/LaunchDaemons/$job.plist"
    chmod 644 "$JB/Library/LaunchDaemons/$job.plist"
done

for job in com.uuremote.host com.uuremote.frida; do
    launchctl bootout system/$job 2>/dev/null || true
    launchctl bootstrap system "$JB/Library/LaunchDaemons/$job.plist" 2>/dev/null \
        || launchctl load -w "$JB/Library/LaunchDaemons/$job.plist" 2>/dev/null || true
done

# The indicator is optional decoration: never let it block remote control.
if [ -f "$DIR/UUStatusHUD.app/UUStatusHUD" ] && [ -f "$DIR/hud-entitlements.plist" ]; then
    echo "installing indicator"
    sh "$DIR/install-indicator.sh" "$JB" "$DIR" \
        || echo "warning: indicator install failed; the host service is unaffected"
else
    echo "warning: this package has no indicator; skipping"
fi
echo "service installed"
