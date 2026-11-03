#!/usr/bin/env python3
"""编译隔离的 UIKit 检查程序；不运行安装器、不访问真实状态或凭据。"""

import argparse
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


def run(*args):
    subprocess.run(args, check=True, timeout=60)


root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--language", choices=["zh", "en"], default="zh")
parser.add_argument("--run", action="store_true", help="运行隔离检查，最多60秒")
args = parser.parse_args()
work = Path(tempfile.mkdtemp(prefix="uu-panel-check-"))
fixtures = work / "fixtures"
fixtures.mkdir()
review = root / ".impeccable/review"
review.mkdir(parents=True, exist_ok=True)
source = (root / "ios/app/main.m").read_text()
# 只替换路径常量，不给发布代码加入测试分支。
source, count = re.subn(
    r'(static NSString \*const (k\w+(?:Path|Dir)) = )@"[^"]+";',
    lambda m: f'{m[1]}@"{fixtures / m[2]}";',
    source,
)
assert count == 9, "路径常量数量变化，请先审查隔离范围"
# 语言固定只存在于测试副本，发布代码仍跟随系统语言。
source = source.replace('[[NSLocale preferredLanguages].firstObject hasPrefix:@"zh"]',
                        "YES" if args.language == "zh" else "NO")
(work / "PanelUnderTest.m").write_text(source)
sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
run("xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64",
    "-miphoneos-version-min=15.0", "-fobjc-arc", "-Wall", "-Wextra",
    "-Wno-unused-parameter", "-Werror", "-isysroot", sdk,
    "-framework", "UIKit", "-framework", "Foundation", "-framework", "QuartzCore",
    "-o", str(work / "UURemotePanel"), str(root / "ios/app/main.m"))
app = work / "PanelNativeCheck.app"
binary = app / "Contents/MacOS/PanelNativeCheck"
binary.parent.mkdir(parents=True)
info = {
    "CFBundleExecutable": binary.name,
    "CFBundleIdentifier": "local.uuremote.panel-native-check",
    "CFBundleName": "PanelNativeCheck",
    "CFBundlePackageType": "APPL",
    "UIDeviceFamily": [2],
    "LSRequiresIPhoneOS": True,
    "NSHighResolutionCapable": True,
}
with (app / "Contents/Info.plist").open("wb") as f:
    plistlib.dump(info, f)
macsdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
frameworks = f"{macsdk}/System/iOSSupport/System/Library/Frameworks"
run("xcrun", "clang", "-target", "arm64-apple-ios15.0-macabi", "-isysroot", macsdk,
    "-iframework", frameworks, "-F", frameworks, "-I", str(work), "-fobjc-arc",
    "-framework", "UIKit", "-framework", "Foundation", "-framework", "QuartzCore",
    "-framework", "CoreGraphics", f'-DUU_REVIEW_DIR=@"{review}"',
    f'-DUU_TEST_SUFFIX=@"{"-en" if args.language == "en" else ""}"',
    "-o", str(binary), str(root / "ios/app/tests/panel-native-check.m"))
(review / "native-check-app.txt").write_text(str(app))
print(f"iOS 15 arm64 编译链接通过；隔离测试程序：{app}")
if args.run:
    log = review / f"native-check{'-en' if args.language == 'en' else ''}.log"
    with log.open("w") as output:
        subprocess.run([str(binary)], check=True, timeout=60, stdout=output, stderr=subprocess.STDOUT)
    print("隔离检查通过；结果写入 .impeccable/review/native-check-results*.json")
else:
    print("用本机应用启动工具打开此测试程序；结果写入 .impeccable/review/native-check-results*.json")
