# Listener-group reference lifecycle

Status: concrete ownership walkthrough, 2026-09-16. Applies the accepted fixed group
membership and Config-taking creation pattern. Helper spellings are illustrative;
no new production signature or ABI is introduced.

## What the application does

Create a group, place it in a reader Config, and pass that Config to
create_datareader_ex(topic, qos, listener, mask, config). The call does not consume the
Config or the application's group reference. After successful creation, either can
be discarded without removing the reader's group membership. Another entity may use
the same group. Standard creation without a group keeps existing default behavior.

No per-call retain/release function arguments are added. The group implementation
and generated managed-reference bridge supply those functions once. Group membership
controls callback exclusion; it does not retain an operational runtime lease or extend
the lifetime of application-owned listener contexts.

## Ownership trace

The counts below represent logical ownership obligations, not a requirement for one
atomic increment per wrapper alias or language reference.

| Step | Live ownership | Required action |
| --- | --- | --- |
| Create group | Application group handle | Constructor transfers one owned reference |
| Put group in owning Config | Application handle + Config field | Retain/copy managed reference; replacing an old field releases its old ownership |
| Enter configured reader creation | Same owners; call borrows Config | Caller keeps Config stable/alive for the synchronous call |
| Prepare reader | Previous owners + provisional entity membership | Retain group before publication; validate same core domain |
| Creation fails | Application handle + Config field | Release provisional membership and other construction resources |
| Creation succeeds | Application handle + Config field + reader membership | Transfer provisional membership into published reader; no extra retain required |
| Destroy Config and application group handle | Reader membership | Drop only their reference obligations |
| Replace listener | Reader membership remains | Retire old listener registration under existing setter rules; group is unchanged |
| Logically delete reader | Retained entity/callback work still protects membership | Stop new eligibility; do not release storage needed by a claimed invocation |
| Last relevant work retires | No reader membership needed | Release membership after group rights/wake obligations are safely relinquished |
| Last group reference retires | None | Reclaim group storage and any independently owned bridge identity |

If another entity/config owns the group, it survives the final step for this reader.
A group does not own its member entities permanently. Dispatch may retain an entity
(which protects its group transitively) or retain the group directly; either is valid
provided the obligation is explicit and not duplicated or lost.

## Callback and replacement cases

An eligible invocation holds entity, listener-identity and optional group execution
rights. Ownership of storage and possession of execution rights are different: merely
retaining a group never blocks another callback. Acquiring group rights does not by
itself keep a freed group object safe.

An active callback may delete its reader. Logical deletion returns according to the
accepted callback rule; the invocation keeps membership storage valid until it unwinds.
It then releases group rights and publishes any wake for another runtime before its
last storage protection disappears. Mandatory wake bookkeeping must not allocate after
logical deletion. An external delete's application-quiescence guarantee need not wait
for every internal storage reference to disappear.

Listener replacement never moves the reader between groups. If no listener is installed,
the entity still retains its creation-time group for a later registration. Parent fallback
uses the selected registration entity's group, not every group traversed during lookup.
Same-chain explicit delegation retains its accepted inherited-rights exception.

Pending records must retire or relinquish ownership when invalidated. A group queue
must not permanently own an entity that owns the group: cancellation/claim retirement
must break any temporary cycle, and dormant membership must not create one.

## Binding consequences

**C++:** an owning group wrapper can use shared ownership; copying it into a Config
keeps the reference target alive. Copies may share one native ownership anchor. Reader
creation establishes independent core membership before returning. Destroying the
Config cannot invalidate that membership. No DDS entity deletion is inferred from
last-wrapper release.

**Java:** a Config field keeps its group wrapper reachable. The native reader must
retain its own group reference at creation; it cannot depend on future Java reachability.
Deterministic wrapper close and fallback cleanup must release their native ownership
once. A closed wrapper still referenced by a Config must be detected at conversion,
not dereferenced as a stale handle. Document whether close invalidates aliases of that
same wrapper; it must not close the shared exclusion domain for other retained members.

**C/Zig:** raw field assignment is not an implicit retain. Provide generated owning
field assignment/clone/move/destroy helpers or an equally explicit scoped API. For
example, a conceptual set_group_retained helper retains the new value before releasing
the old one, including self-assignment. A borrowed Config view may be passed synchronously
only while its owner protects every reference; it must never be destroyed as though
it owned those borrowed fields. The eventual representation must distinguish these
conventions clearly. This helper requirement is generic, not listener-group-specific.

**C-ABI conversion:** use a borrowed argument view or a temporary owning conversion,
with explicit cleanup. Both must convert interface views correctly and propagate failure.
Neither may accidentally add an operational lease, drop a group, or substitute nil.
A borrowed conversion does not permit the callee to save pointers into the Config.

## What this example requires from zidl

1. Managed-reference opt-in and safe nil defaults.
2. Declared field/container ownership with balanced generated helpers.
3. Correct interface-field C-ABI conversion and canonical/view-aware identity.
4. Fallible construction/boxing cleanup without silently changing arguments.

It does not require generic status-code interpretation or transactional inout metadata.
create_datareader_ex already returns an entity; the implementation handles its own
construction success/failure and provisional group retention. If result boxing fails
after core creation, a factory-specific unpublished-result cleanup path must retire
the new entity rather than leak it or call creation again. That provider cleanup is
not automatically supplied by releasing a borrowed DDS entity box.

The inout interface bug remains a separate correctness fix, but this group flow does
not depend on an inout ownership-acquisition method. Leave application output policy
with the operation implementation unless a concrete generic need emerges.

## Validation and next design step

A small non-DDS reference core can validate the same ownership graph: discard Config
and caller handle after creation; fail construction after retain; replace callback;
delete target during invocation; release the last callback; and share the group with
another target. Assert balanced logical ownership and no calls through reclaimed state.
Actual JNI reachability and C++ wrapper alias behavior require binding fixtures.

The remaining representation choice is how generated owning C/Zig fields are assigned
and distinguished from borrowed call views. Settle that with the managed-reference
bridge layout; do not add ownership parameters to every entity creation operation.
