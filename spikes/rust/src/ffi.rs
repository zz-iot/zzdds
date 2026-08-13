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

#[repr(C)]
pub struct zzdds_loaned_sample {
    pub data: *const u8,
    pub data_len: usize,
    pub owner: *mut c_void,
}

#[repr(C)]
pub struct zzdds_sample_info {
    pub valid_data: bool,
    pub instance_state: u32,
    pub instance_handle: DDS_InstanceHandle_t,
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

    pub fn zzdds_write_raw(
        writer: DDS_DataWriter,
        key_hash: *const u8, // [u8; 16]
        handle: DDS_InstanceHandle_t,
        data: *const u8,
        data_len: usize,
    ) -> DDS_ReturnCode_t;

    pub fn zzdds_take_loaned_raw(
        reader: DDS_DataReader,
        loan_out: *mut zzdds_loaned_sample,
        info_out: *mut zzdds_sample_info,
    ) -> DDS_ReturnCode_t;
    pub fn zzdds_return_loaned_raw(reader: DDS_DataReader, loan: *mut zzdds_loaned_sample);

    // spike_shim.c
    pub fn spike_sizeof_writer_qos() -> usize;
    pub fn spike_sizeof_reader_qos() -> usize;
    pub fn spike_set_writer_reliable_keep_all(qos: *mut c_void);
}
