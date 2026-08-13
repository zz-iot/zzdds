/*
 * cpp/waitset -- publisher. Direct C++ port of zig/waitset/publisher.zig;
 * see docs/design/waitset-reference-app.md at the repo root for the full
 * spec.
 *
 * Drives its whole lifecycle through a single WaitSet with two conditions
 * attached at once, instead of a listener:
 *
 *   - StatusCondition (PUBLICATION_MATCHED_STATUS) -- reused across two
 *     separate wait phases: first waiting for a reader to match, later
 *     waiting for it to disconnect again.
 *   - GuardCondition -- a background "watchdog" thread sets this if the
 *     whole run exceeds its overall deadline. Real cross-thread concurrency
 *     on the same WaitSet/GuardCondition -- the same exercise
 *     zig/waitset's own watchdog demonstrates.
 *
 * Unlike Zig, C++'s condition interfaces (GuardCondition, StatusCondition,
 * ReadCondition, QueryCondition) are real public subclasses of Condition,
 * so attach_condition(sc)/attach_condition(gc) upcast implicitly via
 * std::shared_ptr's own conversion -- no as_Condition() workaround needed
 * (see zig/waitset/publisher.zig's comment on the Zig-side gap this avoids).
 *
 * Branches on membership in wait()'s returned ConditionSeq (`if (active
 * contains gc)`), the same idiom zig/waitset's own wait loop uses. This used
 * to be impossible: WaitSet::wait()'s generated C++ binding always re-wrapped
 * a returned Condition as the base ::DDS::ConditionImpl, constructed via its
 * own independent identity cache -- never the same C++ object as the
 * GuardConditionSupport/StatusConditionImpl this program already holds, even
 * though both refer to the same underlying condition (see zidl's
 * docs/roadmap.md "Binding design review: decision" for the raw-C-ABI-handle
 * fix, and its "shared-family _getOrCreate cache" follow-up for the
 * C++-wrapper-layer fix this specifically needed on top of that -- the raw
 * handle alone wasn't enough, since every condition subtype kept its own
 * separate C++ object cache). Fixed by collapsing every sibling's cache into
 * one shared per-family cache (zidl, `dcps_impl.cpp`'s `_familyMutex()`/
 * `_familyCache()`) that GuardCondition also registers into on construction
 * (zzdds's `zzdds_cpp.hpp`, since GuardCondition has no generated
 * `_getOrCreate` of its own) -- confirmed by testing directly against the
 * fixed zzdds, not just reasoned about.
 *
 * After the run completes, delete_datawriter() is called WITHOUT first
 * detaching the writer's StatusCondition from the WaitSet -- deliberately,
 * to demonstrate that this is safe.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Publisher: reader matched", "Publisher: wrote count=", "Publisher:
 * reader disconnected", "Publisher: StatusCondition remained attached
 * through delete_datawriter (safe).", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "waitset_sample.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>

namespace {

constexpr int SAMPLE_COUNT = 10;
constexpr ::DDS::Duration_t WAIT_STEP{1, 0};
constexpr int OVERALL_DEADLINE_MS = 25000;
constexpr int WATCHDOG_POLL_MS = 50;

class Watchdog {
public:
    Watchdog(std::shared_ptr<::DDS::GuardCondition> gc, int deadline_ms)
        : gc_(std::move(gc)), deadline_(std::chrono::steady_clock::now() + std::chrono::milliseconds(deadline_ms)),
          thread_([this] { run(); })
    {}

    Watchdog(const Watchdog&) = delete;
    Watchdog& operator=(const Watchdog&) = delete;

    // Idempotent and safe to skip entirely -- ~Watchdog() calls this too, so
    // every exit path in main() (including an early "FAIL:" return taken
    // before the happy-path call below) still stops and joins the thread
    // instead of destroying it while still joinable, which calls
    // std::terminate().
    void stop_and_join() {
        stop_.store(true);
        if (thread_.joinable()) thread_.join();
    }

    ~Watchdog() { stop_and_join(); }

private:
    void run() {
        while (!stop_.load()) {
            if (std::chrono::steady_clock::now() >= deadline_) {
                std::printf("Watchdog: overall deadline exceeded, triggering GuardCondition\n");
                gc_->set_trigger_value(true);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(WATCHDOG_POLL_MS));
        }
    }

    std::shared_ptr<::DDS::GuardCondition> gc_;
    std::chrono::steady_clock::time_point deadline_;
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

bool condition_active(const ::DDS::ConditionSeq& active, const std::shared_ptr<::DDS::Condition>& c) {
    for (const auto& entry : active) {
        if (entry == c) return true;
    }
    return false;
}

uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) {
            return static_cast<uint32_t>(std::strtoul(argv[i + 1], nullptr, 10));
        }
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    uint32_t domain_id = parse_domain(argc, argv);

    auto factory = zzdds::create_factory();
    if (!factory) {
        std::fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    auto dp = factory->create_participant(domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    if (WaitsetSampleTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("WaitsetSample", "WaitsetSample", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: WaitsetSample\n");

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: WaitsetSample\n");

    // ── WaitSet setup: StatusCondition + GuardCondition together ────────────

    auto ws = zzdds::create_waitset();
    if (!ws) {
        std::fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }

    auto sc = dw->get_statuscondition();
    if (sc->set_enabled_statuses(::DDS::PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_enabled_statuses() failed\n");
        return 1;
    }
    if (ws->attach_condition(sc) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: attach_condition(StatusCondition) failed\n");
        return 1;
    }

    auto gc = zzdds::create_guardcondition();
    if (!gc) {
        std::fprintf(stderr, "FAIL: create_guardcondition() failed\n");
        return 1;
    }
    if (ws->attach_condition(gc) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: attach_condition(GuardCondition) failed\n");
        return 1;
    }

    Watchdog watchdog(gc, OVERALL_DEADLINE_MS);

    // Implicit upcast via shared_ptr's own converting constructor -- real
    // C++ polymorphism, no as_Condition()-style helper needed. `==`-comparable
    // against whatever wait() later returns for the same underlying condition.
    std::shared_ptr<::DDS::Condition> gc_cond = gc;
    std::shared_ptr<::DDS::Condition> sc_cond = sc;

    // ── Wait for a reader to match ───────────────────────────────────────────

    bool matched = false;
    while (!matched) {
        ::DDS::ConditionSeq active;
        auto rc = ws->wait(active, WAIT_STEP);
        if (rc == ::DDS::RETCODE_TIMEOUT) continue;
        if (rc != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", rc);
            return 1;
        }
        if (condition_active(active, gc_cond)) {
            std::fprintf(stderr, "FAIL: watchdog fired before any reader matched\n");
            return 1;
        }
        if (condition_active(active, sc_cond)) {
            ::DDS::PublicationMatchedStatus status{};
            dw->get_publication_matched_status(status);
            if (status.current_count > 0) {
                std::printf("Publisher: reader matched\n");
                matched = true;
            }
        }
    }

    // ── Write samples: priority = count ──────────────────────────────────

    WaitsetSampleDataWriter writer(dw->native_handle());
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        WaitsetSample sample;
        sample.count = i;
        sample.priority = i;
        sample.message = "Hello waitset!";
        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at count=%d\n", i);
            return 1;
        }
        std::printf("Publisher: wrote count=%d priority=%d\n", i, i);
    }

    // ── Wait for the reader to disconnect again ──────────────────────────

    bool disconnected = false;
    while (!disconnected) {
        ::DDS::ConditionSeq active;
        auto rc = ws->wait(active, WAIT_STEP);
        if (rc == ::DDS::RETCODE_TIMEOUT) continue;
        if (rc != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", rc);
            return 1;
        }
        if (condition_active(active, gc_cond)) {
            std::fprintf(stderr, "FAIL: watchdog fired before the reader disconnected\n");
            return 1;
        }
        if (condition_active(active, sc_cond)) {
            ::DDS::PublicationMatchedStatus status{};
            dw->get_publication_matched_status(status);
            if (status.current_count == 0) {
                std::printf("Publisher: reader disconnected\n");
                disconnected = true;
            }
        }
    }

    watchdog.stop_and_join();

    // Well-behaved cleanup for the GuardCondition...
    ws->detach_condition(gc);
    // ...but the StatusCondition is deliberately left attached through
    // delete_datawriter() below, to demonstrate that this is safe.
    std::printf("Publisher: StatusCondition remained attached through delete_datawriter (safe).\n");
    pub->delete_datawriter(dw);

    std::printf("Publisher: done.\n");
    return 0;
}
