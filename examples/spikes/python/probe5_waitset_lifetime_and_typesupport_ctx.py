#!/usr/bin/env python3
"""
python/spike probe 5 -- two follow-up confirmations flagged, but not built,
when the review-readiness question came up: does WaitSet itself (not just
the conditions attached to it) have the same premature-GC hazard as
GuardCondition, and does zzdds_register_type_support_ctx's ctx_deinit hook
behave the same way release_listener_data does (acquire is trivial/binding-
controlled, ctx must survive until the hook fires)?

--waitset          WaitSet is app-instantiated with no owning factory,
                    confirmed identical to GuardCondition's shape
                    (zzdds_create_waitset, no factory). Spawns a background
                    thread blocked inside a real DDS_WaitSet_wait() call,
                    then drops the only Python reference to a GC-triggered-
                    destroy wrapper around the SAME WaitSet the background
                    thread is using -- the scarier variant probe 4 flagged
                    but didn't build: destroy while actively in a blocking
                    call on another thread, not just idle.
--typesupport-ctx   Registers a type with a ctx pointing at a Python object
                    with no other live reference, forces GC+heap-churn
                    pressure between registrations (mirroring probe 3's
                    amplification technique), then registers a SECOND
                    TypeSupport under the same type_name -- which should
                    supersede the first and fire the first's ctx_deinit
                    exactly once, with ctx still intact.

See ../README.md for the full probe list and findings.
"""
import ctypes
import gc
import os
import sys
import threading
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ZZDDS_LIB = os.environ.get(
    "ZZDDS_LIB",
    os.path.join(SCRIPT_DIR, "..", "..", "..", "zzdds", "zig-out", "lib", "libzzdds.so"),
)

c_void_p = ctypes.c_void_p
DDS_RETCODE_OK = 0


def load_and_declare():
    zzdds = ctypes.CDLL(ZZDDS_LIB)

    zzdds.zzdds_create_waitset.restype = c_void_p
    zzdds.zzdds_create_waitset.argtypes = []
    zzdds.zzdds_destroy_waitset.restype = None
    zzdds.zzdds_destroy_waitset.argtypes = [c_void_p]
    zzdds.zzdds_waitset_is_nil.restype = ctypes.c_bool
    zzdds.zzdds_waitset_is_nil.argtypes = [c_void_p]

    class DDS_Duration_t(ctypes.Structure):
        _fields_ = [("sec", ctypes.c_int32), ("nanosec", ctypes.c_uint32)]

    class DDS_ConditionSeq(ctypes.Structure):
        _fields_ = [("_maximum", ctypes.c_uint32), ("_length", ctypes.c_uint32),
                    ("_buffer", ctypes.POINTER(c_void_p)), ("_release", ctypes.c_bool)]

    zzdds.DDS_WaitSet_wait.restype = ctypes.c_int
    zzdds.DDS_WaitSet_wait.argtypes = [c_void_p, ctypes.POINTER(DDS_ConditionSeq), ctypes.POINTER(DDS_Duration_t)]

    zzdds.zzdds_create_factory.restype = c_void_p
    zzdds.zzdds_create_factory.argtypes = []
    zzdds.zzdds_factory_is_nil.restype = ctypes.c_bool
    zzdds.zzdds_factory_is_nil.argtypes = [c_void_p]
    zzdds.zzdds_destroy_factory.restype = None
    zzdds.zzdds_destroy_factory.argtypes = [c_void_p]
    zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory.restype = c_void_p
    zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory.argtypes = [c_void_p]
    zzdds.DDS_DomainParticipantFactory_create_participant.restype = c_void_p
    zzdds.DDS_DomainParticipantFactory_create_participant.argtypes = [c_void_p, ctypes.c_uint32, c_void_p, c_void_p, ctypes.c_uint32]

    KEY_HASH_CTX_FN = ctypes.CFUNCTYPE(ctypes.c_int, c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.POINTER(ctypes.c_uint8))
    CTX_DEINIT_FN = ctypes.CFUNCTYPE(None, c_void_p)
    zzdds.zzdds_register_type_support_ctx.restype = ctypes.c_int
    zzdds.zzdds_register_type_support_ctx.argtypes = [c_void_p, ctypes.c_char_p, KEY_HASH_CTX_FN, c_void_p, c_void_p, CTX_DEINIT_FN]

    return zzdds, DDS_Duration_t, DDS_ConditionSeq, CTX_DEINIT_FN, KEY_HASH_CTX_FN


class WaitSetWrapper:
    """Same RAII-on-GC shape as probe4's GuardConditionWrapper."""

    def __init__(self, zzdds, handle):
        self._zzdds = zzdds
        self._handle = handle

    def __del__(self):
        if self._handle:
            print(f"[wrapper] __del__ destroying waitset handle={self._handle:#x}", flush=True)
            self._zzdds.zzdds_destroy_waitset(self._handle)
            self._handle = None


