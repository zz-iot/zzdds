//! Nil entity handles.
//!
//! DDS `create_*` operations that fail must return a "nil" entity.  Because
//! the generated vtable types (DDS.DomainParticipant, DDS.Publisher, etc.)
//! use non-optional `ptr: *anyopaque`, we provide nil-object vtables that return
//! RETCODE_ERROR for every method.  The nil entity's `ptr` points to
//! `nil_storage`, a distinguishable sentinel address.
//!
//! Use `isNil(entity)` to check whether a returned entity is nil.

const DDS = @import("zzdds_generated").DDS;

/// Single-byte storage whose address serves as the nil-entity sentinel.
pub var nil_storage: u8 = 0;
pub const NIL_PTR: *anyopaque = @ptrCast(&nil_storage);

/// True if the entity's ptr is the nil sentinel.
pub fn isNil(entity: anytype) bool {
    return entity.ptr == NIL_PTR;
}

// ── Nil StatusCondition (shared by all nil entities that need one) ─────────

var nil_sc_vtable = DDS.StatusCondition.Vtable{
    .get_trigger_value = scGetTrigger,
    .get_enabled_statuses = scGetEnabled,
    .set_enabled_statuses = scSetEnabled,
    .get_entity = scGetEntity,
    .deinit = nilDeinit,
};
fn scGetTrigger(_: *anyopaque) bool {
    return false;
}
fn scGetEnabled(_: *anyopaque) DDS.StatusMask {
    return 0;
}
fn scSetEnabled(_: *anyopaque, _: DDS.StatusMask) DDS.ReturnCode_t {
    return DDS.RETCODE_ERROR;
}
fn scGetEntity(_: *anyopaque) DDS.Entity {
    return .{ .ptr = NIL_PTR, .vtable = &nil_entity_vtable };
}
pub const nil_status_condition = DDS.StatusCondition{ .ptr = NIL_PTR, .vtable = &nil_sc_vtable };

// ── Nil Entity ────────────────────────────────────────────────────────────────

var nil_entity_vtable = DDS.Entity.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .deinit = nilDeinit,
};
fn nilEnable(_: *anyopaque) DDS.ReturnCode_t {
    return DDS.RETCODE_ERROR;
}
fn nilGetStatusCond(_: *anyopaque) DDS.StatusCondition {
    return nil_status_condition;
}
fn nilGetStatusChanges(_: *anyopaque) DDS.StatusMask {
    return 0;
}
fn nilGetHandle(_: *anyopaque) DDS.InstanceHandle_t {
    return DDS.HANDLE_NIL;
}
fn nilDeinit(_: *anyopaque) void {}

// Nil listener constants: all function pointers null (zero-init).
pub const nil_topic_listener = DDS.noop_TopicListener;
pub const nil_dw_listener = DDS.noop_DataWriterListener;
pub const nil_dr_listener = DDS.noop_DataReaderListener;

// ── Nil DomainParticipant ─────────────────────────────────────────────────────

