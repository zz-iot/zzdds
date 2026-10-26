#!/usr/bin/env python3
"""Run bounded separate-process UDP checks against prebuilt example artifacts."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import sys


def run_pair(subscriber, publisher):
    processes = []
    logs = []
    failures = []
    try:
        # Publisher waits for both reliable readers; startup needs no fixed sleep.
        # Files also avoid a verbose child blocking on an unread pipe.
        for command in (subscriber, publisher):
            log = tempfile.TemporaryFile(mode="w+t")
            logs.append(log)
            processes.append(subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, text=True))
        for process, log in zip(processes, logs):
            try:
                process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                failures.append(f"process timed out: {process.args}")
                continue
            log.seek(0)
            output = log.read()
            if process.returncode != 0 or "PASS " not in output:
                failures.append(f"process failed: {process.args} (exit {process.returncode})\n{output}")
            else:
                print("\n".join(line for line in output.splitlines() if line.startswith("PASS ")))
        if failures:
            raise RuntimeError("\n".join(failures))
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for log in logs:
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[3]
    windows = sys.platform == "win32"
    suffix = ".dll" if windows else ".dylib" if sys.platform == "darwin" else ".so"
    library_dir = root / ("zig-out/bin" if windows else "zig-out/lib")
    library_prefix = "" if windows else "lib"
    parser.add_argument("--host", type=Path, default=root / ("zig-out/bin/typesupport-demo.exe" if windows else "zig-out/bin/typesupport-demo"))
    parser.add_argument("--sensors", type=Path, default=library_dir / f"{library_prefix}demo_sensors{suffix}")
    parser.add_argument("--control", type=Path, default=library_dir / f"{library_prefix}demo_control{suffix}")
    parser.add_argument("--fastdds-sub", type=Path, help="Optional independent Fast DDS 3 subscriber")
    # Below 102: its ports (7400 + 250*domain up) stay below the OS ephemeral
    # ranges (Linux from 32768, Windows and macOS from 49152).
    parser.add_argument("--domain", type=int, default=98)
    args = parser.parse_args()
    if not 0 <= args.domain <= 232:
        parser.error("expected UDP domain 0..232")
    for path in (args.host, args.sensors, args.control, args.fastdds_sub):
        if path is not None and not path.is_file():
            parser.error(f"missing artifact: {path}")
    host = str(args.host.resolve())
    libraries = [str(args.sensors.resolve()), str(args.control.resolve())]
    domain = str(args.domain)
    subprocess.run([host, "inspect", *libraries], check=True)
    # A missing candidate is an actionable failure, not a silent empty catalog.
    rejected = subprocess.run([host, "inspect", str(args.sensors.resolve()) + ".missing", libraries[1]], capture_output=True, text=True)
    if rejected.returncode == 0:
        raise RuntimeError("missing library unexpectedly accepted")
    run_pair([host, "sub", *libraries, domain], [host, "pub", *libraries, domain])
    if args.fastdds_sub is not None:
        run_pair([str(args.fastdds_sub.resolve()), domain], [host, "pub", *libraries, domain])
    else:
        print("Fast DDS check skipped: supply --fastdds-sub to qualify independent reception")


if __name__ == "__main__":
    main()
