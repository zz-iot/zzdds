"""Two-reader status fixture for the accepted delegation boundary.

Fixed membership (readers 0 and 1), one traversal, one optional new arrival and
one optional independent read/reset. Dispatch claim/reset is atomic here.
Run: python3 docs/design/listener_status_model.py
"""
from collections import deque
from dataclasses import dataclass, replace
from itertools import product


@dataclass(frozen=True)
class State:
    pending: tuple
    subscriber: bool
    cursor: int = 0
    phase: str = 'visit'
    busy: bool = True
    arrived: bool = False
    read: bool = False
    invoked: tuple = ()


def set_at(values, i, value):
    return values[:i] + (value,) + values[i + 1:]


def successors(s, arrival_reader, read_reader, unsafe=False):
    if not s.arrived:
        yield 'arrival', replace(s, arrived=True, subscriber=True,
                                pending=set_at(s.pending, arrival_reader, True))
    if not s.read:
        yield 'independent read/reset', replace(
            s, read=True, subscriber=False, pending=set_at(s.pending, read_reader, False))
    if s.busy:
        yield 'release contending callback', replace(s, busy=False)
    if s.cursor == 2:
        return
    i = s.cursor
    if s.phase in ('visit', 'wait'):
        if not s.pending[i]:
            yield 'skip/withdraw', replace(s, cursor=i + 1, phase='visit')
        elif s.busy:
            if s.phase == 'visit':
                yield 'wait without consumption', replace(s, phase='wait')
        else:
            yield 'claim/reset', replace(
                s, phase='callback', pending=set_at(s.pending, i, False),
                subscriber=False, invoked=s.invoked + (i,))
    elif s.phase == 'callback':
        n = replace(s, cursor=i + 1, phase='visit')
        if unsafe:
            n = replace(n, pending=set_at(s.pending, i, False), subscriber=False)
        yield 'callback return', n


def explore(initial, arrival_reader, read_reader, unsafe=False):
    start = State(initial, any(initial))
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    witnesses = set()
    while todo:
        s = todo.popleft()
        assert len(s.invoked) == len(set(s.invoked))
        ns = list(successors(s, arrival_reader, read_reader, unsafe))
        edges[s] = ns
        for label, n in ns:
            if label == 'callback return':
                if (n.pending, n.subscriber) != (s.pending, s.subscriber):
                    assert unsafe
                    return len(seen), sum(map(len, edges.values())), paths[s] + (label,), witnesses
            if label == 'wait without consumption':
                assert (n.pending, n.subscriber) == (s.pending, s.subscriber)
            if label == 'claim/reset':
                assert s.pending[s.cursor] and not s.busy
                assert not n.pending[s.cursor] and not n.subscriber
            if label == 'skip/withdraw' and s.phase == 'wait' and s.busy:
                witnesses.add('withdraw while rights still busy')
            if not s.subscriber and any(s.pending):
                witnesses.add('subscriber false with reader pending')
            if label == 'callback return' and s.pending[s.cursor]:
                witnesses.add('arrival during callback preserved')
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    terminal = {s for s in seen if s.cursor == 2 and s.arrived and s.read and not s.busy}
    reachable = set(terminal)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return len(seen), sum(map(len, edges.values())), None, witnesses


def main():
    states = transitions = cases = 0
    witnesses = set()
    for initial in product((False, True), repeat=2):
        for arrival_reader, read_reader in product(range(2), repeat=2):
            count, edges, failure, found = explore(initial, arrival_reader, read_reader)
            assert failure is None
            cases += 1
            states += count
            transitions += edges
            witnesses |= found
    assert len(witnesses) == 3
    print(f'PASS: {cases} scenarios, {states} scenario-states, {transitions} transitions')
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    _, _, failure, _ = explore((True, False), 0, 1, unsafe=True)
    assert failure
    print('NEGATIVE CONTROL: return-time reset erases newer state: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
