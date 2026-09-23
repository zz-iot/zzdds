/*
 * integration-tests/c/ignore-entities -- bystander. A deliberately
 * throwaway third participant, used only to demonstrate
 * ignore_participant()'s participant-wide scope: unlike the other three
 * ignore_*() operations (which target one specific topic/publication/
 * subscription and share `peer`'s otherwise-normal participant for their
 * control-topic sanity check), ignoring a participant would blackhole
 * EVERYTHING from that participant -- so it needs its own dedicated,
 * single-purpose participant to ignore, distinct from `peer`. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * Deliberately delays creating its writer (PRE_WRITER_DELAY_S) after its
 * participant exists -- a wide, comfortable window (same convention as
 * enable-defer's PRE_ENABLE_DELAY) for the ignorer to discover and ignore
 * this participant before the writer's SEDP announcement can ever reach
 * it. Set comfortably beyond the harness's own
 * BYSTANDER_IGNORED_TIMEOUT_S (20s, ignore_entities_cross_binding_test.py)
 * for confirming that ignore -- a shorter delay here could let this
 * writer's SEDP announcement race ahead of ignore_participant() even in
 * runs the harness itself still considers within budget (found via
 * Greptile review).
 *
 * IMPORTANT: this process's own match-count is NOT expected to be zero,
 * and this file does not assert that it is. ignore_participant() is called
 * on the *ignorer's* participant only -- exactly like ignore_topic()/
 * ignore_publication()/ignore_subscription(), it is a strictly one-sided,
 * local filter (see ignorer.c's header comment for the full explanation).
 * This process has no idea it has been ignored, so its own SEDP discovery
 * of the ignorer's ParticipantIgnoredTopic reader proceeds completely
 * normally and this writer legitimately reports itself matched. The real,
 * meaningful assertion -- that the ignorer's own reader never actually
 * receives any of this writer's samples -- is checked entirely from
 * ignorer.c's side, which is the only side with anything to verify. This
 * process's job is just to exist, delay, write, and exit cleanly; a hang
 * here would be the wrong failure mode.
 *
 * Required stdout markers: "Bystander: ready.", "Bystander: created writer
 * for ParticipantIgnoredTopic.", "Bystander: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "ignore_event.h"
#include "zzdds_c.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_COUNT 5
#define PRE_WRITER_DELAY_S 22
#define POST_WRITE_SETTLE_S 6

static uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) {
            return (uint32_t)strtoul(argv[i + 1], NULL, 10);
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    uint32_t domain_id = parse_domain(argc, argv);

    zzdds_DomainParticipantFactory factory = zzdds_create_factory();
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, domain_id, NULL, NULL, 0);
    if (!dp) {
        fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }
    printf("Bystander: ready.\n");
    fflush(stdout);

    /* Deliberate wall-clock window -- not a race-avoidance hack. Gives the
     * ignorer a comfortable, unambiguous stretch of real time to discover
     * and ignore this participant before the writer below ever announces. */
    sleep(PRE_WRITER_DELAY_S);

    if (IgnoreEventTypeSupport_register(dp, "IgnoreEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "ParticipantIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Bystander: created writer for ParticipantIgnoredTopic.\n");

    IgnoreEventDataWriter writer;
    IgnoreEventDataWriter_init(&writer, dw, ZIDL_XCDR1);
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        IgnoreEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        IgnoreEventDataWriter_write(&writer, &ev, DDS_HANDLE_NIL);
    }

    /* No match-count assertion here -- see this file's header comment.
     * Just gives ignorer.c's own settle window (which this overlaps) a
     * comfortable stretch of real time before this process exits and tears
     * its participant down. */
    sleep(POST_WRITE_SETTLE_S);

    printf("Bystander: done.\n");
    DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    zzdds_destroy_factory(factory);
    return 0;
}
