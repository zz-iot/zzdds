/*
 * cpp/waitset -- subscriber. Direct C++ port of zig/waitset/subscriber.zig;
 * see docs/design/waitset-reference-app.md at the repo root for the full
 * spec.
 *
 * One WaitSet, four conditions attached simultaneously:
 *
 *   - StatusCondition (SUBSCRIPTION_MATCHED_STATUS) -- logs the match.
 *   - QueryCondition ("priority > %0", param "4") -- real attach/trigger/
 *     query-expression/parameters exercise. Drained via the generated
 *     WaitsetSampleDataReader::take_w_condition (what the OMG spec calls
 *     take_w_condition, and part of the typed DataReader's implicit IDL on
 *     every binding -- see zidl's roadmap for the fuller writeup on closing
 *     this gap).
 *   - ReadCondition (any sample/view/instance state) -- same trigger
 *     condition as QueryCondition above; both together just mean "there is
 *     data," and either one triggering drains everything pending.
 *   - GuardCondition -- same watchdog-thread pattern as the publisher.
 *
 * Like publisher.cpp, branches on membership in wait()'s returned
 * ConditionSeq -- see that file's comment for the full reasoning.
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: writer matched", "Subscriber: high-priority count=",
 * "Subscriber: low-priority count=", "Subscriber: received all 10
 * samples.", "Subscriber: done." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
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
#include <vector>

namespace {

constexpr int EXPECTED_SAMPLES = 10;
constexpr const char* HIGH_PRIORITY_THRESHOLD = "4"; // priority > 4 => count 5..9
constexpr ::DDS::Duration_t WAIT_STEP{1, 0};
constexpr int OVERALL_DEADLINE_MS = 30000;
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

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    // See publisher.cpp's comment: create_topic() constructs
    // zzdds::detail::TopicSupport under the hood, so this upcast is real.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: WaitsetSample\n");

    // ── WaitSet setup: all four condition types on one WaitSet ──────────────

    auto ws = zzdds::create_waitset();
    if (!ws) {
        std::fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }

    auto sc = dr->get_statuscondition();
    if (sc->set_enabled_statuses(::DDS::SUBSCRIPTION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_enabled_statuses() failed\n");
        return 1;
    }

    auto rc_cond = dr->create_readcondition(::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
    if (!rc_cond) {
        std::fprintf(stderr, "FAIL: create_readcondition() failed\n");
        return 1;
    }

    auto qc_cond = dr->create_querycondition(
        ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE,
        "priority > %0", ::DDS::StringSeq{HIGH_PRIORITY_THRESHOLD});
    if (!qc_cond) {
        std::fprintf(stderr, "FAIL: create_querycondition() failed\n");
        return 1;
    }

    auto gc = zzdds::create_guardcondition();
    if (!gc) {
        std::fprintf(stderr, "FAIL: create_guardcondition() failed\n");
        return 1;
    }

    if (ws->attach_condition(sc) != ::DDS::RETCODE_OK ||
        ws->attach_condition(rc_cond) != ::DDS::RETCODE_OK ||
        ws->attach_condition(qc_cond) != ::DDS::RETCODE_OK ||
        ws->attach_condition(gc) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: attach_condition() failed\n");
        return 1;
    }

    // WaitSet.get_conditions() -- all four attached conditions, regardless
    // of trigger state, distinct from wait()'s own out-param (only the ones
    // that triggered *this* call). Otherwise unexercised anywhere in this
    // project; a real assertion here (not just a call) is nearly free given
    // this WaitSet's attached set is already known exactly.
    {
        ::DDS::ConditionSeq attached;
        if (ws->get_conditions(attached) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: WaitSet::get_conditions() failed\n");
            return 1;
        }
        if (attached.size() != 4) {
            std::fprintf(stderr, "FAIL: WaitSet::get_conditions() returned %zu conditions, expected 4\n", attached.size());
            return 1;
        }
    }

    Watchdog watchdog(gc, OVERALL_DEADLINE_MS);

    // Implicit upcasts via shared_ptr's own converting constructor -- real
    // C++ polymorphism, no as_Condition()-style helper needed. Each is
    // `==`-comparable against whatever wait() later returns for the same
    // underlying condition.
    std::shared_ptr<::DDS::Condition> sc_cond = sc;
    std::shared_ptr<::DDS::Condition> rc_as_cond = rc_cond;
    std::shared_ptr<::DDS::Condition> qc_as_cond = qc_cond;
    std::shared_ptr<::DDS::Condition> gc_cond = gc;

    // ── Main loop: wait, branch on which conditions triggered ───────────────

    WaitsetSampleDataReader reader(dr->native_handle());
    int received = 0;
    bool matched_logged = false;
    while (received < EXPECTED_SAMPLES) {
        ::DDS::ConditionSeq active;
        auto wr = ws->wait(active, WAIT_STEP);
        if (wr == ::DDS::RETCODE_TIMEOUT) continue;
        if (wr != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", wr);
            return 1;
        }
        if (condition_active(active, gc_cond)) {
            std::fprintf(stderr, "FAIL: watchdog fired -- only received %d/%d samples\n", received, EXPECTED_SAMPLES);
            return 1;
        }
        if (!matched_logged && condition_active(active, sc_cond)) {
            ::DDS::SubscriptionMatchedStatus status{};
            dr->get_subscription_matched_status(status);
            if (status.current_count > 0) {
                std::printf("Subscriber: writer matched\n");
                matched_logged = true;
            }
        }

        bool query_triggered = condition_active(active, qc_as_cond);
        bool read_triggered = condition_active(active, rc_as_cond);
        if (!query_triggered && !read_triggered) continue;

        // Drain the high-priority subset first via take_w_condition, then
        // whatever's left via a plain take_n. These are two separate calls,
        // each independently locking/unlocking the reader -- a sample can
        // arrive (from the RTPS receive thread) in the gap between them,
        // missing the first (query) take and getting swept up by the
        // second (unfiltered) one. Confirmed as a real, reproducible race
        // in zig/waitset (not just in theory): a high-priority sample
        // occasionally printed as "low-priority" (still correctly
        // *received*, just mislabeled) despite take_w_condition's own
        // filtering being correct at the instant it ran. So: still call
        // both -- take_w_condition is still genuinely exercised, and still
        // does the real draining -- but decide the *label* from each
        // sample's own already-deserialized `priority` field rather than
        // trusting which call it came from.
        std::vector<WaitsetSample> high_values(EXPECTED_SAMPLES);
        std::vector<zzdds_sample_info> high_infos(EXPECTED_SAMPLES);
        int n_high = reader.take_w_condition(
            DDS_QueryCondition_as_DDS_ReadCondition(qc_cond->native_handle()),
            high_values.data(), high_infos.data(), EXPECTED_SAMPLES);

        std::vector<WaitsetSample> low_values(EXPECTED_SAMPLES);
        std::vector<zzdds_sample_info> low_infos(EXPECTED_SAMPLES);
        int n_low = reader.take_n(low_values.data(), low_infos.data(), EXPECTED_SAMPLES,
                                   ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);

        for (int i = 0; i < n_high; i++) {
            if (!high_infos[i].valid_data) continue;
            if (high_values[i].priority > 4) {
                std::printf("Subscriber: high-priority count=%d priority=%d\n", high_values[i].count, high_values[i].priority);
            } else {
                std::printf("Subscriber: low-priority count=%d priority=%d\n", high_values[i].count, high_values[i].priority);
            }
            received++;
        }
        for (int i = 0; i < n_low; i++) {
            if (!low_infos[i].valid_data) continue;
            if (low_values[i].priority > 4) {
                std::printf("Subscriber: high-priority count=%d priority=%d\n", low_values[i].count, low_values[i].priority);
            } else {
                std::printf("Subscriber: low-priority count=%d priority=%d\n", low_values[i].count, low_values[i].priority);
            }
            received++;
        }
    }

    std::printf("Subscriber: received all %d samples.\n", EXPECTED_SAMPLES);

    watchdog.stop_and_join();

    // Well-behaved cleanup: detach and delete every condition explicitly
    // before tearing the reader down (contrast with publisher.cpp, which
    // deliberately does *not* do this for its StatusCondition).
    ws->detach_condition(sc);
    ws->detach_condition(rc_cond);
    ws->detach_condition(qc_cond);
    ws->detach_condition(gc);
    dr->delete_readcondition(rc_cond);
    dr->delete_readcondition(qc_cond);
    sub->delete_datareader(dr);

    std::printf("Subscriber: done.\n");
    return 0;
}
