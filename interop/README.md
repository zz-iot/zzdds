# interop

Cross-language/cross-binding tests: these don't belong under `c/`, `cpp/`,
`java/`, or `zig/` individually because they exercise more than one binding
at once. Written in Python (see the repo root's `_common.py` for the shared
helpers every Python script in this repo uses) rather than shell — process
lifecycle management (bounded waits, graceful-then-forceful shutdown of a
long-running pub/sub process) is much easier to get right and keep right in
Python than in bash. Needs Python 3.10+ and `stdbuf` (part of GNU
coreutils, already present on any standard Linux dev/CI image).

- `cross_binding_smoke_test.py` — builds `c/custom-allocator` and
  `cpp/custom-allocator`, then runs each one's publisher against the other's
  subscriber (both directions), over real UDP DDS discovery. Confirms the C
  and C++ bindings are wire-compatible, not just each internally consistent.

  ```sh
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./cross_binding_smoke_test.py
  ```

- `shape_cross_binding_smoke_test.py` — builds all four `shape` ports
  (`zig/shape`, `c/shape`, `cpp/shape`, `java/shape`) and runs every ordered
  publisher/subscriber pair across all four bindings (12 pairs total). Also
  checks each binding's `--cft` (`ContentFilteredTopic`) support: a
  same-language pub/sub pair with the subscriber filtering on `shapesize`,
  confirming every binding's reader actually drops non-matching samples. The
  CFT check runs both sides indefinitely and waits for the publisher's own
  logged match confirmation (not a fixed delay) before checking results, so
  it isn't a guess about how long DDS discovery happens to take on a given
  machine.

  ```sh
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./shape_cross_binding_smoke_test.py
  ```

- `hello_world_cross_binding_smoke_test.py` — builds all four `hello_world`
  ports and runs every ordered publisher/subscriber pair across all four
  bindings (12 pairs total).

  ```sh
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./hello_world_cross_binding_smoke_test.py
  ```
