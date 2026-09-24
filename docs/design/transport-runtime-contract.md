# Transport/runtime ownership and backpressure

Status: ownership/backpressure direction accepted; bounded saturation model checked,
2026-09-15. Transport-channel work is now merged on main; see the
[main refresh review](main-refresh-review.md). Reconcile its API with these behavioral
requirements rather than duplicating that implementation. No production edits in this audit.

## Source boundary

`src/transport/interface.zig:384` supplies borrowed receive slices via a void callback
that must not block. Its send operation (line 419) may block briefly and has no explicit
asynchronous ownership/completion result. UDP dispatch passes slices of its receive
buffer; TCP `vtSend` (line 563) writes a length prefix then payload using writeAll.
These observations explain the required adapter seam; they are not concurrency
failures reproduced by tests. Existing legacy transport APIs can be adapted while a
versioned internal channel contract supplies the semantics below.

## Ingress

A channel owns socket/connection state, framing and I/O buffers. Delivery to an endpoint
is an explicit ownership decision: process inline under eligible bounded admission,
retain a buffer lease, or copy into bounded owned storage before returning. A borrowed
receive slice must never escape its callback lifetime. Retain the dispatch registration
and destination lifetime before enqueueing; a raw context pointer is not that retention.

Account both bytes and records, including partial frames/fragments and destination
fanout references. A retained multicast buffer may be shared immutably; each recipient
still needs bounded dispatch bookkeeping. Apply configured frame/fragment size limits
before allocating from untrusted lengths. Transport acceptance is not validated RTPS
receipt or DDS admission; follow the separate reception/admission roadmap contract.

On exhaustion:

* UDP may drop an unadmitted datagram and record an internal drop reason. Do not
  update sequence/ACK or historical-completion state for work never accepted by the
  protocol. Reliable recovery may occur through its normal protocol; best-effort
  delivery has no added guarantee. This is not automatically a DDS SAMPLE_LOST event.
* TCP normally pauses reading at a recoverable framing boundary, retaining bounded
  partial-frame state. Never discard arbitrary bytes and continue parsing as though
  framing were intact. An oversized/invalid frame or inability to preserve framing
  follows the channel's explicit failure/close policy. Shared-stream head-of-line
  blocking remains real; control queue reservations cannot bypass bytes on the wire.
* Saturation does not block an interrupt or I/O callback waiting for endpoint rights.
  It must not wait for application callbacks to release space on that same stack.

One slow peer/endpoint must not consume every configured ingress resource: expose
per-channel/peer limits plus aggregate bounds. Exact defaults are measurement and
configuration work, not selected numbers in this specification.

## Output submission and completion

Use these conceptual outcomes, with an explicit request/buffer lifetime:

| Outcome | Ownership and meaning |
| --- | --- |
| Completed locally | Adapter has finished accessing the submitted bytes; not proof of peer receipt |
| Accepted pending | Ownership/lease transferred until exactly one terminal completion |
| Would block / not accepted | No ownership transfer; producer retains data and may register a retry |
| Rejected / terminal failure | No transfer, or a terminal completion for previously accepted work; the distinction is explicit |

The producer registers readiness and releases its context instead of retaining
execution rights through output congestion. Check/register shares synchronization
with capacity release, and retries keep the original applicable deadline. A completed
send, failure or cancellation releases its lease exactly once. Cancellation request
alone does not authorize buffer reuse. An inline completion is permitted if its
ownership handoff is unambiguous and does not invoke application code under locks.

For TCP partial output, preserve the frame prefix/payload cursor and immutable backing
storage until completion or connection failure. Do not interleave frames on a stream,
report an unaccepted request after sending a prefix, or transparently replay a partially
sent frame on a fresh connection without an explicit higher-level retry contract.
UDP submission preserves datagram boundaries. Shared buffers require independently
accounted destination submissions; partial fanout is not all-destinations success.

Output queue acceptance, local transmission completion, DDS write commitment and
remote ACK are separate events. A committed reliable change stays repairable according
to its history/QoS policy even when a send attempt fails; the output lease must protect
its bytes against history reclamation. Best-effort postcommit output failure has no
invented retransmission guarantee. Async failures feed the owning protocol/channel
state and diagnostics; they do not retroactively change a returned write result.

## Capacity needed for progress

