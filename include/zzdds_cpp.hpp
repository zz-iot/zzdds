#pragma once

#include "zzdds_impl.hpp"
#include "zidl_allocator_pmr.hpp"

#include <memory>
#include <memory_resource>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#include <utility>

namespace zzdds {

namespace detail {

class DomainParticipantFactorySupport final : public DomainParticipantFactoryImpl {
public:
    explicit DomainParticipantFactorySupport(zzdds_DomainParticipantFactory handle)
        : DomainParticipantFactoryImpl(handle),
          dds_(zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(handle)),
          handle_(handle)
    {}

    // Sole teardown path for the underlying FactoryOwner (see wrapFactoryHandle's
    // former comment on this, now folded in here): ~DomainParticipantFactoryImpl()
    // is `= default` and does NOT call vtable->deinit, so destroying this object
    // alone would not tear down the C-ABI factory without this. Living in the
    // destructor (rather than a separate custom deleter, as before) is what makes
    // this class constructible via std::allocate_shared, which does not support a
    // deleter distinct from the allocator-driven one.
    ~DomainParticipantFactorySupport() override
    {
        zzdds_destroy_factory(handle_);
    }

    std::shared_ptr<::DDS::DomainParticipant> create_participant(
        ::DDS::DomainId_t domain_id,
        ::DDS::DomainParticipantQos qos,
        std::shared_ptr<::DDS::DomainParticipantListener> a_listener,
        ::DDS::StatusMask mask
    ) override
    {
        return dds_.create_participant(domain_id, qos, std::move(a_listener), mask);
    }

    ::DDS::ReturnCode_t delete_participant(
        std::shared_ptr<::DDS::DomainParticipant> a_participant
    ) override
    {
        return dds_.delete_participant(std::move(a_participant));
    }

    std::shared_ptr<::DDS::DomainParticipant> lookup_participant(
        ::DDS::DomainId_t domain_id
    ) override
    {
        return dds_.lookup_participant(domain_id);
    }

    ::DDS::ReturnCode_t set_default_participant_qos(
        ::DDS::DomainParticipantQos qos
    ) override
    {
        return dds_.set_default_participant_qos(qos);
    }

    ::DDS::ReturnCode_t get_default_participant_qos(
        ::DDS::DomainParticipantQos& qos
    ) override
    {
        return dds_.get_default_participant_qos(qos);
    }

    ::DDS::ReturnCode_t set_qos(::DDS::DomainParticipantFactoryQos qos) override
    {
        return dds_.set_qos(qos);
    }

    ::DDS::ReturnCode_t get_qos(::DDS::DomainParticipantFactoryQos& qos) override
    {
        return dds_.get_qos(qos);
    }

private:
    ::DDS::DomainParticipantFactoryImpl dds_;
    zzdds_DomainParticipantFactory handle_;
};

} // namespace detail

namespace detail {

// TopicSupport/DataWriterSupport/DataReaderSupport/DomainParticipantSupport
// exist for the same reason DomainParticipantFactorySupport above does: the
// zidl-generated zzdds::TopicImpl/DataWriterImpl/DataReaderImpl/
// DomainParticipantImpl (from zzdds_impl.hpp, generated from zzdds.idl
// alone) only implement the *new* zzdds-specific methods
// (as_topic_description, write_serialized/set_listener_ex,
// take_serialized/take_next_instance_serialized, register_type_support) --
// entity interfaces don't get cross-module operation flattening, so the
// inherited DDS::Topic/DataWriter/DataReader/DomainParticipant base methods
// are left unimplemented (abstract) on those classes. Composing a
// fully-implemented DDS::*Impl member and delegating every base method to
// it, same shape as DomainParticipantFactorySupport, makes each one
// concrete.
//
// Unlike the factory (a bootstrap singleton constructed directly from
// zzdds_create_factory(), never via another entity's factory method), these
// four *are* constructed via the ordinary generic entity path --
// DomainParticipant::create_topic() and friends, whose generated
// implementation only ever has a DDS_Topic/DDS_DataWriter/... handle to
// hand over (see --cpp-impl-override in zidl's docs/roadmap.md). That's a
// real difference from the factory case: the base DDS_* handle has to be
// converted to the zzdds_* one explicitly (DDS_Topic_as_zzdds_Topic and
// siblings, from zzdds.h) before zzdds::TopicImpl's own constructor -- which
// only accepts its own zzdds_Topic -- can be called at all. No custom
// destructor is needed here the way the factory's is: entity teardown goes
// through delete_topic()/delete_datawriter()/... (the composed dds_ member's
// own destructor, and the C-ABI entity itself, outlive this wrapper), not a
// destructor-triggered top-level C-ABI call.

class TopicSupport final : public TopicImpl {
public:
    explicit TopicSupport(DDS_Topic handle)
        : TopicImpl(DDS_Topic_as_zzdds_Topic(handle)),
          dds_(handle)
    {}

    // as_topic_description() is already implemented by TopicImpl (base).

