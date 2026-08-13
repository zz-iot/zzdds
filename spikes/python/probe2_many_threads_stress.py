#!/usr/bin/env python3
"""
python/spike probe 2 -- does repeated first-time PyGILState_Ensure from many
DISTINCT, short-lived native OS threads leak (Python-side thread-state
bookkeeping, or native-side memory)?

Probe 1 already showed a single long-lived zzdds-internal thread calling
into Python repeatedly doesn't leak. That's not the same question as this
one: zzdds's writer heartbeat thread (src/dcps/writer_sm.zig) is *lazily
spawned on first match*, per writer -- an application that creates/destroys
many writers over its lifetime causes many DISTINCT native OS threads, each
hitting ctypes' PyGILState_Ensure for the very first time, then terminating.
That's the more realistic stress case for a long-running Python DDS process,
and it's the scenario a Go binding's cgo.Handle design and CPython's
PyGILState internal thread-state table would both actually be exercised by.

This probe doesn't orchestrate real writer/reader matching (that needs two
matched endpoints -- either real loopback discovery or a second process,
more moving parts than this spike needs) -- it substitutes the cheapest
equivalent-shape stress: repeatedly create a whole participant (which
unconditionally spawns its own per-participant DEADLINE/LIVELINESS timer
thread in start()) with a fast DEADLINE reader, let it fire at least once,
then tear the whole participant down (stopping that thread). Each iteration
is therefore a distinct, short-lived native OS thread doing exactly one
first-time PyGILState_Ensure/Release round trip. This is NOT literal
heartbeat-thread coverage -- true heartbeat-thread respawn stress is a
follow-up that needs a real matched pub/sub pair; noted here rather than
silently conflated with what this probe actually exercises.

Tracks, across N iterations:
  - Python thread-object leakage (threading.enumerate() should never grow)
  - process RSS growth (a native-side leak, not just a Python-side one,
    would show up here -- ctypes/CPython bookkeeping AND zzdds's own timer
    thread teardown are both in scope for this check)
"""
import ctypes
import gc
import os
import resource
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe1_deadline_timer as p  # reuse signatures/listener struct

ITERATIONS = 60
DEADLINE_PERIOD_NSEC = 150_000_000  # 150ms -- fast enough for >=1 fire per short-lived iteration
SETTLE_SEC = 0.25
BASE_DOMAIN_ID = 50  # +iteration, so back-to-back SPDP traffic from the
                      # just-torn-down previous participant can't confuse this one


def rss_kb():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss


