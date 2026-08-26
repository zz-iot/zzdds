#!/usr/bin/env python3
"""
python/spike probe 4 -- does a WaitSet keep an attached condition alive, or
does attach_condition() need its own keepalive scheme the way listener
registration did?

Spec answer (see README/roadmap writeup for the full reasoning): no. WaitSet
attachment is always a non-owning reference. A GuardCondition specifically
has no owning entity at all -- the application is its only owner -- so if a
binding's wrapper object auto-destroys the native condition when the
wrapper itself is garbage collected (the natural, RAII-shaped thing a binding
author would likely write), attaching it to a WaitSet and then letting your
only Python reference drop is completely legal per spec and silently
undoes the attachment. zzdds's own condition/WaitSet lifecycle fix (see
zzdds's docs/roadmap.md "WaitSet / condition example") already guarantees
this can't dangle a pointer -- this probe isn't re-testing that. It's
testing the layer above: given that guarantee, what does premature,
GC-triggered destruction actually look like from the application's side?

Two demonstrations:

  --vanish   The "well-behaved" case: only the wrapper's own handle is ever
             touched again. Confirms the condition silently disappears from
             WaitSet.get_conditions() the moment the wrapper is collected --
             no error, no exception, it just isn't there anymore.
  --crash    The sharper case: something *else* also captured the raw
             handle before the wrapper was collected (a realistic pattern --
             cached in a lookup table, logged, handed to another API) and
             tries to use it afterward. Expected to crash: the native
             GuardCondition is genuinely freed, not just detached, so this
             is a real use-after-free, not merely "stopped triggering."
             Run as its own subprocess for the same reason probe 3's
             --unsafe mode was: a real crash should segfault the
             interpreter, that IS the finding.

Both modes create a standalone WaitSet + GuardCondition directly -- neither
needs a participant, topic, or any domain traffic (see zzdds's own
zzdds_create_waitset/zzdds_create_guardcondition doc comments: both are
app-instantiated with no owning factory).
"""
import ctypes
import gc
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ZZDDS_LIB = os.environ.get(
    "ZZDDS_LIB",
    os.path.join(SCRIPT_DIR, "..", "..", "..", "zzdds", "zig-out", "lib", "libzzdds.so"),
)

c_void_p = ctypes.c_void_p
DDS_RETCODE_OK = 0
DDS_RETCODE_TIMEOUT = 10


class DDS_Duration_t(ctypes.Structure):
    _fields_ = [("sec", ctypes.c_int32), ("nanosec", ctypes.c_uint32)]


class DDS_ConditionSeq(ctypes.Structure):
    _fields_ = [
        ("_maximum", ctypes.c_uint32),
        ("_length", ctypes.c_uint32),
        ("_buffer", ctypes.POINTER(c_void_p)),
        ("_release", ctypes.c_bool),
    ]


def load_and_declare():
    if not os.path.exists(ZZDDS_LIB):
        sys.exit(f"FAIL: libzzdds.so not found at {ZZDDS_LIB}")
    zzdds = ctypes.CDLL(ZZDDS_LIB)

    zzdds.zzdds_create_waitset.restype = c_void_p
    zzdds.zzdds_create_waitset.argtypes = []
    zzdds.zzdds_create_guardcondition.restype = c_void_p
    zzdds.zzdds_create_guardcondition.argtypes = []
    zzdds.zzdds_destroy_waitset.restype = None
    zzdds.zzdds_destroy_waitset.argtypes = [c_void_p]
    zzdds.zzdds_destroy_guardcondition.restype = None
    zzdds.zzdds_destroy_guardcondition.argtypes = [c_void_p]
    zzdds.zzdds_waitset_is_nil.restype = ctypes.c_bool
    zzdds.zzdds_waitset_is_nil.argtypes = [c_void_p]
    zzdds.zzdds_guardcondition_is_nil.restype = ctypes.c_bool
    zzdds.zzdds_guardcondition_is_nil.argtypes = [c_void_p]

    zzdds.DDS_GuardCondition_as_DDS_Condition.restype = c_void_p
    zzdds.DDS_GuardCondition_as_DDS_Condition.argtypes = [c_void_p]
    zzdds.DDS_GuardCondition_set_trigger_value.restype = ctypes.c_int
    zzdds.DDS_GuardCondition_set_trigger_value.argtypes = [c_void_p, ctypes.c_bool]

    zzdds.DDS_WaitSet_attach_condition.restype = ctypes.c_int
    zzdds.DDS_WaitSet_attach_condition.argtypes = [c_void_p, c_void_p]
    zzdds.DDS_WaitSet_detach_condition.restype = ctypes.c_int
    zzdds.DDS_WaitSet_detach_condition.argtypes = [c_void_p, c_void_p]
    zzdds.DDS_WaitSet_get_conditions.restype = ctypes.c_int
    zzdds.DDS_WaitSet_get_conditions.argtypes = [c_void_p, ctypes.POINTER(DDS_ConditionSeq)]
    zzdds.DDS_WaitSet_wait.restype = ctypes.c_int
    zzdds.DDS_WaitSet_wait.argtypes = [c_void_p, ctypes.POINTER(DDS_ConditionSeq), ctypes.POINTER(DDS_Duration_t)]
    zzdds.DDS_ConditionSeq_free.restype = None
    zzdds.DDS_ConditionSeq_free.argtypes = [ctypes.POINTER(DDS_ConditionSeq)]

    return zzdds


