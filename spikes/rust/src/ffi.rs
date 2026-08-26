//! Hand-declared `extern "C"` bindings for the small slice of zzdds's C-ABI
//! this spike needs. No bindgen (avoids a crates.io dependency for a
//! throwaway probe) -- mirrors the same "hand-declare just what's needed"
//! approach the Python spike used with ctypes.
#![allow(dead_code, non_camel_case_types, non_snake_case)]

use std::os::raw::{c_char, c_int, c_void};

pub type DDS_DomainParticipantFactory = *mut c_void;
pub type ZzddsDomainParticipantFactory = *mut c_void;
pub type DDS_DomainParticipant = *mut c_void;
pub type DDS_Topic = *mut c_void;
pub type DDS_TopicDescription = *mut c_void;
pub type DDS_Publisher = *mut c_void;
pub type DDS_Subscriber = *mut c_void;
pub type DDS_DataWriter = *mut c_void;
pub type DDS_DataReader = *mut c_void;
pub type DDS_ReturnCode_t = c_int;
pub type DDS_InstanceHandle_t = i32;

pub const DDS_RETCODE_OK: DDS_ReturnCode_t = 0;
pub const DDS_HANDLE_NIL: DDS_InstanceHandle_t = 0;

pub type DDS_ReadCondition = *mut c_void;
pub type DDS_SampleStateMask = u32;
pub type DDS_ViewStateMask = u32;
pub type DDS_InstanceStateMask = u32;

pub const DDS_ANY_SAMPLE_STATE: DDS_SampleStateMask = 65535;
pub const DDS_ANY_VIEW_STATE: DDS_ViewStateMask = 65535;
pub const DDS_ANY_INSTANCE_STATE: DDS_InstanceStateMask = 65535;
pub const DDS_TIME_INVALID_SEC: i32 = -1;
pub const DDS_TIME_INVALID_NSEC: u32 = 4294967295;

// ── Allocator-spike additions (queue item 5, generated-class-lifecycle-design.md) ──
//
// WaitSet/GuardCondition are opaque C-ABI handles, same shape as every other
// entity in this file -- no new representation needed.
pub type DDS_WaitSet = *mut c_void;
pub type DDS_GuardCondition = *mut c_void;
pub type DDS_Condition = *mut c_void;

/// Mirrors `DDS_Duration_t_s` (dcps.h) -- a plain 2-field value struct, no
/// hidden layout concerns.
#[repr(C)]
pub struct DDS_Duration_t {
    pub sec: i32,
    pub nanosec: u32,
}

/// Mirrors `DDS_Condition_seq` (dcps.h) -- same generic
/// `{_maximum, _length, _buffer, _release}` shape as every other zzdds
/// C-ABI sequence, element type `DDS_Condition` (an opaque handle, not a
/// value type).
#[repr(C)]
pub struct DDS_ConditionSeq {
    pub _maximum: u32,
    pub _length: u32,
    pub _buffer: *mut DDS_Condition,
    pub _release: bool,
}

impl DDS_ConditionSeq {
    pub fn empty() -> Self {
        DDS_ConditionSeq { _maximum: 0, _length: 0, _buffer: std::ptr::null_mut(), _release: false }
    }

    /// Safe accessor over the raw buffer -- every element is a live
    /// `DDS_Condition` handle for `0.._length` when this value was just
    /// populated by a successful `DDS_WaitSet_wait()` call.
    pub fn as_slice(&self) -> &[DDS_Condition] {
        if self._buffer.is_null() || self._length == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(self._buffer, self._length as usize) }
        }
    }
}

/// Mirrors `zidl_allocator.h`'s `ZidlAllocator` — the shared C
/// allocator-vtable ABI zidl-generated code and zzdds's own C-ABI bootstrap
/// both consume. `#[repr(C)]` + plain `extern "C" fn` pointers: fully
/// expressible on *stable* Rust, no `#![feature(allocator_api)]` needed —
/// this struct is FFI surface, not Rust's own per-object allocator trait
/// machinery (see `spikes/rust/README.md`'s new "Allocator injection"
/// section for why that distinction is the actual point of this spike).
#[repr(C)]
pub struct ZidlAllocator {
    pub ctx: *mut c_void,
    pub alloc: extern "C" fn(ctx: *mut c_void, len: usize, alignment: usize) -> *mut c_void,
    pub resize: extern "C" fn(
        ctx: *mut c_void,
        ptr: *mut c_void,
        old_len: usize,
        new_len: usize,
        alignment: usize,
    ) -> bool,
    pub free: extern "C" fn(ctx: *mut c_void, ptr: *mut c_void, len: usize, alignment: usize),
}

#[repr(C)]
#[derive(Clone, Copy)]
pub enum DDS_WriteKind {
    ALIVE_WRITE_KIND = 0,
    DISPOSE_WRITE_KIND = 1,
    UNREGISTER_WRITE_KIND = 2,
}

