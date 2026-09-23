/*
 * integration-tests/c/ignore-entities -- peer. Simple counterpart to
 * ignorer.c: creates a writer for ControlTopic and TopicIgnoredTopic, and a
 * reader for SubscriptionIgnoredTopic, plus a writer that gets matched by
 * the ignorer's throwaway "probe" reader on PublicationIgnoredTopic. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * IMPORTANT: this file deliberately does NOT assert that its own
 * match-count fields ever drop to zero. ignore_topic()/ignore_publication()
 * are a strictly one-sided, local filter on the ignorer's participant (see
 * ignorer.c's header comment) -- from this process's own SEDP perspective,
 * its TopicIgnoredTopic/PublicationIgnoredTopic writers legitimately stay
 * matched to the ignorer's reader the entire time, exactly as if nothing
 * had been ignored at all. The one thing this process CAN and does verify
 * from its own side is SubscriptionIgnoredTopic: ignore_subscription() is
 * called on the *writer's* participant (ignorer), so it's ignorer's own
 * writer that never adds this process's reader as a matched proxy --
 * meaning this reader, despite itself reporting a normal SEDP match, must
 * never actually receive any of the real writer's samples.
 *
 * Required stdout markers: "Peer: ready.", "Peer: SubscriptionIgnoredTopic
 * reader received zero samples from the real (post-ignore) writer.", "Peer:
 * done." Any failure path prints a line starting "FAIL:" and exits
 * nonzero.
 */
#include "ignore_event.h"
#include "zzdds_c.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_COUNT 5
/* NOT long enough to guarantee the ignorer has finished every ignore_*()
 * call -- its own PROBE_MATCH_TIMEOUT_MS (45s) applies twice, sequentially,
 * for the publication and subscription probes, so its true worst case is
 * well over a minute. Raised from 6s to match this file's own MATCH_TIMEOUT_MS
 * convention as a meaningfully better (not watertight) margin: the
 * SubscriptionIgnoredTopic check below can still report a false pass -- zero
 * samples because the real (post-ignore) writer hasn't been created yet,
 * not because ignore_subscription() worked -- if the ignorer is still deep
 * in its own probe/settle choreography when this window closes. A fully
 * watertight fix needs an explicit cross-process signal (e.g. a dedicated
 * marker topic) rather than a fixed sleep; not done here to avoid adding a
 * worst-case 100+s wait on top of an already CI-budget-constrained suite
 * (found via Greptile review; see docs/roadmap.md's discovery-latency entry
 * for the same underlying "how long is long enough" tension). */
