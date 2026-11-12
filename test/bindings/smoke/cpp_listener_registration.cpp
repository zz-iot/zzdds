// Binding test for C++ listener registrations. Compiled and run by
// `zig build test-bindings -Dcpp-binding=true`.
//
// Identity: one application object registers under one listener_identity
// whichever listener interfaces it implements (DDS::Listener is a virtual
// base), while each registration has its own listener_data.
//
// Lifetime: set_listener from application code returns only once the
// callback of the listener it replaced has returned, and a replaced listener
// stays alive until then. The application hands the reader its only reference
// to the listener. Its on_subscription_matched blocks while another thread
// clears the reader's listener; that set_listener must not return, and the
// listener must not be destroyed, until the callback is released and returns.
// The core then calls release_listener_data, so the listener is destroyed by
// the time set_listener returns; the binding must not drop it earlier, when
// set_listener overwrites the entity wrapper's reference.
//
// All synchronization state is global: with a bug, the listener is freed
// while its callback runs, so the callback must not touch `this` after waking.
//
// Also: a listener implementing DDS::DataReaderListener directly (not through
// the generated DataReaderListenerBase) is installed, and an entity this
// binding did not create is rejected with an error, not a crash. The test is
// also built with -fno-rtti -fno-exceptions.
#include "zzdds_cpp.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <thread>

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            std::exit(1);                                                             \
        }                                                                             \
    } while (0)

namespace {

std::mutex g_mu;
std::condition_variable g_cv;
bool g_entered = false;
bool g_released = false;
std::atomic<bool> g_destroyed{false};
std::atomic<bool> g_set_returned{false};
// -1 not checked, 0 freed or set_listener returned while it ran, 1 alive, 2 never released
std::atomic<int> g_alive_while_replaced{-1};

class BlockingListener : public ::DDS::DataReaderListenerBase {
public:
    ~BlockingListener() override { g_destroyed = true; }

