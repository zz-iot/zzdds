"""Finite single-reader deletion model; atomic precondition check plus close.

One callback, loan publisher and condition creator; each completes once. Callback
claim/entry/finish/hook retirement are separate. Failed deletion can be retried.
No protocol, real pointers, binding calls or operation-specific DDS error mapping.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    closed: bool = False
    returned: bool = False
    callback: str = 'pending'
    hook_done: bool = False
    loan: str = 'ready'
    condition: str = 'ready'
    prechecked: bool = False


def steps(s, mode, unsafe=False):
    if s.callback == 'pending':
        if s.closed:
            yield 'withdraw callback', replace(s, callback='done')
        else:
            yield 'claim callback', replace(s, callback='claimed')
    elif s.callback == 'claimed':
        yield 'enter callback', replace(s, callback='entered')
    elif s.callback == 'entered':
        yield 'finish callback', replace(s, callback='done')
    if s.callback == 'done' and not s.hook_done:
        yield 'retire context hook', replace(s, hook_done=True)
    for resource in ('loan', 'condition'):
        phase = getattr(s, resource)
        if phase == 'ready':
            yield f'{resource}: reject closed' if s.closed else f'{resource}: publish', replace(
                s, **{resource: 'done' if s.closed else 'live'})
        elif phase == 'live':
            yield f'{resource}: release', replace(s, **{resource: 'done'})
    if not s.closed:
        # Self-deletion runs from this callback; the other callback-context case
        # assumes an independent root callback, not an extra modeled reader.
        allowed = mode != 'self' or s.callback == 'entered'
        clear = s.loan != 'live' and s.condition != 'live'
        if allowed and clear:
            if unsafe and not s.prechecked:
                yield 'precheck deletion', replace(s, prechecked=True)
            elif not unsafe:
                yield 'close deletion', replace(s, closed=True,
                    callback='done' if s.callback == 'pending' else s.callback)
        if unsafe and allowed and s.prechecked:
            yield 'close using stale precheck', replace(s, closed=True,
                callback='done' if s.callback == 'pending' else s.callback)
        if allowed and not clear:
            # Failure is observable but has no state mutation or progress. Keep
            # its self-loop out of BFS; verify its identity result in the audit.
            assert failed_delete(s) == s
    if s.closed and not s.returned:
        if mode != 'external' or (s.callback == 'done' and s.hook_done
                                 and s.loan == 'done' and s.condition == 'done'):
            yield 'delete returns', replace(s, returned=True)


def failed_delete(s):
    assert not s.closed and (s.loan == 'live' or s.condition == 'live')
    return s


def explore(mode, unsafe=False):
    start = State()
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.closed and (s.loan == 'live' or s.condition == 'live'):
            assert unsafe
            return seen, edges, paths[s], witnesses
        if mode == 'external' and s.returned:
            assert s.callback == 'done' and s.hook_done
            assert s.loan == 'done' and s.condition == 'done'
        if s.returned and s.callback == 'claimed':
            witnesses.add('delete returns before claimed callback enters')
        if s.returned and s.callback == 'entered':
            witnesses.add('delete returns during callback')
        if s.closed and s.callback == 'done' and not s.hook_done and not s.returned:
            witnesses.add('hook retirement after callback completion')
        ns = list(steps(s, mode, unsafe))
        edges[s] = ns
        for label, n in ns:
            if label == 'claim callback':
                assert not s.closed
            if label.endswith(': publish'):
                assert not s.closed
            if label == 'close deletion':
                assert s.loan != 'live' and s.condition != 'live'
                if s.callback == 'pending':
                    assert n.callback == 'done'
                    witnesses.add('unclaimed callback withdrawn at close')
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    # Self callback may return without deleting (e.g. resource preconditions fail).
    # That terminal outcome does not claim successful deletion.
    done = {s for s in seen if s.callback == 'done' and s.hook_done
            and s.loan == 'done' and s.condition == 'done'
            and (s.returned or (mode == 'self' and not s.closed))}
    reachable = set(done)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return seen, edges, None, witnesses


def main():
    for mode in ('external', 'other_callback', 'self'):
        seen, edges, failure, witnesses = explore(mode)
        assert failure is None
        assert any(s.returned for s in seen)
        if mode == 'other_callback':
            assert 'delete returns before claimed callback enters' in witnesses
        if mode == 'self':
            assert 'delete returns during callback' in witnesses
        print(f'PASS {mode}: {len(seen)} states, {sum(map(len, edges.values()))} transitions')
    # Verify both resource publications can invalidate a separated precheck.
    for resource in ('loan', 'condition'):
        s = State(prechecked=True, **{resource: 'live'})
        n = next(n for label, n in steps(s, 'external', True)
                 if label == 'close using stale precheck')
        assert n.closed and getattr(n, resource) == 'live'
    _, _, failure, _ = explore('external', unsafe=True)
    assert failure
    print('NEGATIVE CONTROL: precheck/close gap permits deletion with live resource: '
          + ' -> '.join(failure))
    print('Both loan and condition stale-precheck witnesses confirmed.')


if __name__ == '__main__':
    main()
