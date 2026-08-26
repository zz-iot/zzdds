#!/usr/bin/env python3
"""
python/spike probe 1 -- the cheapest possible "does a zzdds-internal thread
correctly call into Python for the first time" check.

Creates a participant + a keyless topic + a subscriber + one DataReader with
a 1-second DEADLINE period, on a topic nobody ever writes to. Nothing else
happens. zzdds's per-participant timer thread (spawned unconditionally in
DomainParticipantImpl.start(), ticking every 100ms, see zzdds's own
docs/roadmap.md "DEADLINE/LIVELINESS QoS is now enforced automatically")
fires DDS_DataReaderListener.on_requested_deadline_missed once per second,
forever, entirely on its own -- no writer, no data flow, no second process.

That timer thread is a plain Zig std.Thread.spawn, never created by Python
and never announced to the interpreter. This is ctypes.CFUNCTYPE's job to
handle transparently: the auto-generated glue for a CFUNCTYPE callback calls
PyGILState_Ensure()/PyGILState_Release() around every invocation, which is
supposed to bootstrap a "dummy thread" Python thread state for a
never-before-seen OS thread the first time it calls in -- the direct
structural analogue of JNI's AttachCurrentThreadAsDaemon, which is what the
Java binding already relies on for this exact situation. This probe doesn't
trust that documented behavior blindly -- it tries to observe it directly:
each callback invocation prints threading.get_native_id() and
threading.current_thread(), which should show a distinct OS thread ID from
the main thread and a synthesized "Dummy-N" thread object, not the main
thread's identity.

See README.md for the full probe list and what's still open.
"""
import ctypes
import os
import sys
import threading
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

ZZDDS_LIB = os.environ.get(
    "ZZDDS_LIB",
    os.path.join(SCRIPT_DIR, "..", "..", "..", "zzdds", "zig-out", "lib", "libzzdds.so"),
)
SHIM_LIB = os.environ.get("SPIKE_SHIM_LIB", os.path.join(SCRIPT_DIR, "libspike_shim.so"))

DOMAIN_ID = 40
DEADLINE_PERIOD_SEC = 1
RUN_SECONDS = 10
MIN_EXPECTED_FIRES = 5  # generous floor for a 10s run at a 1s period

DDS_RETCODE_OK = 0
DDS_REQUESTED_DEADLINE_MISSED_STATUS = 4

c_void_p = ctypes.c_void_p


def load_libs():
    if not os.path.exists(ZZDDS_LIB):
        sys.exit(f"FAIL: libzzdds.so not found at {ZZDDS_LIB} -- build zzdds first "
                  f"(zig build -Dc-binding=true install) or set ZZDDS_LIB")
    if not os.path.exists(SHIM_LIB):
        sys.exit(f"FAIL: libspike_shim.so not found at {SHIM_LIB} -- run "
                  f"'gcc -shared -fPIC -I<zzdds>/zig-out/include -o libspike_shim.so spike_shim.c' first")
    zzdds = ctypes.CDLL(ZZDDS_LIB)
    shim = ctypes.CDLL(SHIM_LIB)
    return zzdds, shim


def declare_signatures(zzdds, shim):
    zzdds.zzdds_create_factory.restype = c_void_p
    zzdds.zzdds_create_factory.argtypes = []

    zzdds.zzdds_factory_is_nil.restype = ctypes.c_bool
    zzdds.zzdds_factory_is_nil.argtypes = [c_void_p]

    zzdds.zzdds_destroy_factory.restype = None
    zzdds.zzdds_destroy_factory.argtypes = [c_void_p]

    zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory.restype = c_void_p
    zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory.argtypes = [c_void_p]

    zzdds.DDS_DomainParticipantFactory_create_participant.restype = c_void_p
    zzdds.DDS_DomainParticipantFactory_create_participant.argtypes = [
        c_void_p, ctypes.c_uint32, c_void_p, c_void_p, ctypes.c_uint32,
    ]

    zzdds.zzdds_register_type_support.restype = ctypes.c_int
    zzdds.zzdds_register_type_support.argtypes = [c_void_p, ctypes.c_char_p, c_void_p, c_void_p]

    zzdds.DDS_DomainParticipant_create_topic.restype = c_void_p
    zzdds.DDS_DomainParticipant_create_topic.argtypes = [
        c_void_p, ctypes.c_char_p, ctypes.c_char_p, c_void_p, c_void_p, ctypes.c_uint32,
    ]

    zzdds.DDS_Topic_as_DDS_TopicDescription.restype = c_void_p
    zzdds.DDS_Topic_as_DDS_TopicDescription.argtypes = [c_void_p]

    zzdds.DDS_DomainParticipant_create_subscriber.restype = c_void_p
    zzdds.DDS_DomainParticipant_create_subscriber.argtypes = [c_void_p, c_void_p, c_void_p, ctypes.c_uint32]

    zzdds.DDS_DataReaderQos_default.restype = None
    zzdds.DDS_DataReaderQos_default.argtypes = [c_void_p]

    zzdds.DDS_Subscriber_create_datareader.restype = c_void_p
    zzdds.DDS_Subscriber_create_datareader.argtypes = [
        c_void_p, c_void_p, c_void_p, c_void_p, ctypes.c_uint32,
    ]

    shim.spike_sizeof_reader_qos.restype = ctypes.c_size_t
    shim.spike_sizeof_reader_qos.argtypes = []

    shim.spike_set_reader_deadline.restype = None
    shim.spike_set_reader_deadline.argtypes = [c_void_p, ctypes.c_int32, ctypes.c_uint32]


