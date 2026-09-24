"""Bounded subtree reservation experiment; atomic metadata transitions.

Two old children, one initial loan, one callback attempting another loan, and
one creator under the surviving root. Retirement/storage and DDS codes omitted.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    phase: str = 'ready'
    reserved: bool = False
    scan: int = 0
    loan0: bool = False
    callback: str = 'publish'
    loan1: bool = False
    old_closed: tuple = (False, False)
    creator: str = 'ready'
    new_target: bool = False
    new_closed: bool = False


def steps(s, fault):
    if s.loan0:
        yield 'return old loan', replace(s, loan0=False)
    if s.creator == 'ready' and not s.reserved:
        # If publication precedes reservation, child joins the deletion set.
        yield 'create child', replace(s, creator='done', new_target=s.phase == 'ready')
    if s.callback == 'publish' and (not s.reserved or fault == 'late_publication'):
        yield 'callback observes close' if s.old_closed[1] else 'callback publishes loan', replace(
            s, callback='finish' if s.old_closed[1] else 'return_loan',
            loan1=not s.old_closed[1])
    if s.callback == 'return_loan':
        yield 'callback returns loan', replace(s, callback='finish', loan1=False)
    if s.callback == 'finish':
        yield 'callback finishes', replace(s, callback='done')
    if s.phase == 'ready':
        yield 'reserve subtree', replace(s, phase='scan', reserved=True)
    elif s.phase == 'scan':
        blocker = (s.loan0, s.loan1)[s.scan]
        if blocker:
            yield 'abort preflight', replace(s, phase='aborted', reserved=False)
        elif s.scan == 0:
            yield 'check child 0', replace(s, scan=1)
        else:
            yield 'check child 1', replace(s, phase='commit')
    elif s.phase == 'commit':
        yield 'commit close', replace(s, phase='drain', old_closed=(True, True),
            new_closed=s.new_target, reserved=fault == 'hold_through_drain')
    elif s.phase == 'drain' and s.callback == 'done':
        yield 'external delete returns', replace(s, phase='done', reserved=False)


def explore(initial_loan, fault=None):
    start = State(loan0=initial_loan)
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    found = set()
    while todo:
        s = todo.popleft()
        if any(s.old_closed) and (s.loan0 or s.loan1):
            assert fault == 'late_publication'
            return len(seen), sum(map(len, edges.values())), paths[s], found
        assert s.old_closed in ((False, False), (True, True))
        if s.phase == 'aborted':
            assert not any(s.old_closed) and not s.new_closed and not s.reserved
        if s.phase in ('drain', 'done'):
            assert s.new_closed == s.new_target
        if s.phase == 'done':
            assert s.callback == 'done'
        if s.phase == 'drain' and s.callback == 'publish' and not s.reserved:
            found.add('reservation released before blocked callback drains')
        if s.creator == 'done' and not s.new_target and s.phase in ('drain', 'done'):
            found.add('post-commit creation survives old deletion')
        if s.new_target and s.new_closed:
            found.add('pre-reservation creation included')
        ns = list(steps(s, fault))
        edges[s] = ns
        terminal = (s.phase in ('done', 'aborted') and s.callback == 'done'
                    and s.creator == 'done' and not s.loan0)
        if not ns and not terminal:
            assert fault == 'hold_through_drain'
            return len(seen), sum(map(len, edges.values())), paths[s], found
        for label, n in ns:
            if label == 'callback publishes loan' and not fault:
                assert not s.reserved
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    done = {s for s in seen if s.phase in ('done', 'aborted') and s.callback == 'done'
            and s.creator == 'done' and not s.loan0}
    reachable = set(done)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return len(seen), sum(map(len, edges.values())), None, found


def main():
    found = set()
    for initial_loan in (False, True):
        states, edges, failure, witnesses = explore(initial_loan)
        assert failure is None
        found |= witnesses
        print(f'PASS initial_loan={initial_loan}: {states} states, {edges} transitions')
    assert len(found) == 3
    for witness in sorted(found):
        print('Witness: ' + witness)
    for fault in ('late_publication', 'hold_through_drain'):
        _, _, failure, _ = explore(False, fault)
        assert failure
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
