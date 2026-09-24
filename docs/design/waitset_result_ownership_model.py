"""Finite result-lease model: one condition and two attachment generations.

Native object, binding wrapper and result lease are distinct. Raw output remains
borrowed. Managed output owns its wrapper, not its deleted native object. Atomic
selection/retention is assumed; this does not validate a concrete lock protocol.
"""
from collections import deque
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    phase: str = 'candidate'
    attached: bool = True
    generation: int = 0
    reattached: bool = False
    live: bool = True
    ws_live: bool = True
    app_wrapper: bool = True
    native_pin: bool = False
    anchor_pin: bool = False
    output_wrapper: bool = False
    native_freed: bool = False
    wrapper_freed: bool = False
    outcome: str = ''
    error: str = ''


def reclaim(s):
    return replace(s,
        native_freed=s.native_freed or (not s.live and not s.native_pin),
        wrapper_freed=s.wrapper_freed or not (
            s.app_wrapper or s.attached or s.anchor_pin or s.output_wrapper))


def steps(s, managed, fault):
    if s.attached:
        yield 'detach', reclaim(replace(s, attached=False))
    if not s.attached and s.live and s.ws_live and not s.reattached and not s.wrapper_freed:
        yield 'reattach generation 1', reclaim(replace(s, attached=True,
                                                      generation=1, reattached=True))
    if s.live:
        yield 'logical condition delete', reclaim(replace(s, live=False, attached=False))
    if s.ws_live:
        yield 'logical WaitSet close', reclaim(replace(s, ws_live=False, attached=False))
    if s.app_wrapper:
        yield 'drop application wrapper reference', reclaim(replace(s, app_wrapper=False))
    if s.phase == 'candidate':
        valid = s.live and s.ws_live and s.attached and s.generation == 0
        if valid:
            yield 'select and retain', reclaim(replace(s, phase='selected',
                native_pin=fault not in ('late_acquire', 'wrapper_only'),
                anchor_pin=fault != 'late_acquire', outcome='observed'))
        else:
            yield 'withdraw stale candidate', reclaim(replace(s, phase='done', outcome='withdrawn'))
    if s.phase in ('selected', 'boxed'):
        # Native C boxing, then managed narrowing/cache lookup, both touch native
        # state; the latter also needs the original wrapper/anchor identity.
        bad = s.native_freed or (managed and s.wrapper_freed)
        next_phase = 'boxed' if s.phase == 'selected' else 'converted'
        if not managed and next_phase == 'boxed':
            next_phase = 'converted'
        n = replace(s, phase=next_phase,
                    error='conversion touched reclaimed storage' if bad else s.error)
        if next_phase == 'converted':
            n = replace(n, output_wrapper=managed)
        if fault == 'c_boundary_release' and next_phase == 'boxed':
            n = replace(n, native_pin=False, anchor_pin=False)
        yield 'C boxing' if s.phase == 'selected' else 'managed conversion', reclaim(n)
        yield 'conversion fails', reclaim(replace(s, phase='failed', outcome='delivery failure'))
    if s.phase in ('converted', 'failed'):
        leak = fault == 'failure_leak' and s.phase == 'failed'
        yield 'release lease and finish', reclaim(replace(s, phase='done',
            native_pin=s.native_pin if leak else False,
            anchor_pin=s.anchor_pin if leak else False,
            outcome='returned' if s.phase == 'converted' else s.outcome))
    if s.phase == 'done' and s.output_wrapper:
        yield 'drop returned wrapper', reclaim(replace(s, output_wrapper=False))


def explore(managed, fault=None):
    start = State()
    todo, paths, graph = deque([start]), {start: ()}, {}
    witnesses = set()
    while todo:
        s = todo.popleft()
        if s.error or (s.phase == 'done' and (s.native_pin or s.anchor_pin)):
            return len(paths), sum(map(len, graph.values())), paths[s], witnesses
        if s.phase in ('selected', 'boxed', 'converted', 'failed') and not s.live:
            witnesses.add('logical delete proceeds with conversion retained')
        if s.phase == 'boxed' and not s.app_wrapper and not s.attached and not s.wrapper_freed:
            witnesses.add('anchor spans C-to-managed conversion gap')
        if s.phase == 'done' and s.outcome == 'returned' and not s.ws_live:
            witnesses.add('selected result survives WaitSet close')
        if s.phase == 'done' and s.outcome == 'delivery failure' and s.native_freed:
            witnesses.add('failure releases native retention')
        if s.phase == 'done' and s.outcome == 'withdrawn' and s.generation == 1:
            witnesses.add('reattachment does not validate old candidate')
        if s.phase == 'done' and s.outcome == 'returned' and s.native_freed:
            if managed and s.output_wrapper and not s.wrapper_freed:
                witnesses.add('managed wrapper survives without native operational lifetime')
            if not managed:
                witnesses.add('raw return does not own native lifetime')
        ns = list(steps(s, managed, fault))
        graph[s] = ns
        for label, n in ns:
            if n not in paths:
                paths[n] = paths[s] + (label,)
                todo.append(n)
    # Existential cleanup reachability, not scheduler fairness.
    reachable = {s for s in paths if s.phase == 'done' and s.native_freed
                 and s.wrapper_freed and not s.ws_live}
    while True:
        more = {s for s, ns in graph.items() if any(n in reachable for _, n in ns)}
        if more <= reachable:
            break
        reachable |= more
    assert reachable == set(paths)
    return len(paths), sum(map(len, graph.values())), None, witnesses


def main():
    witnesses = set()
    for managed in (False, True):
        states, edges, failure, found = explore(managed)
        assert failure is None
        witnesses |= found
        print(f'PASS managed={managed}: {states} states, {edges} transitions; cleanup reachable')
    assert len(witnesses) == 7, witnesses
    for witness in sorted(witnesses):
        print('Witness: ' + witness)
    for fault in ('late_acquire', 'wrapper_only', 'c_boundary_release', 'failure_leak'):
        _, _, failure, _ = explore(True, fault)
        assert failure, fault
        print(f'NEGATIVE CONTROL {fault}: ' + ' -> '.join(failure))


if __name__ == '__main__':
    main()
