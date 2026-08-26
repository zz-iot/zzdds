/*
 * c/participant-config -- publisher. Direct C port of
 * zig/participant-config/publisher.zig; see
 * docs/design/participant-config-reference-app.md at the repo root for the
 * full spec.
 *
 * Two mutually exclusive modes:
 *
 *   Default (no --config): programmatic mode. Builds a
 *   zzdds_DomainParticipantConfig value, round-trips it through
 *   zzdds_DomainParticipantFactory_set_default_participant_config/
 *   _get_default_participant_config (asserting the value read back matches
 *   what was set), then creates the participant via
 *   zzdds_DomainParticipantFactory_create_participant_ex using that same
 *   config.
 *
 *   --config <path>: file mode. Loads `path` via
 *   zzdds_process_configure_from_file before the factory is created, then
 *   creates the participant the plain way. Point this at
 *   ../../config/tcp-non-discovery.toml to see user-data traffic move to
 *   TCP while discovery stays on UDP.
 *
 * Both modes then run the same minimal reliable write loop (3 samples) as
 * hello_world, to prove the configured participant actually works.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "on_reliable_reader_ready", "Publisher: wrote count=", "Publisher: done."
 * Programmatic mode additionally prints "Config round-trip OK: ...". Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_ping.h"
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

/* Distinctive values for the programmatic round-trip check -- one plain
 * string field, one scalar field in an all-primitive nested struct, so a
 * mismatch in either is unambiguous about which kind of field broke. */
#define CONFIG_PARTICIPANT_NAME "participant-config-example"
#define CONFIG_FRAGMENT_SIZE 9000

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
        /* Programmatic mode. */
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
    printf("Create writer for topic: ConfigPing\n");

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

    ConfigPingDataWriter writer;
    ConfigPingDataWriter_init(&writer, dw, ZIDL_XCDR1);

    for (int waited_ms = 0; !atomic_load(&state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        ConfigPing sample;
        memset(&sample, 0, sizeof(sample));
        sample.count = i;

        if (ConfigPingDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
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
