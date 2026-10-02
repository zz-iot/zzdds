#!/usr/bin/env python3
"""Capture network evidence around a CI test run, for diagnosing discovery failures.

    python3 scripts/ci_net_diagnostics.py start <outdir>
    ... run the tests ...
    python3 scripts/ci_net_diagnostics.py stop <outdir>

`start` records a snapshot of interfaces, addresses, routes, multicast memberships and
UDP sockets, then launches two background recorders that outlive this script:

  * `ip -ts monitor all` (Linux): a timestamped log of every interface, address, route
    and neighbour change during the run, which shows whether the host's network changed
    while processes held locators derived from it;
  * `tcpdump -i any udp` (when tcpdump and passwordless sudo are available): every UDP
    datagram, including loopback, size-capped at two 200 MB files. Analyse with
    dds-rtps's rtps_pcap.py.

`stop` ends the recorders (SIGINT, then SIGKILL after a bounded wait, so a capture is
flushed but can never hang the job) and records a second snapshot. Windows and macOS get
the snapshots; Windows has no recorders. Every command here is bounded and best-effort:
diagnostics must never fail or hang the job they are diagnosing.

Match capture timestamps to pairs with the `*.log.meta` files examples/_common.py writes
beside each process log.
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

CMD_TIMEOUT_S = 30
STOP_GRACE_S = 10


def run_to_file(cmd: list[str], out, title: str) -> None:
    out.write(f"===== {title}: {' '.join(cmd)} =====\n")
    out.flush()
    try:
        result = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=CMD_TIMEOUT_S)
        out.write(result.stdout.decode(errors="replace"))
    except (OSError, subprocess.TimeoutExpired) as e:
        out.write(f"(unavailable: {e})\n")
    out.write("\n")


def can_sudo() -> bool:
    if sys.platform == "win32" or shutil.which("sudo") is None:
        return False
    try:
        return subprocess.run(["sudo", "-n", "true"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=CMD_TIMEOUT_S).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def snapshot(outdir: Path, label: str) -> None:
    if sys.platform == "win32":
        cmds = [["ipconfig", "/all"], ["route", "print"],
                ["netsh", "interface", "ipv4", "show", "joins"], ["netstat", "-ano", "-p", "udp"]]
    elif sys.platform == "darwin":
        cmds = [["ifconfig", "-a"], ["netstat", "-rn"], ["netstat", "-g"], ["netstat", "-anv", "-p", "udp"]]
    else:
        cmds = [["ip", "-d", "addr", "show"], ["ip", "-4", "route", "show", "table", "all"],
                ["ip", "-6", "route", "show", "table", "all"], ["ip", "maddr", "show"], ["ss", "-uanp"]]
        if can_sudo():
            cmds.append(["sudo", "-n", "iptables-save"])
            cmds.append(["sudo", "-n", "ip6tables-save"])
    with open(outdir / f"net-{label}.txt", "w") as out:
        out.write(f"snapshot '{label}' at {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n\n")
        for cmd in cmds:
            run_to_file(cmd, out, label)


def spawn(cmd: list[str], log: Path, pidfile: Path) -> None:
    try:
        with open(log, "wb") as out:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        pidfile.write_text(str(proc.pid))
        print(f"started {' '.join(cmd)} (pid {proc.pid})")
    except OSError as e:
        print(f"could not start {cmd[0]}: {e}")


def start(outdir: Path) -> None:
    outdir.mkdir(parents=True, exist_ok=True)
    snapshot(outdir, "before")
    if sys.platform.startswith("linux") and shutil.which("ip"):
        spawn(["ip", "-ts", "monitor", "all"], outdir / "ip-monitor.log", outdir / "ip-monitor.pid")
    if sys.platform != "win32" and shutil.which("tcpdump") and can_sudo():
        # -Z root: keep root after opening the device, or rotation could not create the
        # second file in this runner-owned directory. -U flushes each packet, so a capture
        # cut short still holds everything recorded so far.
        spawn(["sudo", "-n", "tcpdump", "-i", "any", "-n", "-U", "-Z", "root",
               "-C", "200", "-W", "2", "-w", str(outdir / "udp.pcap"), "udp"],
              outdir / "tcpdump.log", outdir / "tcpdump.pid")
    else:
        print("packet capture unavailable (needs tcpdump and passwordless sudo)")


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True  # exists but owned by root (the sudo'd tcpdump)
    except OSError:
        return False


def signal_pid(pid: int, sig: int, use_sudo: bool) -> None:
    """Signal a recorder's whole session (sudo forwards to tcpdump; `ip` has no children)."""
    if use_sudo:
        subprocess.run(["sudo", "-n", "kill", f"-{int(sig)}", "--", f"-{pid}"], stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=CMD_TIMEOUT_S)
        return
    try:
        os.killpg(pid, sig)
    except OSError:
        pass


def stop_recorder(pidfile: Path, use_sudo: bool) -> None:
    if not pidfile.exists():
        return
    pid = int(pidfile.read_text())
    signal_pid(pid, signal.SIGINT, use_sudo)
    deadline = time.monotonic() + STOP_GRACE_S
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.2)
    if alive(pid):
        signal_pid(pid, signal.SIGKILL, use_sudo)
    pidfile.unlink()
    print(f"stopped pid {pid}")


def stop(outdir: Path) -> None:
    if not outdir.is_dir():
        print(f"{outdir} does not exist; nothing to stop")
        return
    if sys.platform != "win32":
        stop_recorder(outdir / "tcpdump.pid", use_sudo=True)
        stop_recorder(outdir / "ip-monitor.pid", use_sudo=False)
        if can_sudo():
            # tcpdump ran as root; let the artifact upload read what it wrote.
            subprocess.run(["sudo", "-n", "chmod", "-R", "a+rX", str(outdir)], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=CMD_TIMEOUT_S)
    snapshot(outdir, "after")


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("start", "stop"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        print("usage: ci_net_diagnostics.py start|stop <outdir>", file=sys.stderr)
        return 2
    outdir = Path(argv[2])
    try:
        (start if argv[1] == "start" else stop)(outdir)
    except Exception as e:  # diagnostics must never fail the job
        print(f"network diagnostics {argv[1]} failed: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
