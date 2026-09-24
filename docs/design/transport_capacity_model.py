"""Bounded output capacity: one data slot, one reserved completion record.

One accepted send A and waiting producer B. Backend terminal event, completion
publication, consumption and cancellation are distinct. No real socket is modeled.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    phase: str = 'io'  # io, terminal, published, released
    terminal: str = ''
    cancel: bool = False
    retiring: bool = False
    slot: bool = True
    buffer: bool = True
    reserved: bool = True
    producer: str = 'waiting'  # waiting, ready, accepted, aborted
    notified: bool = False
    producer_cancel: bool = False
    stopped: bool = False
    releases: int = 0
    error: str = ''


def steps(s, fault):
    if not s.retiring:
        yield 'retirement begins', replace(s, retiring=True)
    if s.phase == 'io':
        for outcome in ('sent locally', 'I/O failure'):
            yield outcome, replace(s, phase='terminal', terminal=outcome)
        if not s.cancel:
            n = replace(s, cancel=True)
            if fault == 'release_on_cancel':
                n = replace(n, buffer=False, error='backend can still access freed buffer')
            yield 'request cancellation', n
        if s.cancel:
            yield 'cancellation completes', replace(s, phase='terminal', terminal='cancelled')
    if s.phase == 'terminal' and not (fault == 'completion_uses_data_slot' and s.slot):
        yield 'publish reserved completion', replace(s, phase='published')
    if s.phase == 'published':
        yield 'consume completion and release capacity', replace(s, phase='released',
            slot=False, buffer=False, reserved=False, releases=s.releases + 1,
            notified=fault != 'lost_capacity_wake')
    if s.producer == 'waiting' and s.notified:
        yield 'service producer wake', replace(s, producer='ready')
    if s.producer in ('waiting', 'ready'):
        if s.retiring or s.producer_cancel:
            yield 'abort unaccepted producer', replace(s, producer='aborted')
        elif s.producer == 'ready' and not s.slot:
            yield 'producer B accepted', replace(s, producer='accepted')
        if not s.producer_cancel:
            yield 'producer B cancellation requested', replace(s, producer_cancel=True)
    if s.producer == 'accepted':
        # B is an abstract independent obligation, retained until this terminal step.
        yield 'producer B completes', replace(s, producer='aborted')
    if s.retiring and not s.stopped:
        if (s.phase == 'released' and s.producer == 'aborted') or fault == 'early_stop':
            yield 'backend stops', replace(s, stopped=True)


def explore(fault=None):
    start = State()
    todo, paths, graph = deque([start]), {start: ()}, {}
    witnesses = set()
    while todo:
        s = todo.popleft()
        bad = bool(s.error) or s.releases > 1
        bad |= s.stopped and (s.phase != 'released' or s.producer != 'aborted')
        bad |= (s.phase != 'released') and not (s.buffer and s.reserved and s.slot)
        bad |= (s.phase == 'released') and (s.buffer or s.reserved or s.slot or s.releases != 1)
        bad |= (s.phase == 'released' and s.producer == 'waiting' and not s.notified
                and not s.retiring and not s.producer_cancel)
        if bad:
            return len(paths), sum(map(len, graph.values())), paths[s], witnesses
        if s.phase == 'published' and s.slot:
            witnesses.add('completion publishes while data capacity is full')
        if s.cancel and s.phase == 'io' and s.buffer:
            witnesses.add('cancel request preserves backend buffer lifetime')
        if s.producer == 'accepted':
            witnesses.add('capacity release wakes waiting producer')
        if s.retiring and s.phase == 'published':
            witnesses.add('retirement preserves completion service')
        if s.stopped and s.terminal == 'I/O failure':
            witnesses.add('failed I/O still releases resources and permits stop')
        if s.stopped and s.terminal == 'cancelled':
            witnesses.add('cancelled I/O releases resources exactly once')
        ns = list(steps(s, fault))
        graph[s] = ns
        for label, n in ns:
            if s.phase == 'released':
                assert n.releases == s.releases
            if n not in paths:
                paths[n] = paths[s] + (label,)
                todo.append(n)
    # Reverse reachability detects a capacity cycle even though application-level
    # cancellation/retirement events remain available in the state graph.
    reachable = {s for s in paths if s.stopped}
    while True:
        more = {s for s, ns in graph.items() if any(n in reachable for _, n in ns)}
        if more <= reachable:
            break
        reachable |= more
    if reachable != set(paths):
        blocked = [s for s in paths if s not in reachable and not graph[s]]
        stranded = min(blocked or [s for s in paths if s not in reachable],
                       key=lambda s: len(paths[s]))
        return len(paths), sum(map(len, graph.values())), paths[stranded] + ('no shutdown completion path',), witnesses
    return len(paths), sum(map(len, graph.values())), None, witnesses


def main():
    states, edges, failure, witnesses = explore()
    assert failure is None and len(witnesses) == 6, (failure, witnesses)
    print(f'PASS: {states} states, {edges} transitions; shutdown reachable from every state')
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('completion_uses_data_slot', 'release_on_cancel', 'lost_capacity_wake', 'early_stop'):
        _, _, failure, _ = explore(fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
