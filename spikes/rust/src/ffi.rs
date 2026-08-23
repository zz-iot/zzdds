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
