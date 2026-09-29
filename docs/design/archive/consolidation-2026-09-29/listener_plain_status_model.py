"""One-entity, two-kind plain-status ordering model; atomic claim/getter/reset.

Finite ordered updates interleave with callback claim/return and one getter.
Counters are generic additive status fields; scenarios instantiate match counts
and liveliness net deltas. No DDS bindings, routing, or actual wake delivery.
"""
from collections import deque
from dataclasses import dataclass, replace


ZERO = ((0, 0), (0, 0))


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def put(values, i, value):
    return values[:i] + (value,) + values[i + 1:]


@dataclass(frozen=True)
class State:
    update: int = 0
    totals: tuple = ZERO
    deltas: tuple = ZERO
    observed: tuple = ZERO
    changed: tuple = (False, False)
    queue: tuple = ()
    active: tuple | None = None
    getter_done: bool = False


def transitions(s, updates, getter, unsafe=False):
    if s.update < len(updates):
        kind, delta = updates[s.update]
        yield 'update', replace(
            s, update=s.update + 1,
            totals=put(s.totals, kind, add(s.totals[kind], delta)),
            deltas=put(s.deltas, kind, add(s.deltas[kind], delta)),
            changed=put(s.changed, kind, True),
            queue=s.queue if kind in s.queue else s.queue + (kind,))
    if not s.getter_done:
        yield 'getter', replace(
            s, getter_done=True, deltas=put(s.deltas, getter, (0, 0)),
            observed=put(s.observed, getter, add(s.observed[getter], s.deltas[getter])),
            changed=put(s.changed, getter, False),
            queue=tuple(k for k in s.queue if k != getter))
    if s.active is None and s.queue:
        k = s.queue[0]
        yield 'claim', replace(
            s, active=(k, s.totals[k], s.deltas[k]), queue=s.queue[1:],
            observed=put(s.observed, k, add(s.observed[k], s.deltas[k])),
            deltas=put(s.deltas, k, (0, 0)), changed=put(s.changed, k, False))
    if s.active is not None:
        n = replace(s, active=None)
        if unsafe:
            k = s.active[0]
            n = replace(n, deltas=put(n.deltas, k, (0, 0)),
                        changed=put(n.changed, k, False),
                        queue=tuple(i for i in n.queue if i != k))
        yield 'return', n


def explore(updates, getter, unsafe=False):
    start = State()
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    witnesses = set()
    while todo:
        s = todo.popleft()
        for k in range(2):
            if add(s.observed[k], s.deltas[k]) != s.totals[k]:
                assert unsafe
                return len(seen), sum(map(len, edges.values())), paths[s], witnesses
        assert set(s.queue) == {k for k in range(2) if s.changed[k]}
        assert len(s.queue) == len(set(s.queue))
        ns = list(transitions(s, updates, getter, unsafe))
        edges[s] = ns
        for label, n in ns:
            if label == 'claim':
                assert n.active[0] == s.queue[0]
                if n.active[2] == (0, 0):
                    witnesses.add('zero-net change still dispatched')
            if label == 'update' and s.queue and updates[s.update][0] in s.queue:
                assert n.queue == s.queue
                witnesses.add('coalescing preserves queue position')
            if s.active and label != 'return':
                assert n.active == s.active
            if label == 'return' and not unsafe:
                assert n.deltas == s.deltas and n.queue == s.queue
                if s.active[0] in s.queue:
                    witnesses.add('new same-kind work survives callback return')
            if label == 'getter' and getter in s.queue:
                witnesses.add('getter withdraws pending notification')
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    done = {s for s in seen if s.update == len(updates) and s.getter_done
            and not s.queue and s.active is None}
    reachable = set(done)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return len(seen), sum(map(len, edges.values())), None, witnesses


def take(s, updates, label):
    return next(n for name, n in transitions(s, updates, 0) if name == label)


def main():
    match = ((0, (1, 1)), (1, (1, 0)), (0, (0, -1)))
    live = ((0, (-1, 1)), (1, (1, 0)), (0, (1, -1)))
    hot = ((0, (1, 1)), (1, (1, 0)), (0, (1, 1)), (0, (1, 1)))
    counts = [0, 0]
    found = set()
    for updates in (match, live, hot):
        for getter in range(2):
            states, edges, failure, witnesses = explore(updates, getter)
            assert failure is None
            counts[0] += states
            counts[1] += edges
            found |= witnesses
    assert len(found) == 4
    # Explicit arithmetic oracle: match, unrelated update, unmatch before claim.
    s = State()
    for _ in match:
        s = take(s, match, 'update')
    s = take(s, match, 'claim')
    assert s.active == (0, (1, 0), (1, 0)) and s.queue == (1,)
    # A kind already active must rejoin behind a different kind waiting for service.
    s = take(State(), hot, 'update')
    s = take(s, hot, 'claim')
    s = take(s, hot, 'update')
    s = take(s, hot, 'update')
    assert s.queue == (1, 0)
    print(f'PASS: 6 scenarios, {counts[0]} scenario-states, {counts[1]} transitions')
    print('Counter conservation, FIFO claims, immutable arguments, completion paths; arithmetic and hot-kind traces.')
    for witness in sorted(found):
        print('Witness: ' + witness)
    _, _, failure, _ = explore(hot, 1, unsafe=True)
    assert failure
    print('NEGATIVE CONTROL: return-time reset loses unobserved deltas: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
