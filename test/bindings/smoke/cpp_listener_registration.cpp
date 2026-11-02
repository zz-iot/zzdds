// Binding test for C++ listener registrations. Compiled and run by
// `zig build test-bindings -Dcpp-binding=true`.
//
// Identity: one application object registers under one listener_identity
// whichever listener interfaces it implements (DDS::Listener is a virtual
// base), while each registration has its own listener_data.
//
// Lifetime: a listener replaced while one of its callbacks is running stays
// alive until that callback returns. The application hands the reader its only reference to the listener. Its
// on_subscription_matched blocks until the main thread has replaced the
// listener, then checks the listener's destructor has not run. The core keeps
// the old registration until an in-flight dispatch finishes and then calls its
// release_listener_data; the binding must hold the listener until then rather
// than drop it when set_listener overwrites the entity wrapper's reference.
//
// All synchronization state is global: with the bug, the listener is freed
// while its callback runs, so the callback must not touch `this` after waking.
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
bool g_replaced = false;
std::atomic<bool> g_destroyed{false};
std::atomic<int> g_alive_after_replace{-1}; // -1 not checked, 0 freed, 1 alive

class BlockingListener : public ::DDS::DataReaderListenerBase {
public:
    ~BlockingListener() override { g_destroyed = true; }

    void on_subscription_matched(std::shared_ptr<::DDS::DataReader>, ::DDS::SubscriptionMatchedStatus status) override {
        if (status.current_count == 0) return;
        std::unique_lock<std::mutex> lock(g_mu);
        if (g_entered) return;
        g_entered = true;
        g_cv.notify_all();
        g_cv.wait_for(lock, std::chrono::seconds(10), [] { return g_replaced; });
        g_alive_after_replace = g_destroyed.load() ? 0 : 1;
    }
};

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

} // namespace

int main() {
    check_identity();

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

    auto dw = pub->create_datawriter(topic_w, ::DDS::DataWriterQos::default_value(), nullptr, 0);
    CHECK(dw);

    {
        std::unique_lock<std::mutex> lock(g_mu);
        CHECK(g_cv.wait_for(lock, std::chrono::seconds(20), [] { return g_entered; }));
    }
    // Replace the listener while its callback is blocked inside it.
    CHECK(dr->set_listener(nullptr, 0) == ::DDS::RETCODE_OK);
    {
        std::lock_guard<std::mutex> lock(g_mu);
        g_replaced = true;
    }
    g_cv.notify_all();

    CHECK(wait_until([] { return g_alive_after_replace.load() != -1; }));
    CHECK(g_alive_after_replace.load() == 1);
    // Released once the callback returned, not leaked.
    CHECK(wait_until([] { return g_destroyed.load(); }));

    CHECK(pub->delete_datawriter(dw) == ::DDS::RETCODE_OK);
    CHECK(sub->delete_datareader(dr) == ::DDS::RETCODE_OK);
    CHECK(dp_w->delete_contained_entities() == ::DDS::RETCODE_OK);
    CHECK(dp_r->delete_contained_entities() == ::DDS::RETCODE_OK);
    CHECK(factory->delete_participant(dp_w) == ::DDS::RETCODE_OK);
    CHECK(factory->delete_participant(dp_r) == ::DDS::RETCODE_OK);
    std::printf("cpp_listener_registration: OK\n");
    return 0;
}
