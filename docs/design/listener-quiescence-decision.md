# Listener replacement and quiescence: proposed v1 choice

Status: accepted as the initial design baseline, 2026-09-11; production behavior is
not implemented. Exact extension APIs and deletion semantics remain separate.
This refines L4 and the [identity proposal](listener-identity-decision.md). It
recommends a stronger standard-only replacement boundary than the earlier blanket
nonblocking proposal in [listener-execution.md](listener-execution.md).

## Standards and source evidence

DDS 1.4 section 2.2.2.1.1.3 specifies listener installation/replacement, the mask,
and nil removal. That operation description does not specify a callback-drain
barrier. The choice below is a proposed zzdds guarantee, not an OMG requirement.
Source: [DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF).

The current reader `swapListener` publishes a new box under `listener_mu` and then
releases the installed reference to the old box. Acquired dispatch references can
keep that box alive. This supports asynchronous box retirement, but does not retain
application-owned C/C++/Zig state or establish quiescence at setter return. Java
binding contexts own global references, which addresses a different ownership case.
Implementing this proposal requires new retirement/admission bookkeeping, not
merely another reference on the existing ListenerBox.

## Alternatives

| Policy | Benefit | Cost |
| --- | --- | --- |
| Always wait for old listener use to retire | Uniform and convenient external lifetime boundary | Self-replacement cannot wait for itself; cross-callback replacement can form cycles; prohibiting those calls needs an explicit supported-API decision |
| Always publish without waiting; separate quiescence operation | Uniform composable setter, natural asynchronous behavior | Standard-only applications cannot use setter return to reclaim their borrowed listener state; dynamic lifetime requires a separate synchronization pattern |
| External quiescence, callback-context asynchronous replacement | Convenient standard-only management path; preserves replacement from callbacks without library-imposed callback drain waits | Return guarantee depends on call context; external calls may wait indefinitely; precise frontier and lifetime rules required |

**Accepted initial policy: the third policy.** Keep an explicit asynchronous replacement/
retirement facility available as a future extension for applications needing bounded
management-thread responsiveness. Its name and IDL are not decided here.

## Accepted return contract

From ordinary application code outside a zzdds callback chain, successful
`set_listener` publishes the replacement and waits for all relevant uses through
a captured registration-generation frontier to retire. It returns with no remaining
application listener/context access through those retired registrations on that
entity. The newly installed registration can remain active. This is an application
lifetime boundary, not a claim that every stale scheduler record has been freed.
Stale records left behind must no longer dereference the retired listener/context.
Any release hooks that can access it must also have completed or transferred valid
independent ownership before quiescence is reported.

From **any** zzdds callback chain, including callbacks on another entity or runtime
in the same identity domain, replacement publishes without waiting for callback
retirement. Already claimed invocations may finish. Unclaimed pending notifications
must reevaluate against the current listener/mask. A claim immediately preceding
replacement can enter application code afterwards: asynchronous replacement is not
a promise about the wall-clock time of the last callback entry.

The old application-owned listener must survive that deferred retirement. In
particular, successful self-replacement does not authorize destroying the object
whose method is still executing. Shared identity exclusion persists while old
invocations/registrations retain it. New pending work does not bypass that exclusion.

The operation does not wait while holding entity, protocol, listener-identity or
registry locks. Any helping/wakeup logic follows the runtime progress contract.
A single-thread manual driver incurs no callback-drain wait outside a callback
when no previous callback is in flight. This is not an OS-thread-per-listener design.

The callback-context distinction is an execution-chain property, not a comparison
of the target entity with the current callback's entity. Restricting the exception
to self-replacement still allows A's callback to wait for B while B waits for A.
Implementation needs a common scope across bindings/runtimes; foreign application
threads causally spawned by a callback are not automatically detectable as that
callback chain.

## Why the frontier includes previously retired registrations

Consider A replacing itself with B from a callback. A is retired but still running.
Another thread then clears B. Waiting only for B would allow the clear to return
while A still accesses old application state. Instead, the external clear captures
all registration generations through B and waits for their applicable uses,
including A. Registrations installed concurrently after the captured frontier do
not extend that wait. Return is a lifetime statement about that frontier; it does
not assert that the entity's current listener still equals the caller's argument
if another setter subsequently changed it.

Retirement bookkeeping must be bounded. Prepare all needed storage before committing
a registration change; failure must leave the previous registration intact. The
mapping of resource failures to permitted DDS return codes still requires the API
review. Do not add TIMEOUT behavior to standard `set_listener` without that review;
this proposal has no finite return-time guarantee if a callback never returns.

## Standard-only ownership pattern

A management thread can clear or replace every registration that uses an old
application-owned listener, wait for those setter calls to return, and then destroy
that listener, provided the application prevents concurrent reinstallation and has
no other users of the object. Parent listener registrations count too: descendant
fallback dispatch retains the actual selected parent registration.

A callback may request replacement immediately and hand final reclamation to such
a management path. The management path can perform a subsequent setter operation
on the affected entity to drain the earlier frontier. On a single-thread application,
perform this management step after the callback returns. No zzdds extension is
required for this pattern. An extension would make nonblocking retirement tracking
more convenient, especially when callers do not wish to issue another setter.

This does not mean clearing one reader makes a listener shared with another reader
safe to destroy. Identity-wide object lifetime and per-entity registration retirement
are different. Concurrent shared-object registration/destruction remains an
application ownership responsibility.

External quiescence remains a blocking operation: callers must not retain an
application lock or wait dependency that the retiring callback needs. The library
can prevent its own self/cross-callback drain waits, not arbitrary application
cycles such as a callback joining a management thread that is draining that callback.

## Deliberately separate decisions

* Exact asynchronous retirement token/barrier API, if needed, belongs in `zzdds.idl`.
  No new `dcps.idl` operation or low-latency flag is required by this policy.
* Entity deletion has its own DDS preconditions and visibility boundary; this note
  does not approve deletion from every callback or define its return semantics.
* Explicit `notify_datareaders()` delegation and exception/unwind behavior still
  need their own contract, while respecting the retirement references defined here.
* Whether a setter dispatches newly eligible notifications on its own stack is
  separate from waiting for old registration quiescence. Such execution must obey
  the listener admission/reentrancy contract; it cannot be hidden inside a lock.

## Validation needed after choosing the policy

A small registration-generation fixture is warranted for: external replacement
with a paused invocation; self-replacement followed by external clear; simultaneous
A/B callback replacement; one object registered on two entities; a claimed callback
paused before application entry; release hooks during retirement; and another setter
publishing after a captured frontier. Add a negative control that waits for only
the immediately replaced generation and demonstrates the A-to-B-to-nil failure.
These are proposed checks, not tests run in this investigation. The user accepted the policy as the initial baseline. The bounded deterministic
fixture in `test/concurrency/listener_retirement_test.zig` now exercises frontier
semantics, callback-context replacement, claimed-before-entry ownership, hook
retirement, later generations and pre-publication capacity failure. It includes
the immediate-generation-only negative witness. It does not implement a blocking
setter, execution-chain detection, real binding hooks or shared identity dispatch.

Validation on 2026-09-11: all five new retirement fixture cases passed in the
LLVM/TSan deterministic runner, alongside existing cases (42 entries total,
including two import-only entries). The immediate-generation negative control
exhibited the expected premature-quiescence witness. This is deterministic policy
evidence, not threaded setter/binding validation.