var nil_participant_vtable = DDS.DomainParticipant.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .create_publisher = struct {
        fn f(_: *anyopaque, _: *const DDS.PublisherQos, _: ?*const DDS.PublisherListener, _: DDS.StatusMask) DDS.Publisher {
            return nil_publisher;
        }
    }.f,
    .delete_publisher = struct {
        fn f(_: *anyopaque, _: DDS.Publisher) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .create_subscriber = struct {
        fn f(_: *anyopaque, _: *const DDS.SubscriberQos, _: ?*const DDS.SubscriberListener, _: DDS.StatusMask) DDS.Subscriber {
            return nil_subscriber;
        }
    }.f,
    .delete_subscriber = struct {
        fn f(_: *anyopaque, _: DDS.Subscriber) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_builtin_subscriber = struct {
        fn f(_: *anyopaque) DDS.Subscriber {
            return nil_subscriber;
        }
    }.f,
    .create_topic = struct {
        fn f(_: *anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: *const DDS.TopicQos, _: ?*const DDS.TopicListener, _: DDS.StatusMask) DDS.Topic {
            return nil_topic;
        }
    }.f,
    .delete_topic = struct {
        fn f(_: *anyopaque, _: DDS.Topic) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .find_topic = struct {
        fn f(_: *anyopaque, _: [*:0]const u8, _: *const DDS.Duration_t) DDS.Topic {
            return nil_topic;
        }
    }.f,
    .lookup_topicdescription = struct {
        fn f(_: *anyopaque, _: [*:0]const u8) DDS.TopicDescription {
            return nil_topic_description;
        }
    }.f,
    .create_contentfilteredtopic = struct {
        fn f(_: *anyopaque, _: [*:0]const u8, _: DDS.Topic, _: [*:0]const u8, _: ?*const DDS.StringSeq) DDS.ContentFilteredTopic {
            return nil_cft;
        }
    }.f,
    .delete_contentfilteredtopic = struct {
        fn f(_: *anyopaque, _: DDS.ContentFilteredTopic) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .create_multitopic = struct {
        fn f(_: *anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8, _: ?*const DDS.StringSeq) DDS.MultiTopic {
            return nil_multitopic;
        }
    }.f,
    .delete_multitopic = struct {
        fn f(_: *anyopaque, _: DDS.MultiTopic) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .delete_contained_entities = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DomainParticipantQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_listener = struct {
        fn f(_: *anyopaque, _: ?*const DDS.DomainParticipantListener, _: DDS.StatusMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_listener = struct {
        fn f(_: *anyopaque) DDS.DomainParticipantListener {
            return nil_dp_listener;
        }
    }.f,
    .ignore_participant = struct {
        fn f(_: *anyopaque, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .ignore_topic = struct {
        fn f(_: *anyopaque, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .ignore_publication = struct {
        fn f(_: *anyopaque, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .ignore_subscription = struct {
        fn f(_: *anyopaque, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_domain_id = struct {
        fn f(_: *anyopaque) DDS.DomainId_t {
            return 0;
        }
    }.f,
    .assert_liveliness = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_default_publisher_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.PublisherQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_default_publisher_qos = struct {
        fn f(_: *anyopaque, _: *DDS.PublisherQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_default_subscriber_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.SubscriberQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_default_subscriber_qos = struct {
        fn f(_: *anyopaque, _: *DDS.SubscriberQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_default_topic_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.TopicQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_default_topic_qos = struct {
        fn f(_: *anyopaque, _: *DDS.TopicQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_discovered_participants = struct {
        fn f(_: *anyopaque, _: ?*DDS.InstanceHandleSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_UNSUPPORTED;
        }
    }.f,
    .get_discovered_participant_data = struct {
        fn f(_: *anyopaque, _: *DDS.ParticipantBuiltinTopicData, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_UNSUPPORTED;
        }
    }.f,
    .get_discovered_topics = struct {
        fn f(_: *anyopaque, _: ?*DDS.InstanceHandleSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_UNSUPPORTED;
        }
    }.f,
    .get_discovered_topic_data = struct {
        fn f(_: *anyopaque, _: *DDS.TopicBuiltinTopicData, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_UNSUPPORTED;
        }
    }.f,
    .contains_entity = struct {
        fn f(_: *anyopaque, _: DDS.InstanceHandle_t) bool {
            return false;
        }
    }.f,
    .get_current_time = struct {
        fn f(_: *anyopaque, _: *DDS.Time_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_participant = DDS.DomainParticipant{ .ptr = NIL_PTR, .vtable = &nil_participant_vtable };

// ── Nil Publisher ─────────────────────────────────────────────────────────────

pub const nil_pub_listener = DDS.noop_PublisherListener;

var nil_publisher_vtable = DDS.Publisher.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .create_datawriter = struct {
        fn f(_: *anyopaque, _: DDS.Topic, _: *const DDS.DataWriterQos, _: ?*const DDS.DataWriterListener, _: DDS.StatusMask) DDS.DataWriter {
            return nil_datawriter;
        }
    }.f,
    .delete_datawriter = struct {
        fn f(_: *anyopaque, _: DDS.DataWriter) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .lookup_datawriter = struct {
        fn f(_: *anyopaque, _: [*:0]const u8) DDS.DataWriter {
            return nil_datawriter;
        }
    }.f,
    .delete_contained_entities = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.PublisherQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.PublisherQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_listener = struct {
        fn f(_: *anyopaque, _: ?*const DDS.PublisherListener, _: DDS.StatusMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_listener = struct {
        fn f(_: *anyopaque) DDS.PublisherListener {
            return nil_pub_listener;
        }
    }.f,
    .suspend_publications = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .resume_publications = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .begin_coherent_changes = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .end_coherent_changes = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .wait_for_acknowledgments = struct {
        fn f(_: *anyopaque, _: *const DDS.Duration_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_participant = struct {
        fn f(_: *anyopaque) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .set_default_datawriter_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DataWriterQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_default_datawriter_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DataWriterQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .copy_from_topic_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DataWriterQos, _: *const DDS.TopicQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_publisher = DDS.Publisher{ .ptr = NIL_PTR, .vtable = &nil_publisher_vtable };

// ── Nil Subscriber ────────────────────────────────────────────────────────────

pub const nil_sub_listener = DDS.noop_SubscriberListener;

var nil_subscriber_vtable = DDS.Subscriber.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .create_datareader = struct {
        fn f(_: *anyopaque, _: DDS.TopicDescription, _: *const DDS.DataReaderQos, _: ?*const DDS.DataReaderListener, _: DDS.StatusMask) DDS.DataReader {
            return nil_datareader;
        }
    }.f,
    .delete_datareader = struct {
        fn f(_: *anyopaque, _: DDS.DataReader) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .delete_contained_entities = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .lookup_datareader = struct {
        fn f(_: *anyopaque, _: [*:0]const u8) DDS.DataReader {
            return nil_datareader;
        }
    }.f,
    .get_datareaders = struct {
        fn f(_: *anyopaque, _: ?*DDS.DataReaderSeq, _: DDS.SampleStateMask, _: DDS.ViewStateMask, _: DDS.InstanceStateMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .notify_datareaders = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.SubscriberQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.SubscriberQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_listener = struct {
        fn f(_: *anyopaque, _: ?*const DDS.SubscriberListener, _: DDS.StatusMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_listener = struct {
        fn f(_: *anyopaque) DDS.SubscriberListener {
            return nil_sub_listener;
        }
    }.f,
    .begin_access = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_OK;
        }
    }.f,
    .end_access = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_OK;
        }
    }.f,
    .get_participant = struct {
        fn f(_: *anyopaque) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .set_default_datareader_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DataReaderQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_default_datareader_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DataReaderQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .copy_from_topic_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DataReaderQos, _: *const DDS.TopicQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_subscriber = DDS.Subscriber{ .ptr = NIL_PTR, .vtable = &nil_subscriber_vtable };

// ── Nil DataWriter ────────────────────────────────────────────────────────────

var nil_datawriter_vtable = DDS.DataWriter.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DataWriterQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DataWriterQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_listener = struct {
        fn f(_: *anyopaque, _: ?*const DDS.DataWriterListener, _: DDS.StatusMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_listener = struct {
        fn f(_: *anyopaque) DDS.DataWriterListener {
            return nil_dw_listener;
        }
    }.f,
    .get_topic = struct {
        fn f(_: *anyopaque) DDS.Topic {
            return nil_topic;
        }
    }.f,
    .get_publisher = struct {
        fn f(_: *anyopaque) DDS.Publisher {
            return nil_publisher;
        }
    }.f,
    .wait_for_acknowledgments = struct {
        fn f(_: *anyopaque, _: *const DDS.Duration_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_liveliness_lost_status = struct {
        fn f(_: *anyopaque, _: *DDS.LivelinessLostStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_offered_deadline_missed_status = struct {
        fn f(_: *anyopaque, _: *DDS.OfferedDeadlineMissedStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_offered_incompatible_qos_status = struct {
        fn f(_: *anyopaque, _: *DDS.OfferedIncompatibleQosStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_publication_matched_status = struct {
        fn f(_: *anyopaque, _: *DDS.PublicationMatchedStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .assert_liveliness = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_matched_subscriptions = struct {
        fn f(_: *anyopaque, _: ?*DDS.InstanceHandleSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_matched_subscription_data = struct {
        fn f(_: *anyopaque, _: *DDS.SubscriptionBuiltinTopicData, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_datawriter = DDS.DataWriter{ .ptr = NIL_PTR, .vtable = &nil_datawriter_vtable };

// ── Nil DataReader ────────────────────────────────────────────────────────────

var nil_datareader_vtable = DDS.DataReader.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .create_readcondition = struct {
        fn f(_: *anyopaque, _: DDS.SampleStateMask, _: DDS.ViewStateMask, _: DDS.InstanceStateMask) DDS.ReadCondition {
            return nil_readcondition;
        }
    }.f,
    .create_querycondition = struct {
        fn f(_: *anyopaque, _: DDS.SampleStateMask, _: DDS.ViewStateMask, _: DDS.InstanceStateMask, _: [*:0]const u8, _: ?*const DDS.StringSeq) DDS.QueryCondition {
            return nil_querycondition;
        }
    }.f,
    .delete_readcondition = struct {
        fn f(_: *anyopaque, _: DDS.ReadCondition) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .delete_contained_entities = struct {
        fn f(_: *anyopaque) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DataReaderQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DataReaderQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_listener = struct {
        fn f(_: *anyopaque, _: ?*const DDS.DataReaderListener, _: DDS.StatusMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_listener = struct {
        fn f(_: *anyopaque) DDS.DataReaderListener {
            return nil_dr_listener;
        }
    }.f,
    .get_topicdescription = struct {
        fn f(_: *anyopaque) DDS.TopicDescription {
            return nil_topic_description;
        }
    }.f,
    .get_subscriber = struct {
        fn f(_: *anyopaque) DDS.Subscriber {
            return nil_subscriber;
        }
    }.f,
    .get_sample_rejected_status = struct {
        fn f(_: *anyopaque, _: *DDS.SampleRejectedStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_liveliness_changed_status = struct {
        fn f(_: *anyopaque, _: *DDS.LivelinessChangedStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_requested_deadline_missed_status = struct {
        fn f(_: *anyopaque, _: *DDS.RequestedDeadlineMissedStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_requested_incompatible_qos_status = struct {
        fn f(_: *anyopaque, _: *DDS.RequestedIncompatibleQosStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_subscription_matched_status = struct {
        fn f(_: *anyopaque, _: *DDS.SubscriptionMatchedStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_sample_lost_status = struct {
        fn f(_: *anyopaque, _: *DDS.SampleLostStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .wait_for_historical_data = struct {
        fn f(_: *anyopaque, _: *const DDS.Duration_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_matched_publications = struct {
        fn f(_: *anyopaque, _: ?*DDS.InstanceHandleSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_matched_publication_data = struct {
        fn f(_: *anyopaque, _: *DDS.PublicationBuiltinTopicData, _: DDS.InstanceHandle_t) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_datareader = DDS.DataReader{ .ptr = NIL_PTR, .vtable = &nil_datareader_vtable };

// ── Nil Topic / TopicDescription ─────────────────────────────────────────────

var nil_topic_description_vtable = DDS.TopicDescription.Vtable{
    .get_type_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_participant = struct {
        fn f(_: *anyopaque) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_topic_description = DDS.TopicDescription{ .ptr = NIL_PTR, .vtable = &nil_topic_description_vtable };

var nil_topic_vtable = DDS.Topic.Vtable{
    .enable = nilEnable,
    .get_statuscondition = nilGetStatusCond,
    .get_status_changes = nilGetStatusChanges,
    .get_instance_handle = nilGetHandle,
    .get_type_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_participant = struct {
        fn f(_: *anyopaque) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.TopicQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.TopicQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_listener = struct {
        fn f(_: *anyopaque, _: ?*const DDS.TopicListener, _: DDS.StatusMask) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_listener = struct {
        fn f(_: *anyopaque) DDS.TopicListener {
            return nil_topic_listener;
        }
    }.f,
    .get_inconsistent_topic_status = struct {
        fn f(_: *anyopaque, _: *DDS.InconsistentTopicStatus) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_topic = DDS.Topic{ .ptr = NIL_PTR, .vtable = &nil_topic_vtable };

// ── Nil ContentFilteredTopic ──────────────────────────────────────────────────

var nil_cft_vtable = DDS.ContentFilteredTopic.Vtable{
    .get_type_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_participant = struct {
        fn f(_: *anyopaque) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .get_filter_expression = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_expression_parameters = struct {
        fn f(_: *anyopaque, _: ?*DDS.StringSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_expression_parameters = struct {
        fn f(_: *anyopaque, _: ?*const DDS.StringSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_related_topic = struct {
        fn f(_: *anyopaque) DDS.Topic {
            return nil_topic;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_cft = DDS.ContentFilteredTopic{ .ptr = NIL_PTR, .vtable = &nil_cft_vtable };

// ── Nil MultiTopic ────────────────────────────────────────────────────────────

var nil_multitopic_vtable = DDS.MultiTopic.Vtable{
    .get_type_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_name = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_participant = struct {
        fn f(_: *anyopaque) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .get_subscription_expression = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_expression_parameters = struct {
        fn f(_: *anyopaque, _: ?*DDS.StringSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_expression_parameters = struct {
        fn f(_: *anyopaque, _: ?*const DDS.StringSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_multitopic = DDS.MultiTopic{ .ptr = NIL_PTR, .vtable = &nil_multitopic_vtable };

// ── Nil Conditions ────────────────────────────────────────────────────────────

var nil_condition_vtable = DDS.Condition.Vtable{
    .get_trigger_value = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_condition = DDS.Condition{ .ptr = NIL_PTR, .vtable = &nil_condition_vtable };

var nil_readcondition_vtable = DDS.ReadCondition.Vtable{
    .get_trigger_value = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .get_sample_state_mask = struct {
        fn f(_: *anyopaque) DDS.SampleStateMask {
            return 0;
        }
    }.f,
    .get_view_state_mask = struct {
        fn f(_: *anyopaque) DDS.ViewStateMask {
            return 0;
        }
    }.f,
    .get_instance_state_mask = struct {
        fn f(_: *anyopaque) DDS.InstanceStateMask {
            return 0;
        }
    }.f,
    .get_datareader = struct {
        fn f(_: *anyopaque) DDS.DataReader {
            return nil_datareader;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_readcondition = DDS.ReadCondition{ .ptr = NIL_PTR, .vtable = &nil_readcondition_vtable };

var nil_querycondition_vtable = DDS.QueryCondition.Vtable{
    .get_trigger_value = struct {
        fn f(_: *anyopaque) bool {
            return false;
        }
    }.f,
    .get_sample_state_mask = struct {
        fn f(_: *anyopaque) DDS.SampleStateMask {
            return 0;
        }
    }.f,
    .get_view_state_mask = struct {
        fn f(_: *anyopaque) DDS.ViewStateMask {
            return 0;
        }
    }.f,
    .get_instance_state_mask = struct {
        fn f(_: *anyopaque) DDS.InstanceStateMask {
            return 0;
        }
    }.f,
    .get_datareader = struct {
        fn f(_: *anyopaque) DDS.DataReader {
            return nil_datareader;
        }
    }.f,
    .get_query_expression = struct {
        fn f(_: *anyopaque) [*:0]const u8 {
            return "";
        }
    }.f,
    .get_query_parameters = struct {
        fn f(_: *anyopaque, _: ?*DDS.StringSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_query_parameters = struct {
        fn f(_: *anyopaque, _: ?*const DDS.StringSeq) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_querycondition = DDS.QueryCondition{ .ptr = NIL_PTR, .vtable = &nil_querycondition_vtable };

// ── Nil DomainParticipantFactory ──────────────────────────────────────────────

pub const nil_dp_listener = DDS.noop_DomainParticipantListener;

var nil_factory_vtable = DDS.DomainParticipantFactory.Vtable{
    .create_participant = struct {
        fn f(_: *anyopaque, _: DDS.DomainId_t, _: *const DDS.DomainParticipantQos, _: ?*const DDS.DomainParticipantListener, _: DDS.StatusMask) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .delete_participant = struct {
        fn f(_: *anyopaque, _: DDS.DomainParticipant) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .lookup_participant = struct {
        fn f(_: *anyopaque, _: DDS.DomainId_t) DDS.DomainParticipant {
            return nil_participant;
        }
    }.f,
    .set_default_participant_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DomainParticipantQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_default_participant_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DomainParticipantQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .set_qos = struct {
        fn f(_: *anyopaque, _: *const DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .get_qos = struct {
        fn f(_: *anyopaque, _: *DDS.DomainParticipantFactoryQos) DDS.ReturnCode_t {
            return DDS.RETCODE_ERROR;
        }
    }.f,
    .deinit = nilDeinit,
};
pub const nil_factory = DDS.DomainParticipantFactory{ .ptr = NIL_PTR, .vtable = &nil_factory_vtable };