    ::DDS::ReturnCode_t enable() override { return dds_.enable(); }
    std::shared_ptr<::DDS::StatusCondition> get_statuscondition() override { return dds_.get_statuscondition(); }
    ::DDS::StatusMask get_status_changes() override { return dds_.get_status_changes(); }
    ::DDS::InstanceHandle_t get_instance_handle() override { return dds_.get_instance_handle(); }
    std::string get_type_name() override { return dds_.get_type_name(); }
    std::string get_name() override { return dds_.get_name(); }
    std::shared_ptr<::DDS::DomainParticipant> get_participant() override { return dds_.get_participant(); }
    ::DDS::ReturnCode_t set_qos(::DDS::TopicQos qos) override { return dds_.set_qos(qos); }
    ::DDS::ReturnCode_t get_qos(::DDS::TopicQos& qos) override { return dds_.get_qos(qos); }
    ::DDS::ReturnCode_t set_listener(std::shared_ptr<::DDS::TopicListener> a_listener, ::DDS::StatusMask mask) override {
        return dds_.set_listener(std::move(a_listener), mask);
    }
    std::shared_ptr<::DDS::TopicListener> get_listener() override { return dds_.get_listener(); }
    ::DDS::ReturnCode_t get_inconsistent_topic_status(::DDS::InconsistentTopicStatus& a_status) override {
        return dds_.get_inconsistent_topic_status(a_status);
    }

    // Consults/populates ::DDS::EntityImpl's shared family cache (see
    // dcps_impl.cpp's non-root _getOrCreate bodies for the generated-code
    // side of the same pattern) instead of an independent cache of its own:
    // TopicSupport is a real member of Entity's shared C-ABI box family
    // (zzdds::Topic : DDS::Topic : DDS::Entity), and e.g.
    // StatusCondition::get_entity() can return a generic ::DDS::Entity for
    // the exact same handle this object wraps — without sharing the cache,
    // that generic Entity would never compare identity-equal to this object.
    static std::shared_ptr<TopicSupport> _getOrCreate(DDS_Topic h) {
        if (!h) return nullptr;
        DDS_Entity _fh = DDS_Topic_as_DDS_Entity(h);
        std::lock_guard<std::mutex> _lock(::DDS::EntityImpl::_familyMutex());
        auto& _cache = ::DDS::EntityImpl::_familyCache();
        auto _it = _cache.find(_fh);
        if (_it != _cache.end()) {
            if (auto _base = _it->second.lock()) {
                if (auto _sp = std::dynamic_pointer_cast<TopicSupport>(_base)) return _sp;
            }
        }
        auto _sp = std::allocate_shared<TopicSupport>(
            std::pmr::polymorphic_allocator<TopicSupport>(std::pmr::get_default_resource()), h);
        _cache[_fh] = _sp;
        return _sp;
    }

private:
    // Shadows the inherited TopicImpl (base) friend of the same name, which
    // returns the zzdds *extension* handle (zzdds_Topic) -- wrong type for
    // call sites expecting the base DDS_Topic (confirmed directly: without
    // this, dcps_impl.cpp fails to compile with "cannot convert zzdds_Topic
    // to DDS_Topic"). Exact-match overload resolution prefers this one over
    // the inherited const TopicImpl& version.
    friend DDS_Topic zidl_concrete_handle(const TopicSupport& self) noexcept { return self.dds_.native_handle(); }
    ::DDS::TopicImpl dds_;
};

class DataWriterSupport final : public DataWriterImpl {
public:
    explicit DataWriterSupport(DDS_DataWriter handle)
        : DataWriterImpl(DDS_DataWriter_as_zzdds_DataWriter(handle)),
          dds_(handle)
    {}

    // write_serialized()/set_listener_ex() are already implemented by
    // DataWriterImpl (base).

    ::DDS::ReturnCode_t enable() override { return dds_.enable(); }
    std::shared_ptr<::DDS::StatusCondition> get_statuscondition() override { return dds_.get_statuscondition(); }
    ::DDS::StatusMask get_status_changes() override { return dds_.get_status_changes(); }
    ::DDS::InstanceHandle_t get_instance_handle() override { return dds_.get_instance_handle(); }
    ::DDS::ReturnCode_t set_qos(::DDS::DataWriterQos qos) override { return dds_.set_qos(qos); }
    ::DDS::ReturnCode_t get_qos(::DDS::DataWriterQos& qos) override { return dds_.get_qos(qos); }
    ::DDS::ReturnCode_t set_listener(std::shared_ptr<::DDS::DataWriterListener> a_listener, ::DDS::StatusMask mask) override {
        return dds_.set_listener(std::move(a_listener), mask);
    }
    std::shared_ptr<::DDS::DataWriterListener> get_listener() override { return dds_.get_listener(); }
    std::shared_ptr<::DDS::Topic> get_topic() override { return dds_.get_topic(); }
    std::shared_ptr<::DDS::Publisher> get_publisher() override { return dds_.get_publisher(); }
    ::DDS::ReturnCode_t wait_for_acknowledgments(::DDS::Duration_t max_wait) override { return dds_.wait_for_acknowledgments(max_wait); }
    ::DDS::ReturnCode_t get_liveliness_lost_status(::DDS::LivelinessLostStatus& p0) override { return dds_.get_liveliness_lost_status(p0); }
    ::DDS::ReturnCode_t get_offered_deadline_missed_status(::DDS::OfferedDeadlineMissedStatus& status) override {
        return dds_.get_offered_deadline_missed_status(status);
    }
    ::DDS::ReturnCode_t get_offered_incompatible_qos_status(::DDS::OfferedIncompatibleQosStatus& status) override {
        return dds_.get_offered_incompatible_qos_status(status);
    }
    ::DDS::ReturnCode_t get_publication_matched_status(::DDS::PublicationMatchedStatus& status) override {
        return dds_.get_publication_matched_status(status);
    }
    ::DDS::ReturnCode_t assert_liveliness() override { return dds_.assert_liveliness(); }
    ::DDS::ReturnCode_t get_matched_subscriptions(::DDS::InstanceHandleSeq& subscription_handles) override {
        return dds_.get_matched_subscriptions(subscription_handles);
    }
    ::DDS::ReturnCode_t get_matched_subscription_data(
        ::DDS::SubscriptionBuiltinTopicData& subscription_data, ::DDS::InstanceHandle_t subscription_handle
    ) override {
        return dds_.get_matched_subscription_data(subscription_data, subscription_handle);
    }

