"""Two competing takes of a two-sample batch, with one invalidating state update.

Retained identity and version are abstract; no real decoding/loan storage. A small
retry limit exercises exhaustion, not the proposed production default of four.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    available: int = 3
    version: int = 0
    updated: bool = False
    live: bool = True
    phase: tuple = ('select', 'select')
    snapshot: tuple = ((0, 0), (0, 0))
    retries: tuple = (0, 0)
    result: tuple = ('', '')
    taken: tuple = (0, 0)
    bad: bool = False


def put(xs, i, value):
    return xs[:i] + (value,) + xs[i+1:]


def finish(s, i, result):
    return replace(s, phase=put(s.phase, i, 'done'), result=put(s.result, i, result))


def steps(s, limit, fault):
    if s.live:
        yield 'reader close', replace(s, live=False)
        if not s.updated:
            yield 'relevant state changes', replace(s, updated=True, version=s.version+1)
        if s.available & 1:
            yield 'sample 1 expires', replace(s, available=s.available & ~1, version=s.version+1)
    for i in range(2):
        if s.phase[i] == 'select':
            if not s.live:
                yield f'{i}: closed', finish(s, i, 'ALREADY_DELETED')
            elif not s.available:
                yield f'{i}: empty', finish(s, i, 'NO_DATA')
            elif s.retries[i] >= limit:
                yield f'{i}: exhausted', finish(s, i, 'NO_DATA' if fault == 'false_empty' else 'ERROR')
            else:
                yield f'{i}: prepare batch', replace(s, phase=put(s.phase, i, 'prepared'),
                    snapshot=put(s.snapshot, i, (s.available, s.version)))
        if s.phase[i] == 'prepared':
            if not s.live:
                yield f'{i}: close before commit', finish(s, i, 'ALREADY_DELETED')
                continue
            mask, version = s.snapshot[i]
            valid = mask == s.available and version == s.version
            if valid or fault == 'skip_validation':
                n = finish(s, i, 'OK')
                yield f'{i}: commit batch', replace(n, available=s.available & ~mask,
                    taken=put(s.taken, i, mask), version=s.version+1, bad=s.bad or not valid)
            elif fault == 'commit_survivors' and mask & s.available:
                n = finish(s, i, 'OK')
                yield f'{i}: commit surviving subset', replace(n, available=0,
                    taken=put(s.taken, i, mask & s.available), bad=True)
            else:
                yield f'{i}: discard conflicted preparation', replace(s,
                    phase=put(s.phase, i, 'select'), retries=put(s.retries, i, s.retries[i]+1))


def explore(limit, fault=None):
    start = State()
    todo, paths, graph = deque([start]), {start: ()}, {}
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.bad or s.taken[0] & s.taken[1]:
            return len(paths), sum(map(len, graph.values())), paths[s], witnesses
        if 'ERROR' in s.result:
            witnesses.add('bounded conflict exhaustion')
        if 'OK' in s.result and 'NO_DATA' in s.result:
            witnesses.add('losing taker observes true empty state')
        if 'ALREADY_DELETED' in s.result:
            witnesses.add('close prevents uncommitted effects')
        if 'OK' in s.result and not s.live:
            witnesses.add('close preserves committed effects')
        if s.taken in ((2, 0), (0, 2)) and any(s.retries):
            witnesses.add('fresh selection after expiry can commit')
        ns = list(steps(s, limit, fault))
        graph[s] = ns
        for label, n in ns:
            for i in range(2):
                if s.result[i]:
                    assert n.result[i] == s.result[i] and n.taken[i] == s.taken[i]
                elif n.result[i] == 'NO_DATA' and (not s.live or s.available):
                    return len(paths), sum(map(len, graph.values())), paths[s]+(label,), witnesses
                if n.result[i] in ('ERROR', 'ALREADY_DELETED', 'NO_DATA'):
                    assert n.taken[i] == 0
            if n not in paths:
                paths[n] = paths[s]+(label,)
                todo.append(n)
    reachable = {s for s in paths if s.phase == ('done', 'done')}
    while True:
        more = {s for s, ns in graph.items() if any(n in reachable for _, n in ns)}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == set(paths)
    return len(paths), sum(map(len, graph.values())), None, witnesses


def main():
    witnesses = set()
    for limit in (1, 2, 4):
        states, edges, failure, found = explore(limit)
        assert failure is None
        witnesses |= found
        print(f'PASS limit={limit}: {states} states, {edges} transitions')
    assert len(witnesses) == 5, witnesses
    for w in sorted(witnesses):
        print('Witness: '+w)
    for fault in ('skip_validation', 'commit_survivors', 'false_empty'):
        _, _, failure, _ = explore(1, fault)
        assert failure
        print(f'NEGATIVE CONTROL {fault}: '+' -> '.join(failure))


if __name__ == '__main__':
    main()