Recommend bounded ordinary ingress/output capacity, plus separately reserved internal
completion/cancellation/retirement records. Reserve each accepted operation's terminal
record before acceptance; rejected submissions need no later completion record.
A full data queue must not prevent returning buffers, publishing an accepted send's
completion, cancelling a timer or handing off retirement. These are logical capacity
classes, not a mandate for one physical queue or worker per class.

Coalescible protocol-ready hints use pre-reserved per-owner state: repeated ACK/repair
or discovery readiness need not allocate a new task each time. Raw control packets
are still untrusted input requiring bounded parsing and admission; they do not receive
unlimited exemption from capacity limits. Validated control work can receive reserved
capacity/bounded priority, with fairness so continuous control traffic cannot starve
ordinary work. Mandatory release work must not depend on allocating another data item.

This prevents local capacity cycles, not arbitrary network or application deadlock.
TCP data can hide a needed control frame behind it, and a full reader history can
require application consumption. Protocol/channel topology and supported runtime
helping must account for those limits. Do not promise that QoS or priority eliminates
all head-of-line blocking.

## Close and retirement

Unregister logically prevents new dispatch claims. Already claimed dispatch and I/O
completion retains registration/channel/target lifetimes until it retires. Separate
logical unregister from an optional external drain; the current blocking unlisten
must not be called in a context where it waits for its own callback. Exact generation
checks cover stale dispatch, ready notifications and queued completions.

Channel close rejects new submissions, resolves accepted work and drains backend
users before resource destruction. Runtime retirement preserves completion/cancel
service even when ordinary queues are full; it must not wait for remote peers solely
to reclaim local state. Shared transport resources close only when their actual owners
release them. A retained stopped runtime identity is not a live channel owner.

## Acceptance and validation

Explicit buffer transfer, bounded data capacity with reserved release capacity,
and UDP-drop/TCP-pause-or-explicit-failure direction are accepted. The bounded model
below covers output saturation and retirement. Concrete TCP framing, I/O errors,
UDP loss, per-peer isolation and legacy adapter blocking need integration fixtures.
No new application controls go in dcps.idl; configuration/extensions belong in zzdds.idl.

## Bounded saturation validation

The user accepted the direction and requested model checking. Run
`python3 docs/design/transport_capacity_model.py`: 164 states and 338 transitions
pass, with six reachable outcome witnesses and a shutdown-completion path from every
state. This is existential reachability, not scheduler fairness or a throughput claim.

The model has one occupied output slot, its retained buffer and pre-reserved completion
record, plus a waiting producer. Backend success/failure, cancellation request,
cancellation completion, completion publication/consumption, producer notification,
retirement and backend stop interleave. Accepted work retains the slot/buffer/record
until completion consumption; release occurs exactly once.

Four negative controls fail as intended:

* Requiring free data capacity to publish completion strands retirement after I/O
  finishes: the occupied slot cannot be released without that completion.
* Releasing a buffer when cancellation is requested violates backend-access lifetime.
* Omitting notification on capacity release leaves an eligible producer asleep.
* Stopping the backend before accepted work/completion retires violates shutdown safety.

No policy change was needed. Completion publication remains possible while data
capacity is full and after ordinary admission closes. Failure and cancellation both
release resources; neither turns already committed DDS effects into precommit failure.
The model checks local transport ownership, not those DDS effects themselves.

Limits: producer B's eventual accepted work is represented by an abstract completion,
not a second fully modeled buffer/credit lifecycle. Retry registration is assumed
already installed; concrete check/register races, inline completion, multiple queues,
TCP partial writes/framing, UDP admission/drop, fanout, priority fairness, shared
sockets and backend cancellation failures remain integration checks. The early-cancel
control directly asserts the retained-buffer invariant; it does not execute an OS
callback against freed memory. A scalar model is not production fault injection.

Next consolidate runtime/transport interfaces with a staged migration and validation
plan, retaining the named concrete backend/binding checks. Add further experiments
only where an unresolved observable contract requires them.

## Channel integration after main refresh

Preserve received-channel routing from the implemented Channel/sendOnChannel API.
Retained queued work must also retain or safely resolve the owning transport lifetime;
a copied pointer token plus generation is not a resource lease. Replace unbounded
dead-channel retention with bounded safe identity reclamation for the evented backend.
Correlate broadcast close notifications against known channel generations and retain
reserved completion/cleanup capacity; never treat every notification as session loss.
The existing API does not yet supply asynchronous send ownership or completion.
