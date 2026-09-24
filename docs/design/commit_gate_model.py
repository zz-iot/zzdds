"""Finite design model, not a model of Zig synchronization or full RTPS.

Run: python3 docs/design/commit_gate_model.py
Two preissued, unnumbered tickets; split gate claim/install; cancellation,
close, retirement, FIFO gate order and immutable progress snapshots.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    phase: tuple = ("ready", "ready")
    queue: tuple = (0, 1)
    gate: int = -1
    installed: tuple = ()
    retired: tuple = (False, False)
    closing: bool = False
    sealed: bool = False
    snapshot: tuple | None = None


def phase(s, i, value):
    p = list(s.phase)
    p[i] = value
    return tuple(p)


def successors(s):
    if not s.closing:
        yield "close admission", replace(s, closing=True)
    if s.closing and all(s.retired) and not s.sealed:
        yield "seal", replace(s, sealed=True)
    for i in range(2):
        if s.phase[i] == "ready":
            yield f"cancel {i}", replace(
                s, phase=phase(s, i, "aborted"),
                queue=tuple(x for x in s.queue if x != i))
            if s.gate == -1 and s.queue and s.queue[0] == i:
                yield f"claim {i}", replace(
                    s, phase=phase(s, i, "claimed"), gate=i,
                    queue=s.queue[1:])
        if s.phase[i] == "claimed":
            yield f"install {i}", replace(
                s, phase=phase(s, i, "committed"), gate=-1,
                installed=s.installed + (i,))
        if s.phase[i] in ("aborted", "committed") and not s.retired[i]:
            r = list(s.retired)
            r[i] = True
            yield f"retire {i}", replace(s, retired=tuple(r))
    # Snapshot acquires the same metadata gate. Packet send may be delayed;
    # it carries this immutable snapshot, never a later mixed watermark.
    if s.gate == -1 and s.snapshot is None:
        yield "snapshot", replace(s, snapshot=(len(s.installed), s.installed))


def check(s):
    assert len(set(s.installed)) == len(s.installed)
    assert sum(p == "claimed" for p in s.phase) == (s.gate != -1)
    for i, p in enumerate(s.phase):
        assert (i in s.installed) == (p == "committed")
        assert not s.retired[i] or p in ("aborted", "committed")
    if s.sealed:
        assert s.closing and all(s.retired) and s.gate == -1
    if s.snapshot is not None:
        watermark, entries = s.snapshot
        assert watermark == len(entries)
        assert s.installed[:watermark] == entries


def explore():
    start = State()
    todo, seen, edges = deque([start]), {start}, {}
    while todo:
        s = todo.popleft()
        check(s)
        next_states = list(successors(s))
        edges[s] = next_states
        for _, n in next_states:
            if n not in seen:
                seen.add(n)
                todo.append(n)
    # Existential termination is weaker than fairness/liveness: every state
    # must have a path to seal, not every arbitrary schedule must terminate.
    reachable = {s for s in seen if s.sealed}
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    print(f"PASS: {len(seen)} states, {sum(map(len, edges.values()))} transitions; "
          "invariants and a path to seal from every state")


def unsafe_snapshot_witness():
    old_writer_entries = ()
    installed = (0,)  # commit occurs between two unsynchronized reads
    mixed = (len(installed), old_writer_entries)
    assert mixed[0] != len(mixed[1])
    print("COUNTEREXAMPLE: old history + new watermark describes no actual snapshot")


if __name__ == "__main__":
    explore()
    unsafe_snapshot_witness()
