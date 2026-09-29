"""Bounded retirement: final owner released inside callback, one timer and I/O.

Logical cancellation and completion are separate. A retained shutdown obligation
moves from callback frame to outer driver, optionally to an external executor.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    retiring: bool = False
    callback: bool = True
    progress: str = 'frame'
    timer: str = 'armed'  # armed, cancelled, running, done
    rearmed: bool = False
    io: str = 'pending'  # pending, cancelled, done
    backend: bool = True
    executor: bool = True
    storage: bool = True
    observer: bool = True  # e.g. retained WaitSet identity
    fault: str = ''


def drained(s):
    return not s.callback and s.timer == 'done' and s.io == 'done'


def steps(s, external, fault):
    if not s.retiring:
        yield 'final operational owner releases', replace(s, retiring=True)
    if s.retiring and s.callback:
        yield 'callback and binding unwind', replace(s, callback=False,
            progress='none' if fault == 'lost_handoff' else 'driver')
    if s.progress == 'driver' and external:
        yield 'transfer to registered external executor', replace(s, progress='external')
    can_service = s.progress == ('external' if external else 'driver')
    if s.timer == 'armed':
        yield 'timer begins in-flight callback', replace(s, timer='running')
        if s.retiring and can_service:
            yield 'request timer cancellation', replace(s, timer='cancelled')
    if s.timer == 'cancelled' and can_service:
        yield 'timer cancellation completes', replace(s, timer='done')
    if s.timer == 'running':
        yield 'timer callback retires', replace(s, timer='done')
        if not s.rearmed and (not s.retiring or fault == 'rearm_after_retire'):
            yield 'timer rearms', replace(s, timer='armed', rearmed=True,
                fault='timer rearmed during retirement' if s.retiring else s.fault)
    if s.io == 'pending':
        yield 'I/O completes', replace(s, io='done')
        if s.retiring and can_service:
            yield 'request I/O cancellation', replace(s,
                io='done' if fault == 'cancel_is_completion' else 'cancelled',
                fault='cancel request dropped pending completion reference'
                if fault == 'cancel_is_completion' else s.fault)
    if s.io == 'cancelled':
        yield 'late I/O completion retires', replace(s, io='done')
    if s.retiring and can_service and s.backend:
        if drained(s) or fault == 'early_backend_stop':
            yield 'stop backend', replace(s, backend=False)
    if s.retiring and s.executor and not s.callback:
        if not s.backend or fault == 'early_executor_exit':
            yield 'final executor exits', replace(s, executor=False, progress='none')
    if s.observer:
        yield 'release stopped-identity observer', replace(s, observer=False)
    if not s.backend and not s.executor and not s.observer and s.storage:
        yield 'reclaim runtime storage', replace(s, storage=False)


def explore(external=False, fault=None):
    start = State()
    todo, paths, graph = deque([start]), {start: ()}, {}
    witnesses = set()
    while todo:
        s = todo.popleft()
        bad = bool(s.fault) or (not s.backend and not drained(s))
        bad |= s.retiring and s.backend and s.progress == 'none'
        bad |= not s.storage and (s.backend or s.executor or s.observer or not drained(s))
        if bad:
            return len(paths), sum(map(len, graph.values())), paths[s], witnesses
        if s.retiring and s.callback and s.progress == 'frame':
            witnesses.add('callback retains retirement obligation until unwind')
        if s.retiring and s.timer == 'running':
            witnesses.add('in-flight timer can retire after final owner release')
        if s.retiring and s.io == 'cancelled' and s.backend:
            witnesses.add('I/O cancellation retains backend until completion')
        if not s.backend and s.observer and s.storage:
            witnesses.add('stopped identity does not keep backend operational')
        if s.progress == 'external':
            witnesses.add('external-loop handoff retains progress responsibility')
        if not s.storage:
            witnesses.add('runtime eventually reclaimable after all references retire')
        ns = list(steps(s, external, fault))
        graph[s] = ns
        for label, n in ns:
            if n not in paths:
                paths[n] = paths[s] + (label,)
                todo.append(n)
    reachable = {s for s in paths if not s.storage}
    while True:
        more = {s for s, ns in graph.items() if any(n in reachable for _, n in ns)}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == set(paths), 'state without a cleanup path'
    return len(paths), sum(map(len, graph.values())), None, witnesses


def main():
    witnesses = set()
    for external in (False, True):
        states, edges, failure, found = explore(external)
        assert failure is None
        witnesses |= found
        print(f'PASS external={external}: {states} states, {edges} transitions; cleanup reachable')
    assert len(witnesses) == 6, witnesses
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('lost_handoff', 'rearm_after_retire', 'cancel_is_completion',
                  'early_backend_stop', 'early_executor_exit'):
        _, _, failure, _ = explore(fault=fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
