/*
 * integration-tests/c/wait-for-historical-data -- publisher. Writes a
 * historical batch immediately, with no reader matched yet, then -- once a
 * reader does match -- writes a live batch. TRANSIENT_LOCAL durability means
 * zzdds's own writer-side cache (not this app) is what makes the historical
 * batch replayable to a late joiner. Direct C analogue of
 * examples/c/catchup/src/publisher.c; see docs/design/integration-test-tier.md
 * for the full scenario spec and subscriber.c for the harder correctness bar
 * this scenario adds over the plain catchup example.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Publisher: wrote historical seq_num=", "Publisher: reader matched,
 * writing live batch", "Publisher: wrote live seq_num=", "Publisher: done."
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "history_event.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define HISTORICAL_COUNT 8
#define LIVE_COUNT 4
#define MATCH_TIMEOUT_MS 20000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_bool ever_matched;
    atomic_int matched_current_count;
} PubState;

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    PubState *state = (PubState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
    if (status->current_count > 0) atomic_store(&state->ever_matched, true);
    printf("on_publication_matched() current_count=%d\n", status->current_count);
}

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

    if (HistoryEventTypeSupport_register(dp, "HistoryEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "HistoryEvent", "HistoryEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: HistoryEvent\n");

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = DDS_DurabilityQosPolicyKind_TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Create writer for topic: HistoryEvent\n");

    PubState state;
    atomic_init(&state.ever_matched, false);
    atomic_init(&state.matched_current_count, 0);

    DDS_DataWriterListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_publication_matched = on_publication_matched;
    if (DDS_DataWriter_set_listener(dw, &listener, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    HistoryEventDataWriter writer;
    HistoryEventDataWriter_init(&writer, dw, ZIDL_XCDR1);

    /* -- Historical batch: written immediately, no reader matched yet. -- */
    int seq = 0;
    for (; seq < HISTORICAL_COUNT; seq++) {
        HistoryEvent sample;
        memset(&sample, 0, sizeof(sample));
        sample.seq_num = seq;
        if (HistoryEventDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at seq_num=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote historical seq_num=%d\n", seq);
    }

    /* -- Verify the batch above was genuinely historical: the subscriber and
     * its reader already exist by the time this process starts (see the
     * harness), so nothing here actually stops discovery from completing
     * fast enough to match before this fast, unthrottled write loop
     * finishes -- which would silently turn some or all of it into ordinary
     * live delivery instead of exercising TRANSIENT_LOCAL replay, without
     * the subscriber's sequence-number-only check ever noticing (found via
     * Greptile review). Assert unmatched here instead of just assuming it,
     * so a race like that fails loudly instead of silently validating
     * nothing. -- */
    if (atomic_load(&state.matched_current_count) != 0) {
        fprintf(stderr, "FAIL: reader matched before the historical batch finished writing -- not exercising late-join replay\n");
        return 1;
    }

    /* -- Wait for the late-joining reader to match. -- */
    for (int waited_ms = 0; !atomic_load(&state.ever_matched); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reader matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Publisher: reader matched, writing live batch\n");

    /* -- Live batch. -- */
    for (; seq < HISTORICAL_COUNT + LIVE_COUNT; seq++) {
        HistoryEvent sample;
        memset(&sample, 0, sizeof(sample));
        sample.seq_num = seq;
        if (HistoryEventDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at seq_num=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote live seq_num=%d\n", seq);
    }

    for (int waited_ms = 0;
         !(atomic_load(&state.ever_matched) && atomic_load(&state.matched_current_count) == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Publisher: done.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