#[repr(C)]
pub struct DDS_Time_t {
    pub sec: i32,
    pub nanosec: u32,
}

/// A bounded octet sequence -- zzdds's generic `{_maximum, _length, _buffer,
/// _release}` C-ABI collection shape (mirrors DDS_OctetSeq/uint8_t_seq in
/// dcps.h). An inout parameter with `_maximum == 0` on entry signals "loan
/// mode" (zero-copy) to `DDS_DataReader_take_raw`; a non-zero `_maximum`
/// would signal "copy into this caller-owned buffer" instead -- this spike
/// only ever passes the zeroed/loan form.
#[repr(C)]
pub struct DDS_OctetSeq {
    pub _maximum: u32,
    pub _length: u32,
    pub _buffer: *mut u8,
    pub _release: bool,
}

impl DDS_OctetSeq {
    pub fn empty() -> Self {
        DDS_OctetSeq { _maximum: 0, _length: 0, _buffer: std::ptr::null_mut(), _release: false }
    }
}

/// A sequence of `DDS_OctetSeq` -- one independently-located descriptor per
/// sample in a batch (never one consolidated contiguous buffer, per
/// zzdds's raw/loan API design -- see docs/design/raw-loan-api.md). This
/// spike always requests `max_samples = 1`, but the take_raw() shape is
/// batch-oriented regardless -- `LoanedSample` deals with a length-1 batch
/// internally rather than a single-sample-shaped API existing at the C ABI.
#[repr(C)]
pub struct DDS_OctetSeqSeq {
    pub _maximum: u32,
    pub _length: u32,
    pub _buffer: *mut DDS_OctetSeq,
    pub _release: bool,
}

impl DDS_OctetSeqSeq {
    pub fn empty() -> Self {
        DDS_OctetSeqSeq { _maximum: 0, _length: 0, _buffer: std::ptr::null_mut(), _release: false }
    }
}

/// Mirrors the real 12-field spec `DDS_SampleInfo` struct (dcps.h) -- this
/// spike only reads `valid_data`, but the fields must match layout exactly
/// since this crosses the C ABI directly (no bindgen).
#[repr(C)]
pub struct DDS_SampleInfo {
    pub sample_state: u32,
    pub view_state: u32,
    pub instance_state: u32,
    pub source_timestamp: DDS_Time_t,
    pub instance_handle: DDS_InstanceHandle_t,
    pub publication_handle: DDS_InstanceHandle_t,
    pub disposed_generation_count: i32,
    pub no_writers_generation_count: i32,
    pub sample_rank: i32,
    pub generation_rank: i32,
    pub absolute_generation_rank: i32,
    pub valid_data: bool,
}

#[repr(C)]
pub struct DDS_SampleInfoSeq {
    pub _maximum: u32,
    pub _length: u32,
    pub _buffer: *mut DDS_SampleInfo,
    pub _release: bool,
}

impl DDS_SampleInfoSeq {
    pub fn empty() -> Self {
        DDS_SampleInfoSeq { _maximum: 0, _length: 0, _buffer: std::ptr::null_mut(), _release: false }
    }
}

