"""Bounded historical wait: one captured source, two covered sequence positions.

Protocol receipt/GAP accounting is separate from retained DDS processing. Boundary
and deadline events are logical observations, not a wire parser or timer backend.
"""
from collections import deque
from dataclasses import dataclass, replace


def put(values, i, value):
    return values[:i] + (value,) + values[i + 1:]


@dataclass(frozen=True)
class State:
    boundary: bool = False  # when known, the fixed upper boundary is 2
    source: bool = True
    reader: bool = True
    disposition: tuple = ('?', '?')  # unknown, Pending, Admitted, reJected, eXcluded, Gap, Failed
    accounted: int = 0
    pending: int = 0
    gap_seen: int = 0
    later_match: bool = False
    later_traffic: bool = False
    expired: bool = False
    silence_checked: bool = False
    result: str = ''
    expected: str = ''
    delivered: bool = False


def resolve(old, new, event, fault):
    expected = old.expected
    if not expected:
        if event == 'deadline':
            expected = 'TIMEOUT'
        elif event == 'reader close':
            expected = 'ALREADY_DELETED'
        elif 'F' in new.disposition:
            expected = 'ERROR'
        elif event == 'source unmatch' and (not new.boundary or '?' in new.disposition):
            expected = 'ERROR'
        elif new.boundary and all(d in ('A', 'J', 'X', 'G') for d in new.disposition):
            expected = 'OK'
    result = old.result
    if not result:
        if event == 'deadline':
            result = 'TIMEOUT'
        elif event == 'reader close':
            result = 'ALREADY_DELETED'
        elif 'F' in new.disposition:
            result = 'ERROR'
        elif event == 'source unmatch':
            if fault == 'unmatch_success':
                result = 'OK'
            elif fault == 'unmatch_always_error' or not new.boundary or new.accounted != 3:
                result = 'ERROR'
        if not result and new.boundary and new.accounted == 3:
            if new.pending == 0 or fault == 'protocol_only':
                result = 'OK'
        if not result and fault == 'silence_success' and event == 'observe silence':
            result = 'OK'
    return replace(new, expected=expected, result=result)


def steps(s, finite, evidence, fault):
    events = []
    if s.reader:
        if s.source:
            if evidence and not s.boundary:
                events.append(('establish boundary H=2', replace(s, boundary=True)))
            if not s.later_traffic:
                events.append(('later traffic beyond H', replace(s, later_traffic=True)))
            for i in range(2):
                bit = 1 << i
                if s.disposition[i] == '?':
                    events.append((f'DATA {i+1}', replace(s,
                        disposition=put(s.disposition, i, 'P'),
                        accounted=s.accounted | bit, pending=s.pending | bit)))
                if evidence and not s.gap_seen & bit:
                    disp = 'G' if s.disposition[i] == '?' else s.disposition[i]
                    pending = s.pending & ~bit if fault == 'gap_erases_local' else s.pending
                    events.append((f'GAP {i+1}', replace(s,
                        disposition=put(s.disposition, i, disp), gap_seen=s.gap_seen | bit,
                        accounted=s.accounted | bit, pending=pending)))
            events.append(('source unmatch', replace(s, source=False)))
        if not s.later_match:
            events.append(('new association excluded', replace(s, later_match=True)))
        # Local work outlives source/proxy removal; receipt already retained it.
        for i in range(2):
            if s.disposition[i] == 'P':
                for disposition, name in (('A', 'admit'), ('J', 'reject'),
                                          ('X', 'exclude by policy'), ('F', 'internal failure')):
                    events.append((f'{name} {i+1}', replace(s,
                        disposition=put(s.disposition, i, disposition), pending=s.pending & ~(1 << i))))
        events.append(('reader close', replace(s, reader=False)))
    if finite and not s.expired:
        events.append(('deadline', replace(s, expired=True)))
    if not s.silence_checked:
        events.append(('observe silence', replace(s, silence_checked=True)))
    for event, n in events:
        yield event, resolve(s, n, event, fault)
    if s.result and not s.delivered:
        yield 'caller wakes', replace(s, delivered=True)


def explore(finite=True, evidence=True, fault=None):
    start = State()
    todo, paths = deque([start]), {start: ()}
    edges = 0
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.result != s.expected:
            return len(paths), edges, paths[s], witnesses
        if s.boundary and s.accounted == 3 and s.pending and not s.result:
            witnesses.add('protocol completion waits for local processing')
            if not s.source:
                witnesses.add('local processing survives source removal')
        if s.result == 'OK':
            if 'G' in s.disposition:
                witnesses.add('GAP completes accounting without payload receipt')
            if 'J' in s.disposition:
                witnesses.add('recorded rejection is completed processing')
            if s.expired and not s.reader and s.delivered:
                witnesses.add('committed success survives close and timeout')
            if s.later_match and s.later_traffic:
                witnesses.add('later association and traffic do not extend target')
        if s.result == 'ERROR' and not s.source and not s.boundary:
            witnesses.add('unmatch before boundary interrupts transfer')
        if s.result == 'ERROR' and 'F' in s.disposition:
            witnesses.add('internal failure cannot silently complete')
        if not evidence and s.result == 'TIMEOUT':
            witnesses.add('absent completion evidence times out')
        if not finite and not evidence and s.reader and s.source and s.silence_checked and not s.pending and not s.result:
            witnesses.add('infinite wait can remain pending without evidence')
        for event, n in steps(s, finite, evidence, fault):
            edges += 1
            if s.result:
                assert n.result == s.result
            if s.boundary:
                assert n.boundary
            if n not in paths:
                paths[n] = paths[s] + (event,)
                todo.append(n)
        if not s.result:
            # Every unresolved state can terminate via reader close. This is not
            # eventual success or fairness; absent that event infinite waits persist.
            assert s.reader
            assert any(n.result for _, n in steps(s, finite, evidence, fault))
    return len(paths), edges, None, witnesses


def main():
    witnesses = set()
    for finite, evidence in ((True, True), (True, False), (False, False)):
        states, edges, failure, found = explore(finite, evidence)
        assert failure is None
        witnesses |= found
        print(f'PASS finite={finite} evidence={evidence}: {states} states, {edges} transitions')
    assert len(witnesses) == 10, witnesses
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('protocol_only', 'gap_erases_local', 'unmatch_success',
                  'unmatch_always_error', 'silence_success'):
        _, _, failure, _ = explore(fault=fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
