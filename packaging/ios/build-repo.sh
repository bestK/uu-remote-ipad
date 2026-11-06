#!/bin/sh
# Builds an APT repository (Sileo / Zebra) for GitHub Pages from a built panel app.
# Usage: build-repo.sh PANEL_APP_DIR VERSION OUT_DIR
#   PANEL_APP_DIR  the signed UURemotePanel.app produced by ios/app/build.sh
#   VERSION        package version, e.g. 0.2.0 (the ipad-v prefix is added by the caller)
#   OUT_DIR        repository root; created fresh
set -eu
APP_SRC=$1
VERSION=$2
OUT=$3
PKG=com.uuremote.ipad
ARCH=iphoneos-arm64
[ -d "$APP_SRC" ] || { echo "missing $APP_SRC" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "$OUT already exists" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/uu-ios-repo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/debs" "$WORK/pkg/DEBIAN" "$WORK/pkg/var/jb/Applications"

# The package carries the whole panel bundle, whose service/ directory already holds the host,
# Frida, the indicator and the installer scripts. postinst runs that installer so the deb and the
# IPA take exactly the same path on the device.
cp -R "$APP_SRC" "$WORK/pkg/var/jb/Applications/UURemotePanel.app"
chmod 755 "$WORK/pkg/var/jb/Applications/UURemotePanel.app/UURemotePanel"
chmod 755 "$WORK/pkg/var/jb/Applications/UURemotePanel.app/service/"*.sh

cat > "$WORK/pkg/DEBIAN/control" <<CONTROL
Package: $PKG
Name: UU Remote iPad host
Version: $VERSION
Architecture: $ARCH
Section: Tweaks
Priority: optional
Depends: firmware (>= 15.0)
Maintainer: bestK
Description: Unofficial host for NetEase UU Remote on a jailbroken iPad
 Runs the host service, the Frida jobs and an optional status-bar indicator.
 Install from Sileo or Zebra; the panel installs the services on first launch.
CONTROL

cat > "$WORK/pkg/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
JB=/var/jb
[ -d "$JB" ] || JB=/
APP="$JB/Applications/UURemotePanel.app"
chmod 755 "$APP/UURemotePanel" "$APP"/service/*.sh 2>/dev/null || true
# Never fail the dpkg transaction: a service problem must not roll back the panel install.
sh "$APP/service/install-service.sh" "$JB" || echo "warning: service install failed; open the panel and retry"
exit 0
POSTINST

cat > "$WORK/pkg/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
JB=/var/jb
[ -d "$JB" ] || JB=/
APP="$JB/Applications/UURemotePanel.app"
[ -x "$APP/service/uninstall-service.sh" ] && sh "$APP/service/uninstall-service.sh" "$JB" || true
exit 0
PRERM
chmod 755 "$WORK/pkg/DEBIAN/postinst" "$WORK/pkg/DEBIAN/prerm"

DEB="$OUT/debs/${PKG}_${VERSION}_${ARCH}.deb"
printf '2.0\n' > "$WORK/debian-binary"
(cd "$WORK/pkg/DEBIAN" && tar --format=ustar --owner=0 --group=0 -czf "$WORK/control.tar.gz" ./control ./postinst ./prerm)
(cd "$WORK/pkg" && tar --format=ustar --owner=0 --group=0 -czf "$WORK/data.tar.gz" ./var)
# Written directly: Apple's ar has no -D and may add a symbol table, which dpkg rejects.
python3 - "$DEB" "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.gz" <<'AR'
import sys
out, members = sys.argv[1], sys.argv[2:]
with open(out, 'wb') as f:
    f.write(b'!<arch>\n')
    for path in members:
        data = open(path, 'rb').read()
        name = path.rsplit('/', 1)[-1][:16].ljust(16).encode()
        f.write(name + b'0'.ljust(12) + b'0'.ljust(6) + b'0'.ljust(6)
                + b'100644'.ljust(8) + str(len(data)).ljust(10).encode() + b'`\n')
        f.write(data)
        if len(data) % 2:
            f.write(b'\n')
AR

SIZE=$(wc -c < "$DEB" | tr -d ' ')
SHA=$(shasum -a 256 "$DEB" | cut -d' ' -f1)
FIELDS=$(cat "$WORK/pkg/DEBIAN/control")
mkdir -p "$OUT/debs"
{
    printf '%s\n' "$FIELDS"
    printf 'Filename: debs/%s\n' "$(basename "$DEB")"
    printf 'Size: %s\n' "$SIZE"
    printf 'SHA256: %s\n\n' "$SHA"
} > "$OUT/Packages"
gzip -9 -c "$OUT/Packages" > "$OUT/Packages.gz"

cat > "$OUT/Release" <<RELEASE
Origin: uu-remote-ipad
Label: UU Remote iPad
Suite: stable
Version: 1.0
Codename: ios
Architectures: $ARCH
Components: main
Description: Unofficial UU Remote host for jailbroken iPad
RELEASE
for list in Packages Packages.gz; do
    printf 'MD5Sum:\n %s %s %s\n' "$(md5 -q "$OUT/$list" 2>/dev/null || md5sum "$OUT/$list" | cut -d' ' -f1)" \
        "$(wc -c < "$OUT/$list" | tr -d ' ')" "$list" >> "$OUT/Release"
done

cat > "$OUT/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UU 远程 iPad 源</title>
<style>
 body{margin:0;padding:48px 24px;background:#0b0c0e;color:#e8eaed;font:16px/1.6 -apple-system,system-ui,sans-serif}
 main{max-width:640px;margin:0 auto}
 h1{font-size:24px;margin:0 0 8px}
 p{color:#a8adb5;margin:0 0 16px}
 code{display:block;padding:14px 16px;background:#16181c;border-radius:12px;color:#7ee0c0;word-break:break-all}
 a{color:#7ee0c0;overflow-wrap:anywhere}
 .qr{display:block;width:222px;max-width:100%;height:auto;margin:16px 0}
 .note{font-size:13px;color:#6f757e;margin-top:28px}
</style>
<main>
 <h1>UU 远程 iPad 源</h1>
 <p>在 Sileo 或 Zebra 里添加下面的源地址：</p>
 <code>https://bestk.github.io/uu-remote-ipad/</code>
 <p style="margin-top:24px">最新版本 / Latest version：<strong>$VERSION</strong></p>
 <p>扫码打开本页面 / Scan to open this page</p>
 <img class="qr" width="222" height="222" alt="本页面二维码 / QR code for this page" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAN4AAADeAQAAAAB6HIMaAAABR0lEQVR42u2Y0W3EMAxDhXoAj5TVPZIHEKCKpC/Xn/a3PCCGccjFP4TCPFGJ+n1lPIfPoe9hYF0xa/B6bPzv6/yKP9Z/HEJtC6t9De7S5k1TtTuoMzJacLTaLrW52lErdecT1ObkRS13tfRtztUik7V19q2YMPa9rZmgJQ/kjzu2vqXI1YK7yHKFbW37/QrIW3jRSIbh7dsmLf607IPcKF/f0gOzq3ps4MwEskvWhStSsm3VyqjoEXF4u51TzRJj27etE2+csdrz9AkEhkZkBlsndEnFW/VcAc2XCXzuVPhGrncvQ0J4A21fxrVlAIMfkBXVfJ0JpnamrUhW3hnszrpnlrTPt8V5BwY2ZoJmh7v5vvhgP5cJthHOTJBa1JZkCP6az7wgGHLCpaZmPvPi68c8w04a+/YwgUlMGayMU83z6fI5/LTDb+ADFoUT9xrHAAAAAElFTkSuQmCC">
 <p>开源地址 / Source code：<a href="https://github.com/bestK/uu-remote-ipad">github.com/bestK/uu-remote-ipad</a></p>
 <p class="note">非官方项目，与网易无关。仅用于越狱设备。<br>Unofficial project, not affiliated with NetEase. For jailbroken devices only.</p>
</main>
HTML

printf 'built %s\n' "$DEB"
printf 'repo %s (Packages %s bytes)\n' "$OUT" "$(wc -c < "$OUT/Packages" | tr -d ' ')"
