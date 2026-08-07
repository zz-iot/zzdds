/*
 * c/hello_world -- subscriber. Direct C port of zig/hello_world/subscriber.zig;
 * see docs/design/hello-world-reference-app.md at the repo root for the
 * full spec. Demonstrates DataReaderListener::on_data_available: every
 * sample is checked against the next expected `count` (fail fast -- any
 * gap or reorder is a hard error), and once all 10 arrive in order this
 * process tears its reader down immediately, which is what lets the
 * publisher's matched reader count drop back to zero and exit.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: received count=", "Subscriber: received
 * all 10 samples in order." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
 */
#include "hello_world.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPECTED_SAMPLES 10
#define RECEIVE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

typedef struct {
    HelloWorldDataReader *reader;
    /* Only ever touched from the listener's dispatch thread -- see
     * on_data_available. */
    int32_t expected_next;
    atomic_bool all_received;
} SubState;

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;

    for (;;) {
        HelloWorld value;
        zzdds_sample_info info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;

        int rc = HelloWorldDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc != 0) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }
        /* info is zeroed above, so an untouched valid_data==false here means
         * the queue is now empty -- same ambiguity custom-allocator's
         * subscriber.c documents, resolved the same way. */
        if (!info.valid_data) break;

        if (value.count != state->expected_next) {
            fprintf(stderr, "FAIL: expected count=%d but got count=%d\n", state->expected_next, value.count);
            exit(1);
        }

        printf("Subscriber: received count=%d message=\"%s\"\n", value.count, value.message);
        state->expected_next++;

        if (state->expected_next == EXPECTED_SAMPLES) {
            atomic_store(&state->all_received, true);
        }
    }
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

    if (zzdds_register_type_support(dp, "HelloWorld", HelloWorld_compute_key_hash_from_cdr, HelloWorld_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "HelloWorld", "HelloWorld", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: HelloWorld\n");

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

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, &listener, DDS_DATA_AVAILABLE_STATUS);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: HelloWorld\n");

    HelloWorldDataReader reader;
    HelloWorldDataReader_init(&reader, dr);
    state.reader = &reader;

    printf("Subscriber: waiting for %d samples...\n", EXPECTED_SAMPLES);
    for (int waited_ms = 0; !atomic_load(&state.all_received); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                    state.expected_next, EXPECTED_SAMPLES, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    /* Tear the reader down immediately -- the publisher is blocked waiting
     * for our matched-reader count to drop back to zero. */
    DDS_Subscriber_delete_datareader(sub, dr);

    printf("Subscriber: received all %d samples in order.\n", EXPECTED_SAMPLES);
    zzdds_destroy_factory(factory);
    return 0;
}
