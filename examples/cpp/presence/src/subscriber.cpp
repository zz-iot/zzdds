/*
 * cpp/presence -- subscriber. Direct C++ port of zig/presence/subscriber.zig;
 * see docs/design/presence-reference-app.md at the repo root for the full
 * spec. Demonstrates DataReaderListener::on_liveliness_changed: observes the
 * writer's lease expiring (OFFLINE) and later recovering (ONLINE) after an
 * explicit assert_liveliness() call, and asserts the full cycle was seen in
 * order.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "ONLINE alive_count=", "OFFLINE alive_count=",
 * "Subscriber: observed full online -> offline -> online cycle." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "presence_sample.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int CYCLE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

enum class Phase { waiting_first_online, waiting_offline, waiting_second_online, done };

struct SubState {
    PresenceBeaconDataReader *reader = nullptr;
    // Only ever touched from the listener's dispatch thread.
    Phase phase = Phase::waiting_first_online;
    std::atomic<int> step{0};
    std::atomic<bool> cycle_complete{false};
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_liveliness_changed(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                                ::DDS::LivelinessChangedStatus status) override {
        bool online = status.alive_count > 0;
        if (online) {
            std::printf("ONLINE alive_count=%d not_alive_count=%d\n", status.alive_count, status.not_alive_count);
        } else {
            std::printf("OFFLINE alive_count=%d not_alive_count=%d\n", status.alive_count, status.not_alive_count);
        }

        switch (state_->phase) {
        case Phase::waiting_first_online:
            if (online) {
                state_->phase = Phase::waiting_offline;
                state_->step.store(1);
            }
            break;
        case Phase::waiting_offline:
            if (!online) {
                state_->phase = Phase::waiting_second_online;
                state_->step.store(2);
            }
            break;
        case Phase::waiting_second_online:
            if (online) {
                state_->phase = Phase::done;
                state_->step.store(3);
                state_->cycle_complete.store(true);
            }
            break;
        case Phase::done:
            break;
        }
    }

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        for (;;) {
            PresenceBeaconDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;

            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }
            if (!sample.info.valid_data) continue;

            std::printf("Subscriber: received sequence=%d\n", sample.value.seq_num);
        }
    }

private:
    SubState *state_;
};

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

    if (PresenceBeaconTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("PresenceBeacon", "PresenceBeacon", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: PresenceBeacon\n");

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_LAST_HISTORY_QOS;
    dr_qos.history.depth = 1;
    dr_qos.liveliness.kind = ::DDS::LivelinessQosPolicyKind::MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dr_qos.liveliness.lease_duration.sec = 2;
    dr_qos.liveliness.lease_duration.nanosec = 0;

    SubState state;
    auto listener = std::make_shared<SubListener>(&state);

    // Create with no listener attached yet: on_data_available/
    // on_liveliness_changed fire on a zzdds-internal dispatch thread as soon
    // as the reader matches, which can race state.reader's own
    // initialization below. Attach the listener only once state.reader is
    // set, via set_listener() below, closing the window entirely.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: PresenceBeacon\n");

    auto dr_handle = dr->native_handle();
    PresenceBeaconDataReader reader(dr_handle);
    state.reader = &reader;

    if (dr->set_listener(listener, DDS_DATA_AVAILABLE_STATUS | DDS_LIVELINESS_CHANGED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    std::printf("Subscriber: waiting for online -> offline -> online cycle...\n");
    for (int waited_ms = 0; !state.cycle_complete.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= CYCLE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: did not observe the full cycle within %ds (stuck at step=%d)\n",
                          CYCLE_TIMEOUT_MS / 1000, state.step.load());
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    sub->delete_datareader(dr);

    std::printf("Subscriber: observed full online -> offline -> online cycle.\n");
    return 0;
}
