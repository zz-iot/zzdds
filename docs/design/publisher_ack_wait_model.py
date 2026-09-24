"""Bounded Publisher ACK aggregation, independent of the writer ACK model.

Two selected writers, one later write on B, one excluded later writer. A single
logical deadline covers capture and ACK progress. Atomics here are requirements
for a future implementation, not a claim that it already has these transitions.
"""
from collections import deque
from dataclasses import dataclass, replace


def put(values, i, value):
    return values[:i] + (value,) + values[i + 1:]


@dataclass(frozen=True)
class State:
    committed: tuple = (1, 1)
    acked: tuple = (0, 0)
    target: tuple = (-1, -1)  # -1: capture outstanding
    child: tuple = ('U', 'U')  # uncaptured, waiting, OK, failed
    closed: tuple = (False, False)
    later_writer: bool = False
    suspended: bool = False
    parent_closed: bool = False
    expired: bool = False
    remaining: int = 2  # counts uncaptured children too
    expected: str = ''
    result: str = ''
    notified: bool = False
    delivered: bool = False


def resolve(s, n, event, fault):
    completed = sum(a != 'O' and b == 'O' for a, b in zip(s.child, n.child))
    remaining = s.remaining - completed
    if fault == 'omit_uncaptured':
        remaining = n.child.count('W')
    n = replace(n, remaining=remaining)
    # Reference: complete child state vector, independent of counter implementation.
    expected = s.expected
    if not expected:
        if event == 'deadline':
            expected = 'TIMEOUT'
        elif event == 'parent close':
            expected = 'ALREADY_DELETED'
        elif 'E' in n.child:
            expected = 'ERROR'
        elif n.child == ('O', 'O'):
            expected = 'OK'
    result = s.result
    if not result:
        if event == 'deadline':
            result = 'TIMEOUT'
        elif event == 'parent close':
            result = 'ERROR' if fault == 'teardown_first' else 'ALREADY_DELETED'
        elif 'E' in n.child:
            result = 'ERROR'
        elif (remaining == 0 and fault != 'resolve_on_notification'
              and n.target != (-1, -1)):
            result = 'OK'
    return replace(n, expected=expected, result=result)


def steps(s, fault):
    events = []
    if not s.parent_closed:
        if not s.later_writer:
            events.append(('create excluded writer C', replace(s, later_writer=True)))
        if s.suspended:
            events.append(('external resume/end', replace(s, suspended=False)))
        if not s.closed[1] and s.committed[1] == 1:
            events.append(('commit B sequence 2', replace(s, committed=(1, 2))))
        for i, name in enumerate(('A', 'B')):
            if s.closed[i]:
                continue
            if s.target[i] == -1 and not s.result and not s.expired:
                target = s.committed[i]
                status = 'O' if s.acked[i] >= target else 'W'
                events.append(('capture ' + name, replace(s,
                    target=put(s.target, i, target), child=put(s.child, i, status))))
            if not s.suspended and s.acked[i] < s.committed[i]:
                ack = s.acked[i] + 1
                status = s.child[i]
                if status == 'W' and ack >= s.target[i]:
                    status = 'O'
                events.append((f'ACK {name} sequence {ack}', replace(s,
                    acked=put(s.acked, i, ack), child=put(s.child, i, status))))
            status = s.child[i] if s.child[i] == 'O' else 'E'
            events.append(('close ' + name, replace(s,
                closed=put(s.closed, i, True), child=put(s.child, i, status))))
        events.append(('parent close', replace(s, parent_closed=True, closed=(True, True))))
    if not s.expired:
        events.append(('deadline', replace(s, expired=True)))
    for event, n in events:
        yield event, resolve(s, n, event, fault)
    if s.expected and not s.notified:
        n = replace(s, notified=True)
        if fault == 'resolve_on_notification' and not s.result:
            n = replace(n, result='TIMEOUT' if s.expired else s.expected)
        yield 'aggregation notification serviced', n
    if s.result and s.notified and not s.delivered:
        yield 'caller wakes', replace(s, delivered=True)


def explore(suspended=False, fault=None):
    start = State(suspended=suspended)
    todo, paths = deque([start]), {start: ()}
    edges = 0
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.result and s.result != s.expected:
            return len(paths), edges, paths[s], witnesses
        if fault is None:
            assert s.result == s.expected
            assert s.remaining == sum(c != 'O' for c in s.child)
            assert not s.delivered or (s.notified and s.result)
        if 'O' in s.child and 'U' in s.child and not s.result:
            witnesses.add('completed child does not hide uncaptured child')
        if s.result == 'ERROR' and -1 in s.target:
            witnesses.add('child close during capture fails aggregate')
        if s.result == 'OK':
            if s.target[1] == 1 and s.committed[1] == 2 and s.acked[1] == 1:
                witnesses.add('post-capture write excluded')
            if s.target[1] == 2:
                witnesses.add('pre-capture concurrent write included')
            if s.later_writer:
                witnesses.add('later writer excluded')
            if any(s.closed) and not s.parent_closed:
                witnesses.add('completed child survives deletion')
            if s.expired and not s.notified:
                witnesses.add('success survives deadline before notification')
            if suspended and not s.suspended:
                witnesses.add('external resume enables completion')
        if s.result == 'ALREADY_DELETED':
            witnesses.add('parent close precedes child teardown')
        if s.result == 'TIMEOUT' and -1 in s.target:
            witnesses.add('shared deadline includes capture')
        for event, n in steps(s, fault):
            edges += 1
            if s.result:
                assert n.result == s.result
            if s.expected:
                assert n.expected == s.expected
            for i in range(2):
                if s.target[i] != -1:
                    assert n.target[i] == s.target[i]
                if s.child[i] == 'O':
                    assert n.child[i] == 'O'
            if n not in paths:
                paths[n] = paths[s] + (event,)
                todo.append(n)
        if not s.result and fault is None:
            assert not s.expired
            assert any(n.result for _, n in steps(s, fault))
    return len(paths), edges, None, witnesses


def main():
    witnesses = set()
    for suspended in (False, True):
        states, edges, failure, found = explore(suspended)
        assert failure is None
        witnesses |= found
        print(f'PASS suspended={suspended}: {states} states, {edges} transitions')
    assert len(witnesses) == 10, witnesses
    for w in sorted(witnesses):
        print('Witness: ' + w)
    for fault in ('omit_uncaptured', 'resolve_on_notification', 'teardown_first'):
        _, _, failure, _ = explore(fault=fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))
    # Deliberately delay notification past expiry after both children finish.
    trace = ('capture A', 'ACK A sequence 1', 'capture B', 'ACK B sequence 1',
             'deadline', 'aggregation notification serviced', 'caller wakes')
    for fault in (None, 'resolve_on_notification'):
        s = State()
        for event in trace:
            s = dict(steps(s, fault))[event]
        assert s.expected == 'OK'
        assert s.result == ('TIMEOUT' if fault else 'OK')
    print('NEGATIVE CONTROL delayed resolution at deadline: ' + ' -> '.join(trace))


if __name__ == '__main__':
    main()