unsafe extern "C" {
    pub fn zzdds_create_factory() -> ZzddsDomainParticipantFactory;
    pub fn zzdds_factory_is_nil(factory: ZzddsDomainParticipantFactory) -> bool;
    pub fn zzdds_destroy_factory(factory: ZzddsDomainParticipantFactory);
    pub fn zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(
        factory: ZzddsDomainParticipantFactory,
    ) -> DDS_DomainParticipantFactory;

    pub fn DDS_DomainParticipantFactory_create_participant(
        self_: DDS_DomainParticipantFactory,
        domain_id: u32,
        qos: *const c_void,
        listener: *const c_void,
        mask: u32,
    ) -> DDS_DomainParticipant;

    pub fn zzdds_register_type_support(
        participant: DDS_DomainParticipant,
        type_name: *const c_char,
        compute_key_hash_fn: *const c_void,
        get_field_fn: *const c_void,
    ) -> c_int;

    pub fn DDS_DomainParticipant_create_topic(
        self_: DDS_DomainParticipant,
        topic_name: *const c_char,
        type_name: *const c_char,
        qos: *const c_void,
        listener: *const c_void,
        mask: u32,
    ) -> DDS_Topic;
    pub fn DDS_Topic_as_DDS_TopicDescription(topic: DDS_Topic) -> DDS_TopicDescription;

    pub fn DDS_DomainParticipant_create_publisher(
        self_: DDS_DomainParticipant,
        qos: *const c_void,
        listener: *const c_void,
        mask: u32,
    ) -> DDS_Publisher;
    pub fn DDS_Publisher_get_default_datawriter_qos(
        self_: DDS_Publisher,
        qos: *mut c_void,
    ) -> DDS_ReturnCode_t;
    pub fn DDS_Publisher_create_datawriter(
        self_: DDS_Publisher,
        a_topic: DDS_Topic,
        qos: *const c_void,
        listener: *const c_void,
        mask: u32,
    ) -> DDS_DataWriter;

    pub fn DDS_DomainParticipant_create_subscriber(
        self_: DDS_DomainParticipant,
        qos: *const c_void,
        listener: *const c_void,
        mask: u32,
    ) -> DDS_Subscriber;
    pub fn DDS_Subscriber_get_default_datareader_qos(
        self_: DDS_Subscriber,
        qos: *mut c_void,
    ) -> DDS_ReturnCode_t;
    pub fn DDS_Subscriber_create_datareader(
        self_: DDS_Subscriber,
        a_topic: DDS_TopicDescription,
        qos: *const c_void,
        listener: *const c_void,
        mask: u32,
    ) -> DDS_DataReader;

    // dcps.idl's real, generated raw/loaned write ops (superseding the old
    // hand-written zzdds_write_raw/zzdds_take_loaned_raw/
    // zzdds_return_loaned_raw C-ABI family -- see
    // docs/design/raw-loan-api.md) -- generated uniformly across all 4
    // zidl backends, this spike just hand-declares the same signatures.
    pub fn DDS_DataWriter_write_raw(
        self_: DDS_DataWriter,
        key_hash: *const DDS_OctetSeq,
        handle: DDS_InstanceHandle_t,
        cdr_payload: *const DDS_OctetSeq,
        kind: DDS_WriteKind,
        source_timestamp: *const DDS_Time_t,
    ) -> DDS_ReturnCode_t;

    pub fn DDS_DataReader_take_raw(
        self_: DDS_DataReader,
        cdr_payloads: *mut DDS_OctetSeqSeq,
        key_hashes: *mut DDS_OctetSeq,
        sample_infos: *mut DDS_SampleInfoSeq,
        instance_handle: DDS_InstanceHandle_t,
        a_condition: DDS_ReadCondition,
        sample_states: DDS_SampleStateMask,
        view_states: DDS_ViewStateMask,
        instance_states: DDS_InstanceStateMask,
        max_samples: i32,
    ) -> DDS_ReturnCode_t;
    pub fn DDS_DataReader_return_loan_raw(
        self_: DDS_DataReader,
        cdr_payloads: *mut DDS_OctetSeqSeq,
        sample_infos: *mut DDS_SampleInfoSeq,
    ) -> DDS_ReturnCode_t;
    pub fn DDS_OctetSeq_free(v: *mut DDS_OctetSeq);

    // spike_shim.c
    pub fn spike_sizeof_writer_qos() -> usize;
    pub fn spike_sizeof_reader_qos() -> usize;
    pub fn spike_set_writer_reliable_keep_all(qos: *mut c_void);
}

unsafe extern "C" {
    // ── Allocator-spike additions ──

    pub fn zzdds_create_factory_with_allocator(
        allocator: *const ZidlAllocator,
    ) -> ZzddsDomainParticipantFactory;

    pub fn zzdds_create_waitset_with_allocator(allocator: *const ZidlAllocator) -> DDS_WaitSet;
    pub fn zzdds_waitset_is_nil(waitset: DDS_WaitSet) -> bool;
    pub fn zzdds_destroy_waitset(waitset: DDS_WaitSet);

    pub fn zzdds_create_guardcondition_with_allocator(
        allocator: *const ZidlAllocator,
    ) -> DDS_GuardCondition;
    pub fn zzdds_guardcondition_is_nil(guardcondition: DDS_GuardCondition) -> bool;
    pub fn zzdds_destroy_guardcondition(guardcondition: DDS_GuardCondition);

    pub fn DDS_GuardCondition_set_trigger_value(self_: DDS_GuardCondition, value: bool) -> DDS_ReturnCode_t;
    pub fn DDS_GuardCondition_as_DDS_Condition(child: DDS_GuardCondition) -> DDS_Condition;

    pub fn DDS_WaitSet_attach_condition(self_: DDS_WaitSet, cond: DDS_Condition) -> DDS_ReturnCode_t;
    pub fn DDS_WaitSet_detach_condition(self_: DDS_WaitSet, cond: DDS_Condition) -> DDS_ReturnCode_t;
    pub fn DDS_WaitSet_wait(
        self_: DDS_WaitSet,
        active_conditions: *mut DDS_ConditionSeq,
        timeout: *const DDS_Duration_t,
    ) -> DDS_ReturnCode_t;
    pub fn DDS_ConditionSeq_free(v: *mut DDS_ConditionSeq);

    // static_pool_allocator.c (copied into this spike directory, same as
    // spike_shim.c -- self-contained, not shared by path across spikes).
    // Reused rather than reimplemented in Rust: the point of this spike is
    // whether Rust can *consume* a ZidlAllocator across the C ABI, not
    // whether Rust can implement one -- see README.md.
    pub static static_pool_allocator: ZidlAllocator;
    pub fn static_pool_allocator_reset();
}
