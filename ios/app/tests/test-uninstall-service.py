#!/usr/bin/env python3
"""Run the real uninstall script with isolated paths and a fake launchctl; never use sudo."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "install/uninstall-service.sh"


class UninstallServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uu-uninstall-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "jobs"
        self.state.mkdir()
        self.env = {**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin",
                    "CHECK_STATE": str(self.state), "CHECK_UID": "0"}
        self.command("id", '#!/bin/sh\nprintf "%s\\n" "$CHECK_UID"\n')
        self.command("launchctl", """#!/bin/sh
job=${2#system/}
[ "$1" != unload ] || job=$(basename "$2" .plist)
printf '%s %s\n' "$1" "$job" >> "$CHECK_STATE/calls"
case "$1" in
    print) [ -f "$CHECK_STATE/$job" ] ;;
    bootout|unload)
        [ -f "$CHECK_STATE/$job" ] || exit 1
        [ "$CHECK_FAIL_JOB" != "$job" ] || exit 1
        [ "$1" != bootout ] || [ "$CHECK_LEGACY" != 1 ] || exit 1
        [ "$CHECK_STILL_LOADED" = 1 ] || rm "$CHECK_STATE/$job"
        ;;
    *) exit 1 ;;
esac
""")
        self.removed = [
            "/var/jb/Library/LaunchDaemons/com.uuremote.host.plist",
            "/var/jb/Library/LaunchDaemons/com.uuremote.frida.plist",
            "/var/jb/usr/local/bin/uuremote-server",
            "/var/jb/usr/local/bin/uuremote-server.new",
            "/private/var/tmp/uu-status.txt", "/private/var/tmp/uu-status.json",
            "/private/var/tmp/uu-qr.png", "/private/var/tmp/uu-unlock.txt",
            "/var/mobile/Library/UURemote/command",
        ]
        self.kept = [
            "/var/jb/usr/sbin/frida-server",
            "/var/jb/Library/LaunchDaemons/re.frida.server.plist",
            "/var/root/.config/uuremote/config.json",
            "/var/mobile/Library/UURemote/unlock.key",
            "/var/mobile/Library/UURemote/settings.json",
            "/private/var/tmp/uu-history.jsonl",
            "/var/jb/var/log/uuremote.log",
        ]
        for path in self.removed + self.kept:
            target = self.path(path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("synthetic fixture\n")
        for job in ("com.uuremote.host", "com.uuremote.frida", "re.frida.server"):
            (self.state / job).touch()
        # Only the test copy has redirected paths; the shipping script has no root/path override.
        source = SOURCE.read_text()
        for prefix in ("/var/jb", "/private/var/tmp", "/var/mobile"):
            source = source.replace(prefix, str(self.root) + prefix)
        self.script = self.root / "uninstall-service.sh"
        self.script.write_text(source)

    def path(self, path):
        return self.root / path.lstrip("/")

    def command(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_script(self, **env):
        return subprocess.run(["/bin/sh", str(self.script)], env={**self.env, **env},
                              capture_output=True, text=True, timeout=10)

    def assert_preserved(self):
        for path in self.kept:
            self.assertEqual(self.path(path).read_text(), "synthetic fixture\n", path)
        self.assertTrue((self.state / "re.frida.server").exists())

    def test_uninstall_and_repeat(self):
        for _ in range(2):
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path in self.removed:
                self.assertFalse(self.path(path).exists(), path)
            self.assertFalse((self.state / "com.uuremote.host").exists())
            self.assertFalse((self.state / "com.uuremote.frida").exists())
            self.assert_preserved()
        calls = (self.state / "calls").read_text()
        self.assertLess(calls.index("bootout com.uuremote.host"), calls.index("bootout com.uuremote.frida"))
        self.assertNotIn("re.frida.server", calls)

    def test_legacy_unload(self):
        result = self.run_script(CHECK_LEGACY="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.state / "calls").read_text()
        self.assertIn("unload com.uuremote.host", calls)
        self.assertIn("unload com.uuremote.frida", calls)
        self.assert_preserved()

    def test_stop_failure_preserves_files_and_can_retry(self):
        for job in ("com.uuremote.host", "com.uuremote.frida"):
            with self.subTest(job=job):
                result = self.run_script(CHECK_FAIL_JOB=job)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("service uninstalled", result.stdout)
                for path in self.removed:
                    self.assertTrue(self.path(path).exists(), path)
                self.assert_preserved()
        self.assertEqual(self.run_script().returncode, 0)

    def test_loaded_job_is_not_reported_as_removed(self):
        result = self.run_script(CHECK_STILL_LOADED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still loaded", result.stdout)
        for path in self.removed:
            self.assertTrue(self.path(path).exists(), path)
        self.assert_preserved()

    def test_non_root_does_not_stop_or_remove_anything(self):
        result = self.run_script(CHECK_UID="501")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / "calls").exists())
        for path in self.removed:
            self.assertTrue(self.path(path).exists(), path)
        self.assert_preserved()

    def test_remove_failure_is_not_success(self):
        target = self.path("/var/jb/usr/local/bin/uuremote-server")
        target.unlink()
        target.mkdir()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("service uninstalled", result.stdout)
        self.assert_preserved()


if __name__ == "__main__":
    unittest.main()