    // See TopicSupport's matching comment.
    static std::shared_ptr<DataWriterSupport> _getOrCreate(DDS_DataWriter h) {
        if (!h) return nullptr;
        DDS_Entity _fh = DDS_DataWriter_as_DDS_Entity(h);
        std::lock_guard<std::mutex> _lock(::DDS::EntityImpl::_familyMutex());
        auto& _cache = ::DDS::EntityImpl::_familyCache();
        auto _it = _cache.find(_fh);
        if (_it != _cache.end()) {
            if (auto _base = _it->second.lock()) {
                if (auto _sp = std::dynamic_pointer_cast<DataWriterSupport>(_base)) return _sp;
            }
        }
        auto _sp = std::allocate_shared<DataWriterSupport>(
            std::pmr::polymorphic_allocator<DataWriterSupport>(std::pmr::get_default_resource()), h);
        _cache[_fh] = _sp;
        return _sp;
    }

private:
    // See TopicSupport's matching comment.
    friend DDS_DataWriter zidl_concrete_handle(const DataWriterSupport& self) noexcept { return self.dds_.native_handle(); }
    ::DDS::DataWriterImpl dds_;
};

class DataReaderSupport final : public DataReaderImpl {
public:
    explicit DataReaderSupport(DDS_DataReader handle)
        : DataReaderImpl(DDS_DataReader_as_zzdds_DataReader(handle)),
          dds_(handle)
    {}

    // take_serialized()/take_next_instance_serialized() are already
    // implemented by DataReaderImpl (base).

    ::DDS::ReturnCode_t enable() override { return dds_.enable(); }
    std::shared_ptr<::DDS::StatusCondition> get_statuscondition() override { return dds_.get_statuscondition(); }
    ::DDS::StatusMask get_status_changes() override { return dds_.get_status_changes(); }
    ::DDS::InstanceHandle_t get_instance_handle() override { return dds_.get_instance_handle(); }
    std::shared_ptr<::DDS::ReadCondition> create_readcondition(
        ::DDS::SampleStateMask sample_states, ::DDS::ViewStateMask view_states, ::DDS::InstanceStateMask instance_states
    ) override {
        return dds_.create_readcondition(sample_states, view_states, instance_states);
    }
    std::shared_ptr<::DDS::QueryCondition> create_querycondition(
        ::DDS::SampleStateMask sample_states, ::DDS::ViewStateMask view_states, ::DDS::InstanceStateMask instance_states,
        std::string query_expression, ::DDS::StringSeq query_parameters
    ) override {
        return dds_.create_querycondition(sample_states, view_states, instance_states, std::move(query_expression), query_parameters);
    }
    ::DDS::ReturnCode_t delete_readcondition(std::shared_ptr<::DDS::ReadCondition> a_condition) override {
        return dds_.delete_readcondition(std::move(a_condition));
    }
    ::DDS::ReturnCode_t delete_contained_entities() override { return dds_.delete_contained_entities(); }
    ::DDS::ReturnCode_t set_qos(::DDS::DataReaderQos qos) override { return dds_.set_qos(qos); }
    ::DDS::ReturnCode_t get_qos(::DDS::DataReaderQos& qos) override { return dds_.get_qos(qos); }
    ::DDS::ReturnCode_t set_listener(std::shared_ptr<::DDS::DataReaderListener> a_listener, ::DDS::StatusMask mask) override {
        return dds_.set_listener(std::move(a_listener), mask);
    }
    std::shared_ptr<::DDS::DataReaderListener> get_listener() override { return dds_.get_listener(); }
    std::shared_ptr<::DDS::TopicDescription> get_topicdescription() override { return dds_.get_topicdescription(); }
    std::shared_ptr<::DDS::Subscriber> get_subscriber() override { return dds_.get_subscriber(); }
    ::DDS::ReturnCode_t get_sample_rejected_status(::DDS::SampleRejectedStatus& status) override {
        return dds_.get_sample_rejected_status(status);
    }
    ::DDS::ReturnCode_t get_liveliness_changed_status(::DDS::LivelinessChangedStatus& status) override {
        return dds_.get_liveliness_changed_status(status);
    }
    ::DDS::ReturnCode_t get_requested_deadline_missed_status(::DDS::RequestedDeadlineMissedStatus& status) override {
        return dds_.get_requested_deadline_missed_status(status);
    }
    ::DDS::ReturnCode_t get_requested_incompatible_qos_status(::DDS::RequestedIncompatibleQosStatus& status) override {
        return dds_.get_requested_incompatible_qos_status(status);
    }
    ::DDS::ReturnCode_t get_subscription_matched_status(::DDS::SubscriptionMatchedStatus& status) override {
        return dds_.get_subscription_matched_status(status);
    }
    ::DDS::ReturnCode_t get_sample_lost_status(::DDS::SampleLostStatus& status) override { return dds_.get_sample_lost_status(status); }
    ::DDS::ReturnCode_t wait_for_historical_data(::DDS::Duration_t max_wait) override { return dds_.wait_for_historical_data(max_wait); }
    ::DDS::ReturnCode_t get_matched_publications(::DDS::InstanceHandleSeq& publication_handles) override {
        return dds_.get_matched_publications(publication_handles);
    }
    ::DDS::ReturnCode_t get_matched_publication_data(
        ::DDS::PublicationBuiltinTopicData& publication_data, ::DDS::InstanceHandle_t publication_handle
    ) override {
        return dds_.get_matched_publication_data(publication_data, publication_handle);
    }

