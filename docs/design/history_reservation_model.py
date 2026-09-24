"""Depth-one logical-credit model; physical memory/QoS eligibility are inputs.

Two requests compete for one instance. Independent policy removal may remove
the original victim before commit. No pointer/index/atomic implementation.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    resident: str = "old"
    owner: int = -1
    phase: tuple = ("waiting", "waiting")
    old_removed: bool = False


def update(s, i, p, **kw):
    phases = list(s.phase)
    phases[i] = p
    return replace(s, phase=tuple(phases), **kw)


def successors(s):
    if s.resident == "old":
        # If owner exists, empty credit remains exclusively reserved to it.
        yield replace(s, resident="", old_removed=True)
    for i in range(2):
        if s.phase[i] == "waiting":
            yield update(s, i, "cancelled")
            if s.owner == -1 and not any(p == "waiting" for p in s.phase[:i]):
                yield update(s, i, "reserved", owner=i)
        if s.phase[i] == "reserved":
            yield update(s, i, "cancelled", owner=-1)
            yield update(s, i, "committed", owner=-1, resident=str(i))


def check(s):
    assert sum(p == "reserved" for p in s.phase) == (s.owner != -1)
    if s.owner != -1:
        assert s.phase[s.owner] == "reserved"
    if s.resident in ("0", "1"):
        assert s.phase[int(s.resident)] == "committed"
    assert not s.old_removed or s.resident != "old"
    # One logical slot: occupied OR reserved-free OR generally free.
    occupied = bool(s.resident)
    reserved_free = not occupied and s.owner != -1
    free = not occupied and s.owner == -1
    assert int(occupied) + int(reserved_free) + int(free) == 1


def main():
    todo, seen, reverse, count = deque([State()]), {State()}, {}, 0
    while todo:
        s = todo.popleft()
        check(s)
        for n in successors(s):
            count += 1
            # Cancellation never removes live data or resurrects removed data.
            if any(a != "cancelled" and b == "cancelled"
                   for a, b in zip(s.phase, n.phase)):
                assert n.resident == s.resident
            reverse.setdefault(n, set()).add(s)
            if n not in seen:
                seen.add(n)
                todo.append(n)
    done = {s for s in seen if all(p in ("cancelled", "committed") for p in s.phase)}
    todo = deque(done)
    while todo:
        for s in reverse.get(todo.popleft(), ()):
            if s not in done:
                done.add(s)
                todo.append(s)
    assert done == seen
    print(f"PASS: {len(seen)} states, {count} transitions; exclusive logical credit, "
          "cancellation preservation and completion reachability")


if __name__ == "__main__":
    main()
