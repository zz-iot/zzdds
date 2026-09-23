/*
 * integration-tests/cpp/ignore-entities -- bystander. Direct C++ port of
 * c/ignore-entities/src/bystander.c -- see that file's header comment for
 * the full scenario rationale and docs/design/integration-test-tier.md for
 * the scenario spec.
 *
 * Required stdout markers: "Bystander: ready.", "Bystander: created writer
 * for ParticipantIgnoredTopic.", "Bystander: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "ignore_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 5;
// Set comfortably beyond the harness's own BYSTANDER_IGNORED_TIMEOUT_S (20s,
// ignore_entities_cross_binding_test.py) for confirming that ignore -- a
// shorter delay here could let this writer's SEDP announcement race ahead of
// ignore_participant() even in runs the harness itself still considers
// within budget (found via Greptile review).
constexpr int PRE_WRITER_DELAY_S = 22;
constexpr int POST_WRITE_SETTLE_S = 6;

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
    std::printf("Bystander: ready.\n");
    std::fflush(stdout);

    // Deliberate wall-clock window -- not a race-avoidance hack. Gives the
    // ignorer a comfortable, unambiguous stretch of real time to discover
    // and ignore this participant before the writer below ever announces.
    sleep(PRE_WRITER_DELAY_S);

    if (IgnoreEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("ParticipantIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Bystander: created writer for ParticipantIgnoredTopic.\n");

    IgnoreEventDataWriter writer(dw->native_handle());
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::IgnoreEvent ev;
        ev.seq = seq;
        writer.write(ev);
    }

    // No match-count assertion here -- see this file's header comment (and
    // ignorer.cpp's, for the full explanation). Just gives ignorer.cpp's
    // own settle window (which this overlaps) a comfortable stretch of
    // real time before this process exits and tears its participant down.
    sleep(POST_WRITE_SETTLE_S);

    std::printf("Bystander: done.\n");
    factory->delete_participant(dp);
    return 0;
}
