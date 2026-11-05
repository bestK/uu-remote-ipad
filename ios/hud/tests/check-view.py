#!/usr/bin/env python3
"""Render isolated indicator states with UIKit/Mac Catalyst, not an iOS device."""

import plistlib
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
hud = root / "ios/hud"
review = root / ".impeccable/review"
review.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="uu-indicator-view-") as tmp:
    app = Path(tmp) / "IndicatorCheck.app"
    binary = app / "Contents/MacOS/IndicatorCheck"
    binary.parent.mkdir(parents=True)
    info = {
        "CFBundleExecutable": binary.name,
        "CFBundleIdentifier": "local.uuremote.indicator-check",
        "CFBundleName": "IndicatorCheck",
        "CFBundlePackageType": "APPL",
        "UIDeviceFamily": [1, 2],
        "LSRequiresIPhoneOS": True,
        "NSHighResolutionCapable": True,
    }
    with (app / "Contents/Info.plist").open("wb") as f:
        plistlib.dump(info, f)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    frameworks = f"{sdk}/System/iOSSupport/System/Library/Frameworks"
    subprocess.run(["xcrun", "clang", "-target", "arm64-apple-ios15.0-macabi", "-isysroot", sdk,
                    "-iframework", frameworks, "-F", frameworks, "-I", str(hud), "-fobjc-arc",
                    "-Wall", "-Wextra", "-Werror", "-framework", "UIKit", "-framework", "Foundation",
                    "-framework", "QuartzCore", "-framework", "CoreGraphics",
                    f'-DUU_INDICATOR_REVIEW_DIR="{review}"', "-o", str(binary),
                    str(hud / "indicator_view.m"), str(hud / "tests/indicator-view-check.m")],
                   check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=60)
print(f"synthetic screenshots: {review}")
