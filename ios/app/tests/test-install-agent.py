#!/usr/bin/env python3
"""Exercise Frida agent installation with isolated files and stubbed system tools."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALL = Path(__file__).resolve().parents[2] / "install"


class InstallAgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uu-agent-install-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.service = self.root / "service"
        self.service.mkdir()
        for name in ("install-service.sh", "com.uuremote.host.plist", "com.uuremote.frida.plist", "entitlements.plist"):
            (self.service / name).write_bytes((INSTALL / name).read_bytes())
        for name in ("uuremote-server", "frida-server", "frida-agent.dylib"):
            (self.service / name).write_bytes((name + " v1\n").encode())
        self.jb = self.root / "var/containers/Bundle/Application/.jbroot-test"
        tools = self.jb / "usr/bin"
        tools.mkdir(parents=True)
        for name, body in (("id", 'printf "0\\n"'), ("ldid", "exit 0"), ("launchctl", "exit 0"),
                           ("ps", 'printf "frida-server\\n"')):
            tool = tools / name
            tool.write_text(f"#!/bin/sh\n{body}\n")
            tool.chmod(0o755)
        self.agent = self.jb / "usr/lib/frida-1.0/frida-agent.dylib"
        self.direct = self.jb / "usr/lib/frida-agent.dylib"

    def run_install(self):
        return subprocess.run(["/bin/sh", str(self.service / "install-service.sh"), str(self.jb)],
                              env={**os.environ, "PATH": "/usr/bin:/bin"},
                              capture_output=True, text=True, timeout=15)

    def test_fresh_install_has_both_agent_paths(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.agent.read_bytes(), (self.service / "frida-agent.dylib").read_bytes())
        self.assertTrue(os.path.samefile(self.agent, self.direct))
        self.assertEqual(self.direct.stat().st_mode & 0o777, 0o755)

    def test_upgrade_refreshes_a_managed_hard_link(self):
        self.assertEqual(self.run_install().returncode, 0)
        (self.service / "frida-agent.dylib").write_bytes(b"agent v2\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(os.path.samefile(self.agent, self.direct))
        self.assertEqual(self.direct.read_bytes(), b"agent v2\n")

    def test_upgrade_preserves_direct_symlink_to_standard_agent(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(b"old agent\n")
        self.direct.symlink_to("frida-1.0/frida-agent.dylib")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.direct.is_symlink())
        self.assertEqual(self.direct.read_bytes(), (self.service / "frida-agent.dylib").read_bytes())

    def test_different_existing_agent_is_not_overwritten(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(b"previous standard agent\n")
        self.direct.write_bytes(b"unrelated agent\n")
        host = self.jb / "usr/local/bin/uuremote-server"
        host.parent.mkdir(parents=True)
        host.write_bytes(b"previous host\n")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.direct.read_bytes(), b"unrelated agent\n")
        self.assertEqual(self.agent.read_bytes(), b"previous standard agent\n")
        self.assertEqual(host.read_bytes(), b"previous host\n")
        self.assertNotIn("service installed", result.stdout)

    def test_upgrade_replaces_a_consistent_older_pair(self):
        # Both paths hold the same older agent: that is the pair a previous install created,
        # so a newer bundle upgrades it instead of refusing.
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(b"old agent\n")
        self.direct.write_bytes(b"old agent\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        expected = (self.service / "frida-agent.dylib").read_bytes()
        self.assertEqual(self.agent.read_bytes(), expected)
        self.assertEqual(self.direct.read_bytes(), expected)
        self.assertTrue(os.path.samefile(self.agent, self.direct))

    def test_identical_unmanaged_agent_is_left_untouched(self):
        self.direct.parent.mkdir(parents=True)
        self.direct.write_bytes((self.service / "frida-agent.dylib").read_bytes())
        inode = self.direct.stat().st_ino
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.direct.stat().st_ino, inode)
        self.assertEqual(self.direct.read_bytes(), self.agent.read_bytes())

    def test_dangling_unrelated_symlink_is_preserved(self):
        self.direct.parent.mkdir(parents=True)
        self.direct.symlink_to("elsewhere.dylib")
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.direct.is_symlink())
        self.assertEqual(os.readlink(self.direct), "elsewhere.dylib")
        self.assertFalse((self.jb / "usr/local/bin/uuremote-server").exists())

    def test_diagnostics_report_both_agent_paths(self):
        self.assertEqual(self.run_install().returncode, 0)

        def diagnostic():
            return subprocess.run(["/bin/sh", str(INSTALL / "diagnose-service.sh"), str(self.jb)],
                                  env={**os.environ, "PATH": "/usr/bin:/bin"},
                                  capture_output=True, text=True, timeout=10)

        both = diagnostic()
        self.assertEqual(both.returncode, 0)
        self.assertIn("frida-agent present=yes", both.stdout)
        self.assertIn("frida-agent-direct present=yes", both.stdout)
        self.direct.unlink()
        missing = diagnostic()
        self.assertEqual(missing.returncode, 0)
        self.assertIn("frida-agent present=yes", missing.stdout)
        self.assertIn("frida-agent-direct present=no", missing.stdout)


if __name__ == "__main__":
    unittest.main()
