#!/usr/bin/env python3
"""Check device families and home-screen icons in a built panel IPA."""

import plistlib
import struct
import sys
import unittest
import zipfile
from pathlib import Path


if len(sys.argv) != 2:
    raise SystemExit("usage: test-panel-package.py UURemotePanel.ipa")
IPA = Path(sys.argv.pop())
PREFIX = "Payload/UURemotePanel.app/"


class PanelPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.package = zipfile.ZipFile(IPA)
        cls.info = plistlib.loads(cls.package.read(PREFIX + "Info.plist"))

    @classmethod
    def tearDownClass(cls):
        cls.package.close()

    def test_device_families_include_phone_and_tablet(self):
        self.assertEqual(set(self.info["UIDeviceFamily"]), {1, 2})

    def test_phone_icon_declaration(self):
        icon = self.info["CFBundleIcons"]["CFBundlePrimaryIcon"]
        self.assertIn("AppIcon60x60", icon["CFBundleIconFiles"])

    def test_ipad_icon_declaration(self):
        icon = self.info["CFBundleIcons~ipad"]["CFBundlePrimaryIcon"]
        self.assertEqual(set(icon["CFBundleIconFiles"]), {"AppIcon76x76", "AppIcon83.5x83.5"})

    def test_carries_the_complete_service(self):
        for name in ("uuremote-server", "frida-server", "frida-agent.dylib",
                     "install-service.sh", "uninstall-service.sh", "restart-service.sh",
                     "diagnose-service.sh", "clear-log.sh", "com.uuremote.host.plist",
                     "com.uuremote.frida.plist"):
            with self.subTest(file=name):
                self.assertGreater(self.package.getinfo(PREFIX + "service/" + name).file_size, 0)

    def test_carries_the_indicator_daemon(self):
        for name in ("service/UUStatusHUD.app/UUStatusHUD",
                     "service/UUStatusHUD.app/Info.plist",
                     "service/hud-entitlements.plist",
                     "service/com.uuremote.indicator.plist",
                     "service/install-indicator.sh",
                     "service/uninstall-indicator.sh"):
            with self.subTest(file=name):
                self.assertGreater(self.package.getinfo(PREFIX + name).file_size, 0)
        entitlements = self.package.read(PREFIX + "service/hud-entitlements.plist")
        self.assertIn(b"accessibility-window-hosting", entitlements)
        hud = self.package.read(PREFIX + "service/UUStatusHUD.app/Info.plist")
        self.assertIn(b"UUStatusHUD", hud)

    def test_host_version_matches_the_panel(self):
        host = self.package.read(PREFIX + "service/uuremote-server")
        self.assertIn(self.info["CFBundleShortVersionString"].encode(), host)

    def test_icon_files_and_sizes(self):
        for name, size in (("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180),
                           ("AppIcon76x76@2x~ipad.png", 152), ("AppIcon83.5x83.5@2x~ipad.png", 167)):
            with self.subTest(icon=name):
                data = self.package.read(PREFIX + name)
                self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                self.assertEqual(struct.unpack(">II", data[16:24]), (size, size))


if __name__ == "__main__":
    unittest.main()