    // See TopicSupport's matching comment.
    static std::shared_ptr<DataReaderSupport> _getOrCreate(DDS_DataReader h) {
        if (!h) return nullptr;
        DDS_Entity _fh = DDS_DataReader_as_DDS_Entity(h);
        std::lock_guard<std::mutex> _lock(::DDS::EntityImpl::_familyMutex());
        auto& _cache = ::DDS::EntityImpl::_familyCache();
        auto _it = _cache.find(_fh);
        if (_it != _cache.end()) {
            if (auto _base = _it->second.lock()) {
                if (auto _sp = std::dynamic_pointer_cast<DataReaderSupport>(_base)) return _sp;
            }
        }
        auto _sp = std::allocate_shared<DataReaderSupport>(
            std::pmr::polymorphic_allocator<DataReaderSupport>(std::pmr::get_default_resource()), h);
        _cache[_fh] = _sp;
        return _sp;
    }

private:
    // See TopicSupport's matching comment.
    friend DDS_DataReader zidl_concrete_handle(const DataReaderSupport& self) noexcept { return self.dds_.native_handle(); }
    ::DDS::DataReaderImpl dds_;
};

class DomainParticipantSupport final : public DomainParticipantImpl {
public:
    explicit DomainParticipantSupport(DDS_DomainParticipant handle)
        : DomainParticipantImpl(DDS_DomainParticipant_as_zzdds_DomainParticipant(handle)),
          dds_(handle)
    {}

    // register_type_support() is already implemented by DomainParticipantImpl (base).