# DDS_DataReaderListener field order, straight from zig-out/include/dcps.h --
# see that file if this backend's generated struct ever reorders fields.
ON_REQ_DEADLINE_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)
ON_REQ_INCOMPAT_QOS_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)
ON_SAMPLE_REJECTED_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)
ON_LIVELINESS_CHANGED_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)
ON_DATA_AVAILABLE_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p)
ON_SUBSCRIPTION_MATCHED_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)
ON_SAMPLE_LOST_CB = ctypes.CFUNCTYPE(None, c_void_p, c_void_p, c_void_p)
RELEASE_LISTENER_DATA_CB = ctypes.CFUNCTYPE(None, c_void_p)


class DDS_DataReaderListener(ctypes.Structure):
    _fields_ = [
        ("listener_data", c_void_p),
        ("on_requested_deadline_missed", ON_REQ_DEADLINE_CB),
        ("on_requested_incompatible_qos", ON_REQ_INCOMPAT_QOS_CB),
        ("on_sample_rejected", ON_SAMPLE_REJECTED_CB),
        ("on_liveliness_changed", ON_LIVELINESS_CHANGED_CB),
        ("on_data_available", ON_DATA_AVAILABLE_CB),
        ("on_subscription_matched", ON_SUBSCRIPTION_MATCHED_CB),
        ("on_sample_lost", ON_SAMPLE_LOST_CB),
        ("release_listener_data", RELEASE_LISTENER_DATA_CB),
    ]


def main():
    zzdds, shim = load_libs()
    declare_signatures(zzdds, shim)

    main_native_id = threading.get_native_id()
    print(f"[main] pid={os.getpid()} main_native_id={main_native_id} "
          f"main_thread={threading.current_thread()!r}")

    state = {"fires": 0, "releases": 0, "native_ids_seen": set(), "foreign_thread_confirmed": False}

    @ON_REQ_DEADLINE_CB
    def on_requested_deadline_missed(reader, status_ptr, listener_data):
        # total_count is field 0 of DDS_RequestedDeadlineMissedStatus --
        # reading just the first int32 is safe regardless of what follows.
        total_count = ctypes.cast(status_ptr, ctypes.POINTER(ctypes.c_int32))[0]
        native_id = threading.get_native_id()
        current = threading.current_thread()
        state["fires"] += 1
        state["native_ids_seen"].add(native_id)
        if native_id != main_native_id:
            state["foreign_thread_confirmed"] = True
        print(f"[callback] on_requested_deadline_missed total_count={total_count} "
              f"native_id={native_id} current_thread={current!r} "
              f"is_main_thread={native_id == main_native_id}")

    @RELEASE_LISTENER_DATA_CB
    def release_listener_data(listener_data):
        state["releases"] += 1
        print(f"[callback] release_listener_data fired native_id={threading.get_native_id()}")

    listener = DDS_DataReaderListener()
    listener.listener_data = None
    listener.on_requested_deadline_missed = on_requested_deadline_missed
    listener.on_requested_incompatible_qos = ON_REQ_INCOMPAT_QOS_CB(0)
    listener.on_sample_rejected = ON_SAMPLE_REJECTED_CB(0)
    listener.on_liveliness_changed = ON_LIVELINESS_CHANGED_CB(0)
    listener.on_data_available = ON_DATA_AVAILABLE_CB(0)
    listener.on_subscription_matched = ON_SUBSCRIPTION_MATCHED_CB(0)
    listener.on_sample_lost = ON_SAMPLE_LOST_CB(0)
    listener.release_listener_data = release_listener_data

    factory = zzdds.zzdds_create_factory()
    if zzdds.zzdds_factory_is_nil(factory):
        sys.exit("FAIL: zzdds_create_factory() returned nil")

    dds_factory = zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory)
    dp = zzdds.DDS_DomainParticipantFactory_create_participant(dds_factory, DOMAIN_ID, None, None, 0)
    if not dp:
        sys.exit(f"FAIL: create_participant() failed on domain {DOMAIN_ID}")

    # Keyless, no CDR/TypeSupport needed at all -- this probe never writes or
    # reads a sample, only exercises DEADLINE timer callback delivery.
    rc = zzdds.zzdds_register_type_support(dp, b"SpikeType", None, None)
    if rc != DDS_RETCODE_OK:
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
    shim.spike_set_reader_deadline(qos_buf, DEADLINE_PERIOD_SEC, 0)

    reader = zzdds.DDS_Subscriber_create_datareader(
        sub, topic_desc, qos_buf, ctypes.byref(listener), DDS_REQUESTED_DEADLINE_MISSED_STATUS
    )
    if not reader:
        sys.exit("FAIL: create_datareader() failed")

    print(f"[main] reader created with {DEADLINE_PERIOD_SEC}s DEADLINE, no writer -- "
          f"waiting {RUN_SECONDS}s for on_requested_deadline_missed to fire repeatedly...")
    time.sleep(RUN_SECONDS)

    print(f"[main] fires={state['fires']} releases_so_far={state['releases']} "
          f"distinct_native_ids={state['native_ids_seen']} "
          f"foreign_thread_confirmed={state['foreign_thread_confirmed']}")

    if state["fires"] < MIN_EXPECTED_FIRES:
        sys.exit(f"FAIL: expected >= {MIN_EXPECTED_FIRES} deadline-missed callbacks in {RUN_SECONDS}s, got {state['fires']}")
    if not state["foreign_thread_confirmed"]:
        sys.exit("FAIL: every callback ran on the main thread's native id -- "
                  "timer thread callback delivery was not actually exercised")

    zzdds.zzdds_destroy_factory(factory)
    print(f"[main] teardown done; release_listener_data fired {state['releases']} time(s) total")
    print("PASS")


if __name__ == "__main__":
    main()