    void on_subscription_matched(std::shared_ptr<::DDS::DataReader>, ::DDS::SubscriptionMatchedStatus status) override {
        if (status.current_count == 0) return;
        std::unique_lock<std::mutex> lock(g_mu);
        if (g_entered) return;
        g_entered = true;
        g_cv.notify_all();
        // A wait that times out never saw the replacement, so it proves
        // nothing about the listener's lifetime: record that as a failure.
        if (!g_cv.wait_for(lock, std::chrono::seconds(20), [] { return g_released; })) {
            g_alive_while_replaced = 2;
            return;
        }
        g_alive_while_replaced = (g_destroyed.load() || g_set_returned.load()) ? 0 : 1;
    }
};

// Implements the listener interface itself, not DataReaderListenerBase.
std::atomic<int> g_direct_matches{0};
class DirectListener : public ::DDS::DataReaderListener {
public:
    void on_requested_deadline_missed(std::shared_ptr<::DDS::DataReader>, ::DDS::RequestedDeadlineMissedStatus) override {}
    void on_requested_incompatible_qos(std::shared_ptr<::DDS::DataReader>, ::DDS::RequestedIncompatibleQosStatus) override {}
    void on_sample_rejected(std::shared_ptr<::DDS::DataReader>, ::DDS::SampleRejectedStatus) override {}
    void on_liveliness_changed(std::shared_ptr<::DDS::DataReader>, ::DDS::LivelinessChangedStatus) override {}
    void on_data_available(std::shared_ptr<::DDS::DataReader>) override {}
    void on_subscription_matched(std::shared_ptr<::DDS::DataReader>, ::DDS::SubscriptionMatchedStatus status) override {
        if (status.current_count > 0) g_direct_matches++;
    }
    void on_sample_lost(std::shared_ptr<::DDS::DataReader>, ::DDS::SampleLostStatus) override {}
};

// A condition this binding did not create: it has no C handle.
class ForeignCondition : public ::DDS::Condition {
public:
    bool get_trigger_value() override { return false; }
};

void check_conditions() {
    auto ws = zzdds::create_waitset();
    CHECK(ws);
    auto foreign = std::make_shared<ForeignCondition>();
    CHECK(ws->attach_condition(foreign) == ::DDS::RETCODE_BAD_PARAMETER);
    CHECK(ws->detach_condition(foreign) != ::DDS::RETCODE_OK);

    // A guard condition registered by zzdds_cpp.hpp comes back as itself.
    auto gc = zzdds::create_guardcondition();
    CHECK(gc);
    CHECK(ws->attach_condition(gc) == ::DDS::RETCODE_OK);
    ::DDS::ConditionSeq attached;
    CHECK(ws->get_conditions(attached) == ::DDS::RETCODE_OK);
    CHECK(attached.size() == 1);
    CHECK(attached[0] == std::static_pointer_cast<::DDS::Condition>(gc));
    CHECK(ws->detach_condition(gc) == ::DDS::RETCODE_OK);
}

// One object, two listener interfaces.
class ReaderWriterListener : public ::DDS::DataReaderListenerBase, public ::DDS::DataWriterListenerBase {};

// DomainParticipantListener reaches DDS::Listener through three interfaces.
class ParticipantListener : public ::DDS::DomainParticipantListenerBase {};

void check_identity() {
    auto rw = std::make_shared<ReaderWriterListener>();
    auto r = ::DDS::DataReaderListenerBase::c_listener(std::shared_ptr<::DDS::DataReaderListenerBase>(rw));
    auto w = ::DDS::DataWriterListenerBase::c_listener(std::shared_ptr<::DDS::DataWriterListenerBase>(rw));
    CHECK(r.listener_identity != nullptr);
    CHECK(r.listener_identity == w.listener_identity);
    CHECK(r.listener_identity == static_cast<::DDS::Listener*>(rw.get()));
    CHECK(r.listener_data != w.listener_data);
    // Each registration holds a reference until the core releases it.
    CHECK(rw.use_count() == 3);
    r.release_listener_data(r.listener_data);
    w.release_listener_data(w.listener_data);
    CHECK(rw.use_count() == 1);

    auto p = std::make_shared<ParticipantListener>();
    auto pl = ::DDS::DomainParticipantListenerBase::c_listener(p);
    CHECK(pl.listener_identity == static_cast<::DDS::Listener*>(p.get()));
    pl.release_listener_data(pl.listener_data);
}

template <typename Pred>
bool wait_until(Pred pred) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline) {
        if (pred()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return pred();
}

// zzdds creates every reader as its zzdds extension class, so without RTTI
// (this test is also built with -fno-rtti) a static cast reaches that API.
template <typename To, typename From>
std::shared_ptr<To> as_zzdds(const std::shared_ptr<From>& p) {
#if defined(__cpp_rtti) || defined(__GXX_RTTI) || defined(_CPPRTTI)
    return std::dynamic_pointer_cast<To>(p);
#else
    return std::static_pointer_cast<To>(p);
#endif
}

// Rejected registrations: a call that registers a listener and fails leaves
// the registration with the caller, so the binding must release what it built.
// set_listener and set_listener_ex on a reader whose deletion has begun return
// ALREADY_DELETED from the core. The shared runtime makes that window
// deterministic: deleting a reader waits for its running callback before
// retiring the wrapper, so a call from that callback still reaches the core.
// The callback retries until the core rejects, then checks the rejected
// listener was released by the time the call returned.
std::atomic<int> g_probes_made{0};
std::atomic<int> g_probes_destroyed{0};

class Probe : public ::DDS::DataReaderListenerBase {
public:
    Probe() { g_probes_made++; }
    ~Probe() override { g_probes_destroyed++; }
};

class ProbeEx : public ::zzdds::DataReaderListenerExBase {
public:
    ProbeEx() { g_probes_made++; }
    ~ProbeEx() override { g_probes_destroyed++; }
};

struct Rejection {
    std::mutex mu;
    std::condition_variable cv;
    bool entered = false;
    bool deleting = false;
    bool done = false;
    ::DDS::ReturnCode_t plain_rc = -1;
    ::DDS::ReturnCode_t ex_rc = -1;
    bool plain_released = false;
    bool ex_released = false;
};
Rejection g_rej;

// Calls `set` with a new listener until the reader rejects one; returns that
// result and whether the rejected listener was already destroyed on return.
template <typename L, typename Set>
::DDS::ReturnCode_t set_until_rejected(Set set, bool &released) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (std::chrono::steady_clock::now() < deadline) {
        std::weak_ptr<L> weak;
        ::DDS::ReturnCode_t rc;
        {
            auto listener = std::make_shared<L>();
            weak = listener;
            rc = set(listener);
        }
        if (rc != ::DDS::RETCODE_OK) {
            released = weak.expired();
            return rc;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return ::DDS::RETCODE_TIMEOUT;
}

class RejectingListener : public ::DDS::DataReaderListenerBase {
public:
    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> reader, ::DDS::SubscriptionMatchedStatus status) override {
        if (status.current_count == 0) return;
        {
            std::unique_lock<std::mutex> lock(g_rej.mu);
            if (g_rej.entered) return;
            g_rej.entered = true;
            g_rej.cv.notify_all();
            if (!g_rej.cv.wait_for(lock, std::chrono::seconds(20), [] { return g_rej.deleting; })) return;
        }
        bool plain_released = false;
        bool ex_released = false;
        const auto plain_rc = set_until_rejected<Probe>(
            [&](std::shared_ptr<Probe> l) { return reader->set_listener(l, ::DDS::SUBSCRIPTION_MATCHED_STATUS); },
            plain_released);
        auto zreader = as_zzdds<::zzdds::DataReaderImpl>(reader);
        const auto ex_rc = set_until_rejected<ProbeEx>(
            [&](std::shared_ptr<ProbeEx> l) { return zreader->set_listener_ex(l, ::DDS::SUBSCRIPTION_MATCHED_STATUS); },
            ex_released);
        std::lock_guard<std::mutex> lock(g_rej.mu);
        g_rej.plain_rc = plain_rc;
        g_rej.ex_rc = ex_rc;
        g_rej.plain_released = plain_released;
        g_rej.ex_released = ex_released;
        g_rej.done = true;
        g_rej.cv.notify_all();
    }
};

void check_rejected_registrations(const std::shared_ptr<::DDS::Subscriber> &sub,
                                  const std::shared_ptr<::DDS::TopicDescription> &topic) {
    auto dr = sub->create_datareader(topic, ::DDS::DataReaderQos::default_value(),
                                     std::make_shared<RejectingListener>(), ::DDS::SUBSCRIPTION_MATCHED_STATUS);
    CHECK(dr);
    {
        std::unique_lock<std::mutex> lock(g_rej.mu);
        CHECK(g_rej.cv.wait_for(lock, std::chrono::seconds(20), [] { return g_rej.entered; }));
        g_rej.deleting = true;
    }
    g_rej.cv.notify_all();
    // Returns once the callback has returned.
    CHECK(sub->delete_datareader(dr) == ::DDS::RETCODE_OK);
    std::lock_guard<std::mutex> lock(g_rej.mu);
    CHECK(g_rej.done);
    CHECK(g_rej.plain_rc == ::DDS::RETCODE_ALREADY_DELETED);
    CHECK(g_rej.plain_released);
    CHECK(g_rej.ex_rc == ::DDS::RETCODE_ALREADY_DELETED);
    CHECK(g_rej.ex_released);
    // Accepted listeners go with the reader.
    CHECK(wait_until([] { return g_probes_destroyed.load() == g_probes_made.load(); }));
    CHECK(g_probes_destroyed.load() == g_probes_made.load());
}

} // namespace