    ::DDS::ReturnCode_t enable() override { return dds_.enable(); }
    std::shared_ptr<::DDS::StatusCondition> get_statuscondition() override { return dds_.get_statuscondition(); }
    ::DDS::StatusMask get_status_changes() override { return dds_.get_status_changes(); }
    ::DDS::InstanceHandle_t get_instance_handle() override { return dds_.get_instance_handle(); }
    std::shared_ptr<::DDS::Publisher> create_publisher(
        ::DDS::PublisherQos qos, std::shared_ptr<::DDS::PublisherListener> a_listener, ::DDS::StatusMask mask
    ) override {
        return dds_.create_publisher(qos, std::move(a_listener), mask);
    }
    ::DDS::ReturnCode_t delete_publisher(std::shared_ptr<::DDS::Publisher> p) override { return dds_.delete_publisher(std::move(p)); }
    std::shared_ptr<::DDS::Subscriber> create_subscriber(
        ::DDS::SubscriberQos qos, std::shared_ptr<::DDS::SubscriberListener> a_listener, ::DDS::StatusMask mask
    ) override {
        return dds_.create_subscriber(qos, std::move(a_listener), mask);
    }
    ::DDS::ReturnCode_t delete_subscriber(std::shared_ptr<::DDS::Subscriber> s) override { return dds_.delete_subscriber(std::move(s)); }
    std::shared_ptr<::DDS::Subscriber> get_builtin_subscriber() override { return dds_.get_builtin_subscriber(); }
    std::shared_ptr<::DDS::Topic> create_topic(
        std::string topic_name, std::string type_name, ::DDS::TopicQos qos,
        std::shared_ptr<::DDS::TopicListener> a_listener, ::DDS::StatusMask mask
    ) override {
        return dds_.create_topic(std::move(topic_name), std::move(type_name), qos, std::move(a_listener), mask);
    }
    ::DDS::ReturnCode_t delete_topic(std::shared_ptr<::DDS::Topic> a_topic) override { return dds_.delete_topic(std::move(a_topic)); }
    std::shared_ptr<::DDS::Topic> find_topic(std::string topic_name, ::DDS::Duration_t timeout) override {
        return dds_.find_topic(std::move(topic_name), timeout);
    }
    std::shared_ptr<::DDS::TopicDescription> lookup_topicdescription(std::string name) override {
        return dds_.lookup_topicdescription(std::move(name));
    }
    std::shared_ptr<::DDS::ContentFilteredTopic> create_contentfilteredtopic(
        std::string name, std::shared_ptr<::DDS::Topic> related_topic, std::string filter_expression,
        ::DDS::StringSeq expression_parameters
    ) override {
        return dds_.create_contentfilteredtopic(std::move(name), std::move(related_topic), std::move(filter_expression), expression_parameters);
    }
    ::DDS::ReturnCode_t delete_contentfilteredtopic(std::shared_ptr<::DDS::ContentFilteredTopic> a_contentfilteredtopic) override {
        return dds_.delete_contentfilteredtopic(std::move(a_contentfilteredtopic));
    }
    std::shared_ptr<::DDS::MultiTopic> create_multitopic(
        std::string name, std::string type_name, std::string subscription_expression, ::DDS::StringSeq expression_parameters
    ) override {
        return dds_.create_multitopic(std::move(name), std::move(type_name), std::move(subscription_expression), expression_parameters);
    }
    ::DDS::ReturnCode_t delete_multitopic(std::shared_ptr<::DDS::MultiTopic> a_multitopic) override {
        return dds_.delete_multitopic(std::move(a_multitopic));
    }
    ::DDS::ReturnCode_t delete_contained_entities() override { return dds_.delete_contained_entities(); }
    ::DDS::ReturnCode_t set_qos(::DDS::DomainParticipantQos qos) override { return dds_.set_qos(qos); }
    ::DDS::ReturnCode_t get_qos(::DDS::DomainParticipantQos& qos) override { return dds_.get_qos(qos); }
    ::DDS::ReturnCode_t set_listener(std::shared_ptr<::DDS::DomainParticipantListener> a_listener, ::DDS::StatusMask mask) override {
        return dds_.set_listener(std::move(a_listener), mask);
    }
    std::shared_ptr<::DDS::DomainParticipantListener> get_listener() override { return dds_.get_listener(); }
    ::DDS::ReturnCode_t ignore_participant(::DDS::InstanceHandle_t handle) override { return dds_.ignore_participant(handle); }
    ::DDS::ReturnCode_t ignore_topic(::DDS::InstanceHandle_t handle) override { return dds_.ignore_topic(handle); }
    ::DDS::ReturnCode_t ignore_publication(::DDS::InstanceHandle_t handle) override { return dds_.ignore_publication(handle); }
    ::DDS::ReturnCode_t ignore_subscription(::DDS::InstanceHandle_t handle) override { return dds_.ignore_subscription(handle); }
    ::DDS::DomainId_t get_domain_id() override { return dds_.get_domain_id(); }
    ::DDS::ReturnCode_t assert_liveliness() override { return dds_.assert_liveliness(); }
    ::DDS::ReturnCode_t set_default_publisher_qos(::DDS::PublisherQos qos) override { return dds_.set_default_publisher_qos(qos); }
    ::DDS::ReturnCode_t get_default_publisher_qos(::DDS::PublisherQos& qos) override { return dds_.get_default_publisher_qos(qos); }
    ::DDS::ReturnCode_t set_default_subscriber_qos(::DDS::SubscriberQos qos) override { return dds_.set_default_subscriber_qos(qos); }
    ::DDS::ReturnCode_t get_default_subscriber_qos(::DDS::SubscriberQos& qos) override { return dds_.get_default_subscriber_qos(qos); }
    ::DDS::ReturnCode_t set_default_topic_qos(::DDS::TopicQos qos) override { return dds_.set_default_topic_qos(qos); }
    ::DDS::ReturnCode_t get_default_topic_qos(::DDS::TopicQos& qos) override { return dds_.get_default_topic_qos(qos); }
    ::DDS::ReturnCode_t get_discovered_participants(::DDS::InstanceHandleSeq& participant_handles) override {
        return dds_.get_discovered_participants(participant_handles);
    }
    ::DDS::ReturnCode_t get_discovered_participant_data(
        ::DDS::ParticipantBuiltinTopicData& participant_data, ::DDS::InstanceHandle_t participant_handle
    ) override {
        return dds_.get_discovered_participant_data(participant_data, participant_handle);
    }
    ::DDS::ReturnCode_t get_discovered_topics(::DDS::InstanceHandleSeq& topic_handles) override {
        return dds_.get_discovered_topics(topic_handles);
    }
    ::DDS::ReturnCode_t get_discovered_topic_data(::DDS::TopicBuiltinTopicData& topic_data, ::DDS::InstanceHandle_t topic_handle) override {
        return dds_.get_discovered_topic_data(topic_data, topic_handle);
    }
    bool contains_entity(::DDS::InstanceHandle_t a_handle) override { return dds_.contains_entity(a_handle); }
    ::DDS::ReturnCode_t get_current_time(::DDS::Time_t& current_time) override { return dds_.get_current_time(current_time); }

