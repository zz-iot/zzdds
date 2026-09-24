"""Replacement/cancellation extension of the two-chain admission model.

One child per chain; one external replacement or removal per scenario. Atomic
invalidation, immutable claimed invocations, and fresh FIFO admission after change.
No application object memory, OS wake delivery, or DDS deletion return semantics.
"""
from collections import deque
from dataclasses import dataclass, replace
from itertools import product

from listener_delegation_model import State, cyclic, put, successors


@dataclass(frozen=True)
class Model:
    admission: State
    targets: tuple
    changed: bool = False
    generation: tuple = (0, 0)
    claimed: tuple = (-1, -1)


def scripts(m):
    return tuple((target,) for target in m.targets)


def advance(m, roots, target, replacement, unsafe=False):
    s = m.admission
    for label, n in successors(s, roots, scripts(m)):
        claimed = m.claimed
        for i in range(2):
            if s.phase[i] == 'wait' and n.phase[i] == 'child':
                claimed = put(claimed, i, m.generation[i])
        yield label, replace(m, admission=n, claimed=claimed)
    if not m.changed:
        # Replacement publication is independent of a setter's later drain wait.
        generation = put(m.generation, target, 1)
        phase = s.phase[target]
        n, targets = s, m.targets
        if phase in ('ready', 'wait'):
            if replacement:
                targets = put(targets, target, replacement)
                if not unsafe:
                    n = replace(s, queue=tuple(i for i in s.queue if i != target),
                                phase=put(s.phase, target, 'ready'))
                # Unsafe mode changes rights in place without readmission.
            else:
                n = replace(s, queue=tuple(i for i in s.queue if i != target),
                            phase=put(s.phase, target, 'done'))
        # A claim already won: keep its rights and generation until it finishes.
        yield 'replace' if replacement else 'remove', replace(
            m, admission=n, targets=targets, generation=generation, changed=True)


def explore(roots, targets, target, replacement, unsafe=False):
    start = Model(State(held=roots), targets)
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    while todo:
        m = todo.popleft()
        s = m.admission
        if cyclic(s, scripts(m)):
            assert unsafe
            return len(seen), sum(map(len, edges.values())), paths[m], seen
        assert not s.held[0] & s.held[1]
        assert set(s.queue) == {i for i in range(2) if s.phase[i] == 'wait'}
        ns = list(advance(m, roots, target, replacement, unsafe))
        edges[m] = ns
        for label, n in ns:
            for i in range(2):
                if s.phase[i] == 'wait' and n.admission.phase[i] == 'child':
                    assert n.claimed[i] == m.generation[i]
                if s.phase[i] == 'child':
                    assert n.claimed[i] == m.claimed[i]
            if n not in seen:
                seen.add(n)
                paths[n] = paths[m] + (label,)
                todo.append(n)
    # Require completion after the external event too: it cannot rescue a stuck
    # state merely by remaining available forever.
    reachable = {m for m in seen if m.changed and m.admission.phase == ('terminal', 'terminal')}
    while True:
        more = {m for m in seen if any(n in reachable for _, n in edges[m])}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == seen
    return len(seen), sum(map(len, edges.values())), None, seen


def main():
    cases = states = transitions = 0
    old_claim = fresh_claim = removed_wait = False
    for roots in product(range(4), repeat=2):
        if roots[0] & roots[1]:
            continue
        for targets in product(range(1, 4), repeat=2):
            for target, replacement in product(range(2), range(4)):
                count, edges, witness, seen = explore(roots, targets, target, replacement)
                assert witness is None
                cases += 1
                states += count
                transitions += edges
                old_claim |= any(m.changed and m.admission.phase[target] == 'child'
                                 and m.claimed[target] == 0 for m in seen)
                fresh_claim |= any(m.claimed[target] == 1 for m in seen)
                removed_wait |= replacement == 0 and any(
                    m.changed and m.admission.phase[target] == 'done'
                    and m.claimed[target] == -1 for m in seen)
    assert old_claim and fresh_claim and removed_wait
    print(f'PASS: {cases} scenarios, {states} scenario-states, {transitions} transitions')
    print('Exclusion, current-generation claims, retained old claims, queue cleanup, completion paths.')
    # A holds X; B queues X+Y. A initially requests inherited X, then replacement
    # changes its child to Y. Keeping that queue entry creates the FIFO cycle.
    _, _, witness, _ = explore((1, 0), (1, 3), 0, 2, unsafe=True)
    assert witness is not None
    print('NEGATIVE CONTROL: changing queued rights without readmission creates a cycle: '
          + ' -> '.join(witness))


if __name__ == '__main__':
    main()
