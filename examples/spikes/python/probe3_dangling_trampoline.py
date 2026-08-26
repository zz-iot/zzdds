#!/usr/bin/env python3
"""
python/spike probe 3 -- the adversarial one. Deliberately violates the
"keep the listener alive" contract and checks whether anything protects
against the result.

Background: zzdds's DDS_DataReaderListener carries an explicit
release_listener_data(void *listener_data) field -- zzdds's own way of
telling a binding "I'm done calling through this listener's function
pointers, it's now safe to free whatever you were keeping alive on my
behalf." zzdds's ListenerBox/EntityQuiesce refcounting (see zzdds's
docs/roadmap.md "Entity quiesce decision" / "Listener release hook
decision") makes sure that hook fires at the right time relative to
in-flight callback dispatch -- but that machinery protects the DDS
*entity*'s lifetime (the reader/writer), not the *native function pointer's
own backing memory*, which is an entirely different, Python/ctypes-side
concern zzdds's C code has no visibility into at all.

Concretely: create_datareader() copies the DDS_DataReaderListener struct's
function-pointer VALUES (raw addresses) into zzdds's internal storage. Those
addresses point at trampoline code ctypes generates and owns for as long as
the corresponding CFUNCTYPE Python object is alive. If a binding drops every
Python reference to that CFUNCTYPE object -- NOT the ctypes.Structure that
was passed in, which is no longer needed the moment create_datareader()
returns, but the actual callable -- before the DDS entity is destroyed and
before release_listener_data has fired, ctypes is free to deallocate the
trampoline. The next time zzdds's internal timer thread tries to call
through that now-dangling function pointer, that's a jump into freed (and,
worse, possibly-since-reused) memory: undefined behavior, most likely a
segfault, not a Python exception -- release_listener_data existing does NOT
save you here, because the mistake being tested is exactly "the binding
didn't wait for it."

This can't be safely tested in-process (a real crash should segfault the
interpreter, by design -- that's the finding). Each mode below is run as an
isolated subprocess so a crash in --unsafe doesn't take the harness down
with it, and the exit code (negative == died from that signal on POSIX) is
what actually gets checked, not any Python-level exception.

Modes:
  --safe    Keeps the callback objects alive (the correct pattern probes 1/2
            already relied on implicitly) -- expected to run clean.
  --unsafe  Drops every Python reference to the callback objects immediately
            after create_datareader() returns, forces gc.collect(), then
            churns the heap to encourage the freed trampoline memory to
            actually get reused before waiting for a deadline tick to try to
            call through it. Expected to crash -- if it doesn't, that's
            itself worth knowing (see README's findings section for which
            outcome this run actually produced).
"""
import ctypes
import gc
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe1_deadline_timer as p

DOMAIN_ID = 60
DEADLINE_PERIOD_NSEC = 100_000_000  # 100ms
RUN_SECONDS = 5
HEAP_CHURN_ROUNDS = 20000  # encourage the freed trampoline's memory to be reused, not just freed


def heap_churn():
    # Allocate/free a lot of same-ish-sized objects so whatever allocator
    # ctypes' trampoline memory came from is under real pressure to reuse
    # it -- a freed-but-never-reused pointer can "coincidentally" still
    # work, which would be a false pass, not a real one.
    junk = []
    for _ in range(HEAP_CHURN_ROUNDS):
        junk.append(bytearray(64))
        if len(junk) > 500:
            junk.pop(0)


def run(mode):
    zzdds, shim = p.load_libs()
    p.declare_signatures(zzdds, shim)

    state = {"fires": 0}

    @p.ON_REQ_DEADLINE_CB
    def cb(reader, status_ptr, listener_data):
        state["fires"] += 1
        print(f"[callback] fired (fires={state['fires']})", flush=True)

    @p.RELEASE_LISTENER_DATA_CB
    def release_cb(listener_data):
        print("[callback] release_listener_data fired", flush=True)

    listener = p.DDS_DataReaderListener()
    listener.listener_data = None
    listener.on_requested_deadline_missed = cb
    listener.on_requested_incompatible_qos = p.ON_REQ_INCOMPAT_QOS_CB(0)
    listener.on_sample_rejected = p.ON_SAMPLE_REJECTED_CB(0)
    listener.on_liveliness_changed = p.ON_LIVELINESS_CHANGED_CB(0)
    listener.on_data_available = p.ON_DATA_AVAILABLE_CB(0)
    listener.on_subscription_matched = p.ON_SUBSCRIPTION_MATCHED_CB(0)
    listener.on_sample_lost = p.ON_SAMPLE_LOST_CB(0)
    listener.release_listener_data = release_cb

    factory = zzdds.zzdds_create_factory()
    if zzdds.zzdds_factory_is_nil(factory):
        sys.exit("FAIL: zzdds_create_factory() returned nil")
    dds_factory = zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory)
    dp = zzdds.DDS_DomainParticipantFactory_create_participant(dds_factory, DOMAIN_ID, None, None, 0)
    if not dp:
        sys.exit("FAIL: create_participant() failed")

    rc = zzdds.zzdds_register_type_support(dp, b"SpikeType", None, None)
    if rc != p.DDS_RETCODE_OK:
        sys.exit(f"FAIL: register_type_support failed rc={rc}")

    topic = zzdds.DDS_DomainParticipant_create_topic(dp, b"SpikeTopic", b"SpikeType", None, None, 0)
    topic_desc = zzdds.DDS_Topic_as_DDS_TopicDescription(topic)
    sub = zzdds.DDS_DomainParticipant_create_subscriber(dp, None, None, 0)

    qos_buf = ctypes.create_string_buffer(shim.spike_sizeof_reader_qos())
    zzdds.DDS_DataReaderQos_default(qos_buf)
    shim.spike_set_reader_deadline(qos_buf, 0, DEADLINE_PERIOD_NSEC)

    reader = zzdds.DDS_Subscriber_create_datareader(
        sub, topic_desc, qos_buf, ctypes.byref(listener), p.DDS_REQUESTED_DEADLINE_MISSED_STATUS
    )
    if not reader:
        sys.exit("FAIL: create_datareader() failed")

    print(f"[main] mode={mode}: reader created, native side now holds raw pointers to "
          f"cb/release_cb's ctypes trampolines", flush=True)

    if mode == "unsafe":
        # The violation: create_datareader() already copied the function
        # POINTER VALUES out of `listener` -- `listener` itself is dead
        # weight now. What actually has to stay alive is `cb`/`release_cb`
        # themselves, and this drops the only references to them.
        del cb
        del release_cb
        del listener
        gc.collect()
        print("[main] dropped all Python references to the callback objects + gc.collect() done "
              "-- churning the heap, then waiting for a deadline tick to try to call through them", flush=True)
        heap_churn()
        gc.collect()
    else:
        print("[main] keeping callback objects alive (correct pattern) -- waiting for deadline ticks", flush=True)

    time.sleep(RUN_SECONDS)

    print(f"[main] survived {RUN_SECONDS}s post-setup, fires={state['fires']}", flush=True)
    zzdds.zzdds_destroy_factory(factory)
    print("[main] teardown completed without crashing", flush=True)
    print("PASS" if mode == "safe" else "PASS (unsafe mode did not crash -- see README before trusting this)")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("--safe", "--unsafe"):
        sys.exit(f"usage: {sys.argv[0]} --safe|--unsafe")
    run("safe" if sys.argv[1] == "--safe" else "unsafe")
