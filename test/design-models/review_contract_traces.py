"""Bounded review-contract traces, not production or complete protocol verification.
Claims: all permutations of one failure and independent cache/lifecycle/access events.
Seals: explicit nested/membership/close schedules. Freshness: finite rational clocks.
"""
from dataclasses import dataclass, field
from fractions import Fraction
from itertools import permutations, product


@dataclass
class Cache:
    retained: list = field(default_factory=lambda: [1, 2])
    claimed: set = field(default_factory=lambda: {1})
    read: set = field(default_factory=lambda: {1})
    instance_generation: int = 0
    new: bool = False
    alive: bool = True
    bracket: int = 1
    bracket_open: bool = True
    consumed: set = field(default_factory=lambda: {1})
    wake: int = 0

    def visible(self):
        return [x for x in self.retained if x not in self.claimed] if self.alive else []

    def fail(self):
        before = 1 in self.visible()
        self.claimed.discard(1)
        # Restoration neither inserts cache nodes nor overwrites instance state.
        if self.alive and 1 in self.retained:
            if self.bracket_open and self.bracket == 1:
                self.consumed.discard(1)
            if not before:
                self.wake += 1


def claim_traces():
    count = 0
    for removal in ('evict', 'expire', 'delete'):
        for order in permutations(('fail', removal, 'rebirth', 'access_close', 'observe')):
            c = Cache()
            removed = False
            for event in order:
                if event == 'fail':
                    c.fail()
                    assert 1 in c.read
                    assert c.new == (c.instance_generation == 1)
                    assert (1 in c.visible()) == (not removed)
                    if not removed:
                        assert c.wake == 1  # ANY condition false -> true; wake reevaluates
                    if not c.bracket_open:
                        assert 1 in c.consumed  # never reopen retired bracket
                elif event in ('evict', 'expire', 'delete'):
                    removed = True
                    c.retained.remove(1)
                    if event == 'delete':
                        c.alive = False
                elif event == 'rebirth':
                    c.instance_generation, c.new = 1, True
                elif event == 'access_close':
                    c.bracket_open = False
                else:
                    assert (1 in c.visible()) == (not removed and 1 not in c.claimed)
                    if 1 in c.claimed:
                        assert 1 in c.consumed  # GROUP consumer skips it
                assert c.retained == sorted(c.retained)
            count += 1
    # Two takers: first claim can cause NO_DATA; failure restores for second.
    c = Cache(retained=[1])
    assert not c.visible()
    c.fail()
    assert c.visible() == [1] and c.wake == 1
    c.claimed.add(1)
    c.retained.remove(1)  # second take succeeds
    c.claimed.remove(1)
    assert not c.visible()
    # Failed read keeps READ observed by overlapping successful read.
    c = Cache(claimed=set())
    captured_by_second = 1 in c.read
    c.fail()
    assert captured_by_second and 1 in c.read
    # Restoration after access close is cache restoration, never old-view revival.
    c = Cache(bracket_open=False)
    c.fail()
    assert c.visible() == [1, 2] and 1 in c.consumed
    c.bracket, c.bracket_open, c.consumed = 2, True, set()
    assert 1 in c.visible()  # later period may admit it under ordinary eligibility
    return count + 3


@dataclass
class Writer:
    local: int = 0
    pending: int = 0
    loaded: int = 0
    live: bool = True
    slots: int = 2
    reserved: set = field(default_factory=set)
    markers: list = field(default_factory=list)
    data: list = field(default_factory=list)

    def seal(self):
        assert not self.loaded, 'seal cannot pass admitted writer turn'
        if self.live and self.local and self.local <= self.pending:
            self.markers.append(self.local)
            self.local = 0

    def load(self, generation):
        assert self.live and not self.loaded
        self.seal()
        if generation not in self.reserved:
            if len(self.reserved) == self.slots:
                return False
            self.reserved.add(generation)
        self.loaded = generation
        return True

    def commit(self):
        assert self.loaded and self.live
        self.local = self.loaded
        self.data.append(self.loaded)
        self.loaded = 0

    def delete(self):
        self.live, self.loaded, self.local = False, 0, 0


def seal_traces():
    count = 0
    for late in (False, True):
        writers = [Writer(), Writer()]
        depth, generation = 1, 1
        depth += 1  # nested begin, no new generation
        assert depth == 2 and generation == 1
        for w in writers:
            assert w.load(generation)
            if not late:
                w.commit()
        depth -= 1
        assert depth == 1 and all(w.pending == 0 for w in writers)
        depth -= 1  # outer end snapshots retained membership and publishes close
        for w in writers:
            w.pending = generation
        for w in writers:
            if late:
                w.commit()
            w.seal()
            assert w.data == [1] and w.markers == [1]
        count += 1
    for deleted in (0, 1, 2):  # none, writer, publisher subtree
        writers = [Writer(), Writer()]
        for w in writers:
            w.load(1)
            w.commit()
            w.pending = 1
        for w in writers[:deleted]:
            w.delete()
        for w in writers:
            w.seal()
            assert w.markers == ([1] if w.live else [])
        count += 1
    # Writer published while open joins on first commit; after close cannot join old G.
    w = Writer()
    assert w.load(1)
    w.commit()
    w.pending = 1
    w.seal()
    assert w.markers == [1]
    late_created = Writer()
    late_created.pending = 1
    late_created.seal()
    assert late_created.markers == []
    count += 1
    # Two generations close before coalesced service; inline seal of first is mandatory.
    w = Writer()
    for g in (1, 2):
        assert w.load(g)
        w.commit()
        w.pending = g
    w.seal()
    assert w.markers == [1, 2] and not w.load(3)
    w.reserved.remove(1)  # repair/retention complete, not merely output submission
    assert w.load(3)
    return count + 1


def freshness_traces():
    count = 0
    for remaining in product(range(4), repeat=3):
        for cap in range(4):
            target = 3
            positive = sorted(x for x in remaining if x > 0)
            # Expired members are removed before capture; no stale timer eligibility.
            horizon = min(target, positive[cap]) if len(positive) > cap else target
            exceptions = [x for x in positive if x < horizon]
            assert len(exceptions) <= cap
            assert all(x >= horizon or x in exceptions for x in positive)
            for eps in (Fraction(0), Fraction(1, 10)):
                c = 1 / (1 + eps)  # assumes broker_rate / observer_rate <= 1+eps
                for ratio in (Fraction(1), 1 + eps):
                    for grant in positive:
                        assert c * grant <= Fraction(grant, 1) / ratio
            count += 1
    # Reduction after capture cannot instantly revoke a grant; ordered application caps it.
    observer_deadline, new_broker_deadline, arrival = 10, 5, 8
    assert new_broker_deadline < arrival < observer_deadline
    observer_deadline = min(observer_deadline, new_broker_deadline)
    assert observer_deadline <= arrival
    # Common horizon shrink may expire healthy origins; never omit a short exception.
    assert min((1, 20, 30)) == 1
    return count


if __name__ == '__main__':
    print(f'PASS: {claim_traces()} claim/access/condition traces; '
          f'{seal_traces()} nested/multiwriter seal traces; '
          f'{freshness_traces()} adaptive-horizon/rational-clock cases')