class GuardConditionWrapper:
    """The natural, RAII-shaped thing a binding author would plausibly
    write: destroy the native condition when the wrapper is collected.
    This is the design choice under test -- not a strawman, the obvious
    default absent a deliberate decision not to do this."""

    def __init__(self, zzdds, handle):
        self._zzdds = zzdds
        self._handle = handle

    def __del__(self):
        if self._handle:
            print(f"[wrapper] __del__ destroying guardcondition handle={self._handle:#x}", flush=True)
            self._zzdds.zzdds_destroy_guardcondition(self._handle)
            self._handle = None


def attached_count(zzdds, waitset):
    seq = DDS_ConditionSeq()
    rc = zzdds.DDS_WaitSet_get_conditions(waitset, ctypes.byref(seq))
    if rc != DDS_RETCODE_OK:
        sys.exit(f"FAIL: get_conditions() rc={rc}")
    n = seq._length
    zzdds.DDS_ConditionSeq_free(ctypes.byref(seq))
    return n


def run_vanish():
    zzdds = load_and_declare()

    waitset = zzdds.zzdds_create_waitset()
    if zzdds.zzdds_waitset_is_nil(waitset):
        sys.exit("FAIL: zzdds_create_waitset() returned nil")

    gc_handle = zzdds.zzdds_create_guardcondition()
    if zzdds.zzdds_guardcondition_is_nil(gc_handle):
        sys.exit("FAIL: zzdds_create_guardcondition() returned nil")

    wrapper = GuardConditionWrapper(zzdds, gc_handle)
    cond = zzdds.DDS_GuardCondition_as_DDS_Condition(wrapper._handle)

    rc = zzdds.DDS_WaitSet_attach_condition(waitset, cond)
    if rc != DDS_RETCODE_OK:
        sys.exit(f"FAIL: attach_condition() rc={rc}")

    before = attached_count(zzdds, waitset)
    print(f"[main] attached, get_conditions() reports {before} condition(s) (expect 1)")
    if before != 1:
        sys.exit(f"FAIL: expected 1 attached condition before drop, got {before}")

    print("[main] dropping the only Python reference to the wrapper, exactly like "
          "`gc = create_guardcondition(); waitset.attach_condition(gc)` with `gc` "
          "then going out of scope -- no explicit detach, no explicit destroy", flush=True)
    del wrapper
    gc.collect()

    after = attached_count(zzdds, waitset)
    print(f"[main] after drop+collect, get_conditions() reports {after} condition(s)")

    zzdds.zzdds_destroy_waitset(waitset)

    if after == 0:
        print("[main] CONFIRMED: the condition silently vanished from the waitset -- "
              "no error, no exception, attach_condition() did not keep it referenced")
        print("PASS (vanish confirmed)")
    else:
        print("[main] condition was still attached after the wrapper was collected -- "
              "either __del__ didn't run as expected, or something is keeping it alive")
        sys.exit("FAIL: expected the condition to have vanished")


def run_crash():
    zzdds = load_and_declare()

    waitset = zzdds.zzdds_create_waitset()
    if zzdds.zzdds_waitset_is_nil(waitset):
        sys.exit("FAIL: zzdds_create_waitset() returned nil")

    gc_handle = zzdds.zzdds_create_guardcondition()
    if zzdds.zzdds_guardcondition_is_nil(gc_handle):
        sys.exit("FAIL: zzdds_create_guardcondition() returned nil")

    wrapper = GuardConditionWrapper(zzdds, gc_handle)
    cond = zzdds.DDS_GuardCondition_as_DDS_Condition(wrapper._handle)
    zzdds.DDS_WaitSet_attach_condition(waitset, cond)

    # Realistic escape: something else captured the raw handle before the
    # wrapper went away -- a lookup table keyed by handle, a log line, a
    # second API that only needed the handle value, not the wrapper object.
    escaped_handle = wrapper._handle
    print(f"[main] escaped_handle={escaped_handle:#x} captured separately from the wrapper", flush=True)

    print("[main] dropping the wrapper (escaped_handle is untouched) + gc.collect()", flush=True)
    del wrapper
    gc.collect()

    print("[main] wrapper collected -- native GuardCondition should now be destroyed. "
          "Trying to use escaped_handle anyway (the realistic mistake: whoever holds "
          "escaped_handle has no way to know it's already dead)...", flush=True)
    zzdds.DDS_GuardCondition_set_trigger_value(escaped_handle, True)

    print("[main] survived the use-after-free call (see README before trusting this)", flush=True)
    zzdds.zzdds_destroy_waitset(waitset)
    print("PASS (crash mode did not crash -- see README)")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("--vanish", "--crash"):
        sys.exit(f"usage: {sys.argv[0]} --vanish|--crash")
    (run_vanish if sys.argv[1] == "--vanish" else run_crash)()
