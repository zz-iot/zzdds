/*
 * c/discovery -- subscriber. Direct C port of zig/discovery/subscriber.zig;
 * see docs/design/discovery-reference-app.md at the repo root for the full
 * spec.
 *
 * Waits for a matched publication (polling DDS_DataReader_get_matched_
 * publications, bounded by a timeout), then calls DDS_DataReader_get_
 * matched_publication_data to look up the matched writer's own topic/type
 * name. Then runs the same minimal reliable read loop (3 samples) as
 * hello_world/participant-config.
 *
 * Unlike zig/discovery (a pure-Zig call, borrowed strings, nothing to
 * free), this crosses the C ABI: get_matched_publication_data always hands
 * back a fresh, caller-owned copy, freed via DDS_PublicationBuiltinTopicData_free().
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Discovery OK (reader):", "Subscriber: received count=", "Subscriber:
 * received all 3 samples in order." Any failure path prints a line
 * starting "FAIL:" and exits nonzero.
 */
#include "discovery_ping.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPECTED_SAMPLES 3
#define MATCH_TIMEOUT_MS 10000
#define RECEIVE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

#define TOPIC_NAME "DiscoveryPing"
#define TYPE_NAME "DiscoveryPing"

typedef struct {
    DiscoveryPingDataReader *reader;
    int32_t expected_next;
    atomic_bool all_received;
} SubState;

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;

    for (;;) {
        DiscoveryPing value;
        zzdds_sample_info info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;

        int rc = DiscoveryPingDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }
        if (!info.valid_data) break;

        if (value.count != state->expected_next) {
            fprintf(stderr, "FAIL: expected count=%d but got count=%d\n", state->expected_next, value.count);
            exit(1);
        }

        printf("Subscriber: received count=%d\n", value.count);
        state->expected_next++;

        if (state->expected_next == EXPECTED_SAMPLES) {
            atomic_store(&state->all_received, true);
        }
    }
}

typedef struct {
    uint32_t domain_id;
} Options;

static Options parse_args(int argc, char **argv) {
    Options opts;
    memset(&opts, 0, sizeof(opts));
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) && i + 1 < argc) {
            opts.domain_id = (uint32_t)strtoul(argv[++i], NULL, 10);
        }
    }
    return opts;
}

int main(int argc, char **argv) {
    Options opts = parse_args(argc, argv);

    zzdds_DomainParticipantFactory factory = zzdds_create_factory();
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, opts.domain_id, NULL, NULL, 0);
    if (!dp) {
        fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", opts.domain_id);
        return 1;
    }

    if (zzdds_register_type_support(dp, TOPIC_NAME, DiscoveryPing_compute_key_hash_from_cdr, DiscoveryPing_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, TOPIC_NAME, TYPE_NAME, NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: %s\n", TOPIC_NAME);

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    SubState state;
    state.reader = NULL;
    state.expected_next = 0;
    atomic_init(&state.all_received, false);

    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_data_available = on_data_available;

    /* Create with no listener attached yet: on_data_available fires on a
     * zzdds-internal dispatch thread as soon as the reader matches, which
     * can race state.reader's own initialization below. Attach the
     * listener only once state.reader is set, via set_listener() below,
     * closing the window entirely. */
    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: %s\n", TOPIC_NAME);

    DiscoveryPingDataReader reader;
    DiscoveryPingDataReader_init(&reader, dr);
    state.reader = &reader;

    if (DDS_DataReader_set_listener(dr, &listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    /* Reader-level discovery: wait for the remote publisher to match. */
    DDS_InstanceHandleSeq pub_handles;
    memset(&pub_handles, 0, sizeof(pub_handles));
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (DDS_DataReader_get_matched_publications(dr, &pub_handles) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_matched_publications() failed\n");
            return 1;
        }
        if (pub_handles._length > 0) break;
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no matched publication within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    DDS_PublicationBuiltinTopicData pub_data;
    DDS_PublicationBuiltinTopicData_default(&pub_data);
    if (DDS_DataReader_get_matched_publication_data(dr, &pub_data, pub_handles._buffer[0]) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_matched_publication_data() failed\n");
        return 1;
    }
    DDS_InstanceHandleSeq_free(&pub_handles);
    if (!pub_data.topic_name || strcmp(pub_data.topic_name, TOPIC_NAME) != 0 ||
        !pub_data.type_name || strcmp(pub_data.type_name, TYPE_NAME) != 0) {
        fprintf(stderr, "FAIL: matched publication topic_name/type_name mismatch: got '%s'/'%s'\n",
                pub_data.topic_name ? pub_data.topic_name : "(null)",
                pub_data.type_name ? pub_data.type_name : "(null)");
        return 1;
    }
    printf("Discovery OK (reader): matched_publication.topic_name='%s' type_name='%s'\n", pub_data.topic_name, pub_data.type_name);
    DDS_PublicationBuiltinTopicData_free(&pub_data);

    printf("Subscriber: waiting for %d samples...\n", EXPECTED_SAMPLES);
    for (int waited_ms = 0; !atomic_load(&state.all_received); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                    state.expected_next, EXPECTED_SAMPLES, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    DDS_Subscriber_delete_datareader(sub, dr);

    printf("Subscriber: received all %d samples in order.\n", EXPECTED_SAMPLES);
    zzdds_destroy_factory(factory);
    return 0;
}
