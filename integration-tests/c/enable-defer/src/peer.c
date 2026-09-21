/*
 * integration-tests/c/enable-defer -- peer.
 *
 * Simple counterpart to configurer.c: creates a normal, fully-enabled
 * DataReader on ConfigTopic immediately, then spends ~3 seconds
 * (comfortably inside the configurer's own ~4s pre-enable delay) proving it
 * observes ZERO matching -- direct evidence the deferred SEDP announcement
 * genuinely never went out while the configurer's writer was disabled.
 * After that window, waits normally for matching and 5 samples. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * Required stdout markers: "Create topic: ConfigTopic", "Create reader for
 * topic: ConfigTopic", "Peer: no premature match during Ns window.", "Peer:
 * no premature match; matched and received cleanly after enable()." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_event.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_TARGET 5
#define PREMATURE_CHECK_WINDOW_SEC 3
#define MATCH_TIMEOUT_MS 30000
#define RECEIVE_TIMEOUT_MS 20000
#define POLL_PERIOD_MS 20

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

    if (ConfigEventTypeSupport_register(dp, "ConfigEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register ConfigEventTypeSupport failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "ConfigTopic", "ConfigEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic(ConfigTopic) failed\n");
        return 1;
    }
    printf("Create topic: ConfigTopic\n");

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_TopicDescription desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader(ConfigTopic) failed\n");
        return 1;
    }
    printf("Create reader for topic: ConfigTopic\n");

    ConfigEventDataReader reader;
    ConfigEventDataReader_init(&reader, dr);

    /* Core assertion: for a window comfortably inside the configurer's own
     * pre-enable delay, matched-current-count must stay exactly 0 -- direct
     * proof the deferred SEDP announcement genuinely never went out while
     * the configurer's writer was disabled. */
    DDS_SubscriptionMatchedStatus status;
    for (int waited_ms = 0; waited_ms < PREMATURE_CHECK_WINDOW_SEC * 1000; waited_ms += POLL_PERIOD_MS) {
        if (DDS_DataReader_get_subscription_matched_status(dr, &status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_subscription_matched_status() failed\n");
            return 1;
        }
        if (status.current_count != 0) {
            fprintf(stderr, "FAIL: matched before enable() was called -- deferred SEDP announcement isn't working (current_count=%d)\n", status.current_count);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Peer: no premature match during %ds window.\n", PREMATURE_CHECK_WINDOW_SEC);

    /* Now wait normally for the real match, once the configurer enables. */
    bool matched = false;
    for (int waited_ms = 0; !matched; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: never matched within %ds of the premature-match window ending\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        if (DDS_DataReader_get_subscription_matched_status(dr, &status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_subscription_matched_status() failed\n");
            return 1;
        }
        if (status.current_count > 0) {
            matched = true;
        } else {
            usleep(POLL_PERIOD_MS * 1000);
        }
    }

    int received = 0;
    int32_t last_seq = -1;
    ConfigEvent values[SAMPLE_TARGET];
    DDS_SampleInfo infos[SAMPLE_TARGET];
    for (int waited_ms = 0; received < SAMPLE_TARGET; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: did not receive all %d samples within %ds (got %d)\n", SAMPLE_TARGET, RECEIVE_TIMEOUT_MS / 1000, received);
            return 1;
        }
        int n = ConfigEventDataReader_take_n(&reader, values, infos, SAMPLE_TARGET,
                                              DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
        for (int i = 0; i < n; i++) {
            if (!infos[i].valid_data) continue;
            if (values[i].seq != last_seq + 1) {
                fprintf(stderr, "FAIL: out-of-order sample, expected seq=%d got seq=%d\n", last_seq + 1, values[i].seq);
                return 1;
            }
            last_seq = values[i].seq;
            received++;
        }
        if (received < SAMPLE_TARGET) usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Peer: no premature match; matched and received cleanly after enable().\n");

    DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    zzdds_destroy_factory(factory);
    return 0;
}