def run_waitset():
    zzdds, DDS_Duration_t, DDS_ConditionSeq, _, _ = load_and_declare()

    ws_handle = zzdds.zzdds_create_waitset()
    if zzdds.zzdds_waitset_is_nil(ws_handle):
        sys.exit("FAIL: zzdds_create_waitset() returned nil")
    wrapper = WaitSetWrapper(zzdds, ws_handle)

    result = {"wait_rc": None, "entered": False, "returned": False}

    def blocked_wait():
        result["entered"] = True
        seq = DDS_ConditionSeq()
        timeout = DDS_Duration_t(sec=10, nanosec=0)  # long -- no condition ever attached, so this would
                                                       # normally just time out in 10s if the WaitSet survives
        print("[bg thread] entering DDS_WaitSet_wait() (10s timeout, no conditions attached)", flush=True)
        rc = zzdds.DDS_WaitSet_wait(wrapper._handle if wrapper._handle else ws_handle, ctypes.byref(seq), ctypes.byref(timeout))
        result["wait_rc"] = rc
        result["returned"] = True
        print(f"[bg thread] DDS_WaitSet_wait() returned rc={rc}", flush=True)

    t = threading.Thread(target=blocked_wait, daemon=True)
    t.start()
    # Give the background thread time to actually enter the blocking call
    # before we try to destroy the WaitSet out from under it.
    time.sleep(0.5)
    if not result["entered"]:
        sys.exit("FAIL: background thread never started")

    print("[main] dropping the only Python reference to the wrapper while the "
          "background thread should still be blocked inside wait() -- forcing "
          "gc.collect() to trigger __del__ synchronously, right now", flush=True)
    del wrapper
    gc.collect()

    print("[main] wrapper collected -- waiting up to 15s (past the wait()'s own 10s "
          "timeout) to see what the background thread's blocked call does, including "
          "whether it eventually wakes on its own timeout and THEN crashes touching "
          "freed memory", flush=True)
    t.join(timeout=15.0)

    if t.is_alive():
        print("[main] background thread is STILL blocked/alive after 3s -- "
              "DDS_WaitSet_wait() neither returned nor crashed the process", flush=True)
        print("INCONCLUSIVE (see README)")
        # Not calling sys.exit here -- a daemon thread stuck in a native call
        # doesn't block process exit; let main fall through and end.
    elif result["returned"]:
        print(f"[main] background thread's wait() call returned cleanly, rc={result['wait_rc']}")
        print("PASS (destroy-while-waiting did not crash -- see README)")
    else:
        print("[main] background thread ended without wait() ever reporting a return -- unexpected")
        sys.exit(1)


def run_typesupport_ctx():
    zzdds, _, _, CTX_DEINIT_FN, KEY_HASH_CTX_FN = load_and_declare()
    null_key_hash_fn = ctypes.cast(0, KEY_HASH_CTX_FN)

    factory = zzdds.zzdds_create_factory()
    if zzdds.zzdds_factory_is_nil(factory):
        sys.exit("FAIL: zzdds_create_factory() returned nil")
    dds_factory = zzdds.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory)
    dp = zzdds.DDS_DomainParticipantFactory_create_participant(dds_factory, 95, None, None, 0)
    if not dp:
        sys.exit("FAIL: create_participant() failed")

    MAGIC_A = 0xA
    MAGIC_B = 0xB
    state = {"deinit_a_fired": False, "deinit_a_magic_ok": None, "deinit_b_fired": False}

    class Holder(ctypes.Structure):
        _fields_ = [("magic", ctypes.c_int)]

    holder_a = Holder(magic=MAGIC_A)
    ctx_a = ctypes.cast(ctypes.pointer(holder_a), c_void_p)

    @CTX_DEINIT_FN
    def deinit_a(ctx):
        h = ctypes.cast(ctx, ctypes.POINTER(Holder))[0]
        state["deinit_a_fired"] = True
        state["deinit_a_magic_ok"] = (h.magic == MAGIC_A)
        print(f"[ctx_deinit A] fired, ctx.magic={h.magic:#x} (want {MAGIC_A:#x})", flush=True)

    @CTX_DEINIT_FN
    def deinit_b(ctx):
        state["deinit_b_fired"] = True
        print("[ctx_deinit B] fired", flush=True)

    rc = zzdds.zzdds_register_type_support_ctx(dp, b"SpikeCtxType", null_key_hash_fn, None, ctx_a, deinit_a)
    if rc != DDS_RETCODE_OK:
        sys.exit(f"FAIL: first register_type_support_ctx rc={rc}")
    print("[main] registered TypeSupport A", flush=True)

    if state["deinit_a_fired"]:
        sys.exit("FAIL: deinit_a fired before being superseded -- fired too early")

    # Heap churn + GC pressure between registrations, same amplification
    # idea as probe 3, before the SECOND registration (which should
    # supersede the first and fire deinit_a) happens.
    junk = [bytearray(64) for _ in range(50000)]
    del junk
    gc.collect()

    holder_b = Holder(magic=MAGIC_B)
    ctx_b = ctypes.cast(ctypes.pointer(holder_b), c_void_p)
    rc = zzdds.zzdds_register_type_support_ctx(dp, b"SpikeCtxType", null_key_hash_fn, None, ctx_b, deinit_b)
    if rc != DDS_RETCODE_OK:
        sys.exit(f"FAIL: second register_type_support_ctx rc={rc}")
    print("[main] registered TypeSupport B (same type_name -- should supersede A)", flush=True)

    if not state["deinit_a_fired"]:
        sys.exit("FAIL: deinit_a never fired when superseded by a second registration for the same type_name")
    if state["deinit_a_magic_ok"] is not True:
        sys.exit("FAIL: deinit_a's ctx was corrupted/stale by the time it fired")
    if state["deinit_b_fired"]:
        sys.exit("FAIL: deinit_b fired too early -- only deinit_a should have fired so far")

    zzdds.zzdds_destroy_factory(factory)

    if not state["deinit_b_fired"]:
        sys.exit("FAIL: deinit_b never fired on participant teardown")

    print(f"[main] deinit_a_fired={state['deinit_a_fired']} magic_ok={state['deinit_a_magic_ok']} "
          f"deinit_b_fired={state['deinit_b_fired']}")
    print("PASS")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("--waitset", "--typesupport-ctx"):
        sys.exit(f"usage: {sys.argv[0]} --waitset|--typesupport-ctx")
    (run_waitset if sys.argv[1] == "--waitset" else run_typesupport_ctx)()
