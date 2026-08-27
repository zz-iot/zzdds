/*
 * cpp/participant-config -- publisher. Direct C++ port of
 * zig/participant-config/publisher.zig / c/participant-config/src/publisher.c;
 * see docs/design/participant-config-reference-app.md at the repo root for
 * the full spec.
 *
 * Two mutually exclusive modes (see c/participant-config's publisher.c for
 * the full description): programmatic (default) round-trips a
 * zzdds::DomainParticipantConfig value through
 * set_default_participant_config/get_default_participant_config before
 * creating the participant via create_participant_ex; file mode
 * (--config <path>) loads a zzdds.toml-style file instead. Both then run
 * the same minimal reliable write loop (3 samples) as hello_world.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "on_reliable_reader_ready", "Publisher: wrote count=", "Publisher: done."
 * Programmatic mode additionally prints "Config round-trip OK: ...". Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
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

constexpr int SAMPLE_COUNT = 3;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

// Distinctive values for the programmatic round-trip check -- one plain
// string field, one scalar field in an all-primitive nested struct, so a
// mismatch in either is unambiguous about which kind of field broke.
const char *CONFIG_PARTICIPANT_NAME = "participant-config-example";
constexpr uint16_t CONFIG_FRAGMENT_SIZE = 9000;

struct PubState {
    std::atomic<bool> reader_ready{false};
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
};

class PubListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit PubListener(PubState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
        std::printf("on_publication_matched() current_count=%d\n", status.current_count);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
        std::printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
    }

private:
    PubState *state_;
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
        // Programmatic mode.
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
    std::printf("Create writer for topic: ConfigPing\n");

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    auto dw_handle = dw->native_handle();
    ConfigPingDataWriter writer(dw_handle);

    for (int waited_ms = 0; !state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        ::ConfigPing sample;
        sample.count = i;

        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at count=%d\n", i);
            return 1;
        }
        std::printf("Publisher: wrote count=%d\n", i);
    }

    for (int waited_ms = 0;
         !(state.ever_matched.load() && state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Publisher: done.\n");
    return 0;
}
