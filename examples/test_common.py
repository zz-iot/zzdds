"""Shared harness helpers (python -m unittest discover -s examples -p test_common.py)."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import _common
from _common import LiveProcess, executable_path


class ExecutablePathTests(unittest.TestCase):
    def test_platform_and_generator_layouts(self):
        for platform in ("win32", "linux", "darwin"):
            for directory in ("", "Debug"):
                with self.subTest(platform=platform, directory=directory):
                    with tempfile.TemporaryDirectory() as tmp, patch("_common.sys.platform", platform):
                        root = Path(tmp)
                        name = "sample.exe" if platform == "win32" else "sample"
                        binary = root / directory / name
                        binary.parent.mkdir(exist_ok=True)
                        binary.touch()
                        self.assertEqual(executable_path(root / "sample"), binary)

    def test_missing_debug_does_not_select_another_configuration(self):
        with tempfile.TemporaryDirectory() as tmp, patch("_common.sys.platform", "win32"):
            root = Path(tmp)
            (root / "Release").mkdir()
            (root / "Release" / "sample.exe").touch()
            self.assertEqual(executable_path(root / "sample"), root / "sample.exe")


SLEEPER = [sys.executable, "-c", "import time; time.sleep(60)"]


class StuckStackTests(unittest.TestCase):
    """stop() dumps stacks only for a process the caller expected to have exited."""

    def run_case(self, *, enabled: bool, waited: bool) -> int:
        env = {_common.STUCK_STACKS_ENV: "1"} if enabled else {}
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, env, clear=False), \
                patch("_common.dump_stacks") as dump:
            if not enabled:
                os.environ.pop(_common.STUCK_STACKS_ENV, None)
            proc = LiveProcess(SLEEPER, log_path=Path(tmp) / "p.log")
            if waited:
                self.assertIsNone(proc.wait(0.1))
            proc.stop(grace=5)
            return dump.call_count

    def test_dumps_when_enabled_and_wait_timed_out(self):
        self.assertEqual(self.run_case(enabled=True, waited=True), 1)

    def test_no_dump_for_deliberate_stop(self):
        self.assertEqual(self.run_case(enabled=True, waited=False), 0)

    def test_no_dump_when_disabled(self):
        self.assertEqual(self.run_case(enabled=False, waited=True), 0)

    def test_no_dump_for_process_that_exited(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.dict(os.environ, {_common.STUCK_STACKS_ENV: "1"}), patch("_common.dump_stacks") as dump:
            proc = LiveProcess([sys.executable, "-c", "pass"], log_path=Path(tmp) / "p.log")
            proc.wait(30)
            proc.stop()
            self.assertEqual(dump.call_count, 0)


class OverdueTests(unittest.TestCase):
    """Marker deadlines and explicit failures count as overdue, like wait() timeouts."""

    def stop_count(self, setup) -> int:
        with tempfile.TemporaryDirectory() as tmp, \
                patch.dict(os.environ, {_common.STUCK_STACKS_ENV: "1"}), patch("_common.dump_stacks") as dump:
            proc = LiveProcess(SLEEPER, log_path=Path(tmp) / "p.log")
            setup(proc)
            proc.stop(grace=5)
            return dump.call_count

    def test_marker_timeout_dumps(self):
        self.assertEqual(self.stop_count(lambda p: self.assertFalse(p.wait_for_output("never", 0.2))), 1)

    def test_mark_overdue_dumps(self):
        self.assertEqual(self.stop_count(lambda p: p.mark_overdue()), 1)

    def test_marker_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = LiveProcess([sys.executable, "-c", "print('ready', flush=True); import time; time.sleep(60)"],
                               log_path=Path(tmp) / "p.log")
            self.assertTrue(proc.wait_for_output("ready", 30))
            proc.stop(grace=5)


class StackDumpCommandTests(unittest.TestCase):
    def test_java_uses_jstack_beside_java(self):
        with tempfile.TemporaryDirectory() as tmp:
            java = Path(tmp) / "java"
            (Path(tmp) / "jstack").touch()
            self.assertEqual(_common._stack_dump_cmd(42, [str(java), "-cp", "x", "Main"]),
                             [str(Path(tmp) / "jstack"), "-l", "42"])

    def test_native_debuggers(self):
        with patch("_common.shutil.which", return_value="/usr/bin/tool"), patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ZZDDS_TEST_DEBUGGER", None)
            with patch("_common.sys.platform", "linux"):
                cmd = _common._stack_dump_cmd(7, ["/bin/app"])
                self.assertEqual(cmd[:4], ["gdb", "--batch", "-p", "7"])
                self.assertIn("thread apply all backtrace", cmd)
            with patch("_common.sys.platform", "darwin"):
                self.assertEqual(_common._stack_dump_cmd(7, ["/bin/app"]), ["lldb", "--batch", "-p", "7", "-o", "bt all"])
            with patch("_common.sys.platform", "win32"):
                self.assertIsNone(_common._stack_dump_cmd(7, ["C:/app.exe"]))

    def test_missing_debugger(self):
        with patch("_common.shutil.which", return_value=None), patch("_common.sys.platform", "linux"):
            self.assertIsNone(_common._stack_dump_cmd(7, ["/bin/app"]))


class MetaFileTests(unittest.TestCase):
    def test_meta_written_at_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = LiveProcess(SLEEPER, log_path=Path(tmp) / "p.log")
            meta = (Path(tmp) / "p.log.meta").read_text()
            self.assertIn("started_utc:", meta)
            self.assertNotIn("stopped_utc:", meta)
            proc.stop(grace=5)
            self.assertIn("stopped_externally: true", (Path(tmp) / "p.log.meta").read_text())

    def test_meta_records_times_and_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "sub.log"
            proc = LiveProcess([sys.executable, "-c", "pass"], log_path=log)
            proc.wait(30)
            proc.stop()
            meta = (Path(tmp) / "sub.log.meta").read_text()
            for key in ("cmd:", "pid:", "started_utc:", "stopped_utc:", "returncode: 0", "stopped_externally: false"):
                self.assertIn(key, meta)


if __name__ == "__main__":
    unittest.main()
