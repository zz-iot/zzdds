#!/usr/bin/env python3
"""Shared helpers for zzdds's examples/ Python build/run/smoke-test scripts.

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

import datetime
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent


def zzdds_zig_out() -> Path:
    return Path(os.environ.get("ZZDDS_ZIG_OUT", str(REPO_ROOT.parent / "zig-out")))


def executable_path(path: Path) -> Path:
    """Resolve a native binary from a Zig or CMake Debug build.

    Single-config CMake generators put executables directly in the build
    directory; multi-config generators put them under Debug/. Callers build
    with --config Debug so the lookup and selected configuration agree.
    Return the direct path when missing so prerequisite checks can report it.
    """
    if sys.platform == "win32":
        path = path.with_name(path.name + ".exe")
    if path.is_file():
        return path
    configured = path.parent / "Debug" / path.name
    return configured if configured.is_file() else path


def run_env(zig_out: Path) -> dict:
    """Environment for running a built binary/jar against zig_out's libs.

    Platform-specific: build.zig installs the shared library to a different
    directory, and the loader consults a different search-path variable, on
    each OS -- Linux (libzzdds.so in zig-out/lib, LD_LIBRARY_PATH), macOS
    (libzzdds.dylib in zig-out/lib, DYLD_LIBRARY_PATH), Windows (zzdds.dll in
    zig-out/bin, since .dll counts as isDll() -- see build.zig's
    zzdds_dll_install_dir -- and Windows has no rpath equivalent, so it's
    found via PATH like any other DLL, not a dedicated variable).
    """
    env = os.environ.copy()
    if sys.platform == "win32":
        var, lib_dir = "PATH", str(zig_out / "bin")
    elif sys.platform == "darwin":
        var, lib_dir = "DYLD_LIBRARY_PATH", str(zig_out / "lib")
    else:
        var, lib_dir = "LD_LIBRARY_PATH", str(zig_out / "lib")
    existing = env.get(var, "")
    env[var] = f"{lib_dir}{os.pathsep}{existing}" if existing else lib_dir
    return env


def java_cmd(zig_out: Path, classpath: Path, main_class: str, *args: str) -> list[str]:
    lib_dir = zig_out / ("bin" if sys.platform == "win32" else "lib")
    return [
        "java",
        "--enable-native-access=ALL-UNNAMED",
        "-Xss8m",
        f"-Djava.library.path={lib_dir}",
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
        # Set when a wait() ran out of time: the caller expected the process to
        # exit by then, so a later stop() that has to kill it is a hang worth
        # diagnosing (see dump_stacks). Callers that stop a deliberately
        # long-running process don't wait() on it first.
        self._wait_timed_out = False
        if log_path is not None:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            self._log_file = open(log_path, "wb")
            stdout, stderr = self._log_file, subprocess.STDOUT
        else:
            self._log_file = None
            stdout, stderr = None, None
        self._started = _utc_now()
        self.proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=stdout, stderr=stderr)
        if log_path is not None:
            # Written now as well as at stop(), so a process that is never stopped
            # (or whose script dies first) still has its start time on record.
            self._write_meta(None)

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
            self._wait_timed_out = True
            return None

    def wait_for_output(self, marker: str, timeout: float) -> bool:
        """Poll this process's log for `marker` until it appears, the process
        exits, or `timeout` passes. A real signal that a phase of the app has
        completed, not a fixed sleep. A timeout with the process still running
        marks it overdue, like a timed-out wait()."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in self.log_text():
                return True
            if self.proc.poll() is not None:
                return marker in self.log_text()
            time.sleep(0.05)
        if marker in self.log_text():
            return True
        if self.proc.poll() is None:
            self._wait_timed_out = True
        return False

    def mark_overdue(self) -> None:
        """Record that the caller expected progress from this process by now
        (e.g. a match it never reported), so stop() treats it as hung."""
        self._wait_timed_out = True

    def stop(self, grace: float = 5) -> int:
        """Ensure the process is stopped. If still running: SIGINT (the
        graceful-shutdown signal every binding's shape_main/hello_world
        handles), wait up to `grace` seconds, then escalate to SIGKILL if
        it's still alive. Always returns promptly with an exit code --
        this is the one place an indefinite hang is structurally
        prevented.

        Windows exception: Popen.send_signal() there only accepts SIGTERM,
        CTRL_C_EVENT, or CTRL_BREAK_EVENT -- anything else, including
        SIGINT, raises ValueError (verified against cpython's subprocess.py;
        there is no Windows equivalent of a plain SIGINT here without also
        spawning with CREATE_NEW_PROCESS_GROUP, which this class doesn't do,
        to avoid CTRL_C_EVENT hitting this Python process too). This path
        uses terminate() for bounded cleanup. Callers requiring successful
        self-termination check the exit code; intentionally long-running
        checks (such as shape filtering) validate their output instead.
        """
        killed_while_running = self.proc.poll() is None
        if killed_while_running and self._wait_timed_out and stuck_stacks_enabled():
            dump_stacks(self.proc.pid, self.cmd)
        if self.proc.poll() is None:
            try:
                if sys.platform == "win32":
                    self.proc.terminate()
                else:
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
            self._log_file = None
            self._write_meta(killed_while_running)
        return self.proc.returncode if self.proc.returncode is not None else -1

    def _write_meta(self, killed_while_running: bool | None) -> None:
        """Record wall-clock start/stop times beside the log, so CI packet
        captures and interface-change logs (scripts/ci_net_diagnostics.py)
        can be matched to the pair that was running at the time.
        killed_while_running=None writes the start-only record."""
        assert self.log_path is not None
        lines = [
            f"cmd: {' '.join(self.cmd)}",
            f"pid: {self.proc.pid}",
            f"started_utc: {self._started}",
        ]
        if killed_while_running is not None:
            rc = self.proc.returncode
            lines += [
                f"stopped_utc: {_utc_now()}",
                f"returncode: {rc if rc is not None else 'unknown'}",
                f"stopped_externally: {str(killed_while_running).lower()}",
            ]
        try:
            self.log_path.with_name(self.log_path.name + ".meta").write_text("\n".join(lines) + "\n")
        except OSError:
            pass  # diagnostics only; never fail a test over it

    def log_text(self) -> str:
        if self.log_path is None:
            return ""  # inherited stdout/stderr directly; nothing captured to read back
        try:
            return self.log_path.read_text(errors="replace")
        except FileNotFoundError:
            return ""


