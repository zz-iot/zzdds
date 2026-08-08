#!/usr/bin/env python3
"""Shared helpers for zzdds-examples' Python build/run/smoke-test scripts.

Common across interop/*.py, java/*.py, cpp/opencv_zzdds/smoke_test.py, and
the top-level run_all.py: environment/path resolution, running a build
step with captured output, and running a long-lived pub/sub process with a
*bounded* lifecycle -- every wait has a timeout, and stop() always
escalates to a hard kill if a process doesn't react to a graceful signal
in time. This is deliberate: a bash version of one of these scripts once
hung for 40+ minutes because a Java subscriber didn't react to SIGINT the
way a native binary does, and bash's `wait "$pid"` blocked forever with no
way to time out. That class of hang is structurally impossible here --
every process interaction in this module has an explicit ceiling.

Every script in this repo that uses this module locates it the same way,
regardless of which subdirectory it lives in:

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[N]))  # N = depth to repo root
    import _common
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


def zzdds_zig_out() -> Path:
    return Path(os.environ.get("ZZDDS_ZIG_OUT", str(REPO_ROOT.parent / "zzdds" / "zig-out")))


def run_env(zig_out: Path) -> dict:
    """Environment for running a built binary/jar against zig_out's libs."""
    env = os.environ.copy()
    lib_dir = str(zig_out / "lib")
    existing = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{existing}" if existing else lib_dir
    return env


def java_cmd(zig_out: Path, classpath: Path, main_class: str, *args: str) -> list[str]:
    return [
        "java",
        "--enable-native-access=ALL-UNNAMED",
        f"-Djava.library.path={zig_out / 'lib'}",
        "-cp",
        str(classpath),
        main_class,
        *args,
    ]


def run_build(
    cmd: list[str], *, cwd: Path, log_path: Path, timeout: int = 300, env: dict | None = None
) -> bool:
    """Run a build step, capturing combined stdout+stderr to log_path.

    Returns True on success (exit 0 within `timeout` seconds). Never
    raises -- a timeout or missing command counts as failure, same as a
    nonzero exit.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(log_path, "wb") as f:
            proc = subprocess.run(
                cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout, env=env
            )
        return proc.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        with open(log_path, "ab") as f:
            f.write(f"\n[smoke test] build step failed to run: {e}\n".encode())
        return False


def require_tool(name: str) -> bool:
    if shutil.which(name) is None:
        print(f"FAIL: required tool not found on PATH: {name}", file=sys.stderr)
        return False
    return True


def require_path(path: Path, *hint_lines: str) -> bool:
    """Check a prerequisite file/dir exists, printing a FAIL + hints (each
    a separate line, matching the bash scripts' existing "FAIL: X\\n  hint"
    style) if not."""
    if path.exists():
        return True
    print(f"FAIL: {path} not found.", file=sys.stderr)
    for line in hint_lines:
        print(f"  {line}", file=sys.stderr)
    return False


class LiveProcess:
    """A pub/sub process under test, with output captured to a log file
    and a lifecycle that can never hang the calling script indefinitely.
    """

    def __init__(
        self,
        cmd: list[str],
        *,
        cwd: Path | None = None,
        env: dict | None = None,
        log_path: Path | None = None,
    ):
        """log_path=None (the default) inherits stdout/stderr straight
        through to this process's own -- for a user-facing run.py meant to
        be watched interactively, live-streaming output beats a batch dump
        at the end. Pass a real log_path (as every interop/*.py smoke test
        does) when the caller needs to grep captured output afterward.
        """
        self.cmd = cmd
        self.log_path = log_path
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            self._log_file = open(log_path, "wb")
            stdout, stderr = self._log_file, subprocess.STDOUT
        else:
            self._log_file = None
            stdout, stderr = None, None
        self.proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=stdout, stderr=stderr)

    def poll(self) -> int | None:
        return self.proc.poll()

    def wait(self, timeout: float) -> int | None:
        """Wait up to `timeout` seconds for the process to exit on its
        own. Returns the exit code, or None if it's still running --
        never blocks past `timeout` and never kills the process itself
        (call stop() for that).
        """
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None

    def stop(self, grace: float = 5) -> int:
        """Ensure the process is stopped. If still running: SIGINT (the
        graceful-shutdown signal every binding's shape_main/hello_world
        handles), wait up to `grace` seconds, then escalate to SIGKILL if
        it's still alive. Always returns promptly with an exit code --
        this is the one place an indefinite hang is structurally
        prevented.
        """
        if self.proc.poll() is None:
            try:
                self.proc.send_signal(signal.SIGINT)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass  # truly stuck (e.g. a zombie under a dead container) -- give up, don't hang
        if self._log_file is not None:
            self._log_file.flush()
            self._log_file.close()
        return self.proc.returncode if self.proc.returncode is not None else -1

    def log_text(self) -> str:
        if self.log_path is None:
            return ""  # inherited stdout/stderr directly; nothing captured to read back
        try:
            return self.log_path.read_text(errors="replace")
        except FileNotFoundError:
            return ""


def print_fail(label: str, detail: str = "", *log_sections: tuple[str, "LiveProcess | str"]) -> None:
    suffix = f" ({detail})" if detail else ""
    print(f"FAIL: {label}{suffix}", file=sys.stderr)
    for name, source in log_sections:
        text = source.log_text() if isinstance(source, LiveProcess) else source
        print(f"-- {name} log --", file=sys.stderr)
        print(text, file=sys.stderr)


def mktemp_logdir(prefix: str) -> Path:
    return Path(tempfile.mkdtemp(prefix=f"{prefix}-"))
