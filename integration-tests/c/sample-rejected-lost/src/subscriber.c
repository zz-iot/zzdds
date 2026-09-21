/*
 * integration-tests/c/sample-rejected-lost -- subscriber.
 *
 * Three DataReaders: RejectedTopic (RELIABLE, KEEP_ALL, tight
 * resource_limits = {max_samples: 3, max_instances: 1,
 * max_samples_per_instance: 3}), created immediately at startup and
 * deliberately never drained until AFTER confirming rejection happened, so
 * the publisher's 5 back-to-back writes overflow it; SyncTopic, also
 * created immediately, polled first and used purely as a "publisher is
 * done writing" gate; LostTopic (RELIABLE, KEEP_LAST depth=1,
 * TRANSIENT_LOCAL), whose reader is deliberately created only AFTER the
 * Sync signal -- by construction the publisher already wrote+evicted its 5
 * LostTopic samples before this reader could possibly match, making the
 * loss a genuine, deterministic late-join gap rather than a real-time
 * race; TRANSIENT_LOCAL lets the still-cached last sample (seq=4) reach
 * this late-joining reader while the 4 evicted ones remain genuinely lost.
 * See docs/design/integration-test-tier.md for the full scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create reader for topic:"
 * x3, "Subscriber: sample_rejected confirmed (count=N, buffered=M).",
 * "Subscriber: sample_lost confirmed (count=N, last seq=N).", "Subscriber:
 * SAMPLE_REJECTED/SAMPLE_LOST both verified." Any failure path prints a
 * line starting "FAIL:" and exits nonzero.
 */
