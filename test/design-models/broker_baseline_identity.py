"""Bounded contract checks, not a broker implementation or complete state model.
Run directly with Python. Retention and compatibility are explicit model inputs.
"""
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Key:
    epoch: int = 1
    session: int = 2
    owner: int = 3
    view: int = 4
    cut: int = 12


@dataclass(frozen=True)
class Baseline:
    key: Key = Key()
    scope: tuple = (0, '')
    policy: str = 'topics-A'
    floor: int = 20
    sent: int = 27


def resume(store, key, scope, policy, frontier, retained):
    baseline = store.get(key)
    return bool(retained and baseline and baseline.scope == scope
                and baseline.policy == policy
                and baseline.floor <= frontier <= baseline.sent)


def applied(bound, key, frontier):
    return key == bound.key and bound.floor <= frontier <= bound.sent


baseline = Baseline()
store = {baseline.key: baseline}
assert resume(store, baseline.key, baseline.scope, baseline.policy, 23, True)
assert applied(baseline, baseline.key, 23)
checks = 2
for field in ('epoch', 'session', 'owner', 'view', 'cut'):
    wrong = replace(baseline.key, **{field: getattr(baseline.key, field) + 1})
    assert not resume(store, wrong, baseline.scope, baseline.policy, 23, True)
    assert not applied(baseline, wrong, 23)
    checks += 2
for scope, policy, frontier, retained in (
    ((1, ''), baseline.policy, 23, True),
    ((0, 'other'), baseline.policy, 23, True),
    (baseline.scope, 'topics-B', 23, True),
    (baseline.scope, baseline.policy, 19, True),
    (baseline.scope, baseline.policy, 28, True),
    (baseline.scope, baseline.policy, 23, False),
):
    assert not resume(store, baseline.key, scope, policy, frontier, retained)
    checks += 1
assert not resume({}, baseline.key, baseline.scope, baseline.policy, 23, True)
assert not applied(baseline, baseline.key, 28)
checks += 2
# Identical cuts/frontiers do not make a new session/view the old baseline.
new = replace(baseline, key=replace(baseline.key, session=9, view=1))
assert resume(store, baseline.key, baseline.scope, baseline.policy, 23, True)
assert not applied(new, baseline.key, 23)
checks += 2
# Mutation controls demonstrate why lookup by cut or trusting the cursor is unsafe.
wrong_view = replace(baseline.key, view=99)
assert any(b.key.cut == wrong_view.cut for b in store.values())
assert not resume(store, wrong_view, baseline.scope, baseline.policy, 23, True)
assert bool(baseline.key) and not resume({}, baseline.key, baseline.scope, baseline.policy, 23, True)
print(f'{checks} baseline identity checks; 2 unsafe shortcut counterexamples: PASS')
