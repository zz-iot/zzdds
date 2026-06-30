#pragma once

#include "zzdds_impl.hpp"

#include <memory>
#include <utility>

namespace zzdds {

namespace detail {

class DomainParticipantFactorySupport final : public DomainParticipantFactoryImpl {
public:
    explicit DomainParticipantFactorySupport(zzdds_DomainParticipantFactory handle) noexcept
        : DomainParticipantFactoryImpl(handle),
          dds_(zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(handle))
    {}

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
};

} // namespace detail

inline std::shared_ptr<DomainParticipantFactory> create_factory()
{
    const zzdds_DomainParticipantFactory handle = zzdds_create_factory();
    if (zzdds_factory_is_nil(handle)) return {};

    struct FactoryHandleGuard {
        zzdds_DomainParticipantFactory handle;
        bool armed = true;

        ~FactoryHandleGuard()
        {
            if (armed) zzdds_destroy_factory(handle);
        }

        void release() noexcept { armed = false; }
    } guard{handle};

    auto deleter = [handle](detail::DomainParticipantFactorySupport* factory) {
        delete factory;
        zzdds_destroy_factory(handle);
    };
    std::unique_ptr<detail::DomainParticipantFactorySupport, decltype(deleter)> owned(
        new detail::DomainParticipantFactorySupport(handle),
        deleter
    );
    guard.release();

    return std::shared_ptr<DomainParticipantFactory>(std::move(owned));
}

} // namespace zzdds