def run_one_iteration(zzdds, shim, domain_id, state):
    @p.ON_REQ_DEADLINE_CB
    def cb(reader, status_ptr, listener_data):
        state["fires"] += 1
        state["native_ids_seen"].add(threading.get_native_id())

    listener = p.DDS_DataReaderListener()
    listener.listener_data = None
    listener.on_requested_deadline_missed = cb
    listener.on_requested_incompatible_qos = p.ON_REQ_INCOMPAT_QOS_CB(0)
    listener.on_sample_rejected = p.ON_SAMPLE_REJECTED_CB(0)
    listener.on_liveliness_changed = p.ON_LIVELINESS_CHANGED_CB(0)
    listener.on_data_available = p.ON_DATA_AVAILABLE_CB(0)
    listener.on_subscription_matched = p.ON_SUBSCRIPTION_MATCHED_CB(0)
    listener.on_sample_lost = p.ON_SAMPLE_LOST_CB(0)
    listener.release_listener_data = p.RELEASE_LISTENER_DATA_CB(0)

    factory = zzdds.zzdds_create_factory()
    if zzdds.zzdds_factory_is_nil(factory):
        sys.exit("FAIL: zzdds_create_factory() returned nil")
    dds_factory = zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory)
    dp = zzdds.DDS_DomainParticipantFactory_create_participant(dds_factory, domain_id, None, None, 0)
    if not dp:
        sys.exit(f"FAIL: create_participant() failed on domain {domain_id}")

    rc = zzdds.zzdds_register_type_support(dp, b"SpikeType", None, None)
    if rc != p.DDS_RETCODE_OK:
        sys.exit(f"FAIL: register_type_support failed rc={rc}")

    topic = zzdds.DDS_DomainParticipant_create_topic(dp, b"SpikeTopic", b"SpikeType", None, None, 0)
    if not topic:
        sys.exit("FAIL: create_topic() failed")
    topic_desc = zzdds.DDS_Topic_as_DDS_TopicDescription(topic)

    sub = zzdds.DDS_DomainParticipant_create_subscriber(dp, None, None, 0)
    if not sub:
        sys.exit("FAIL: create_subscriber() failed")

    qos_buf = ctypes.create_string_buffer(shim.spike_sizeof_reader_qos())
    zzdds.DDS_DataReaderQos_default(qos_buf)
    shim.spike_set_reader_deadline(qos_buf, 0, DEADLINE_PERIOD_NSEC)

    reader = zzdds.DDS_Subscriber_create_datareader(
        sub, topic_desc, qos_buf, ctypes.byref(listener), p.DDS_REQUESTED_DEADLINE_MISSED_STATUS
    )
    if not reader:
        sys.exit("FAIL: create_datareader() failed")

    time.sleep(SETTLE_SEC)
    zzdds.zzdds_destroy_factory(factory)
    # cb/listener must outlive the factory (native side may still be
    # mid-dispatch right up to destroy_factory returning) but not this
    # function -- drop them now, deliberately, and let gc.collect() below
    # prove nothing native still points at them. (Probe 3 is the dedicated,
    # adversarial version of "drop the reference *before* teardown".)


def main():
    zzdds, shim = p.load_libs()
    p.declare_signatures(zzdds, shim)

    state = {"fires": 0, "native_ids_seen": set()}

    baseline_threads = threading.active_count()
    baseline_rss = rss_kb()
    print(f"[main] baseline active_count={baseline_threads} rss_kb={baseline_rss}")

    for i in range(ITERATIONS):
        run_one_iteration(zzdds, shim, BASE_DOMAIN_ID + i, state)
        gc.collect()
        active = threading.active_count()
        dummies = [t for t in threading.enumerate() if "Dummy" in t.name]
        rss = rss_kb()
        print(f"[iter {i+1}/{ITERATIONS}] cumulative_fires={state['fires']} "
              f"distinct_native_ids_so_far={len(state['native_ids_seen'])} "
              f"active_count={active} dummy_threads_registered={len(dummies)} rss_kb={rss}")
        if active > baseline_threads:
            sys.exit(f"FAIL: thread leak -- active_count grew from {baseline_threads} to {active} "
                      f"at iteration {i+1}")

    final_rss = rss_kb()
    rss_growth = final_rss - baseline_rss
    print(f"[main] done: {ITERATIONS} distinct participants/timer-threads, "
          f"{len(state['native_ids_seen'])} distinct native thread ids observed in callbacks, "
          f"{state['fires']} total callback fires, rss_kb {baseline_rss} -> {final_rss} "
          f"(growth {rss_growth} kb)")

    if len(state["native_ids_seen"]) < ITERATIONS // 2:
        sys.exit(f"FAIL: expected close to {ITERATIONS} distinct native thread ids "
                  f"(one per iteration's timer thread), only saw {len(state['native_ids_seen'])} -- "
                  f"either threads are being reused unexpectedly or most iterations never fired")

    # Not a hard-fail threshold (RSS is noisy under a GC'd interpreter) --
    # printed as a flag for a human to look at, not asserted on.
    if rss_growth > 20_000:
        print(f"[main] WARNING: rss grew by {rss_growth} kb over {ITERATIONS} iterations -- "
              f"worth a longer run with a real leak-checker (valgrind/tracemalloc) before trusting this")

    print("PASS")


if __name__ == "__main__":
    main()
