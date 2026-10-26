# Concurrency: transport adapters

Requirements use the [shared convention](../concurrency-broker-status.md#requirement-convention).
[The index](../concurrency-broker-status.md) owns scope and unresolved design items.

The [runtime contract](runtime.md#transportruntime-ownership-and-backpressure) states what
ingress, output, capacity and close must guarantee. This document gives that contract a
code shape and fixes the adapters that implement it in hosted, manual and MCU builds, so
one protocol implementation runs over all of them. It does not select queue containers,
pool sizes or the external-loop ABI ([open design item](../concurrency-broker-status.md#open-design-items)).

<a id="starting-point"></a>
## Starting point

<a id="current-transports"></a>
### Current transports

* `Transport.listen` registers a `ReceiveHandler` that the transport calls from its own
  threads. There is no entry a driver could call to service sockets, so the transports
  cannot run without background threads.
* UDP runs one receive thread per socket: one per interface address and port, plus one
  per multicast socket. Each polls its socket every 50 ms, receives into a 64 KiB stack
  buffer and calls every handler with a slice borrowed for the call.
* TCP runs an accept thread and one receive thread per connection. `send` dials with a
  blocking `connect` and writes with a blocking `send` under the connection's send lock,
  so a send can stall its caller for as long as the peer or the network takes.
* Every send is synchronous on the caller's thread (a writer, the heartbeat thread, SPDP).
  Nothing reports output asynchronously, and `MessageBuilder`'s gather list is flattened
  into one buffer before each send.
* A UDP `Channel` is a socket pointer plus a generation. Retired sockets and port entries
  are kept until the transport closes so that a stale token never dereferences freed
  memory, which retains them without bound under interface churn.
* The memory transport delivers synchronously on the sender's stack.

<a id="zig-std-io-in-0-17"></a>
### Zig `std.Io` in 0.17.0

Checked against Zig 0.17.0 on 2026-10-19:

* `std.Io.Threaded` works. Its operations are blocking syscalls on the calling thread,
  `io.concurrent` runs tasks on its pool, and it is safe to call from any thread.
* `std.Io.Evented` does not compile on any target in 0.17.0: its io_uring (Linux), kqueue
  (BSD) and Dispatch (Apple) backends each fail against the current `Io.VTable`. When it
  does build, its per-thread state is a thread-local that only its own pool threads set
  (`Uring.Thread.current()`), so a thread it does not own (an application thread calling
  through the C, C++ or Java binding) cannot call into that `Io`, not even to wake a waiter.
* `std.Io.net` cannot set up the sockets RTPS needs: it has no multicast join or leave, no
  outgoing multicast interface, no address reuse on a UDP bind and no receive-buffer size.
  Its operations accept a raw socket handle, so sockets created elsewhere can still use them.
* Under Threaded, an `Io.Batch` of receives plus a read on a wake descriptor, awaited with a
  timeout, is a `poll`-based readiness wait. A zero timeout returns at once, a datagram
  completes its receive, and a wake written from another thread ends the wait. Re-arming a
  receive that had completed immediately misbehaved in the same probe; the cause is
  unconfirmed.

<a id="adapter-model"></a>
## Adapter model

Protocol code and the runtime see one transport contract. Adapters implement it:

| Adapter | Where it runs | I/O model | Wait |
| --- | --- | --- | --- |
| Readiness | Hosted and manual on POSIX and Windows | Nonblocking sockets; service ready ones | `poll`/`epoll`/`WSAPoll` over the sockets and a wake descriptor, with a deadline |
| Completion | Hosted on Linux, later | Receives and sends submitted ahead, results consumed as completions | The completion queue with a deadline |
| In-process | Both modes | Memory transport and direct discovery | The runtime's own wake |
| MCU | Manual on bare metal or an RTOS | Network driver callbacks fill bounded rings | Interrupt or RTOS event with a deadline |

* Protocol code, the runtime core and the channel owner depend only on the contract. No
  protocol path may assume sockets, file descriptors, threads or a particular adapter.
* The readiness adapter is the default for hosted and manual builds on hosted platforms.
  In hosted mode, a configured number of I/O threads run it; in manual mode, `drive()`
  runs it. Either way the thread count is independent of the socket count, and the
  per-socket receive threads are removed.
* A blocking-worker adapter (blocking receive per socket) is permitted only on a platform
  that offers no readiness or completion interface. It obeys the same contract.
* The completion adapter is not scheduled. It may be written directly against io_uring or
  built on `std.Io.Evented` once Evented compiles and a thread it does not own can wake
  it. Until then no requirement in this document depends on it, and nothing may call an
  Evented `Io` from a thread outside its pool.
* A hosted runtime may run its workers and I/O threads as `std.Io.Threaded` tasks and use
  its clock and futex; Threaded is safe to call from any thread. That is a hosted choice:
  the runtime core, the contract and the manual and MCU adapters do not depend on `std.Io`
  ([platform boundaries](architecture.md#platform-boundaries)).

<a id="adopting-other-std-io-backends"></a>
### Adopting other `std.Io` backends

Zig defines the `std.Io` interface ahead of most of its implementations: the
[0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html) call
Evented "work-in-progress, experimental" without networking, its io_uring backend a
proof of concept and its kqueue backend proof-of-concept only, and only Threaded
"feature-complete and well-tested". The initial adapters therefore rely on Threaded
alone, while keeping room for the others:

* The runtime core and the transport contract never name a `std.Io` type. A backend built
  on another `Io` is one more adapter behind the progress backend.
* Use another backend only once it compiles, is tested upstream, implements the networking
  operations the adapter needs and has been measured against Threaded.
* Application threads in the bindings are outside any Evented pool. An Evented-based
  backend therefore accepts `wake()` through a mechanism any thread may trigger, and a
  blocking DDS call from an application thread waits on zzdds's own primitive, never on
  that `Io`.
* Protocol work must not block an Evented thread: execution rights are never waited for
  (take-turns admission queues instead), internal locks go through `src/util/mutex.zig` so
  they can move to `Io.Mutex`, and protocol paths make no blocking syscalls.

**Conforming approach.** Until Evented offers a way for outside threads to wake it, an
Evented backend keeps a read on an `eventfd` posted in its ring, and `wake()` writes the
`eventfd`. Each Zig release should be checked for an official cross-thread wake or
callback mechanism to replace it.

<a id="socket-setup-and-data-path"></a>
### Socket setup and data path

Socket setup is platform code, separate from the data path: creating and binding sockets,
address reuse, multicast membership and the outgoing multicast interface, buffer sizes,
interface enumeration and TCP listen. It produces registered I/O sources. The data path
moves bytes on registered sources through the adapter. Setup runs under the channel owner
and may use `std.Io.net` where it covers what is needed; the data path uses the adapter.

<a id="transport-contract"></a>
## Transport contract

<a id="progress-backend"></a>
### Progress backend and wake

The adapter supplies the runtime's wait. A runtime is constructed with one progress backend,
and every transport the runtime uses registers its sources with it. The backend provides:

* `wake()`: callable from any thread, and from interrupt context in the MCU adapter. It
  ends a current or the next wait. It never runs DDS work.
* `prepare_wait()`: returns a wake token. The caller then rechecks for runnable work and
  due timers before waiting, as the prepare-to-wait handshake in
  [external-loop adapter](runtime.md#external-loop-adapter) and
  [waiter sleep](architecture.md#waiter-sleep-and-shared-runtime-progress) requires.
* `wait(deadline, token)`: blocks until I/O is ready, a wake newer than `token` arrives
  or the deadline passes. A wake after `prepare_wait()` is never lost.
* `service(budget)`: nonblocking. It turns ready I/O and completions into ingress
  deliveries and output completions, at most `budget` of them, rotating across ready
  sources so one busy socket cannot starve the others, and returns whether more are ready.
* Several hosted I/O threads may wait and service the same backend at once. Each ready
  source is serviced by one of them at a time, so per-source state such as TCP framing
  needs no further lock.

`drive(budget, max_wait)` services runnable runtime work and `service`, and waits only
through `wait`. A runtime without I/O sources, such as one using only the in-process
adapter, has a backend whose `wait` is a futex or condition wait. Hosted runtime workers
waiting for ready contexts may use a futex or condition variable; a hosted I/O thread waits
through `wait`. Work that becomes ready wakes whoever will execute it: a hosted worker
through its futex or condition, a manual driver through `wake()`. The runtime core never
assumes the wait is a futex.

**Conforming approach.** The readiness adapter's wake is an `eventfd` on Linux, a pipe
on other POSIX systems, and a loopback socket or an event handle on Windows; it is
registered with the sockets in the same `poll` set. An external loop receives the
handles to wait on through the external-loop adapter, whose ABI is the open design item.
Under Threaded, an `Io.Batch` of receives and a read on the wake descriptor implements
the same wait, but it does not expose the handles an external loop needs.

<a id="ingress-delivery"></a>
### Ingress delivery

The adapter delivers each received message to the channel owner as a borrowed view of its
bytes, its source locator and its `Channel`. The receiving executor (a hosted I/O thread,
the manual driver, or a runtime worker servicing the backend) then routes it:

* If the destination owner can be admitted at once within the executor's budget, it is
  processed inline, and the view is not retained.
* Otherwise the channel owner retains it, either by taking a lease on the receive buffer
  or by copying it into bounded owned storage, and queues it to the destination owner. A
  borrowed view never outlives the delivery call.
* Retained ingress is accounted per channel, per peer and in aggregate, in bytes and in
  records, as [ingress](runtime.md#ingress) requires. Exhaustion follows that section:
  UDP drops the unadmitted datagram with a recorded reason; TCP pauses reading at a frame
  boundary.

How an adapter applies backpressure follows its I/O model. The readiness adapter stops
asking for read readiness on a paused source, and the kernel queues or drops further
input. The completion adapter stops posting receives. The MCU adapter stops taking buffers
from the driver, which drops at its own limit.

**Conforming approach.** The readiness adapter receives into one scratch buffer per
executor and copies only what it retains, so its buffer memory does not grow with the
socket count. The completion adapter must post buffers before data arrives, so its
deliveries are leases on posted buffers and it bounds the number posted per source.

<a id="output-submission"></a>
### Output submission

Sending becomes a submission with one of the four outcomes in
[output submission and completion](runtime.md#output-submission-and-completion):

* A request carries a gather list (a `MessageBuilder` iovec list, so the flattening copy
  goes away), a destination locator or `Channel`, a lease that keeps the bytes alive and
  a reserved completion record that names the submitting owner and its generation.
* **Completed locally:** the adapter has finished with the bytes, and the lease is
  released before `submit` returns.
* **Accepted pending:** the adapter holds the lease and completes the request exactly once.
* **Would block:** nothing is transferred. The owner keeps its data, registers for output
  readiness through the adapter and releases its execution rights.
* **Rejected:** nothing is transferred, and the error is returned.
* The readiness adapter tries a nonblocking send at once. A UDP datagram completes or
  would block. A TCP frame that sends only partly is accepted pending: the adapter keeps
  its cursor and lease, and nothing else is written on that stream until it finishes or
  the connection fails.
* A TCP dial is nonblocking: the connection completes on output readiness, so a dial
  never blocks the executor that requested it.

<a id="channels-and-lifetimes"></a>
### Channels and lifetimes

* A `Channel` names a slot in the channel owner's table plus that slot's generation. Work
  that keeps a channel holds a counted reference to the slot. A stale generation fails with
  `ChannelClosed`, and a slot is reused only when no reference remains, which replaces
  the retained graveyards.
* Closing a source unregisters it from the adapter first. Pending output on it completes
  as failed; leases on received buffers keep those buffers, which come from the channel
  owner's receive pool rather than from the source.
* An interface change re-enumerates, creates and closes sources under the channel owner,
  and registers or unregisters them with the adapter. Shutdown follows
  [close and retirement](runtime.md#close-and-retirement).

<a id="in-process-and-mcu-adapters"></a>
### In-process and MCU adapters

* **In-process:** a submission to another participant is ingress for the receiving
  participant's runtime. It is processed inline only when both participants share that
  runtime and admission permits; otherwise the receiver retains a copy within its own
  ingress limits. The sender's request completes locally either way.
* **MCU:** network driver callbacks run in interrupt or driver context. They place a
  bounded event (a buffer reference from the stack, or a copy) on a fixed ring and call
  `wake()`; they never call DDS. `service` drains the ring under the ingress rules, and
  send completions return through the same ring.

<a id="validation"></a>
## Validation

* A scripted test adapter replays readiness, completions, would-block and partial sends
  against the fake runtime clock, with no sockets or wall-clock sleeps. The mock and lossy
  transports are its starting point.
* Tests cover a wake racing `wait` (also under TSan), ingress exhaustion on UDP and TCP,
  partial TCP output with a channel closing midway, a dial that fails while output is
  pending, a stale `Channel` after slot reuse, and an interface change with retained
  leases outstanding.
* Manual mode runs a reliable pair over loopback UDP through `drive()` alone, with no
  thread started by zzdds.

<a id="phasing"></a>
## Phasing

| Stage | Transport work |
| --- | --- |
| Runtime core | The progress backend interface (`wake`, `prepare_wait`, `wait`, `service`), with a futex or condition implementation and a scripted one for tests |
| First vertical slice | The in-process adapter: ingress delivery, retention and output outcomes for the memory transport |
| Endpoint migration | The readiness adapter for UDP and then TCP, in hosted and manual mode; submissions with gather lists; channel slots; the per-socket threads and graveyards deleted |
| Later | A completion adapter, and an MCU adapter with a real network stack |

The external-loop adapter's handle and wake representation remain the open design item;
the readiness adapter is the first backend that has handles to expose.
