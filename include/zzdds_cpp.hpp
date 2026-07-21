#pragma once

#include "zzdds_impl.hpp"
#include "zidl_allocator_pmr.hpp"

#include <memory>
#include <memory_resource>
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

} // namespace zzdds
