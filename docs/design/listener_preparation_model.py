"""Finite optimistic callback preparation model, not a binding/runtime test.

One candidate, two permitted snapshots, two updates and one getter; invocation can fail.
Version counts both publication and consumption. Counter conservation is an oracle.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    phase: str = 'start'
    version: int = 0
    pending: int = 1
    total: int = 1
    observed: int = 0
    snapshot: tuple | None = None
    attempts: int = 0
    updated: int = 0
    getter: bool = False
    frame: bool = False
    retained: bool = False
    recursion_checked: bool = False
    commits: int = 0
    outcome: str = ''


def steps(s, fault=None):
    if s.updated < 2:
        yield 'new change', replace(s, updated=s.updated + 1, version=s.version + 1,
                                    pending=s.pending + 1, total=s.total + 1)
    if not s.getter:
        yield 'getter consumes', replace(s, getter=True, version=s.version + 1,
            observed=s.observed + s.pending, pending=0)
    if s.phase == 'start':
        yield 'install frame', replace(s, phase='snapshot', frame=True, retained=True)
    elif s.phase == 'snapshot':
        if not s.pending:
            yield 'skip ineligible', replace(s, phase='cleanup', outcome='skip')
        elif s.attempts == 2:
            yield 'retry exhausted', replace(s, phase='cleanup', outcome='exhausted')
        else:
            yield 'capture', replace(s, phase='prepare', attempts=s.attempts + 1,
                                    snapshot=(s.version, s.pending))
    elif s.phase == 'prepare':
        if not s.recursion_checked:
            assert s.frame
            yield 'reject recursive same-target preparation', replace(s, recursion_checked=True)
        yield 'preparation fails', replace(s, phase='cleanup', outcome='prepare_error')
        yield 'arguments ready', replace(s, phase='validate')
    elif s.phase == 'validate':
        if s.snapshot[0] == s.version or fault == 'stale_snapshot':
            yield 'commit', replace(s, phase='invoke', commits=s.commits + 1,
                observed=s.observed + s.snapshot[1], pending=0, version=s.version + 1)
        else:
            yield 'invalidate/retry', replace(s, phase='snapshot', snapshot=None)
    elif s.phase == 'invoke':
        yield 'invocation succeeds', replace(s, phase='cleanup', outcome='success')
        n = replace(s, phase='cleanup', outcome='invoke_error')
        if fault == 'rollback':
            # Wrong even when entry is uncertain: another observer can have run.
            n = replace(n, pending=n.pending + s.snapshot[1])
        yield 'invocation fails', n
    elif s.phase == 'cleanup':
        yield 'retire foreign cleanup', replace(s, phase='done', frame=False, retained=False,
                                              snapshot=None)


def explore(fault=None):
    start = State()
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    outcomes, witnesses = set(), set()
    while todo:
        s = todo.popleft()
        if s.observed + s.pending != s.total:
            assert fault
            return len(seen), sum(map(len, edges.values())), paths[s], outcomes, witnesses
        assert s.commits <= 1 and s.attempts <= 2
        assert s.frame == s.retained == (s.phase not in ('start', 'done'))
        if s.phase == 'done':
            outcomes.add(s.outcome)
            if s.commits and s.pending:
                witnesses.add('new changes survive committed invocation cleanup')
        if s.recursion_checked:
            witnesses.add('recursive preparation rejected while frame retained')
        ns = list(steps(s, fault))
        edges[s] = ns
        for label, n in ns:
            if label in ('preparation fails', 'retry exhausted', 'invalidate/retry',
                         'reject recursive same-target preparation', 'retire foreign cleanup'):
                assert (n.pending, n.observed, n.version) == (s.pending, s.observed, s.version)
            if label == 'commit' and not fault:
                assert s.snapshot == (s.version, s.pending) and s.pending > 0
            if label == 'invocation fails' and not fault:
                assert (n.pending, n.observed) == (s.pending, s.observed)
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    terminal = {s for s in seen if s.phase == 'done' and s.updated == 2 and s.getter}
    reachable = set(terminal)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return len(seen), sum(map(len, edges.values())), None, outcomes, witnesses


def main():
    states, edges, failure, outcomes, witnesses = explore()
    assert failure is None
    # Two arrivals can invalidate both permitted captures while status stays pending.
    assert outcomes == {'skip', 'prepare_error', 'success', 'invoke_error', 'exhausted'}, outcomes
    assert len(witnesses) == 2
    print(f'PASS: {states} states, {edges} transitions; conservation, single commit, cleanup, completion paths')
    print('Outcomes reached: ' + ', '.join(sorted(outcomes)))
    for w in sorted(witnesses):
        print('Witness: ' + w)
    for fault in ('stale_snapshot', 'rollback'):
        _, _, failure, _, _ = explore(fault)
        assert failure
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
