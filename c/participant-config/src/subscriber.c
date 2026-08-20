/*
 * c/participant-config -- subscriber. Direct C port of
 * zig/participant-config/subscriber.zig; see
 * docs/design/participant-config-reference-app.md at the repo root for the
 * full spec. Same two mutually exclusive modes as the publisher (see
 * publisher.c's doc comment).
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: received count=", "Subscriber: received all 3 samples in
 * order." Programmatic mode additionally prints "Config round-trip OK: ...".
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_ping.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPECTED_SAMPLES 3
#define RECEIVE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

#define CONFIG_PARTICIPANT_NAME "participant-config-example"
#define CONFIG_FRAGMENT_SIZE 9000

typedef struct {
    ConfigPingDataReader *reader;
    int32_t expected_next;
    atomic_bool all_received;
} SubState;

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;

    for (;;) {
        ConfigPing value;
        zzdds_sample_info info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;

        int rc = ConfigPingDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
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
    const char *config_path;
} Options;

static Options parse_args(int argc, char **argv) {
    Options opts;
    memset(&opts, 0, sizeof(opts));
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) && i + 1 < argc) {
            opts.domain_id = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            opts.config_path = argv[++i];
        }
    }
    return opts;
}

int main(int argc, char **argv) {
    Options opts = parse_args(argc, argv);

    if (opts.config_path) {
        DDS_ReturnCode_t cfg_rc = zzdds_process_configure_from_file(opts.config_path, NULL);
        if (cfg_rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: failed to load config file '%s' (rc=%d)\n", opts.config_path, (int)cfg_rc);
            return 1;
        }
    }

    zzdds_DomainParticipantFactory factory = zzdds_create_factory();
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    DDS_DomainParticipant dp;
    if (!opts.config_path) {
        zzdds_DomainParticipantConfig cfg;
        zzdds_DomainParticipantConfig_default(&cfg);
        cfg.participant.name = CONFIG_PARTICIPANT_NAME;
        cfg.rtps.fragment_size = CONFIG_FRAGMENT_SIZE;

        if (zzdds_DomainParticipantFactory_set_default_participant_config(factory, &cfg) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: set_default_participant_config() failed\n");
            return 1;
        }

        zzdds_DomainParticipantConfig readback;
        zzdds_DomainParticipantConfig_default(&readback);
        if (zzdds_DomainParticipantFactory_get_default_participant_config(factory, &readback) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_default_participant_config() failed\n");
            return 1;
        }

        if (!readback.participant.name || strcmp(readback.participant.name, CONFIG_PARTICIPANT_NAME) != 0) {
            fprintf(stderr, "FAIL: participant.name round-trip mismatch: expected '%s', got '%s'\n",
                    CONFIG_PARTICIPANT_NAME, readback.participant.name ? readback.participant.name : "(null)");
            return 1;
        }
        if (readback.rtps.fragment_size != CONFIG_FRAGMENT_SIZE) {
            fprintf(stderr, "FAIL: rtps.fragment_size round-trip mismatch: expected %d, got %u\n",
                    CONFIG_FRAGMENT_SIZE, (unsigned)readback.rtps.fragment_size);
            return 1;
        }
        printf("Config round-trip OK: participant.name='%s' rtps.fragment_size=%u\n",
               readback.participant.name, (unsigned)readback.rtps.fragment_size);

        dp = zzdds_DomainParticipantFactory_create_participant_ex(factory, opts.domain_id, NULL, NULL, 0, &cfg);
        zzdds_DomainParticipantConfig_free(&readback);
    } else {
        DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
        dp = DDS_DomainParticipantFactory_create_participant(dds_factory, opts.domain_id, NULL, NULL, 0);
    }
    if (!dp) {
        fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", opts.domain_id);
        return 1;
    }

    if (zzdds_register_type_support(dp, "ConfigPing", ConfigPing_compute_key_hash_from_cdr, ConfigPing_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "ConfigPing", "ConfigPing", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: ConfigPing\n");

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
    printf("Create reader for topic: ConfigPing\n");

    ConfigPingDataReader reader;
    ConfigPingDataReader_init(&reader, dr);
    state.reader = &reader;

    if (DDS_DataReader_set_listener(dr, &listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

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
