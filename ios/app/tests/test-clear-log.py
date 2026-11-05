#!/usr/bin/env python3
"""Isolated clear-log checks: fake root identity, temporary logs, no sudo or real services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "install/clear-log.sh"


class ClearLogTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="uu-clear-log-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "usr/bin").mkdir(parents=True)
        identity = self.root / "usr/bin/id"
        identity.write_text('#!/bin/sh\nprintf "%s\\n" "${CHECK_UID:-0}"\n')
        identity.chmod(0o755)
        logs = self.root / "var/log"
        logs.mkdir(parents=True)
        self.host = logs / "uuremote.log"
        self.frida = logs / "frida-server.log"
        for log in (self.host, self.frida):
            log.write_text("synthetic log\n")
            log.chmod(0o644)

    def run_script(self, source, **env):
        return subprocess.run(["/bin/sh", str(SCRIPT), str(self.root), source],
                              env={**os.environ, "PATH": "/usr/bin:/bin", **env},
                              capture_output=True, text=True, timeout=10)

    def test_host_truncates_in_place_and_writer_can_continue(self):
        inode = self.host.stat().st_ino
        with self.host.open("a") as writer:
            result = self.run_script("host")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.host.read_text(), "")
            writer.write("new log\n")
        self.assertEqual(self.host.read_text(), "new log\n")
        self.assertEqual(self.host.stat().st_ino, inode)
        self.assertEqual(self.host.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.frida.read_text(), "synthetic log\n")

    def test_frida_only(self):
        self.assertEqual(self.run_script("frida").returncode, 0)
        self.assertEqual(self.frida.read_text(), "")
        self.assertEqual(self.host.read_text(), "synthetic log\n")

    def test_rejects_arbitrary_selection(self):
        self.assertNotEqual(self.run_script("../config.json").returncode, 0)
        self.assertEqual(self.host.read_text(), "synthetic log\n")

    def test_rejects_non_root(self):
        self.assertNotEqual(self.run_script("host", CHECK_UID="501").returncode, 0)
        self.assertEqual(self.host.read_text(), "synthetic log\n")

    def test_rejects_symlink(self):
        self.host.unlink()
        self.host.symlink_to(self.frida)
        self.assertNotEqual(self.run_script("host").returncode, 0)
        self.assertEqual(self.frida.read_text(), "synthetic log\n")

    def test_absent_is_already_clear(self):
        self.host.unlink()
        self.assertEqual(self.run_script("host").returncode, 0)
        self.assertFalse(self.host.exists())


if __name__ == "__main__":
    unittest.main()
