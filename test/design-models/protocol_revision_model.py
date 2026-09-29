"""Finite asynchronous models for review revisions; no production conformance claim.
Two TOPIC generations and a delayed/replayed freshness stream. Run directly with Python.
"""
from dataclasses import dataclass, replace
from collections import deque


def explore(initial, successors, invariant):
    seen = {initial}
    todo = deque([initial])
    edges = 0
    while todo:
        state = todo.popleft()
        invariant(state)
        for nxt in successors(state):
            edges += 1
            if nxt not in seen:
                seen.add(nxt)
                todo.append(nxt)
    return len(seen), edges


@dataclass(frozen=True)
class Seal:
    generation: int = 0
    opened: bool = False
    pending: int = 0
    loaded: int = 0  # retained writer turn excludes seal execution
    local: int = 0
    written: tuple = ()
    seals: tuple = ()
    history: tuple = ()  # repair-retained marker generations
    deleted: bool = False
    blocked: bool = False


def seal_model(capacity=1, early_seal=False):
    def inv(s):
        assert len(s.history) + bool(s.local) <= capacity, 'completion reservation overcommit'
        assert len(s.seals) == len(set(s.seals)), 'duplicate seal'
        assert all(g in s.written for g in s.seals), 'seal fabricated without set'
        assert not s.local or s.local not in s.seals, 'sealed set reopened'
        if s.pending and not s.loaded and not s.deleted:
            # Bounded internal service must seal any open set covered by close frontier.
            if s.local and s.local <= s.pending:
                assert any(n.local == 0 for n in succ(s)), 'close cannot service without write'
        if not s.opened and not s.loaded and s.local and not s.deleted:
            assert s.pending >= s.local, 'lost seal wake for closed generation'

    def succ(s):
        if s.deleted:
            return
        if not s.opened and s.generation < 2:
            yield replace(s, generation=s.generation + 1, opened=True)
        if s.opened:
            # Coalesced command carries a maximum CLOSED generation, never just latest.
            p = s.generation
            yield replace(s, opened=False, pending=p)
        if s.opened and s.generation not in s.written and not s.loaded:
            # Seal prior local set before admission into a new generation.
            if not s.local or s.local == s.generation:
                if len(s.history) + bool(s.local) < capacity or s.local == s.generation:
                    yield replace(s, loaded=s.generation)
                elif not s.blocked:
                    yield replace(s, blocked=True)
        if s.loaded:
            yield replace(s, local=s.loaded, loaded=0,
                          written=s.written + (s.loaded,))
        if s.pending and (not s.loaded or early_seal):
            if s.local and s.local <= s.pending:
                yield replace(s, local=0, pending=0, seals=s.seals + (s.local,),
                              history=s.history + (s.local,))
            else:
                yield replace(s, pending=0)
        if s.history:
            yield replace(s, history=s.history[1:])
        # Deletion fences pending work; incomplete local sets are abandoned, not sealed.
        yield replace(s, deleted=True, loaded=0, local=0, pending=0)

    return explore(Seal(), succ, inv)


@dataclass(frozen=True)
class Fresh:
    now: int = 0
    nonce: int = 0
    t0: int = 0
    consumed: bool = False
    queued: tuple = ()  # ordered state: withdrawal or (nonce,t0,captured_remaining)
    member: bool = True
    withdrawn: bool = False
    grant: int = 0
    captures: int = 0
    session: int = 1


def fresh_model(arrival_time=False, bypass_state=False):
    expiry = 3

    def inv(s):
        assert s.grant <= expiry, 'freshness beyond captured origin expiry'
        assert s.member or not s.grant, 'withdrawal left active proof'

    def succ(s):
        if s.now < 5:
            yield replace(s, now=s.now + 1)
        if s.nonce == 0:
            yield replace(s, nonce=1, t0=s.now)
        if s.nonce and not s.consumed and s.captures < 2:
            q = s.queued
            withdrawn = s.withdrawn
            if s.now >= expiry and not withdrawn:
                q += (('withdraw', 0, 0, 0, s.session),)
                withdrawn = True
            remaining = max(0, expiry - s.now)
            q += (('marker', s.nonce, s.t0, remaining, s.session),)
            yield replace(s, queued=q, withdrawn=withdrawn, captures=s.captures + 1)
        if s.queued:
            positions = range(len(s.queued)) if bypass_state else [0]
            for i in positions:
                kind, nonce, t0, remaining, session = s.queued[i]
                rest = s.queued[:i] + s.queued[i+1:]
                if kind == 'withdraw':
                    yield replace(s, queued=rest, member=False, grant=0)
                elif session == s.session and nonce == s.nonce and not s.consumed:
                    assert not any(x[0] == 'withdraw' for x in s.queued[:i]), 'marker overtook withdrawal'
                    grant = (s.now if arrival_time else t0) + remaining
                    grant = grant if remaining and s.member else s.grant
                    yield replace(s, queued=rest, consumed=True, grant=max(s.grant, grant))
                else:
                    yield replace(s, queued=rest)  # stale/duplicate discarded
        if s.session == 1:
            # Retained membership may resume; old proof/nonces may not.
            yield replace(s, session=2, nonce=0, consumed=False, grant=0, captures=0)

    return explore(Fresh(), succ, inv)


def must_fail(fn, **kwargs):
    try:
        fn(**kwargs)
    except AssertionError:
        return
    raise AssertionError(f'negative control did not fail: {kwargs}')


if __name__ == '__main__':
    for slots in (1, 2):
        print('seal', slots, 'slots:', seal_model(slots), 'states/transitions')
    print('freshness:', fresh_model(), 'states/transitions')
    must_fail(seal_model, early_seal=True)
    must_fail(fresh_model, arrival_time=True)
    must_fail(fresh_model, bypass_state=True)
    print('PASS: 3 negative controls')
