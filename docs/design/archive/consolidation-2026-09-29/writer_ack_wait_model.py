"""Finite ACK-wait model: one captured write, two association generations.

Later write, new match, same-GUID rematch, stale old-generation ACK, deadline,
close and delayed caller wake interleave. Atomic transitions represent writer-owned
state changes, not packet arrival. This is not an RTPS implementation or proof.
Run: python3 docs/design/writer_ack_wait_model.py
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    # Bits: original A, original B, rematched A, newly matched C.
    active: int = 3
    acked: int = 0
    removed: int = 0
    later_write: bool = False
    matched_c: bool = False
    rematched_a: bool = False
    closed: bool = False
    expired: bool = False
    result: str = ''
    expected: str = ''
    delivered: bool = False


def settle(old, new, event, fault):
    # Independent reference ledger: only two captured obligations can complete.
    expected = old.expected
    if not expected:
        if event == 'deadline':
            expected = 'TIMEOUT'
        elif event == 'close':
            expected = 'ALREADY_DELETED'
        elif (new.acked | new.removed) & 3 == 3:
            expected = 'OK'
    result = old.result
    if not result:
        if fault == 'close_empty_success' and event == 'close':
            result = 'OK'  # Wrong: proxy destruction precedes completion.
        elif event == 'deadline':
            result = 'TIMEOUT'
        elif event == 'close':
            result = 'ALREADY_DELETED'
        else:
            covered = new.active if fault == 'live_membership' else new.active & 3
            acknowledgments = new.acked
            if fault == 'guid_reuse' and new.rematched_a:
                # Wrong: treat the new A as the old covered association.
                covered = (covered & ~1) | 4
            if covered & ~acknowledgments == 0:
                result = 'OK'
    return replace(new, expected=expected, result=result)


def steps(s, fault):
    events = []
    if not s.closed:
        if not s.later_write:
            events.append(('later write', replace(s, later_write=True)))
        if not s.matched_c:
            events.append(('match C', replace(s, matched_c=True, active=s.active | 8)))
        if s.removed & 1 and not s.rematched_a:
            events.append(('rematch A generation 2', replace(s, rematched_a=True,
                                                            active=s.active | 4)))
        for bit, name in ((1, 'A generation 1'), (2, 'B')):
            if s.active & bit:
                events.append(('unmatch ' + name, replace(s, active=s.active & ~bit,
                                                         removed=s.removed | bit)))
        for bit, name in ((1, 'A generation 1'), (2, 'B'), (4, 'A generation 2'), (8, 'C')):
            # Old captured records may arrive after removal; generation stays exact.
            if ((s.active | s.removed) & bit) and not s.acked & bit:
                events.append(('ACK captured sequence: ' + name,
                               replace(s, acked=s.acked | bit)))
        events.append(('close', replace(s, closed=True, active=0)))
    if not s.expired:
        events.append(('deadline', replace(s, expired=True)))
    for event, n in events:
        yield event, settle(s, n, event, fault)
    if s.result and not s.delivered:
        yield 'caller wakes', replace(s, delivered=True)


def explore(fault=None):
    start = State()
    todo, paths = deque([start]), {start: ()}
    transitions = 0
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.result != s.expected:
            return len(paths), transitions, paths[s], witnesses
        if s.result == 'OK':
            if s.later_write:
                witnesses.add('later write does not extend target')
            if s.active & 8 and not s.acked & 8:
                witnesses.add('later match does not extend target')
            if s.active & 4 and not s.acked & 4:
                witnesses.add('same-GUID rematch does not revive obligation')
            if s.removed & ~s.acked & 3:
                witnesses.add('unmatch can complete without delivery evidence')
            if s.expired and s.closed and s.delivered:
                witnesses.add('success survives deadline and close before caller wake')
        if s.result == 'ALREADY_DELETED' and s.expired and s.delivered:
            witnesses.add('close outcome survives later deadline')
        if s.result == 'TIMEOUT' and s.acked & 3 == 3:
            witnesses.add('late ACK cannot undo timeout')
        for event, n in steps(s, fault):
            transitions += 1
            if s.result:
                assert n.result == s.result
            if s.expected:
                assert n.expected == s.expected
            if n not in paths:
                paths[n] = paths[s] + (event,)
                todo.append(n)
        # Every unresolved state has an immediate deadline-completion path;
        # every completed state has a caller-wake path. No fairness claim.
        if not s.result and fault is None:
            assert not s.expired
            assert any(n.result for _, n in steps(s, fault))
    return len(paths), transitions, None, witnesses


def initial_poll(target, reliable_associations, already_acked, expired):
    if target == 0 or reliable_associations & ~already_acked == 0:
        return 'OK'
    return 'TIMEOUT' if expired else ''


def main():
    assert initial_poll(0, 3, 0, True) == 'OK'
    assert initial_poll(1, 0, 0, True) == 'OK'
    assert initial_poll(1, 3, 3, True) == 'OK'
    assert initial_poll(1, 3, 1, True) == 'TIMEOUT'
    assert initial_poll(1, 3, 1, False) == ''
    states, transitions, failure, witnesses = explore()
    assert failure is None and len(witnesses) == 7, (failure, witnesses)
    print(f'PASS: {states} states, {transitions} transitions; 5 initial polling cases')
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('live_membership', 'close_empty_success', 'guid_reuse'):
        _, _, failure, _ = explore(fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
