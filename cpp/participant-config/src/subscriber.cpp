/*
 * cpp/participant-config -- subscriber. Direct C++ port of
 * zig/participant-config/subscriber.zig / c/participant-config/src/subscriber.c;
 * see docs/design/participant-config-reference-app.md at the repo root for
 * the full spec. Same two mutually exclusive modes as the publisher (see
 * publisher.cpp's doc comment).
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: received count=", "Subscriber: received all 3 samples in
 * order." Programmatic mode additionally prints "Config round-trip OK: ...".
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_ping.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int EXPECTED_SAMPLES = 3;
constexpr int RECEIVE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

const char *CONFIG_PARTICIPANT_NAME = "participant-config-example";
constexpr uint16_t CONFIG_FRAGMENT_SIZE = 9000;

struct SubState {
    ConfigPingDataReader *reader = nullptr;
    int32_t expected_next = 0;
    std::atomic<bool> all_received{false};
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        for (;;) {
            ConfigPingDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;

            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }
            if (!sample.info.valid_data) break;

            if (sample.value.count != state_->expected_next) {
                std::fprintf(stderr, "FAIL: expected count=%d but got count=%d\n",
                              state_->expected_next, sample.value.count);
                std::exit(1);
            }

            std::printf("Subscriber: received count=%d\n", sample.value.count);
            state_->expected_next++;

            if (state_->expected_next == EXPECTED_SAMPLES) {
                state_->all_received.store(true);
            }
        }
    }

private:
    SubState *state_;
};

struct Options {
    uint32_t domain_id = 0;
    const char *config_path = nullptr;
};

Options parse_args(int argc, char **argv) {
    Options opts;
    for (int i = 1; i < argc; i++) {
        if ((std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) && i + 1 < argc) {
            opts.domain_id = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
        } else if (std::strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            opts.config_path = argv[++i];
        }
    }
    return opts;
}

} // namespace

int main(int argc, char **argv) {
    Options opts = parse_args(argc, argv);

    if (opts.config_path) {
        auto cfg_rc = zzdds::process_configure_from_file(opts.config_path, nullptr);
        if (cfg_rc != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: failed to load config file '%s' (rc=%d)\n", opts.config_path, static_cast<int>(cfg_rc));
            return 1;
        }
    }

    auto factory = zzdds::create_factory();
    if (!factory) {
        std::fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    std::shared_ptr<::DDS::DomainParticipant> dp;
    if (!opts.config_path) {
        auto cfg = ::zzdds::DomainParticipantConfig::default_value();
        cfg.participant.name = CONFIG_PARTICIPANT_NAME;
        cfg.rtps.fragment_size = CONFIG_FRAGMENT_SIZE;

        if (factory->set_default_participant_config(cfg) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: set_default_participant_config() failed\n");
            return 1;
        }

        auto readback = ::zzdds::DomainParticipantConfig::default_value();
        if (factory->get_default_participant_config(readback) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_default_participant_config() failed\n");
            return 1;
        }

        if (readback.participant.name != CONFIG_PARTICIPANT_NAME) {
            std::fprintf(stderr, "FAIL: participant.name round-trip mismatch: expected '%s', got '%s'\n",
                         CONFIG_PARTICIPANT_NAME, readback.participant.name.c_str());
            return 1;
        }
        if (readback.rtps.fragment_size != CONFIG_FRAGMENT_SIZE) {
            std::fprintf(stderr, "FAIL: rtps.fragment_size round-trip mismatch: expected %u, got %u\n",
                         static_cast<unsigned>(CONFIG_FRAGMENT_SIZE), static_cast<unsigned>(readback.rtps.fragment_size));
            return 1;
        }
        std::printf("Config round-trip OK: participant.name='%s' rtps.fragment_size=%u\n",
                    readback.participant.name.c_str(), static_cast<unsigned>(readback.rtps.fragment_size));

        dp = factory->create_participant_ex(opts.domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0, cfg);
    } else {
        dp = factory->create_participant(opts.domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    }
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", opts.domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    if (ConfigPingTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("ConfigPing", "ConfigPing", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: ConfigPing\n");

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
    // can race state.reader's own initialization below. Attach the
    // listener only once state.reader is set, via set_listener() below,
    // closing the window entirely.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: ConfigPing\n");

    auto dr_handle = dr->native_handle();
    ConfigPingDataReader reader(dr_handle);
    state.reader = &reader;

    if (dr->set_listener(listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    std::printf("Subscriber: waiting for %d samples...\n", EXPECTED_SAMPLES);
    for (int waited_ms = 0; !state.all_received.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                          state.expected_next, EXPECTED_SAMPLES, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    sub->delete_datareader(dr);

    std::printf("Subscriber: received all %d samples in order.\n", EXPECTED_SAMPLES);
    return 0;
}
