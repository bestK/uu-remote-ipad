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

    def run_script(self, *args, **env):
        return subprocess.run(["/bin/sh", str(self.script), *args], env={**self.env, **env},
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

    def test_roothide_root_argument(self):
        # The panel passes roothide's randomized root as $1; /var/jb does not exist there.
        jb = self.path("/var/jb")
        jbroot = self.path("/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF")
        jbroot.parent.mkdir(parents=True)
        jb.rename(jbroot)
        result = self.run_script(str(jbroot))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in self.removed:
            moved = jbroot / path[len("/var/jb/"):] if path.startswith("/var/jb/") else self.path(path)
            self.assertFalse(moved.exists(), path)
        self.assertEqual((jbroot / "usr/sbin/frida-server").read_text(), "synthetic fixture\n")
        self.assertEqual((jbroot / "var/log/uuremote.log").read_text(), "synthetic fixture\n")


class InstallServiceTests(unittest.TestCase):
    """Run the real install script against a roothide-style root with fake ldid/launchctl/id."""

    def test_roothide_install_rewrites_plists(self):
        with tempfile.TemporaryDirectory(prefix="uu-install-check-") as temp:
            temp = Path(temp)
            service = temp / "service"
            service.mkdir()
            source = SOURCE.parent
            for name in ("install-service.sh", "com.uuremote.host.plist", "com.uuremote.frida.plist", "entitlements.plist"):
                (service / name).write_bytes((source / name).read_bytes())
            for name in ("uuremote-server", "frida-server", "frida-agent.dylib"):
                (service / name).write_text("synthetic binary\n")
            jbroot = temp / "var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
            bin_dir = jbroot / "usr/bin"
            bin_dir.mkdir(parents=True)
            for name, body in (("id", 'printf "0\\n"'), ("ldid", "exit 0"),
                               ("launchctl", f'printf "%s\\n" "$*" >> "{temp}/calls"')):
                (bin_dir / name).write_text(f"#!/bin/sh\n{body}\n")
                (bin_dir / name).chmod(0o755)
            result = subprocess.run(["/bin/sh", str(service / "install-service.sh"), str(jbroot)],
                                    env={**os.environ, "PATH": "/usr/bin:/bin"},
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("service installed", result.stdout)
            self.assertTrue((jbroot / "usr/local/bin/uuremote-server").is_file())
            self.assertTrue((jbroot / "usr/sbin/frida-server").is_file())
            agent = jbroot / "usr/lib/frida-1.0/frida-agent.dylib"
            self.assertEqual(agent.read_text(), "synthetic binary\n")
            self.assertEqual(agent.stat().st_mode & 0o777, 0o755)
            self.assertFalse(agent.with_suffix(".dylib.new").exists())
            # Refuse an incomplete bundle before touching an existing installation.
            (service / "frida-agent.dylib").unlink()
            (service / "uuremote-server").write_text("should not install\n")
            missing = subprocess.run(["/bin/sh", str(service / "install-service.sh"), str(jbroot)],
                                     env={**os.environ, "PATH": "/usr/bin:/bin"},
                                     capture_output=True, text=True, timeout=10)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("missing frida-agent.dylib", missing.stdout)
            self.assertEqual((jbroot / "usr/local/bin/uuremote-server").read_text(), "synthetic binary\n")
            self.assertEqual(agent.read_text(), "synthetic binary\n")
            for job in ("com.uuremote.host", "com.uuremote.frida"):
                plist = (jbroot / f"Library/LaunchDaemons/{job}.plist").read_text()
                self.assertNotIn("/var/jb", plist)
                self.assertIn(str(jbroot), plist)
            self.assertIn(f"bootstrap system {jbroot}/Library/LaunchDaemons/com.uuremote.host.plist",
                          (temp / "calls").read_text())


class RestartServiceTests(unittest.TestCase):
    """Run the real restart script against a roothide-style root with fake launchctl/id."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="uu-restart-check-")
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.jbroot = self.temp / "var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
        bin_dir = self.jbroot / "usr/bin"
        bin_dir.mkdir(parents=True)
        (self.jbroot / "Library/LaunchDaemons").mkdir(parents=True)
        (self.jbroot / "var/log").mkdir(parents=True)
        for job in ("com.uuremote.host", "com.uuremote.frida"):
            (self.jbroot / f"Library/LaunchDaemons/{job}.plist").write_text("synthetic\n")
        self.log = self.jbroot / "var/log/uuremote.log"
        self.log.write_text("synthetic\n")
        self.log.chmod(0o600)
        self.calls = self.temp / "calls"
        launchctl = f"""printf '%s\\n' "$*" >> "{self.calls}"
case "$1" in
    print) exit 0 ;;
    kickstart) [ "$CHECK_NO_KICKSTART" != 1 ] ;;
    bootout|bootstrap) exit 0 ;;
    *) exit 1 ;;
esac"""
        for name, body in (("id", 'printf "0\\n"'), ("launchctl", launchctl)):
            (bin_dir / name).write_text(f"#!/bin/sh\n{body}\n")
            (bin_dir / name).chmod(0o755)

    def run_script(self, **env):
        return subprocess.run(["/bin/sh", str(SOURCE.parent / "restart-service.sh"), str(self.jbroot)],
                              env={**os.environ, "PATH": "/usr/bin:/bin", **env},
                              capture_output=True, text=True, timeout=10)

    def test_restarts_frida_then_host_and_opens_logs(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("service restarted", result.stdout)
        calls = self.calls.read_text()
        self.assertLess(calls.index("kickstart -k system/com.uuremote.frida"),
                        calls.index("kickstart -k system/com.uuremote.host"))
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o644)

    def test_without_kickstart_reloads(self):
        result = self.run_script(CHECK_NO_KICKSTART="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"bootstrap system {self.jbroot}/Library/LaunchDaemons/com.uuremote.host.plist",
                      self.calls.read_text())

    def test_not_installed_fails(self):
        (self.jbroot / "Library/LaunchDaemons/com.uuremote.host.plist").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not installed: com.uuremote.host", result.stdout)


if __name__ == "__main__":
    unittest.main()
