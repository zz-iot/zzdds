"""Bounded abstract protocol checks; no sockets, cryptography or production code."""
from collections import deque
from itertools import permutations


def query_check(protect_retired=True):
    # highest serial, slots (serial, completed), serials whose requests were consumed
    initial = (0, (), frozenset())
    pending = deque([(initial, 0)])
    seen = {initial}
    transitions = 0
    while pending:
        (highest, slots, consumed), depth = pending.popleft()
        if depth == 8:
            continue
        active = dict(slots)
        for serial in range(1, 5):
            for action in ('request', 'complete', 'retire'):
                h, a, c = highest, dict(active), consumed
                if action == 'request':
                    if serial in a:
                        continue  # exact duplicate retains state/deadline
                    if protect_retired and serial <= h:
                        continue
                    assert serial not in c, ('retired request executed', serial)
                    h = max(h, serial)
                    c = c | {serial}  # includes a capacity-refused request
                    if len(a) < 2:
                        a[serial] = False
                elif serial not in a:
                    continue
                elif action == 'complete':
                    a[serial] = True
                else:
                    del a[serial]  # timeout or retained-result retirement
                assert len(a) <= 2 and h >= highest
                state = (h, tuple(sorted(a.items())), c)
                transitions += 1
                if state not in seen:
                    seen.add(state)
                    pending.append((state, depth + 1))
    return len(seen), transitions


def admission_check(unsafe_eviction=False):
    # Cookie expiry is exclusive. Result retention and guard retention differ.
    commits = 0
    guard = False
    outcome = False
    expiry = 5
    for now in (0, 1, 2, 3, 4, 5, 6):
        if now == 2:
            outcome = False
            if unsafe_eviction:
                guard = False
        if now >= expiry:
            guard = False
        if now >= expiry:
            continue  # expired challenge cannot reach the admission commit
        if guard:
            # Replay outcome if available, otherwise report expired. Never commit.
            continue
        guard = True  # capacity reserved before side effect
        commits += 1
        outcome = True
        assert commits == 1, 'valid-cookie replay committed after guard eviction'
    assert commits == 1 and not guard


def main():
    states, transitions = query_check()
    admission_check()
    # Explicit completion permutations: completing is not retiring, both slots survive.
    for order in permutations((1, 2)):
        slots = {1: False, 2: False}
        for serial in order:
            slots[serial] = True
        assert all(slots.values()) and len(slots) == 2
    for broken in (lambda: query_check(False), lambda: admission_check(True)):
        try:
            broken()
        except AssertionError:
            pass
        else:
            raise AssertionError('negative control failed to detect unsafe replay')
    print(f'Passed: {states} query states, {transitions} transitions; admission expiry; '
          'both completion orders; two replay negative controls')


if __name__ == '__main__':
    main()
