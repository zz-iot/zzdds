"""Bounded callback admission experiment; no threads, DDS status or object lifetime.

Run: python3 docs/design/listener_delegation_model.py
Atomic publication/check, two chains, two rights, all-or-retry FIFO admission.
"""
from collections import deque
from dataclasses import dataclass, replace
from itertools import product


@dataclass(frozen=True)
class State:
    held: tuple
    phase: tuple = ('ready', 'ready')
    step: tuple = (0, 0)
    queue: tuple = ()
    completed: tuple = (0, 0)
    rejected: tuple = (False, False)


def put(values, i, value):
    return values[:i] + (value,) + values[i + 1:]


def blockers(s, scripts, i, queue_edges=True):
    # Already held rights are inherited. An older waiter cannot revoke them.
    needed = scripts[i][s.step[i]] & ~s.held[i]
    result = {j for j in range(2) if j != i and s.held[j] & needed}
    if queue_edges:
        for j in s.queue[:s.queue.index(i)]:
            older_needed = scripts[j][s.step[j]] & ~s.held[j]
            if older_needed & needed:
                result.add(j)
    return result


def cyclic(s, scripts, queue_edges=True):
    graph = {i: blockers(s, scripts, i, queue_edges) for i in s.queue}
    def visit(i, path):
        return i in path or any(visit(j, path | {i}) for j in graph.get(i, ()))
    return any(visit(i, set()) for i in graph)


def successors(s, roots, scripts, queue_edges=True):
    for i in range(2):
        p = s.phase[i]
        if p == 'ready':
            candidate = replace(s, queue=s.queue + (i,),
                                phase=put(s.phase, i, 'wait'))
            if cyclic(candidate, scripts, queue_edges):
                yield f'{i}: reject cycle', replace(
                    s, phase=put(s.phase, i, 'done'),
                    rejected=put(s.rejected, i, True))
            else:
                yield f'{i}: publish', candidate
        elif p == 'wait' and not blockers(s, scripts, i):
            yield f'{i}: claim child', replace(
                s, held=put(s.held, i, s.held[i] | scripts[i][s.step[i]]),
                queue=tuple(j for j in s.queue if j != i),
                phase=put(s.phase, i, 'child'))
        elif p == 'child':
            step = s.step[i] + 1
            yield f'{i}: finish child', replace(
                s, held=put(s.held, i, roots[i]), step=put(s.step, i, step),
                completed=put(s.completed, i, s.completed[i] + 1),
                phase=put(s.phase, i, 'ready' if step < len(scripts[i]) else 'done'))
        elif p == 'done':
            yield f'{i}: return parent', replace(
                s, held=put(s.held, i, 0), phase=put(s.phase, i, 'terminal'))


def explore(roots, scripts, queue_edges=True):
    start = State(held=roots)
    todo, seen, edges, paths = deque([start]), {start}, {}, {start: ()}
    while todo:
        s = todo.popleft()
        assert not s.held[0] & s.held[1], 'exclusion violation'
        assert set(s.queue) == {i for i in range(2) if s.phase[i] == 'wait'}
        assert len(s.queue) == len(set(s.queue))
        if queue_edges:
            assert not cyclic(s, scripts), 'known dependency cycle'
        ns = list(successors(s, roots, scripts, queue_edges))
        edges[s] = ns
        for label, n in ns:
            if n not in seen:
                seen.add(n)
                paths[n] = paths[s] + (label,)
                todo.append(n)
    terminal = {s for s in seen if s.phase == ('terminal', 'terminal')}
    reachable = set(terminal)
    while True:
        more = {s for s in seen if any(n in reachable for _, n in edges[s])}
        if more <= reachable:
            break
        reachable |= more
    deadlocks = [s for s in seen if not edges[s] and s not in terminal]
    if queue_edges:
        assert reachable == seen, 'state has no completion path'
        assert not deadlocks
    return seen, sum(map(len, edges.values())), deadlocks, paths


def main():
    cases = states = transitions = 0
    inherited = partial = opposite = False
    # Enumerate every disjoint initial ownership and every one-child target pair.
    scenarios = [(r, ((a,), (b,)))
                 for r in product(range(4), repeat=2) if not r[0] & r[1]
                 for a, b in product(range(1, 4), repeat=2)]
    # Extra bounded batches expose earlier child effects followed by cycle error.
    scenarios += [((1, 2), ((1, 2), (2, 1))),
                  ((1, 0), ((1, 2), (3,)))]
    for roots, scripts in scenarios:
        seen, count, _, _ = explore(roots, scripts)
        cases += 1
        states += len(seen)
        transitions += count
        partial |= any(any(s.completed[i] and s.rejected[i] for i in range(2)) for s in seen)
        inherited |= roots == (1, 2) and scripts == ((1,), (2,)) and any(
            s.completed == (1, 1) for s in seen)
        opposite |= roots == (1, 2) and scripts == ((2,), (1,)) and any(
            any(s.rejected) for s in seen)
    assert inherited and partial and opposite
    print(f'PASS: {cases} scenarios, {states} scenario-states, {transitions} transitions')
    print('Exclusion, queue membership, acyclic dependencies, and a completion path from every state.')
    print('Witnesses: inherited rights, opposite-direction cycle rejection, partial batch then error.')
    # B queues X+Y while A holds X. A then needs free Y, behind B in FIFO.
    roots, scripts = (1, 0), ((2,), (3,))
    _, _, deadlocks, paths = explore(roots, scripts, queue_edges=False)
    assert deadlocks, 'negative control failed to expose hidden FIFO cycle'
    witness = min(deadlocks, key=lambda s: len(paths[s]))
    assert cyclic(witness, scripts) and not cyclic(witness, scripts, False)
    print('NEGATIVE CONTROL: owner-only detection deadlocks: ' + ' -> '.join(paths[witness]))
    print('Actual dependencies: chain 0 -> older queued chain 1 -> chain 0 holding X.')


if __name__ == '__main__':
    main()