    // See TopicSupport's matching comment.
    static std::shared_ptr<DomainParticipantSupport> _getOrCreate(DDS_DomainParticipant h) {
        if (!h) return nullptr;
        DDS_Entity _fh = DDS_DomainParticipant_as_DDS_Entity(h);
        std::lock_guard<std::mutex> _lock(::DDS::EntityImpl::_familyMutex());
        auto& _cache = ::DDS::EntityImpl::_familyCache();
        auto _it = _cache.find(_fh);
        if (_it != _cache.end()) {
            if (auto _base = _it->second.lock()) {
                if (auto _sp = std::dynamic_pointer_cast<DomainParticipantSupport>(_base)) return _sp;
            }
        }
        auto _sp = std::allocate_shared<DomainParticipantSupport>(
            std::pmr::polymorphic_allocator<DomainParticipantSupport>(std::pmr::get_default_resource()), h);
        _cache[_fh] = _sp;
        return _sp;
    }

private:
    // See TopicSupport's matching comment.
    friend DDS_DomainParticipant zidl_concrete_handle(const DomainParticipantSupport& self) noexcept { return self.dds_.native_handle(); }
    ::DDS::DomainParticipantImpl dds_;
};

} // namespace detail

namespace detail {

// Shared by both create_factory() overloads below.
//
// Allocates DomainParticipantFactorySupport via std::allocate_shared against
// the process-wide std::pmr default resource — see zidl::setCppAllocator
// (zidl_allocator_pmr.hpp) to register a ZidlAllocator-backed one. This is a
// SEPARATE, independent knob from `handle`'s own allocator
// (zzdds_create_factory_with_allocator): that one controls the zzdds/Zig-side
// factory and everything IT creates (participants, topics, writers, readers,
// history cache); this one controls the C++ wrapper OBJECTS
// (DomainParticipantFactorySupport here, and every generated `_getOrCreate`)
// sitting on top of the C-ABI. They can't be unified into one call even in
// principle: `handle`'s allocator is scoped per-factory, while
// std::pmr::set_default_resource is process-wide — silently having one call
// imply the other would misrepresent which scope each actually has.
//
// allocate_shared requires the teardown call (zzdds_destroy_factory) to live
// in DomainParticipantFactorySupport's own destructor rather than a separate
// custom deleter — allocate_shared has no hook for a deleter distinct from
// the allocator-driven one, unlike the raw new + shared_ptr(ptr, deleter)
// construction this replaced. DomainParticipantFactorySupport's own
// constructor can't throw partway through and leave `handle` stored nowhere
// (every initializer is a trivial, noexcept, handle-storing constructor) --
// but that's not the only way to fail here: std::allocate_shared's PMR
// allocation itself (the control-block + object storage) can throw
// std::bad_alloc *before* the constructor ever runs, e.g. under a bounded
// pool allocator registered via zidl::setCppAllocator that's exhausted. In
// that case DomainParticipantFactorySupport never exists, so its destructor
// never runs, so nothing frees `handle` -- the try/catch below is what
// closes that gap, not the constructor's own noexcept-ness.
inline std::shared_ptr<DomainParticipantFactory> wrapFactoryHandle(zzdds_DomainParticipantFactory handle)
{
    if (zzdds_factory_is_nil(handle)) return {};

    try {
        return std::allocate_shared<detail::DomainParticipantFactorySupport>(
            std::pmr::polymorphic_allocator<detail::DomainParticipantFactorySupport>(
                std::pmr::get_default_resource()),
            handle
        );
    } catch (...) {
        zzdds_destroy_factory(handle);
        throw;
    }
}

} // namespace detail

inline std::shared_ptr<DomainParticipantFactory> create_factory()
{
    return detail::wrapFactoryHandle(zzdds_create_factory());
}

/**
 * Same as create_factory(), but every allocation the factory and everything it
 * ever creates makes is routed through `allocator` instead of the default
 * libc malloc/free (see zzdds_create_factory_with_allocator's contract in
 * zzdds_c.h). `allocator` must outlive the returned factory and everything
 * created through it. Pass nullptr for the default (equivalent to
 * create_factory()).
 */
inline std::shared_ptr<DomainParticipantFactory> create_factory(const ZidlAllocator* allocator)
{
    return detail::wrapFactoryHandle(zzdds_create_factory_with_allocator(allocator));
}

namespace detail {

// WaitSet and GuardCondition are the only two condition-family types with no
// factory operation in dcps.idl (per OMG spec, both are app-instantiated
// directly), so — like DomainParticipantFactorySupport above — they need a
// thin subclass over the generated ::DDS::WaitSetImpl/::DDS::GuardConditionImpl
// (whose own destructor is `= default` and does not call zzdds_destroy_*)
// adding the C-ABI teardown call. Unlike DomainParticipantFactorySupport,
// neither interface is vendor-extended by zzdds.idl, so these subclass the
// plain ::DDS:: generated impl classes directly — no --cpp-impl-override
// wiring needed, and no *Support class for zzdds::create_waitset() to
// register anywhere.
//
// WaitSet has no family to register into (not `@shared_c_abi_box`, no
// concrete sibling implementors — every WaitSet view really is a WaitSet).
// GuardCondition is different: it's a real member of Condition's shared
// C-ABI box family (see dcps.idl's `@shared_c_abi_box` annotations and
// zidl's docs/roadmap.md "Binding design review: decision"), and
// `WaitSet::wait()`/`get_conditions()` construct a generic `::DDS::Condition`
// for every handle they return via `::DDS::ConditionImpl::_getOrCreate` — the
// same shared per-family cache `StatusConditionImpl`/`ReadConditionImpl`/
// `QueryConditionImpl` all consult in dcps_impl.cpp. Because GuardCondition
// is never wrapped via any generated `_getOrCreate` (nothing in dcps.idl
// returns/holds a generic `Condition` value that's ever *constructed* from
// this path — only `wait()`'s return path does that, from the OTHER side),
// `wrapGuardConditionHandle` below has to register the object it constructs
// into that same shared cache itself, or a later `wait()` call would
// construct an unrelated second `ConditionImpl` for the identical handle —
// exactly the identity-fragmentation bug the shared cache exists to prevent.

class WaitSetSupport final : public ::DDS::WaitSetImpl {
public:
    explicit WaitSetSupport(DDS_WaitSet handle) noexcept
        : ::DDS::WaitSetImpl(handle), handle_(handle)
    {}

