/*
 * cpp/registry -- subscriber. Direct C++ port of
 * zig/registry/subscriber.zig; see docs/design/registry-reference-app.md at
 * the repo root for the full spec. Tracks each of the publisher's three
 * instances' observed SampleInfo.instance_state sequence (fail fast on an
 * unexpected transition), and once all three have reached their expected
 * outcome, calls lookup_instance() to confirm the key-to-handle direction
 * matches what the publisher's own samples for that instance carried.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: sensor_id=... instance_state=...",
 * "Subscriber: lookup_instance round-trip OK for sensor_id=",
 * "Subscriber: all three instance lifecycles observed correctly." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "registry_sample.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int RECEIVE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

const char *state_name(DDS_InstanceStateKind s) {
    switch (s) {
        case DDS_ALIVE_INSTANCE_STATE: return "ALIVE";
        case DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE: return "NOT_ALIVE_DISPOSED";
        case DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE: return "NOT_ALIVE_NO_WRITERS";
        default: return "UNKNOWN";
    }
}

struct InstanceTrack {
    int32_t sensor_id;
    bool seen_alive = false;
    bool reached_terminal = false;
    DDS_InstanceHandle_t handle = 0;
};

struct SubState {
    SensorReadingDataReader *reader = nullptr;
    // Only ever touched from the listener's dispatch thread.
    InstanceTrack tracks[3] = { {1}, {2}, {3} };
    std::atomic<bool> all_done{false};
};

InstanceTrack *track_for(SubState *state, int32_t sensor_id) {
    for (auto &t : state->tracks) {
        if (t.sensor_id == sensor_id) return &t;
    }
    std::fprintf(stderr, "FAIL: unexpected sensor_id=%d\n", sensor_id);
    std::exit(1);
}

bool all_instances_done(SubState *state) {
    for (auto &t : state->tracks) {
        if (!t.reached_terminal) return false;
    }
    return true;
}

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        // Deferred, not stored directly inside the loop below: main()
        // deletes the reader as soon as it observes state_->all_done, so
        // storing it mid-loop would let main()'s delete_datareader() race
        // this same invocation's next take() call. Only commit the flag
        // once this invocation's take loop has fully drained and won't
        // touch the reader again.
        bool became_done = false;

        for (;;) {
            SensorReadingDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;

            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }

            InstanceTrack *track = track_for(state_, sample.value.sensor_id);
            std::printf("Subscriber: sensor_id=%d instance_state=%s\n", sample.value.sensor_id, state_name(sample.info.instance_state));
            track->handle = sample.info.instance_handle;

            switch (sample.info.instance_state) {
                case DDS_ALIVE_INSTANCE_STATE:
                    track->seen_alive = true;
                    if (track->sensor_id == 3) track->reached_terminal = true;
                    break;
                case DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE:
                    if (track->sensor_id != 1) {
                        std::fprintf(stderr, "FAIL: unexpected NOT_ALIVE_DISPOSED for sensor_id=%d\n", track->sensor_id);
                        std::exit(1);
                    }
                    if (!track->seen_alive) {
                        std::fprintf(stderr, "FAIL: sensor_id=1 reached NOT_ALIVE_DISPOSED without ever being ALIVE\n");
                        std::exit(1);
                    }
                    track->reached_terminal = true;
                    break;
                case DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE:
                    if (track->sensor_id != 2) {
                        std::fprintf(stderr, "FAIL: unexpected NOT_ALIVE_NO_WRITERS for sensor_id=%d\n", track->sensor_id);
                        std::exit(1);
                    }
                    if (!track->seen_alive) {
                        std::fprintf(stderr, "FAIL: sensor_id=2 reached NOT_ALIVE_NO_WRITERS without ever being ALIVE\n");
                        std::exit(1);
                    }
                    track->reached_terminal = true;
                    break;
                default:
                    std::fprintf(stderr, "FAIL: unknown instance_state=%u for sensor_id=%d\n", sample.info.instance_state, track->sensor_id);
                    std::exit(1);
            }

            if (all_instances_done(state_) && !state_->all_done.load() && !became_done) {
                InstanceTrack *c_track = track_for(state_, 3);
                ::SensorReading query;
                query.sensor_id = 3;
                query.value = 0;
                DDS_InstanceHandle_t looked_up = state_->reader->lookup_instance(query);
                if (looked_up == 0 || looked_up != c_track->handle) {
                    std::fprintf(stderr, "FAIL: lookup_instance() round-trip mismatch for sensor_id=3\n");
                    std::exit(1);
                }
                std::printf("Subscriber: lookup_instance round-trip OK for sensor_id=3\n");
                became_done = true;
            }
        }

        if (became_done) {
            state_->all_done.store(true);
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

    if (SensorReadingTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("SensorReading", "SensorReading", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: SensorReading\n");

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    SubState state;
    auto listener = std::make_shared<SubListener>(&state);

    // Create with no listener attached yet: on_data_available fires on a
    // zzdds-internal dispatch thread as soon as the reader matches, which
    // can race state.reader's own initialization below. Attach the listener
    // only once state.reader is set, via set_listener() below, closing the
    // window entirely.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SensorReading\n");

    auto dr_handle = dr->native_handle();
    SensorReadingDataReader reader(dr_handle);
    state.reader = &reader;

    if (dr->set_listener(listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    std::printf("Subscriber: waiting for all three instance lifecycles...\n");
    for (int waited_ms = 0; !state.all_done.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: did not observe all three instance lifecycles within %ds\n", RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    sub->delete_datareader(dr);

    std::printf("Subscriber: all three instance lifecycles observed correctly.\n");
    return 0;
}
