"""One admitted WaitSet request; bounded level changes and membership changes.

Scan, park registration, wake service and caller delivery are separate steps.
Notification/park arbitration is atomic here: concrete synchronization is not proven.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    phase: str = 'scan'
    attached: bool = False
    generation: int = 0
    attached_once: bool = False
    detached_once: bool = False
    reattached: bool = False
    level: bool = True
    raised: bool = True
    reset: bool = False
    condition_live: bool = True
    ws_live: bool = True
    notified: bool = False
    stale_sent: bool = False
    expired: bool = False
    second_called: bool = False
    second_result: str = ''
    result: str = ''
    selected_generation: int = -1
    bad_success: bool = False


def eligible(s):
    return s.attached and s.condition_live and s.level


def terminal(s, result):
    return s if s.result else replace(s, result=result, phase='terminal',
        selected_generation=s.generation if result == 'OK' else -1,
        bad_success=result == 'OK' and not eligible(s))


def steps(s, fault):
    if s.ws_live and s.condition_live:
        if not s.attached_once:
            yield 'attach already-true condition' if s.level else 'attach condition', replace(s,
                attached=True, attached_once=True,
                notified=s.notified or fault != 'omit_attach_wake')
        if s.attached and not s.detached_once:
            yield 'detach', replace(s, attached=False, detached_once=True, notified=True)
        if s.detached_once and not s.attached and not s.reattached:
            yield 'reattach generation 1', replace(s, attached=True, generation=1,
                                                  reattached=True, notified=True)
        if not s.raised:
            yield 'trigger true', replace(s, level=True, raised=True,
                                         notified=s.notified or s.attached)
        if s.level and not s.reset:
            yield 'reset false', replace(s, level=False, reset=True,
                                        notified=s.notified or s.attached)
    if s.condition_live:
        yield 'condition delete', replace(s, condition_live=False, attached=False, notified=True)
    if s.ws_live:
        yield 'WaitSet close', terminal(replace(s, ws_live=False, attached=False), 'ALREADY_DELETED')
    if not s.expired:
        yield 'deadline', terminal(replace(s, expired=True), 'TIMEOUT')
    if not s.second_called and s.phase != 'done':
        yield 'second caller', replace(s, second_called=True,
            second_result='OK' if fault == 'allow_second' else 'PRECONDITION_NOT_MET')
    if not s.stale_sent:
        # A spurious/retired-attachment wake is only a recheck hint, never evidence.
        yield 'stale wake', replace(s, stale_sent=True, notified=True)
    if s.phase == 'scan':
        n = replace(s, notified=False)
        yield 'scan', terminal(n, 'OK') if eligible(n) else replace(n, phase='gap')
    if s.phase == 'gap':
        if fault == 'clear_at_park':
            yield 'park clearing notification', replace(s, phase='sleep', notified=False)
        elif s.notified:
            yield 'notification prevents park', replace(s, phase='scan')
        else:
            yield 'register sleep', replace(s, phase='sleep')
    if s.phase == 'sleep' and s.notified:
        yield 'service wake', terminal(s, 'OK') if fault == 'wake_is_success' else replace(s, phase='scan')
    if s.phase == 'terminal':
        yield 'publish output and release waiter slot', replace(s, phase='done')


def explore(initially_attached=False, fault=None):
    start = State(attached=initially_attached, attached_once=initially_attached,
                  level=not initially_attached, raised=not initially_attached)
    todo, paths, graph = deque([start]), {start: ()}, {}
    witnesses = set()
    while todo:
        s = todo.popleft()
        broken = s.bad_success or (s.second_called and s.second_result != 'PRECONDITION_NOT_MET')
        broken |= s.phase == 'sleep' and eligible(s) and not s.notified
        if broken:
            return len(paths), sum(map(len, graph.values())), paths[s], witnesses
        if s.phase == 'gap' and s.notified and eligible(s):
            witnesses.add('notification covers check-to-park gap')
        if s.phase == 'sleep' and s.reset and not s.level:
            witnesses.add('reset before observation can leave wait pending')
        if s.phase == 'sleep' and not s.condition_live:
            witnesses.add('condition deletion does not close WaitSet')
        if s.result == 'OK' and s.selected_generation == 1:
            witnesses.add('reattached generation can independently trigger')
        if s.result == 'OK' and s.expired and not s.ws_live and s.phase == 'done':
            witnesses.add('committed result survives close and deadline')
        if s.result == 'TIMEOUT' and eligible(s):
            witnesses.add('late observation cannot turn timeout into success')
        if s.phase == 'terminal' and s.second_called:
            witnesses.add('waiter slot remains occupied through output publication')
        ns = list(steps(s, fault))
        graph[s] = ns
        for label, n in ns:
            if s.result:
                assert n.result == s.result
                assert n.selected_generation == s.selected_generation
            if n not in paths:
                paths[n] = paths[s] + (label,)
                todo.append(n)
    reachable = {s for s in paths if s.phase == 'done'}
    while True:
        more = {s for s, ns in graph.items() if any(n in reachable for _, n in ns)}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == set(paths)
    return len(paths), sum(map(len, graph.values())), None, witnesses


def main():
    witnesses = set()
    for attached in (False, True):
        states, edges, failure, found = explore(attached)
        assert failure is None
        witnesses |= found
        print(f'PASS initially_attached={attached}: {states} states, {edges} transitions')
    assert len(witnesses) == 7, witnesses
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('omit_attach_wake', 'clear_at_park', 'wake_is_success', 'allow_second'):
        _, _, failure, _ = explore(fault=fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