    ~WaitSetSupport() override
    {
        // Every still-attached condition's release_fn (see attach_condition
        // below) fires synchronously as part of this call, before it
        // returns -- each one erases its own keepalive_ entry via
        // release_trampoline, so keepalive_ is already empty by the time
        // this object's members get torn down right after. No explicit
        // cleanup needed here.
        zzdds_destroy_waitset(handle_);
    }

    // Keeps a shared_ptr keep-alive for every attached condition, released
    // via zzdds_waitset_attach_condition_with_release's release_fn exactly
    // once the attachment actually ends (explicit detach_condition(), this
    // WaitSet destroyed, or the condition itself destroyed -- no override of
    // detach_condition() needed: the plain, inherited one already fires the
    // same release_fn, since it's the SAME underlying C-ABI attachment
    // record either way). Not because the DDS spec requires this (WaitSet
    // attachment is not ownership) -- because a C++ app that drops its own
    // last shared_ptr right after attaching, relying on the WaitSet to keep
    // the condition alive the way wait()'s returned handles might suggest,
    // would otherwise be left holding a dangling wrapper the moment the
    // underlying C-ABI entity is torn down. See zidl's docs/roadmap.md
    // "Binding design review: decision" -> "WaitSet-attached-condition
    // release hook" for the C-ABI side of this, and its own "Explicitly not
    // done" note this closes for C++.
    ::DDS::ReturnCode_t attach_condition(std::shared_ptr<::DDS::Condition> cond) override
    {
        if (!cond) return ::DDS::WaitSetImpl::attach_condition(cond);
        DDS_Condition h = resolve_handle(cond);
        std::lock_guard<std::mutex> lock(mu_);
        if (keepalive_.count(h)) {
            // Already attached (and already tracked) -- a redundant
            // re-attach is a documented no-op either way, and
            // zzdds_waitset_attach_condition_with_release would silently
            // ignore a second release_ctx/release_fn for an
            // already-attached condition (never swapping one registration
            // in for another), leaking this one -- go through the plain
            // path instead of registering a context that would never fire.
            return ::DDS::WaitSetImpl::attach_condition(cond);
        }
        auto* ctx = new ReleaseCtx{this, h};
        auto rc = zzdds_waitset_attach_condition_with_release(handle_, h, ctx, &release_trampoline);
        if (rc != DDS_RETCODE_OK) {
            delete ctx;
            return rc;
        }
        keepalive_.emplace(h, std::move(cond));
        return rc;
    }

private:
    struct ReleaseCtx {
        WaitSetSupport* self;
        DDS_Condition handle;
    };

    // Fires from inside zzdds, outside any zzdds-internal lock, on whichever
    // of the three ways an attachment ends -- never synchronously from
    // within attach_condition() itself (only detach/destroy paths fire it),
    // so taking mu_ here can't deadlock against attach_condition() holding
    // it across its own zzdds_waitset_attach_condition_with_release() call.
    static void release_trampoline(void* ctx_raw)
    {
        std::unique_ptr<ReleaseCtx> ctx(static_cast<ReleaseCtx*>(ctx_raw));
        std::lock_guard<std::mutex> lock(ctx->self->mu_);
        ctx->self->keepalive_.erase(ctx->handle);
    }

    // Mirrors WaitSetImpl::attach_condition's own generated dynamic_cast
    // cascade (dcps_impl.cpp) -- duplicated rather than shared because that
    // one lives inline in a lambda with no separately-callable entry point.
    static DDS_Condition resolve_handle(const std::shared_ptr<::DDS::Condition>& cond)
    {
        if (auto* impl = dynamic_cast<::DDS::ConditionImpl*>(cond.get()))
            return zidl_concrete_handle(*impl);
        if (auto* impl = dynamic_cast<::DDS::GuardConditionImpl*>(cond.get()))
            return DDS_GuardCondition_as_DDS_Condition(zidl_concrete_handle(*impl));
        if (auto* impl = dynamic_cast<::DDS::StatusConditionImpl*>(cond.get()))
            return DDS_StatusCondition_as_DDS_Condition(zidl_concrete_handle(*impl));
        if (auto* impl = dynamic_cast<::DDS::ReadConditionImpl*>(cond.get()))
            return DDS_ReadCondition_as_DDS_Condition(zidl_concrete_handle(*impl));
        if (auto* impl = dynamic_cast<::DDS::QueryConditionImpl*>(cond.get()))
            return DDS_ReadCondition_as_DDS_Condition(DDS_QueryCondition_as_DDS_ReadCondition(zidl_concrete_handle(*impl)));
        throw std::invalid_argument("zidl: incompatible entity implementation for DDS::Condition");
    }

