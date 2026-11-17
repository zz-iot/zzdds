# Participant stack retirement

Participant deletion can return before storage reclamation when it originates
inside a listener, a listener-group traversal, or the participant's ingress or
timer turn. Logical deletion retires the public handles; reclamation follows
completion of the work that still uses the participant.

The native factory holds an owner reference and references for its runtime
users and participant create/delete calls. A participant releases its factory
reference and runtime-use count from its final destruction hook, after its own
storage is reclaimed. Closing a factory prevents further creation; its storage
remains alive until these references drain. Its `on_destroy` hook runs after
factory reclamation and before releasing its selected runtime reference.

Each C-ABI participant stack uses that hook to destroy combined discovery and
UDP transport, then release its reference to the outer C-ABI factory. The outer
factory likewise survives its stacks and factory calls. In particular, its
allocator bookkeeping outlives all deferred stack cleanup. A participant keeps
its runtime reference through the destruction hook, so the plugins can finish
closing while the runtime is operational.

Native factories borrow their plugins. A native caller that destroys a factory
from a callback must likewise retain those plugins through final factory
cleanup, using `on_destroy` where necessary; return from `deinit` alone does not
establish reclamation.

## Announcements

Endpoint creation and writer/reader announcement commits are listener-group
traversals. A callback can delete the participant or factory during a commit;
that deletion follows the traversal's final temporary-job and buffer cleanup.
A call encountering an already closed group does not start an announcement.
The existing announcement/disposal ordering remains intact.

A traversal can be nested inside a participant ingress or timer turn. Deferred
listener-group cleanup preserves those outstanding waits and completes them
before tearing down the participant's fields. The close latch accepts its
completion hook both before and after the context closes, without holding its
mutex across the hook.

## Regression coverage

A watching allocator and manual runtime verify that participant, discovery,
stack and outer factory storage are retained through deferred cleanup, including
two participants whose cleanup finishes separately. Recording discovery tests
exercise participant/factory deletion during writer and reader creation and
later enable announcements. Additional manual-runtime tests finish group cleanup
before and after its enclosing ingress/timer turn closes. These orderings do not
rely on deadlines, sleeps or a racing worker.