def _utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


STUCK_STACKS_ENV = "ZZDDS_TEST_LOG_STUCK_STACKS"
STACK_DUMP_TIMEOUT_S = 60


def stuck_stacks_enabled() -> bool:
    return os.environ.get(STUCK_STACKS_ENV, "") not in ("", "0")


def _stack_dump_cmd(pid: int, cmd: list[str]) -> list[str] | None:
    """Debugger command printing every thread's stack for `pid`, or None if
    this platform has no supported tool. Java gets jstack (JVM frames, not the
    interpreter's native ones); native processes get gdb, or lldb on macOS.
    ZZDDS_TEST_DEBUGGER overrides the native debugger (gdb or lldb)."""
    if Path(cmd[0]).name.lower() in ("java", "java.exe"):
        jstack = Path(cmd[0]).with_name("jstack.exe" if cmd[0].lower().endswith(".exe") else "jstack")
        tool = str(jstack) if jstack.is_file() else shutil.which("jstack")
        return [tool, "-l", str(pid)] if tool else None
    if sys.platform == "win32":
        return None
    debugger = os.environ.get("ZZDDS_TEST_DEBUGGER") or ("lldb" if sys.platform == "darwin" else "gdb")
    if shutil.which(debugger) is None:
        return None
    if Path(debugger).name.startswith("lldb"):
        return [debugger, "--batch", "-p", str(pid), "-o", "bt all"]
    return [debugger, "--batch", "-p", str(pid), "-ex", "set pagination off", "-ex", "thread apply all backtrace"]


def dump_stacks(pid: int, cmd: list[str]) -> None:
    """Print every thread's stack of a process that failed to exit in time, so
    a hang in CI can be diagnosed from the job log. Opt in with
    ZZDDS_TEST_LOG_STUCK_STACKS=1 (modelled on ACE's ACE_TEST_LOG_STUCK_STACKS).
    The debugger itself is bounded: it is killed after STACK_DUMP_TIMEOUT_S.
    On Linux, attaching to a process that isn't the debugger's own child needs
    kernel.yama.ptrace_scope=0 (CI sets it)."""
    print(f"\n======= Begin stuck stacks: pid {pid}: {' '.join(cmd)} =======", file=sys.stderr, flush=True)
    dump_cmd = _stack_dump_cmd(pid, cmd)
    if dump_cmd is None:
        print("(no stack-dump tool available on this platform)", file=sys.stderr)
    else:
        try:
            result = subprocess.run(dump_cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=STACK_DUMP_TIMEOUT_S)
            sys.stderr.write(result.stdout.decode(errors="replace"))
        except subprocess.TimeoutExpired:
            print(f"(stack dump timed out after {STACK_DUMP_TIMEOUT_S}s)", file=sys.stderr)
        except OSError as e:
            print(f"(stack dump failed: {e})", file=sys.stderr)
    print("======= End stuck stacks =======", file=sys.stderr, flush=True)


def print_fail(label: str, detail: str = "", *log_sections: tuple[str, "LiveProcess | str"]) -> None:
    suffix = f" ({detail})" if detail else ""
    print(f"FAIL: {label}{suffix}", file=sys.stderr)
    for name, source in log_sections:
        text = source.log_text() if isinstance(source, LiveProcess) else source
        print(f"-- {name} log --", file=sys.stderr)
        print(text, file=sys.stderr)


def mktemp_logdir(prefix: str) -> Path:
    return Path(tempfile.mkdtemp(prefix=f"{prefix}-"))
