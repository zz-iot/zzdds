# Broker route authority and forwarding errors

Status: superseded, 2026-09-18. Historical unaccepted proposal; do not implement.
The [accepted relay direction](broker-relay-direction.md) removes v1 forwarding and
preserves direct WLP. Original analysis follows for context only.
Scope: single-broker cached v1 metatraffic, initially WLP. Not user-topic relaying,
a native DDS Security protocol, ICE nomination or a durable service message queue.

## Finding

The draft RouteMessage and RouteError carry route_generation but there is no operation
that distributes such a generation to senders. Treating it as the destination's session
would expose a value the sender does not know; letting the sender invent it would not
establish which broker registration is current. A cached route therefore needs either
an explicit route-advertisement lifecycle or a different v1 rule.

## Options and recommendation

* Publish broker-assigned route handles/generations. Senders cache them and include them
  in every ROUTE. This explicitly detects stale advertised routes and can fit future
  nomination protocols, but needs dissemination, invalidation, limits and recovery when
  a handle is unavailable or arrives after dependent work.
* Resolve each ROUTE against the current broker participant registry. The sender supplies
  destination GUID/incarnation and service; the broker selects the currently admitted,
  authorized registration. This reuses existing state and avoids a separate route protocol.

Recommend the second for v1. Remove route_generation from the unfrozen baseline, reserving
its former member IDs against accidental reuse. Do not replace it with an always-zero
field masquerading as useful validation. Future route handles are a negotiated extension
with explicit distribution/expiry, not a reinterpretation of this baseline.

## Resolve once per accepted message; fence queued work

Validate incoming Envelope/session/source identity, service support and current disclosure
policy. Look up destination by scope/GUID/incarnation. Reserve bounded forwarding capacity,
then capture both source and destination registration tokens in the queued work. The
actual transport send uses that destination's established channel and peer endpoints.

Before submission, check both captured tokens still identify the current registrations,
that authorization permits forwarding, and that the local queue deadline has not expired.
If either token changed, discard this queued message; do not silently retarget it to the
replacement session. A newly received native retransmission is resolved again. Thus
fresh traffic reaches a reconnected participant, while stale queued work does not acquire
a new destination merely by waiting in the broker.

Broker-to-client Envelope identifies the recipient session. Source_participant preserves
the origin GUID/incarnation and is checked independently of the broker's network address.
Native INFO_SRC/INFO_DST and service identifiers must be consistent with the permitted
routing context; validate all relevant submessages, not merely the first RTPS header.
Unknown/protected semantics require their separately supported profile, not blind
classification. Existing view/authorization/freshness rules govern receiver installation.

A message already handed to the network may arrive after a source disconnect. A broker
cannot retract it. The destination's own session fencing, installed participant state,
native sequence handling and freshness rules apply; do not promise instantaneous remote
revocation. This is separate from preventing stale broker-queued work after reconnect.

## Bounded error correlation

Use a fresh forwarding request ID in the destination-session Envelope. Keep a bounded,
expiring broker entry mapping (destination registration token, forwarding request ID) to
(source registration token, original request ID, destination incarnation, service).
The ID is never a credential. Reserve this map entry before forwarding if a returned
error is to be routable; do not forward and hope unlimited tracking can be added later.

Destination ROUTE_ERROR refers to the forwarded Envelope request ID. Validate that it
comes from exactly the recorded destination session and names the recorded destination.
Then emit a new error on the original source session with its original request ID. A
broker-detected failure before forwarding already has the original correlation. After
expiry, session replacement or lookup failure, drop the error with bounded diagnostics;
never infer a source from a supplied GUID or send to an arbitrary address.

Errors are best effort, not a completion service. They never create native ACK/NACK or
promise delivery. A retained error can be suppressed after its first report; no error
receives an error response. Quota exhaustion may drop forwarding with a bounded local
LIMIT report, subject to output budget; silence remains possible. This map has configured
entry/byte/age limits and per-session/global quotas. It is a bounded cache per forwarded
message, not an indefinitely retained conversation or origin credential registry.

An alternative is a broker-authenticated return token carried in every forwarded message.
It saves map state but requires a reviewed token format, expiry/key handling and additional
wire fields. Do not introduce it merely to avoid a small explicitly bounded v1 cache.

## Lifetime and native reliability

remaining_lifetime_ns is a finite local forwarding/queue budget. It is not an absolute
end-to-end expiry proof: without a common clock or a nonce exchange, network transit time
cannot be measured from that field alone. Each hop subtracts its own measured residence
time (including local scheduling/queue delay) before forwarding. Reject zero/overflow and
cap against configured service limits; never reset to the original maximum during retry.

No claim that an old assertion is fresh follows from a positive remaining budget.
Native service semantics and observer presence checks retain their own authority. Do not
retain routed WLP assertions across reconnect or replay a broker queue as fresh liveliness.
A stronger network-age bound would require an explicit protocol and belongs in a separate
review; current “bounded lifetime” wording must not imply one already exists.

Native HEARTBEAT/ACKNACK/GAP and fragment repair use new routed messages resolved by the
same rules in the opposite direction. They are not ROUTE_ERROR responses. The routing
layer does not retry user payloads or synthesize writer liveliness. TypeLookup/Security
routes remain unavailable until their own negotiated service contracts are implemented.

## Trace expectations

* Destination reconnects before queued send: old token fails; discard, do not retarget.
* A fresh message arrives after destination readmission: resolve the new session normally.
* Source reconnects before a returned error: discard the old source-token mapping.
* Two senders choose equal original request IDs: destination forwarding IDs remain unique
  within their session; each mapping returns only to the recorded source.
* Destination sends an unknown or expired error ID: bounded drop, no reflection/lookup by
  attacker-supplied source address.
* Forwarding map fills: bounded refusal/drop; other session quotas preserve fair progress.
* Packet spends a long time in the network: queue budget does not assert fresh presence
  or provide an unimplemented end-to-end age guarantee.

Acceptance would update RouteMessage/RouteError, routing table rows and golden/codec
fixtures together. F4 remains open until this resolution/error policy is accepted.
