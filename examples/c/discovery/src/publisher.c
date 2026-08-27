/*
 * c/discovery -- publisher. Direct C port of zig/discovery/publisher.zig;
 * see docs/design/discovery-reference-app.md at the repo root for the full
 * spec.
 *
 * After creating its topic, calls DDS_DomainParticipant_get_discovered_
 * topics/_topic_data -- these succeed immediately, even before any remote
 * peer appears (a participant registers its own locally-created topics
 * right away). Once a reliable reader is ready (proving cross-process
 * match happened), calls DDS_DataWriter_get_matched_subscriptions/
 * _subscription_data to look up the matched subscriber's own topic/type
 * name. Then runs the same minimal reliable write loop (3 samples) as
 * hello_world/participant-config.
 *
 * Unlike zig/discovery (a pure-Zig call, borrowed strings, nothing to
 * free), this crosses the C ABI: get_discovered_topic_data/get_matched_
 * subscription_data always hand back a fresh, caller-owned copy (the C-ABI
 * mirror conversion allocates unconditionally) -- both are freed via their
 * own DDS_*BuiltinTopicData_free().
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Discovery OK (participant):", "on_reliable_reader_ready", "Discovery OK
 * (writer):", "Publisher: wrote count=", "Publisher: done." Any failure
 * path prints a line starting "FAIL:" and exits nonzero.
 */
#include "discovery_ping.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_COUNT 3
#define READER_READY_TIMEOUT_MS 10000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

#define TOPIC_NAME "DiscoveryPing"
#define TYPE_NAME "DiscoveryPing"

typedef struct {
    atomic_bool reader_ready;
    atomic_bool ever_matched;
    atomic_int matched_current_count;
} PubState;

static void on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void *listener_data) {
    (void)reader_handle;
    PubState *state = (PubState *)listener_data;
    if (is_ready) atomic_store(&state->reader_ready, true);
    printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
}

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    PubState *state = (PubState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
    if (status->current_count > 0) atomic_store(&state->ever_matched, true);
    printf("on_publication_matched() current_count=%d\n", status->current_count);
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

    /* Participant-level discovery: a freshly-created local topic is
     * immediately visible, no cross-process wait needed. */
    {
        DDS_InstanceHandleSeq handles;
        memset(&handles, 0, sizeof(handles));
        if (DDS_DomainParticipant_get_discovered_topics(dp, &handles) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_discovered_topics() failed\n");
            return 1;
        }
        bool found = false;
        DDS_TopicBuiltinTopicData topic_data;
        DDS_TopicBuiltinTopicData_default(&topic_data);
        /* get_discovered_topic_data's own C-ABI wrapper frees the caller's
         * prior topic_data content before writing new content each call
         * (same "free old, write new" contract as get_default_participant_
         * config -- see participant-config's design doc), so no manual
         * free/reset is needed between iterations here. */
        for (uint32_t i = 0; i < handles._length; i++) {
            if (DDS_DomainParticipant_get_discovered_topic_data(dp, &topic_data, handles._buffer[i]) != DDS_RETCODE_OK) continue;
            if (topic_data.name && strcmp(topic_data.name, TOPIC_NAME) == 0) {
                found = true;
                break;
            }
        }
        DDS_InstanceHandleSeq_free(&handles);
        if (!found) {
            fprintf(stderr, "FAIL: get_discovered_topic_data() never returned '%s'\n", TOPIC_NAME);
            return 1;
        }
        if (!topic_data.type_name || strcmp(topic_data.type_name, TYPE_NAME) != 0) {
            fprintf(stderr, "FAIL: discovered topic type_name mismatch: expected '%s', got '%s'\n",
                    TYPE_NAME, topic_data.type_name ? topic_data.type_name : "(null)");
            return 1;
        }
        printf("Discovery OK (participant): topic.name='%s' topic.type_name='%s'\n", topic_data.name, topic_data.type_name);
        DDS_TopicBuiltinTopicData_free(&topic_data);
    }

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Create writer for topic: %s\n", TOPIC_NAME);

    PubState state;
    atomic_init(&state.reader_ready, false);
    atomic_init(&state.ever_matched, false);
    atomic_init(&state.matched_current_count, 0);

    zzdds_DataWriter zdw = DDS_DataWriter_as_zzdds_DataWriter(dw);
    zzdds_DataWriterListenerEx listener_ex;
    memset(&listener_ex, 0, sizeof(listener_ex));
    listener_ex.listener_data = &state;
    listener_ex.on_publication_matched = on_publication_matched;
    listener_ex.on_reliable_reader_ready = on_reliable_reader_ready;
    if (zzdds_DataWriter_set_listener_ex(zdw, &listener_ex, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    DiscoveryPingDataWriter writer;
    DiscoveryPingDataWriter_init(&writer, dw, ZIDL_XCDR1);

    for (int waited_ms = 0; !atomic_load(&state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    /* Writer-level discovery: the remote subscriber has definitely matched
     * by now (on_reliable_reader_ready only fires once it has). */
    {
        DDS_InstanceHandleSeq handles;
        memset(&handles, 0, sizeof(handles));
        if (DDS_DataWriter_get_matched_subscriptions(dw, &handles) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_matched_subscriptions() failed\n");
            return 1;
        }
        if (handles._length == 0) {
            fprintf(stderr, "FAIL: get_matched_subscriptions() returned no matches\n");
            return 1;
        }
        DDS_SubscriptionBuiltinTopicData sub_data;
        DDS_SubscriptionBuiltinTopicData_default(&sub_data);
        if (DDS_DataWriter_get_matched_subscription_data(dw, &sub_data, handles._buffer[0]) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_matched_subscription_data() failed\n");
            return 1;
        }
        DDS_InstanceHandleSeq_free(&handles);
        if (!sub_data.topic_name || strcmp(sub_data.topic_name, TOPIC_NAME) != 0 ||
            !sub_data.type_name || strcmp(sub_data.type_name, TYPE_NAME) != 0) {
            fprintf(stderr, "FAIL: matched subscription topic_name/type_name mismatch: got '%s'/'%s'\n",
                    sub_data.topic_name ? sub_data.topic_name : "(null)",
                    sub_data.type_name ? sub_data.type_name : "(null)");
            return 1;
        }
        printf("Discovery OK (writer): matched_subscription.topic_name='%s' type_name='%s'\n", sub_data.topic_name, sub_data.type_name);
        DDS_SubscriptionBuiltinTopicData_free(&sub_data);
    }

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        DiscoveryPing sample;
        memset(&sample, 0, sizeof(sample));
        sample.count = i;

        if (DiscoveryPingDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at count=%d\n", i);
            return 1;
        }
        printf("Publisher: wrote count=%d\n", i);
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