    DDS_WaitSet handle_;
    std::mutex mu_;
    std::unordered_map<DDS_Condition, std::shared_ptr<::DDS::Condition>> keepalive_;
};

class GuardConditionSupport final : public ::DDS::GuardConditionImpl {
public:
    explicit GuardConditionSupport(DDS_GuardCondition handle) noexcept
        : ::DDS::GuardConditionImpl(handle), handle_(handle)
    {}

    ~GuardConditionSupport() override
    {
        zzdds_destroy_guardcondition(handle_);
    }

private:
    DDS_GuardCondition handle_;
};

// Same allocate_shared-against-the-process-wide-pmr-resource shape as
// wrapFactoryHandle above; see its comment for why this is a separate knob
// from `handle`'s own allocator.
inline std::shared_ptr<::DDS::WaitSet> wrapWaitSetHandle(DDS_WaitSet handle)
{
    if (zzdds_waitset_is_nil(handle)) return {};

    try {
        return std::allocate_shared<WaitSetSupport>(
            std::pmr::polymorphic_allocator<WaitSetSupport>(
                std::pmr::get_default_resource()),
            handle
        );
    } catch (...) {
        zzdds_destroy_waitset(handle);
        throw;
    }
}

inline std::shared_ptr<::DDS::GuardCondition> wrapGuardConditionHandle(DDS_GuardCondition handle)
{
    if (zzdds_guardcondition_is_nil(handle)) return {};

    try {
        auto sp = std::allocate_shared<GuardConditionSupport>(
            std::pmr::polymorphic_allocator<GuardConditionSupport>(
                std::pmr::get_default_resource()),
            handle
        );
        // Register into Condition's shared family cache (see the comment
        // above this function) so a later WaitSet::wait()/get_conditions()
        // resolving the same handle via ::DDS::ConditionImpl::_getOrCreate
        // finds THIS object instead of constructing an unrelated one.
        // create_guardcondition() always mints a fresh handle, so this is
        // always a first registration, never a "someone else already cached
        // it" race to reconcile against.
        {
            std::lock_guard<std::mutex> _lock(::DDS::ConditionImpl::_familyMutex());
            ::DDS::ConditionImpl::_familyCache()[DDS_GuardCondition_as_DDS_Condition(handle)] = sp;
        }
        return sp;
    } catch (...) {
        zzdds_destroy_guardcondition(handle);
        throw;
    }
}

} // namespace detail

inline std::shared_ptr<::DDS::WaitSet> create_waitset()
{
    return detail::wrapWaitSetHandle(zzdds_create_waitset());
}

/**
 * Same as create_waitset(), but every allocation the WaitSet itself makes is
 * routed through `allocator` instead of the default libc malloc/free (see
 * zzdds_create_waitset_with_allocator's contract in zzdds_c.h). `allocator`
 * must outlive the returned WaitSet. Pass nullptr for the default
 * (equivalent to create_waitset()).
 */
inline std::shared_ptr<::DDS::WaitSet> create_waitset(const ZidlAllocator* allocator)
{
    return detail::wrapWaitSetHandle(zzdds_create_waitset_with_allocator(allocator));
}

inline std::shared_ptr<::DDS::GuardCondition> create_guardcondition()
{
    return detail::wrapGuardConditionHandle(zzdds_create_guardcondition());
}

/**
 * Same as create_guardcondition(), but the GuardCondition itself is
 * allocated through `allocator` instead of the default libc malloc/free.
 * `allocator` must outlive the returned GuardCondition. Pass nullptr for
 * the default (equivalent to create_guardcondition()).
 */
inline std::shared_ptr<::DDS::GuardCondition> create_guardcondition(const ZidlAllocator* allocator)
{
    return detail::wrapGuardConditionHandle(zzdds_create_guardcondition_with_allocator(allocator));
}

/**
 * Resolve `path` as a zzdds TOML config file and install the result as the
 * process-wide configuration, entirely through `allocator` (nullptr for the
 * default, libc malloc/free) -- see zzdds_process_configure_from_file's
 * contract in zzdds_c.h. Call this before create_factory()/
 * create_factory(allocator), with the SAME allocator you'll pass to the
 * latter, to avoid the ambient lazy-default path's libc malloc use for the
 * process-wide config's own persistent storage.
 */
inline ::DDS::ReturnCode_t process_configure_from_file(const char* path, const ZidlAllocator* allocator)
{
    return zzdds_process_configure_from_file(path, allocator);
}

} // namespace zzdds
