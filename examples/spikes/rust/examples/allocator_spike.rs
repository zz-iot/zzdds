//! spikes/rust — allocator injection probe. Fills the one gap the main
//! loan-cycle spike (`src/main.rs`) explicitly left open ("Allocator-
//! injection interaction with Rust's own allocator story — not examined",
//! `README.md`'s "Non-findings" section): does zzdds's `ZidlAllocator`
//! C-ABI injection point work from Rust, and what's the realistic ceiling
//! for a real future Rust binding's create/destroy story given Rust's
//! *current stable* allocator ecosystem? See README.md's new "Allocator
//! injection" section for the full writeup and findings — this file is the
//! probe, not the analysis.
//!
//! Deliberately small: one factory, one WaitSet, one GuardCondition, all
//! under the same caller-supplied allocator (zzdds-examples' existing
//! `static_pool_allocator.c`, reused via FFI — copied into this directory,
//! not reimplemented in Rust, since the question here is whether Rust can
//! *consume* a ZidlAllocator across the C ABI, not whether it can implement
//! one). No loan cycle, no sample exchange — that's already covered by
//! `src/main.rs`; this probe is scoped to the create/destroy+allocator
//! question alone.
use zzdds_rust_spike::ffi;

fn main() {
    unsafe {
        ffi::static_pool_allocator_reset();
        let allocator: *const ffi::ZidlAllocator = &raw const ffi::static_pool_allocator;

        // Every allocation the factory and everything it creates makes is
        // now routed through the pool -- same contract as the C/C++
        // examples' zzdds_create_factory_with_allocator usage, just called
        // from Rust across the same C ABI, no bindgen, no unstable
        // features.
        let factory = ffi::zzdds_create_factory_with_allocator(allocator);
        assert!(!ffi::zzdds_factory_is_nil(factory), "zzdds_create_factory_with_allocator returned nil");
        println!("[allocator_spike] factory created under static-pool allocator");

        // WaitSet/GuardCondition: the two condition-family types with no
        // factory operation (app-instantiated directly, per OMG spec) --
        // this session's `get_allocator` vtable accessor work made their
        // `wait()` output's native-temporary-buffer free entity-specific
        // rather than process-wide; exercising that here from Rust is a
        // second, independent confirmation of that fix (already verified
        // this session via the C/C++ custom-allocator examples' own
        // `noalloc_guard`), not a new claim about Rust's own allocator
        // story specifically.
        let waitset = ffi::zzdds_create_waitset_with_allocator(allocator);
        assert!(!ffi::zzdds_waitset_is_nil(waitset), "zzdds_create_waitset_with_allocator returned nil");
        let guard = ffi::zzdds_create_guardcondition_with_allocator(allocator);
        assert!(
            !ffi::zzdds_guardcondition_is_nil(guard),
            "zzdds_create_guardcondition_with_allocator returned nil"
        );
        println!("[allocator_spike] WaitSet + GuardCondition created under the same allocator");

        let guard_cond = ffi::DDS_GuardCondition_as_DDS_Condition(guard);
        let rc = ffi::DDS_WaitSet_attach_condition(waitset, guard_cond);
        assert_eq!(rc, ffi::DDS_RETCODE_OK, "WaitSet_attach_condition failed rc={}", rc);

        let rc = ffi::DDS_GuardCondition_set_trigger_value(guard, true);
        assert_eq!(rc, ffi::DDS_RETCODE_OK, "GuardCondition_set_trigger_value failed rc={}", rc);

        let mut active = ffi::DDS_ConditionSeq::empty();
        let timeout = ffi::DDS_Duration_t { sec: 1, nanosec: 0 };
        let rc = ffi::DDS_WaitSet_wait(waitset, &mut active, &timeout);
        assert_eq!(rc, ffi::DDS_RETCODE_OK, "WaitSet_wait failed rc={}", rc);

        let fired = active.as_slice().iter().any(|&c| c == guard_cond);
        ffi::DDS_ConditionSeq_free(&mut active);
        assert!(fired, "WaitSet_wait did not report the triggered GuardCondition");
        println!("[allocator_spike] wait() reported the triggered GuardCondition — OK");

        ffi::DDS_WaitSet_detach_condition(waitset, guard_cond);
        ffi::zzdds_destroy_guardcondition(guard);
        ffi::zzdds_destroy_waitset(waitset);
        ffi::zzdds_destroy_factory(factory);

        println!("PASS");
    }
}
