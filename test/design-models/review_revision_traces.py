"""Bounded review traces, not a production scheduler/codec or DDS conformance proof.
Checks D7/D8 restoration and arithmetic/order assumptions; negative controls must fail.
Run from any directory with python3. No third-party dependencies.
"""
from itertools import permutations


def claims(undo_state=False, resurrect=False):
    checked = 0
    # A selected/claimed generation-0 sample starts READ, instance NOT_NEW.
    # Its conversion eventually fails; independently it may be evicted and reborn.
    for order in permutations(('observe', 'evict', 'rebirth', 'fail')):
        retained, claimed, read, generation, new = True, True, True, 0, False
        for event in order:
            if event == 'observe':
                assert not (claimed and retained and not read)
            elif event == 'evict':
                retained = False
            elif event == 'rebirth':
                generation, new = 1, True
            else:
                claimed = False
                if undo_state:
                    read = False
                if resurrect:
                    retained = True
                assert read, 'failure rolled back READ'
                assert not ('evict' in order[:order.index('fail')] and retained), 'resurrected eviction'
                assert new == (generation == 1), 'cleanup overwrote new instance generation'
        checked += 1
    return checked


def freshness(use_arrival=False, ignore_exception=False):
    checked = 0
    # Equal-rate clocks only: clock-skew implementation remains a separate gate.
    for t0 in range(3):
        for capture in range(t0, t0 + 3):
            for remaining in range(1, 5):
                for delay in range(4):
                    horizon = 4
                    grant = horizon if ignore_exception else min(horizon, remaining)
                    base = capture + delay if use_arrival else t0
                    deadline = base + grant
                    assert deadline <= capture + remaining, 'evidence extends past captured origin deadline'
                    checked += 1
    # Later reduction cannot promise an instant observer-side deadline change.
    original_deadline, reduced_deadline, reduction_arrival = 10, 5, 8
    assert reduced_deadline < reduction_arrival < original_deadline
    return checked


def seal_capacity():
    # One slot is occupied by an unacknowledged old seal: another set cannot be
    # admitted unless additional completion capacity is reserved. ACK frees it.
    for capacity in range(1, 4):
        reserved = 0
        for _ in range(capacity):
            assert reserved < capacity
            reserved += 1
        assert reserved == capacity  # next set must backpressure before first effect
        reserved -= 1  # repair obligation retired
        assert reserved < capacity
    return 3


def negative(fn, **kwargs):
    try:
        fn(**kwargs)
    except AssertionError:
        return
    raise AssertionError(f'negative control escaped: {kwargs}')


if __name__ == '__main__':
    c, f, s = claims(), freshness(), seal_capacity()
    negative(claims, undo_state=True)
    negative(claims, resurrect=True)
    negative(freshness, use_arrival=True)
    negative(freshness, ignore_exception=True)
    print(f'PASS: {c} claim event orders, {f} freshness cases, {s} seal-capacity cases; 4 negative controls')
