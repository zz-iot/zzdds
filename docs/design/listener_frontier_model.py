"""Bounded descendant frontier model: two old children, one post-capture child.

Atomic accounting/capture; callback and final hook retire separately. Detached
parent retains ancestry. Internal storage pins are independent of application use.
Run: python3 docs/design/listener_frontier_model.py
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    attached: tuple = (True, True, False)
    use: tuple = (0, 0, -1)  # -1 absent; 0 callback; 1 hook; 2 application-quiescent
    pins: tuple = (True, True, False)
    parent_attached: bool = True
    frontier: tuple | None = None
    later_created: bool = False
    returned: bool = False


def put(values, i, value):
    return values[:i] + (value,) + values[i + 1:]


def ready(s, fault):
    if fault == 'max_completion':
        # Wrong: completion IDs can have holes.
        return max((i for i, u in enumerate(s.use) if u == 2), default=-1) >= max(s.frontier, default=-1)
    return all(s.use[i] == 2 for i in s.frontier)


def steps(s, fault):
    for i in range(3):
        if s.attached[i]:
            yield f'detach {i}', replace(s, attached=put(s.attached, i, False))
        if s.use[i] in (0, 1):
            yield f'{i}: finish ' + ('callback' if s.use[i] == 0 else 'hook'), replace(
                s, use=put(s.use, i, s.use[i] + 1))
        if s.pins[i] and s.use[i] == 2 and not s.attached[i]:
            yield f'{i}: release storage pin', replace(s, pins=put(s.pins, i, False))
    if s.parent_attached and not any(s.attached[:2]):
        yield 'detach intermediate parent', replace(s, parent_attached=False)
    if s.frontier is None:
        covered = (0, 1)
        if fault == 'live_only':
            covered = tuple(i for i in covered if s.attached[i] and s.parent_attached)
        # A bulk commit closes all old live members while capturing previously
        # detached lifetimes. New child creation is enabled only afterwards.
        yield 'capture/close old set', replace(s, frontier=covered,
                                              attached=(False, False, False))
    if s.frontier is not None and not s.later_created:
        yield 'create later child 2', replace(s, later_created=True,
            attached=put(s.attached, 2, True), use=put(s.use, 2, 0), pins=put(s.pins, 2, True))
    if s.frontier is not None and not s.returned and ready(s, fault):
        yield 'barrier returns', replace(s, returned=True)


def explore(fault=None):
    start = State()
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.returned and any(s.use[i] != 2 for i in (0, 1)):
            assert fault
            return len(seen), sum(map(len, edges.values())), paths[s], witnesses
        if fault is None and s.frontier is not None:
            assert s.frontier == (0, 1)
        if s.returned and any(s.pins[:2]):
            witnesses.add('barrier returns while old storage remains pinned')
        if s.returned and s.use[2] in (0, 1):
            witnesses.add('later child does not extend captured wait')
        if s.frontier is not None and s.use[0] != 2 and s.use[1] == 2 and not s.returned:
            witnesses.add('newer completion cannot hide unfinished older use')
        if not s.parent_attached and s.frontier is not None and s.use[0] != 2:
            witnesses.add('detached intermediate parent preserves ancestry coverage')
        ns = list(steps(s, fault))
        edges[s] = ns
        for label, n in ns:
            if s.frontier is not None:
                assert n.frontier == s.frontier
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    done = {s for s in seen if s.returned and s.later_created and all(u == 2 for u in s.use)
            and not any(s.attached) and not any(s.pins) and not s.parent_attached}
    reachable = set(done)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return len(seen), sum(map(len, edges.values())), None, witnesses


def main():
    states, edges, failure, witnesses = explore()
    assert failure is None and len(witnesses) == 4
    print(f'PASS: {states} states, {edges} transitions; fixed frontier, safe return, completion paths')
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('live_only', 'max_completion'):
        _, _, failure, _ = explore(fault)
        assert failure
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
