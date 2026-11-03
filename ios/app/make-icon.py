#!/usr/bin/env python3
"""Builds the panel's home-screen icons from the locally installed official UU Remote Mac app.

No NetEase artwork is stored in this repository (AGENTS.md): the icon is derived at build time from
/Applications/UURemote.app, with its white tile turned black. Usage: make-icon.py OUT_APP_DIR
"""
import os, subprocess, sys, tempfile
from PIL import Image

SOURCE = "/Applications/UURemote.app/Contents/Resources/AppIcon.icns"
# (file name, edge in pixels) for CFBundleIcons~ipad; iOS masks the corners itself.
OUTPUTS = [("AppIcon76x76@2x~ipad.png", 152), ("AppIcon83.5x83.5@2x~ipad.png", 167)]


def largest_png(iconset):
    files = [os.path.join(iconset, f) for f in os.listdir(iconset) if f.endswith(".png")]
    return max(files, key=lambda f: Image.open(f).size[0])


def on_black(tile):
    """The macOS tile is a logo blended over white. Re-blend it over black: estimate each pixel's
    logo coverage from its distance to white, then drop the white share (keeps edges clean)."""
    out = Image.new("RGB", tile.size, (0, 0, 0))
    src, dst = tile.load(), out.load()
    for y in range(tile.size[1]):
        for x in range(tile.size[0]):
            r, g, b, a = src[x, y]
            if a < 250:
                continue  # rounded corners and shadow: plain black
            coverage = min(1.0, max(255 - r, 255 - g, 255 - b) / 110.0)
            white = (1.0 - coverage) * 255
            dst[x, y] = tuple(max(0, min(255, round(c - white))) for c in (r, g, b))
    return out


def main(out_dir):
    if not os.path.exists(SOURCE):
        print("make-icon: official UU Remote app not installed; building without an icon")
        return
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        subprocess.run(["iconutil", "-c", "iconset", SOURCE, "-o", iconset], check=True, capture_output=True)
        image = Image.open(largest_png(iconset)).convert("RGBA")
    # Crop to the opaque tile; the macOS template pads it with transparency and a drop shadow.
    alpha = image.getchannel("A").point(lambda v: 255 if v >= 250 else 0)
    tile = image.crop(alpha.getbbox())
    edge = max(tile.size)
    square = Image.new("RGBA", (edge, edge), (0, 0, 0, 0))
    square.paste(tile, ((edge - tile.size[0]) // 2, (edge - tile.size[1]) // 2))
    black = on_black(square)
    for name, size in OUTPUTS:
        black.resize((size, size), Image.LANCZOS).save(os.path.join(out_dir, name))
    print(f"make-icon: wrote {len(OUTPUTS)} icons from {os.path.basename(SOURCE)}")


if __name__ == "__main__":
    main(sys.argv[1])