int main() {
    check_identity();
    check_conditions();

    const char *base = std::getenv("ZZDDS_TEST_DOMAIN_BASE");
    const ::DDS::DomainId_t domain = base ? std::atoi(base) : 101;

    auto factory = zzdds::create_factory();
    CHECK(factory);
    auto dp_w = factory->create_participant(domain, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    auto dp_r = factory->create_participant(domain, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    CHECK(dp_w && dp_r);

    auto topic_w = dp_w->create_topic("CppListenerLifetime", "CppListenerLifetimeType",
                                      ::DDS::TopicQos::default_value(), nullptr, 0);
    auto topic_r = dp_r->create_topic("CppListenerLifetime", "CppListenerLifetimeType",
                                      ::DDS::TopicQos::default_value(), nullptr, 0);
    CHECK(topic_w && topic_r);
    auto pub = dp_w->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    auto sub = dp_r->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    CHECK(pub && sub);

    auto dr = sub->create_datareader(
        std::static_pointer_cast<::zzdds::TopicImpl>(topic_r)->as_topic_description(),
        ::DDS::DataReaderQos::default_value(), nullptr, 0);
    CHECK(dr);
    CHECK(dr->set_listener(std::make_shared<BlockingListener>(), ::DDS::SUBSCRIPTION_MATCHED_STATUS) == ::DDS::RETCODE_OK);
    auto direct = std::make_shared<DirectListener>();
    auto dr_direct = sub->create_datareader(
        std::static_pointer_cast<::zzdds::TopicImpl>(topic_r)->as_topic_description(),
        ::DDS::DataReaderQos::default_value(), direct, ::DDS::SUBSCRIPTION_MATCHED_STATUS);
    CHECK(dr_direct);
    // get_listener reads the core's registration, so a listener installed
    // by create_datareader comes back too.
    CHECK(dr_direct->get_listener() == direct);

    auto dw = pub->create_datawriter(topic_w, ::DDS::DataWriterQos::default_value(), nullptr, 0);
    CHECK(dw);

    {
        std::unique_lock<std::mutex> lock(g_mu);
        CHECK(g_cv.wait_for(lock, std::chrono::seconds(20), [] { return g_entered; }));
    }
    // Clear the listener from another thread while its callback is blocked
    // inside it: set_listener waits for the callback.
    ::DDS::ReturnCode_t set_rc = ::DDS::RETCODE_ERROR;
    std::thread setter([&] {
        set_rc = dr->set_listener(nullptr, 0);
        g_set_returned = true;
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    CHECK(!g_set_returned.load());
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_released = true;
    }
    g_cv.notify_all();
    setter.join();
    CHECK(set_rc == ::DDS::RETCODE_OK);
    CHECK(g_alive_while_replaced.load() == 1);
    // Released once the callback returned, before set_listener did.
    CHECK(g_destroyed.load());
    CHECK(wait_until([] { return g_direct_matches.load() > 0; }));

    CHECK(dr->get_listener() == nullptr);

    check_rejected_registrations(
        sub, std::static_pointer_cast<::zzdds::TopicImpl>(topic_r)->as_topic_description());

    // Deletion retires the wrapper before returning, even if native references
    // postpone freeing the handle. Its calls no longer reach the core.
    CHECK(pub->delete_datawriter(dw) == ::DDS::RETCODE_OK);
    CHECK(dw->enable() == ::DDS::RETCODE_ALREADY_DELETED);
    CHECK(sub->delete_datareader(dr) == ::DDS::RETCODE_OK);
    CHECK(dp_w->delete_contained_entities() == ::DDS::RETCODE_OK);
    // The same for entities a cascading delete takes, which never pass
    // through the binding.
    CHECK(dp_r->delete_contained_entities() == ::DDS::RETCODE_OK);
    CHECK(dr_direct->enable() == ::DDS::RETCODE_ALREADY_DELETED);
    CHECK(dr_direct->get_listener() == nullptr);
    CHECK(sub->enable() == ::DDS::RETCODE_ALREADY_DELETED);
    // A new subscriber gets a wrapper of its own, even at a reused address.
    auto sub2 = dp_r->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    CHECK(sub2 && sub2 != sub);
    CHECK(sub2->enable() == ::DDS::RETCODE_OK);
    CHECK(dp_r->delete_contained_entities() == ::DDS::RETCODE_OK);
    CHECK(factory->delete_participant(dp_w) == ::DDS::RETCODE_OK);
    CHECK(factory->delete_participant(dp_r) == ::DDS::RETCODE_OK);
    std::printf("cpp_listener_registration: OK\n");
    return 0;
}
