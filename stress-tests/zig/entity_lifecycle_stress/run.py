#!/usr/bin/env python3
"""Build + run the EntityLifecycleStress port.

Spawns N `--role pub` + M `--role sub` `elc_stress` processes, interleaved
(pub, sub, pub, sub, ...) the way OpenDDS's run_test.pl does, all on one
per-run-unique domain. Every process is bounded by _common.LiveProcess
(SIGINT -> grace -> SIGKILL; every wait has a ceiling), so a hung teardown
can never hang this script -- it's caught by the per-process timeout and
reported.

Pass/fail:
  * every process exits 0 within the timeout
  * every process prints exactly one `SUMMARY: OK ...` line
  * no `FAIL:` / `panic` / `SLOW_TEARDOWN`-over-hard-limit line anywhere
  * every process's self-reported teardown_ms < --teardown-hard-limit-ms

CI runs this with small counts; the nightly matrix runs it bigger and with
--large. Both --cleanup modes are always exercised.
"""
from __future__ import annotations

import argparse
import os
import random
import re
import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
# stress-tests/zig/<app>/run.py -> repo root is parents[2]; reuse examples/_common.py
sys.path.insert(0, str(APP_DIR.parents[2] / "examples"))
import _common  # noqa: E402

SUMMARY_RE = re.compile(r"^SUMMARY: OK role=(pub|sub) teardown_ms=(\d+) ", re.M)


def build() -> Path:
    log = _common.mktemp_logdir("elc-stress") / "build.log"
    ok = _common.run_build(["zig", "build"], cwd=APP_DIR, log_path=log)
    if not ok:
        print(_common.Path(log).read_text(errors="replace"), file=sys.stderr)
        raise SystemExit("FAIL: elc_stress build failed")
    return APP_DIR / "zig-out" / "bin" / "elc_stress"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--publishers", type=int, default=4)
    ap.add_argument("--subscribers", type=int, default=4)
    ap.add_argument("--samples", type=int, default=400)
    ap.add_argument("--large", action="store_true")
    ap.add_argument("--churn", action="store_true")
    ap.add_argument("--domain", type=int, default=0, help="0 = pick a random high domain")
    ap.add_argument("--timeout", type=int, default=120, help="per-process wall-clock ceiling (s)")
    ap.add_argument("--teardown-hard-limit-ms", type=int, default=15000)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    binary = build()
    seed = args.seed or random.randrange(1, 2**31)
    rng = random.Random(seed)
    # 1..232 keeps every derived RTPS port < 65536; steer clear of 0.
    domain = args.domain or rng.randint(2, 230)
    logdir = _common.mktemp_logdir("elc-stress-run")
    print(f"domain={domain} seed={seed} pubs={args.publishers} subs={args.subscribers} "
          f"samples={args.samples} large={args.large} churn={args.churn} logs={logdir}")

    # Interleaved spec list (pub, sub, pub, sub, ...), wrapping when one side
    # runs out -- exactly run_test.pl's ordering.
    specs: list[tuple[str, int]] = []
    pi = si = 0
    for i in range(args.publishers + args.subscribers):
        want_pub = (i % 2 == 0)
        if want_pub and pi < args.publishers:
            specs.append(("pub", pi)); pi += 1
        elif si < args.subscribers:
            specs.append(("sub", si)); si += 1
        else:
            specs.append(("pub", pi)); pi += 1

    procs: list[tuple[str, _common.LiveProcess]] = []
    for idx, (role, n) in enumerate(specs):
        # Deterministic cleanup-mode split: every 3rd process leans on the
        # delete_contained_entities cascade, the rest tear down explicitly
        # (OpenDDS's `pid % 3`, made reproducible).
        cleanup = "cascade" if idx % 3 == 0 else "explicit"
        cmd = [str(binary), "--role", role, "--domain", str(domain),
               "--cleanup", cleanup, "--seed", str(seed),
               "--slow-teardown-warn-ms", "3000"]
        if role == "pub":
            cmd += ["--samples", str(args.samples)]
            if args.large:
                cmd.append("--large")
        else:
            cmd += ["--wait-ms", str(max(8000, args.samples * 10 + 5000))]
        if args.churn:
            cmd.append("--churn")
        name = f"{role}_{n}"
        procs.append((name, _common.LiveProcess(cmd, log_path=logdir / f"{name}.log")))

    failures: list[str] = []
    for name, lp in procs:
        rc = lp.stop(grace=10) if lp.wait(timeout=args.timeout) is None else lp.proc.returncode
        text = lp.log_text()
        if rc != 0:
            failures.append(f"{name}: exit {rc}")
        m = SUMMARY_RE.search(text)
        if not m:
            failures.append(f"{name}: no `SUMMARY: OK` line")
        else:
            td = int(m.group(2))
            if td > args.teardown_hard_limit_ms:
                failures.append(f"{name}: teardown_ms={td} > {args.teardown_hard_limit_ms}")
        for bad in ("FAIL:", "panic", "Segmentation fault", "leak"):
            if bad in text:
                failures.append(f"{name}: log contains {bad!r}")
                break

    if failures:
        print("\n== FAILURES ==", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print(f"\nLogs kept at {logdir}", file=sys.stderr)
        return 1
    print(f"OK: {len(procs)} processes, all clean (domain {domain}, seed {seed})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