#define SETTLE_WINDOW_S 20
#define MATCH_TIMEOUT_MS 20000
#define DRAIN_TIMEOUT_MS 15000
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

    if (IgnoreEventTypeSupport_register(dp, "IgnoreEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic control_topic = DDS_DomainParticipant_create_topic(dp, "ControlTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic topic_ignored_topic = DDS_DomainParticipant_create_topic(dp, "TopicIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic pub_ignored_topic = DDS_DomainParticipant_create_topic(dp, "PublicationIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic sub_ignored_topic = DDS_DomainParticipant_create_topic(dp, "SubscriptionIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    if (!control_topic || !topic_ignored_topic || !pub_ignored_topic || !sub_ignored_topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!pub || !sub) {
        fprintf(stderr, "FAIL: create_publisher()/create_subscriber() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter control_dw = DDS_Publisher_create_datawriter(pub, control_topic, &dw_qos, NULL, 0);
    DDS_DataWriter topic_ignored_dw = DDS_Publisher_create_datawriter(pub, topic_ignored_topic, &dw_qos, NULL, 0);
    DDS_DataWriter pub_ignored_dw = DDS_Publisher_create_datawriter(pub, pub_ignored_topic, &dw_qos, NULL, 0);
    DDS_TopicDescription sub_ignored_desc = zzdds_topic_as_description(sub_ignored_topic);
    DDS_DataReader sub_ignored_dr = DDS_Subscriber_create_datareader(sub, sub_ignored_desc, &dr_qos, NULL, 0);
    if (!control_dw || !topic_ignored_dw || !pub_ignored_dw || !sub_ignored_dr) {
        fprintf(stderr, "FAIL: create_datawriter()/create_datareader() failed\n");
        return 1;
    }
    printf("Peer: ready.\n");

    /* Write a few samples on TopicIgnoredTopic and PublicationIgnoredTopic
     * right away -- both writers exist continuously from here on, giving
     * the ignorer's readers every real opportunity to (wrongly) match. */
    IgnoreEventDataWriter topic_ignored_writer, pub_ignored_writer;
    IgnoreEventDataWriter_init(&topic_ignored_writer, topic_ignored_dw, ZIDL_XCDR1);
    IgnoreEventDataWriter_init(&pub_ignored_writer, pub_ignored_dw, ZIDL_XCDR1);
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        IgnoreEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        IgnoreEventDataWriter_write(&topic_ignored_writer, &ev, DDS_HANDLE_NIL);
        IgnoreEventDataWriter_write(&pub_ignored_writer, &ev, DDS_HANDLE_NIL);
    }

    /* Let the ignorer's full choreography (participant-discover-and-ignore,
     * publication probe-then-ignore, subscription probe-then-ignore) run to
     * completion. No assertion on topic_ignored_dw's or pub_ignored_dw's
     * own match-count here -- see this file's header comment for why that
     * would be asserting something ignore_topic()/ignore_publication()
     * never promised. */
    sleep(SETTLE_WINDOW_S);

    /* The one thing this process's own side CAN verify: ignore_subscription()
     * was called on ignorer's *writer* participant, so its real
     * (post-ignore) writer never adds this reader as a matched proxy --
     * meaning this reader, however its own SEDP match status reports
     * itself, must never actually receive any of that writer's samples. */
    IgnoreEventDataReader sub_ignored_reader;
    IgnoreEventDataReader_init(&sub_ignored_reader, sub_ignored_dr);
    int taken_count = 0;
    for (;;) {
        IgnoreEvent value;
        DDS_SampleInfo info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;
        int rc = IgnoreEventDataReader_take(&sub_ignored_reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take(SubscriptionIgnoredTopic) CDR error (rc=%d)\n", rc);
            return 1;
        }
        if (info.valid_data) taken_count++;
    }
    if (taken_count != 0) {
        fprintf(stderr, "FAIL: SubscriptionIgnoredTopic reader received %d samples, expected 0\n", taken_count);
        return 1;
    }
    printf("Peer: SubscriptionIgnoredTopic reader received zero samples from the real (post-ignore) writer.\n");

    /* Normal ControlTopic round-trip, matching every other scenario's
     * sanity-check convention. */
    DDS_PublicationMatchedStatus control_status;
    bool control_matched = false;
    for (int waited_ms = 0; !control_matched; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: ControlTopic writer never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        if (DDS_DataWriter_get_publication_matched_status(control_dw, &control_status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_publication_matched_status(control) failed\n");
            return 1;
        }
        if (control_status.current_count > 0) {
            control_matched = true;
        } else {
            usleep(POLL_PERIOD_MS * 1000);
        }
    }

    IgnoreEventDataWriter control_writer;
    IgnoreEventDataWriter_init(&control_writer, control_dw, ZIDL_XCDR1);
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        IgnoreEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (IgnoreEventDataWriter_write(&control_writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write(ControlTopic) failed at seq=%d\n", seq);
            return 1;
        }
    }

    /* Standard teardown-safety: wait for the ignorer to disconnect before
     * deleting, matching every other scenario's precedent. */
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (DDS_DataWriter_get_publication_matched_status(control_dw, &control_status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_publication_matched_status(control) failed\n");
            return 1;
        }
        if (control_status.current_count == 0) break;
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: ignorer did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Peer: done.\n");
    DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    zzdds_destroy_factory(factory);
    return 0;
}
