"""Finite handoff model; no Zig atomics, network or timing claims.

Run: python3 docs/design/commit_handoff_model.py
Two preissued tickets, one per writer; each writer starts with older work.
Publication is separate from entitlement; cancellation can leave stale events.
"""
from collections import deque
from dataclasses import dataclass, replace


def put(values, index, value):
    result = list(values)
    result[index] = value
    return tuple(result)


@dataclass(frozen=True)
class State:
    phase: tuple = ("pending", "pending")
    gate_queue: tuple = (0, 1)
    entitled: int = -1
    active: int = -1
    publication: tuple = (False, False)
    writer_queue: tuple = ((-1,), (-1,))  # -1 is older background work
    running: tuple = (None, None)
    resource: tuple = ("reserved", "reserved")
    retired: tuple = (False, False)
    installed: tuple = ()
    closing: bool = False
    sealed: bool = False


def successors(s, workers):
    if not s.closing:
        yield "close", replace(s, closing=True)
    if s.closing and all(s.retired) and not s.sealed:
        yield "seal", replace(s, sealed=True)
    if s.entitled == -1 and s.active == -1 and s.gate_queue:
        i = s.gate_queue[0]
        yield f"entitle {i}", replace(
            s, entitled=i, gate_queue=s.gate_queue[1:],
            publication=put(s.publication, i, True))
    for i in range(2):
        if s.publication[i]:
            yield f"publish {i}", replace(
                s, publication=put(s.publication, i, False),
                writer_queue=put(s.writer_queue, i, s.writer_queue[i] + (i,)))
        if s.phase[i] == "pending":
            yield f"cancel {i}", replace(
                s, phase=put(s.phase, i, "aborted"),
                gate_queue=tuple(x for x in s.gate_queue if x != i),
                entitled=-1 if s.entitled == i else s.entitled)
        if (s.running[i] is None and s.writer_queue[i]
                and sum(x is not None for x in s.running) < workers):
            yield f"writer claim {i}", replace(
                s, running=put(s.running, i, s.writer_queue[i][0]),
                writer_queue=put(s.writer_queue, i, s.writer_queue[i][1:]))
        if s.running[i] == -1:
            yield f"older work ends {i}", replace(s, running=put(s.running, i, None))
        if s.running[i] == i:
            if s.phase[i] == "aborted":
                yield f"stale wake {i}", replace(s, running=put(s.running, i, None))
            elif s.phase[i] == "pending" and s.entitled == i and s.active == -1:
                yield f"commit claim {i}", replace(
                    s, phase=put(s.phase, i, "claimed"), active=i)
            elif s.phase[i] == "claimed":
                yield f"install {i}", replace(
                    s, phase=put(s.phase, i, "committed"),
                    resource=put(s.resource, i, "history"),
                    installed=s.installed + (i,), active=-1, entitled=-1,
                    running=put(s.running, i, None))
        if s.phase[i] == "aborted" and s.resource[i] == "reserved":
            yield f"release reservation {i}", replace(
                s, resource=put(s.resource, i, "released"))
        if (s.phase[i] in ("aborted", "committed") and not s.retired[i]
                and s.resource[i] != "reserved"):
            yield f"retire ticket {i}", replace(s, retired=put(s.retired, i, True))


def check(s):
    assert len(set(s.installed)) == len(s.installed)
    assert list(s.installed) == sorted(s.installed), "FIFO overtaking"
    if s.active != -1:
        assert s.entitled == s.active
        assert s.running[s.active] == s.active, "gate held without writer execution"
    assert sum(p == "claimed" for p in s.phase) == (s.active != -1)
    for i in range(2):
        assert (i in s.installed) == (s.resource[i] == "history")
        assert (s.phase[i] == "committed") == (i in s.installed)
        assert s.resource[i] != "released" or s.phase[i] == "aborted"
        assert not s.retired[i] or s.resource[i] != "reserved"
        # Exactly one retained publication/event/running reference until consumed.
        assert (int(s.publication[i]) + s.writer_queue[i].count(i)
                + int(s.running[i] == i)) <= 1
    if s.sealed:
        assert all(s.retired) and s.closing and s.active == -1


def terminal(s):
    return (s.sealed and not any(s.publication)
            and not any(s.writer_queue) and all(x is None for x in s.running))


def explore(workers):
    start = State()
    todo, seen, reverse = deque([start]), {start}, {}
    transitions = 0
    terminals = set()
    while todo:
        s = todo.popleft()
        check(s)
        if terminal(s):
            terminals.add(s)
        for label, n in successors(s, workers):
            transitions += 1
            reverse.setdefault(n, set()).add(s)
            if n not in seen:
                seen.add(n)
                todo.append(n)
    reachable, todo = set(terminals), deque(terminals)
    while todo:
        for p in reverse.get(todo.popleft(), ()):
            if p not in reachable:
                reachable.add(p)
                todo.append(p)
    assert reachable == seen, "state with no completion/cleanup path"
    print(f"PASS workers={workers}: {len(seen)} states, {transitions} transitions; "
          "invariants and path to full cleanup from every state")


def wake_litmus():
    # Enumerate producer release before/after atomic check-and-register.
    for release_first in (True, False):
        busy, waiting, runnable = True, False, False
        order = ("release", "register") if release_first else ("register", "release")
        for event in order:
            if event == "release":
                busy = False
                runnable |= waiting
            elif busy:
                waiting = True
            else:
                runnable = True
        assert runnable
    # Negative control: check -> release -> register, without recheck/handshake.
    busy, waiting, runnable = True, False, False
    observed_busy = busy
    busy = False
    runnable |= waiting
    waiting = observed_busy
    assert waiting and not runnable and not busy
    print("PASS wake litmus; broken split check/register strands the waiter")


if __name__ == "__main__":
    explore(1)
    explore(2)
    wake_litmus()