#include "status_event.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SYNC_TIMEOUT_MS 20000
#define STATUS_TIMEOUT_MS 20000
#define POLL_PERIOD_MS 20
#define MAX_SAMPLES 8

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

    if (StatusEventTypeSupport_register(dp, "StatusEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register StatusEventTypeSupport failed\n");
        return 1;
    }

    DDS_Topic rejected_topic = DDS_DomainParticipant_create_topic(dp, "RejectedTopic", "StatusEvent", NULL, NULL, 0);
    if (!rejected_topic) {
        fprintf(stderr, "FAIL: create_topic(RejectedTopic) failed\n");
        return 1;
    }
    printf("Create topic: RejectedTopic\n");

    DDS_Topic lost_topic = DDS_DomainParticipant_create_topic(dp, "LostTopic", "StatusEvent", NULL, NULL, 0);
    if (!lost_topic) {
        fprintf(stderr, "FAIL: create_topic(LostTopic) failed\n");
        return 1;
    }
    printf("Create topic: LostTopic\n");

    DDS_Topic sync_topic = DDS_DomainParticipant_create_topic(dp, "SyncTopic", "StatusEvent", NULL, NULL, 0);
    if (!sync_topic) {
        fprintf(stderr, "FAIL: create_topic(SyncTopic) failed\n");
        return 1;
    }
    printf("Create topic: SyncTopic\n");

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos rejected_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &rejected_qos);
    rejected_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    rejected_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    rejected_qos.resource_limits.max_samples = 3;
    rejected_qos.resource_limits.max_instances = 1;
    rejected_qos.resource_limits.max_samples_per_instance = 3;
    DDS_TopicDescription rejected_desc = zzdds_topic_as_description(rejected_topic);
    DDS_DataReader rejected_dr = DDS_Subscriber_create_datareader(sub, rejected_desc, &rejected_qos, NULL, 0);
    if (!rejected_dr) {
        fprintf(stderr, "FAIL: create_datareader(RejectedTopic) failed\n");
        return 1;
    }
    printf("Create reader for topic: RejectedTopic\n");

    DDS_DataReaderQos sync_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &sync_qos);
    sync_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    DDS_TopicDescription sync_desc = zzdds_topic_as_description(sync_topic);
    DDS_DataReader sync_dr = DDS_Subscriber_create_datareader(sub, sync_desc, &sync_qos, NULL, 0);
    if (!sync_dr) {
        fprintf(stderr, "FAIL: create_datareader(SyncTopic) failed\n");
        return 1;
    }
    printf("Create reader for topic: SyncTopic\n");

    StatusEventDataReader rejected_reader, sync_reader;
    StatusEventDataReader_init(&rejected_reader, rejected_dr);
    StatusEventDataReader_init(&sync_reader, sync_dr);

    StatusEvent values[MAX_SAMPLES];
    DDS_SampleInfo infos[MAX_SAMPLES];

    /* Gate: don't create the LostTopic reader, or check RejectedTopic's
     * final status, until the publisher has genuinely finished writing
     * everything (it writes Sync last). */
    {
        int got_sync = 0;
        for (int waited_ms = 0; !got_sync; waited_ms += POLL_PERIOD_MS) {
            if (waited_ms >= SYNC_TIMEOUT_MS) {
                fprintf(stderr, "FAIL: sync sample never arrived within %ds\n", SYNC_TIMEOUT_MS / 1000);
                return 1;
            }
            int n = StatusEventDataReader_take_n(&sync_reader, values, infos, MAX_SAMPLES,
                                                  DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
            if (n > 0) got_sync = 1;
            else usleep(POLL_PERIOD_MS * 1000);
        }
    }

    DDS_DataReaderQos lost_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &lost_qos);
    lost_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    lost_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
    lost_qos.history.depth = 1;
    lost_qos.durability.kind = DDS_DurabilityQosPolicyKind_TRANSIENT_LOCAL_DURABILITY_QOS;
    DDS_TopicDescription lost_desc = zzdds_topic_as_description(lost_topic);
    DDS_DataReader lost_dr = DDS_Subscriber_create_datareader(sub, lost_desc, &lost_qos, NULL, 0);
    if (!lost_dr) {
        fprintf(stderr, "FAIL: create_datareader(LostTopic) failed\n");
        return 1;
    }
    printf("Create reader for topic: LostTopic\n");
    StatusEventDataReader lost_reader;
    StatusEventDataReader_init(&lost_reader, lost_dr);

    /* RejectedTopic: deliberately never drained until now. Confirm
     * rejection happened, then take whatever made it through. */
    DDS_SampleRejectedStatus rejected_status;
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (DDS_DataReader_get_sample_rejected_status(rejected_dr, &rejected_status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_sample_rejected_status() failed\n");
            return 1;
        }
        if (rejected_status.total_count > 0) break;
        if (waited_ms >= STATUS_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no sample ever rejected on RejectedTopic within %ds\n", STATUS_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    int rejected_buffered = StatusEventDataReader_take_n(&rejected_reader, values, infos, MAX_SAMPLES,
                                                          DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
    /* Count-conservation invariant, not a hardcoded exact split: every
     * written sample is either rejected or successfully buffered -- see
     * docs/decisions.md's dds-rtps CoherentSets flake history for why this
     * project avoids asserting exact counts where a property suffices. */
    int rejected_total = rejected_status.total_count + rejected_buffered;
    if (rejected_total != 5) {
        fprintf(stderr, "FAIL: RejectedTopic count mismatch -- rejected=%d buffered=%d total=%d, expected 5\n",
                rejected_status.total_count, rejected_buffered, rejected_total);
        return 1;
    }
    if (rejected_buffered == 0) {
        fprintf(stderr, "FAIL: RejectedTopic: nothing was ever successfully buffered (rejected everything)\n");
        return 1;
    }
    printf("Subscriber: sample_rejected confirmed (count=%d, buffered=%d).\n", rejected_status.total_count, rejected_buffered);

    /* LostTopic: confirm loss happened, then take whatever remains and
     * confirm the writer's LAST value survived. */
    DDS_SampleLostStatus lost_status;
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (DDS_DataReader_get_sample_lost_status(lost_dr, &lost_status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_sample_lost_status() failed\n");
            return 1;
        }
        if (lost_status.total_count > 0) break;
        if (waited_ms >= STATUS_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no sample ever lost on LostTopic within %ds\n", STATUS_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    int lost_n = StatusEventDataReader_take_n(&lost_reader, values, infos, MAX_SAMPLES,
                                               DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
    int max_seq = -1;
    for (int i = 0; i < lost_n; i++) {
        if (infos[i].valid_data && values[i].seq > max_seq) max_seq = values[i].seq;
    }
    if (max_seq != 4) {
        fprintf(stderr, "FAIL: LostTopic did not deliver the writer's last sample (seq=4) -- last seen=%d\n", max_seq);
        return 1;
    }
    printf("Subscriber: sample_lost confirmed (count=%d, last seq=%d).\n", lost_status.total_count, max_seq);

    printf("Subscriber: SAMPLE_REJECTED/SAMPLE_LOST both verified.\n");

    zzdds_destroy_factory(factory);
    return 0;
}
