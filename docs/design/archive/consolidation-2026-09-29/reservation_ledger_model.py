"""Finite multi-reservation model: two writes competing for the same instance.

Run: python3 docs/design/reservation_ledger_model.py
Models depth-one replacement, physical-node budget, delayed reclamation,
head-only ticket/gate admission, cancellation and one coherent boundary.
Not a model of actual atomics, QoS eligibility, or writer-context scheduling.
"""
from collections import deque
from dataclasses import dataclass, replace

INSTANCE = (0, 0)


def put(xs, i, x):
    return xs[:i] + (x,) + xs[i + 1:]


@dataclass(frozen=True)
class State:
    phase: tuple = ("new",) * 2
    ledger: tuple = ((),)
    resident: tuple = (-2,)
    allocated: frozenset = frozenset((-2,))
    garbage: frozenset = frozenset()
    ticket: tuple = (-1,) * 2
    retired: tuple = (False,) * 2
    gate: tuple = ()
    active: int = -1
    log: tuple = ()
    closing: bool = False
    sealed: bool = False


def remove_ledger(s, i):
    k = INSTANCE[i]
    return put(s.ledger, k, tuple(x for x in s.ledger[k] if x != i))


def steps(s, limit, budget):
    if not s.closing:
        yield "close", replace(s, closing=True)
    if s.closing and not s.sealed and all(
            t != 0 or s.retired[i] for i, t in enumerate(s.ticket)):
        yield "seal", replace(s, sealed=True)
    for k, victim in enumerate(s.resident):
        if victim is not None:
            # Removal is assumed policy-permitted; entitlement stays in ledger.
            yield "policy removal", replace(s, resident=put(s.resident, k, None),
                                             garbage=s.garbage | {victim})
    for victim in s.garbage:
        yield "reclaim", replace(s, garbage=s.garbage - {victim},
                                 allocated=s.allocated - {victim})
    for i, p in enumerate(s.phase):
        k = INSTANCE[i]
        if p == "new" and len(s.ledger[k]) < limit and len(s.allocated) < budget:
            # Fixed per-instance preparation order for this finite scenario.
            if not any(INSTANCE[j] == k and s.phase[j] == "new" for j in range(i)):
                yield "prepare", replace(s, phase=put(s.phase, i, "prepared"),
                    ledger=put(s.ledger, k, s.ledger[k] + (i,)),
                    allocated=s.allocated | {i})
        if p in ("new", "prepared", "ticketed", "queued"):
            yield "cancel", replace(s, phase=put(s.phase, i, "cancelled"),
                ledger=remove_ledger(s, i), gate=tuple(x for x in s.gate if x != i),
                garbage=s.garbage | ({i} if i in s.allocated else set()))
        if p == "prepared" and s.ledger[k][0] == i and (not s.closing or s.sealed):
            yield "ticket", replace(s, phase=put(s.phase, i, "ticketed"),
                                    ticket=put(s.ticket, i, int(s.sealed)))
        if p == "ticketed":
            yield "enqueue gate", replace(s, phase=put(s.phase, i, "queued"),
                                           gate=s.gate + (i,))
        if p == "queued" and s.active == -1 and s.gate[0] == i:
            yield "claim", replace(s, phase=put(s.phase, i, "claimed"), active=i,
                                   gate=s.gate[1:])
        if p == "claimed":
            victim = s.resident[k]
            yield "install", replace(s, phase=put(s.phase, i, "committed"),
                resident=put(s.resident, k, i), ledger=remove_ledger(s, i),
                garbage=s.garbage | ({victim} if victim is not None else set()),
                active=-1, log=s.log + (i,))
        if p in ("cancelled", "committed") and not s.retired[i]:
            yield "retire", replace(s, retired=put(s.retired, i, True))


def check(s, limit, budget):
    assert len(s.allocated) <= budget
    live = {v for v in s.resident if v is not None}
    prepared = {i for i, p in enumerate(s.phase)
                if p in ("prepared", "ticketed", "queued", "claimed")}
    assert not (live & prepared or live & s.garbage or prepared & s.garbage)
    assert s.allocated == live | prepared | s.garbage
    assert len(set(s.log)) == len(s.log)
    assert not (0 in s.log and 1 in s.log) or s.log.index(0) < s.log.index(1)
    for k, entries in enumerate(s.ledger):
        assert len(entries) <= limit
        assert all(INSTANCE[i] == k and i in prepared for i in entries)
    for i, p in enumerate(s.phase):
        if p in ("ticketed", "queued", "claimed"):
            assert s.ledger[INSTANCE[i]][0] == i
        assert (i in s.log) == (p == "committed")
        if s.sealed and s.ticket[i] == 0:
            assert s.retired[i]
    assert sum(p == "claimed" for p in s.phase) == (s.active != -1)
    assert [s.ticket[i] for i in s.log] == sorted(s.ticket[i] for i in s.log)


def explore(limit, budget):
    start = State()
    seen, todo, reverse, edges = {start}, deque([start]), {}, 0
    reverse_no_cancel = {}
    while todo:
        s = todo.popleft()
        check(s, limit, budget)
        for label, n in steps(s, limit, budget):
            if label == "cancel":
                assert n.resident == s.resident
            edges += 1
            reverse.setdefault(n, set()).add(s)
            if label != "cancel":
                reverse_no_cancel.setdefault(n, set()).add(s)
            if n not in seen:
                seen.add(n)
                todo.append(n)
    done = {s for s in seen if all(s.retired) and s.sealed and not s.garbage}
    reached, todo = set(done), deque(done)
    while todo:
        for p in reverse.get(todo.popleft(), ()):
            if p not in reached:
                reached.add(p)
                todo.append(p)
    assert reached == seen, "stranded state"
    # Stronger check: from every state, remaining noncancelled writes have
    # a completion path without using cancellation as an escape hatch.
    reached, todo = set(done), deque(done)
    while todo:
        for p in reverse_no_cancel.get(todo.popleft(), ()):
            if p not in reached:
                reached.add(p)
                todo.append(p)
    assert reached == seen, "completion requires additional cancellation"
    print(f"PASS limit={limit}, nodes={budget}: {len(seen)} states, {edges} transitions; "
          "ownership/order/bounds and completion without further cancellation")


if __name__ == "__main__":
    for configuration in ((1, 2), (2, 2), (2, 3)):
        explore(*configuration)
    # Negative control: successor owns gate while awaiting predecessor,
    # predecessor queues behind successor. Neither can install.
    ledger = (0, 1)
    incorrectly_admitted_gate = (1, 0)
    runnable_commits = [i for i in ledger
                        if i == ledger[0] and i == incorrectly_admitted_gate[0]]
    assert not runnable_commits
    print("COUNTEREXAMPLE: successor-first gate admission creates a dependency cycle")
