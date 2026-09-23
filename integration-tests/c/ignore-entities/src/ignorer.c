/*
 * integration-tests/c/ignore-entities -- ignorer. The entity under test:
 * exercises all four DomainParticipant ignore_*() operations and proves
 * each one's specific discovery-gating scope. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * IMPORTANT, and the reason this scenario's assertions live entirely on
 * THIS side of the wire: ignore_topic()/ignore_publication()/
 * ignore_subscription() are a strictly one-sided, LOCAL filter (DDS spec
 * wording: "locally ignore"). They change only what THIS participant's own
 * onWriterDiscovered/onReaderDiscovered decide counts as a match --
 * `peer`'s own writers/readers have no idea they've been ignored and
 * legitimately keep reporting themselves matched from their own side (see
 * peer.c, which deliberately does NOT assert its own match-count drops to
 * zero, only that it never observes any *data* flow to/from the ignored
 * entity). What these three operations guarantee, and all that this file
 * checks, is that data never actually reaches (or, for
 * ignore_subscription(), leaves) THIS participant's own reader/writer.
 * ignore_participant() is the one exception: in zzdds's implementation it
 * additionally tears down the underlying SEDP proxy exchange with that
 * prefix -- but bystander.c's own side still legitimately sees itself
 * matched (it has no idea it's been ignored either), so its assertions
 * also live entirely here.
 *
 * - ignore_topic(): resolved from this participant's OWN local topic
 *   instance handle -- no discovery needed -- called before `peer`'s
 *   writer for that topic can possibly exist, so the block is
 *   unconditional from the very first SEDP announcement onward.
 * - ignore_participant(): `bystander` deliberately delays creating its
 *   writer, giving this process a wide, comfortable window to discover
 *   (via get_discovered_participants()) and ignore its participant handle
 *   before that writer's SEDP announcement can ever reach us. Critically,
 *   the harness does not start `peer` until this step has completed and
 *   printed "ignore_participant() applied to bystander." --
 *   get_discovered_participants() makes no ordering promise across
 *   multiple simultaneously-discovered participants, so if `peer` were
 *   already running, handles[0] could just as easily be *peer's* handle,
 *   silently ignoring the wrong participant for the rest of the run
 *   (found the hard way: an earlier version of this harness started
 *   `peer` and `bystander` together, and intermittently ignored `peer`
 *   instead -- see docs/roadmap.md).
 * - ignore_publication()/ignore_subscription(): these target a SPECIFIC
 *   remote entity's handle, which can only be learned by discovering it
 *   first -- so each uses a throwaway "probe" reader/writer purely to
 *   learn `peer`'s counterpart handle via get_matched_publications()/
 *   get_matched_subscriptions(), ignores it, deletes the probe, then
 *   creates the real entity under test and confirms it never matches (and,
 *   for ignore_publication(), never receives any of peer's continuously-
 *   written samples).
 *
 * Required stdout markers: "Ignorer: ready for bystander.", "Ignorer:
 * ignore_participant() applied to bystander.", "Ignorer:
 * ignore_publication() applied via probe.", "Ignorer: ignore_subscription()
 * applied via probe.", "Ignorer: all ignore checks passed.", "Ignorer:
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
#define DISCOVER_BYSTANDER_TIMEOUT_MS 15000
/* 45s, not the 20s every other match-wait in this tier uses -- this
 * scenario's probe-match steps showed intermittent delays under this
 * suite's own CI/dev sandbox load that 20s didn't reliably clear; see
 * docs/roadmap.md. */
#define PROBE_MATCH_TIMEOUT_MS 45000
#define SETTLE_WINDOW_S 3
#define MATCH_TIMEOUT_MS 20000
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

    if (IgnoreEventTypeSupport_register(dp, "IgnoreEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic control_topic = DDS_DomainParticipant_create_topic(dp, "ControlTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic topic_ignored_topic = DDS_DomainParticipant_create_topic(dp, "TopicIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic pub_ignored_topic = DDS_DomainParticipant_create_topic(dp, "PublicationIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic sub_ignored_topic = DDS_DomainParticipant_create_topic(dp, "SubscriptionIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    DDS_Topic participant_ignored_topic = DDS_DomainParticipant_create_topic(dp, "ParticipantIgnoredTopic", "IgnoreEvent", NULL, NULL, 0);
    if (!control_topic || !topic_ignored_topic || !pub_ignored_topic || !sub_ignored_topic || !participant_ignored_topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }

    /* -- ignore_topic(): local knowledge only, no peer needed yet. -- */
    DDS_InstanceHandle_t topic_ignored_handle = DDS_Topic_get_instance_handle(topic_ignored_topic);
    if (DDS_DomainParticipant_ignore_topic(dp, topic_ignored_handle) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: ignore_topic() failed\n");
        return 1;
    }
    printf("Ignorer: ignore_topic() applied to TopicIgnoredTopic.\n");
    fflush(stdout);

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!sub || !pub) {
        fprintf(stderr, "FAIL: create_subscriber()/create_publisher() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    /* Reader created immediately after ignoring -- the writer it must never
     * match (peer's) doesn't exist yet at this point. */
    DDS_TopicDescription topic_ignored_desc = zzdds_topic_as_description(topic_ignored_topic);
    DDS_DataReader topic_ignored_dr = DDS_Subscriber_create_datareader(sub, topic_ignored_desc, &dr_qos, NULL, 0);
    /* Harmless to create now, before ignore_participant() below -- the
     * participant-level guard blocks at first discovery regardless of when
     * this reader was created (see this file's header comment). */
    DDS_TopicDescription participant_ignored_desc = zzdds_topic_as_description(participant_ignored_topic);
    DDS_DataReader participant_ignored_dr = DDS_Subscriber_create_datareader(sub, participant_ignored_desc, &dr_qos, NULL, 0);
    DDS_TopicDescription control_desc = zzdds_topic_as_description(control_topic);
    DDS_DataReader control_dr = DDS_Subscriber_create_datareader(sub, control_desc, &dr_qos, NULL, 0);
    if (!topic_ignored_dr || !participant_ignored_dr || !control_dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }

    printf("Ignorer: ready for bystander.\n");
    fflush(stdout);

    /* -- ignore_participant(): discover bystander's participant, ignore it
     * well within its own deliberate pre-writer delay. -- */
    bool found_bystander = false;
    for (int waited_ms = 0; !found_bystander; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DISCOVER_BYSTANDER_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: bystander's participant never appeared within %ds\n", DISCOVER_BYSTANDER_TIMEOUT_MS / 1000);
            return 1;
        }
        DDS_InstanceHandleSeq handles;
        memset(&handles, 0, sizeof(handles));
        DDS_DomainParticipant_get_discovered_participants(dp, &handles);
        if (handles._length > 0) {
            DDS_ReturnCode_t rc = DDS_DomainParticipant_ignore_participant(dp, handles._buffer[0]);
            DDS_InstanceHandleSeq_free(&handles);
            if (rc != DDS_RETCODE_OK) {
                fprintf(stderr, "FAIL: ignore_participant() returned %d\n", rc);
                return 1;
            }
            found_bystander = true;
        } else {
            DDS_InstanceHandleSeq_free(&handles);
            usleep(POLL_PERIOD_MS * 1000);
        }
    }
    printf("Ignorer: ignore_participant() applied to bystander.\n");
    fflush(stdout);

    /* -- ignore_publication(): probe, learn peer's writer handle, ignore,
     * then prove a freshly-created reader never matches it. -- */
    {
        DDS_TopicDescription pub_ignored_desc = zzdds_topic_as_description(pub_ignored_topic);
        DDS_DataReader probe_dr = DDS_Subscriber_create_datareader(sub, pub_ignored_desc, &dr_qos, NULL, 0);
        if (!probe_dr) {
            fprintf(stderr, "FAIL: create_datareader(probe, PublicationIgnoredTopic) failed\n");
            return 1;
        }
        DDS_SubscriptionMatchedStatus status;
        bool matched = false;
        for (int waited_ms = 0; !matched; waited_ms += POLL_PERIOD_MS) {
            if (waited_ms >= PROBE_MATCH_TIMEOUT_MS) {
                fprintf(stderr, "FAIL: probe reader never matched peer's PublicationIgnoredTopic writer within %ds\n", PROBE_MATCH_TIMEOUT_MS / 1000);
                return 1;
            }
            if (DDS_DataReader_get_subscription_matched_status(probe_dr, &status) != DDS_RETCODE_OK) {
                fprintf(stderr, "FAIL: get_subscription_matched_status(probe) failed\n");
                return 1;
            }
            if (status.current_count > 0) matched = true; else usleep(POLL_PERIOD_MS * 1000);
        }

        DDS_InstanceHandleSeq pub_handles;
        memset(&pub_handles, 0, sizeof(pub_handles));
        if (DDS_DataReader_get_matched_publications(probe_dr, &pub_handles) != DDS_RETCODE_OK || pub_handles._length == 0) {
            fprintf(stderr, "FAIL: get_matched_publications(probe) returned no handles\n");
            return 1;
        }
        DDS_InstanceHandle_t writer_handle = pub_handles._buffer[0];
        DDS_InstanceHandleSeq_free(&pub_handles);
        if (DDS_DomainParticipant_ignore_publication(dp, writer_handle) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: ignore_publication() failed\n");
            return 1;
        }
        DDS_Subscriber_delete_datareader(sub, probe_dr);
        printf("Ignorer: ignore_publication() applied via probe.\n");
        fflush(stdout);
    }
    DDS_TopicDescription pub_ignored_desc2 = zzdds_topic_as_description(pub_ignored_topic);
    DDS_DataReader pub_ignored_dr = DDS_Subscriber_create_datareader(sub, pub_ignored_desc2, &dr_qos, NULL, 0);
    if (!pub_ignored_dr) {
        fprintf(stderr, "FAIL: create_datareader(real, PublicationIgnoredTopic) failed\n");
        return 1;
    }

    /* -- ignore_subscription(): probe, learn peer's reader handle, ignore,
     * then prove a freshly-created writer never matches it. -- */
    {
        DDS_DataWriter probe_dw = DDS_Publisher_create_datawriter(pub, sub_ignored_topic, &dw_qos, NULL, 0);
        if (!probe_dw) {
            fprintf(stderr, "FAIL: create_datawriter(probe, SubscriptionIgnoredTopic) failed\n");
            return 1;
        }
        DDS_PublicationMatchedStatus status;
        bool matched = false;
        for (int waited_ms = 0; !matched; waited_ms += POLL_PERIOD_MS) {
            if (waited_ms >= PROBE_MATCH_TIMEOUT_MS) {
                fprintf(stderr, "FAIL: probe writer never matched peer's SubscriptionIgnoredTopic reader within %ds\n", PROBE_MATCH_TIMEOUT_MS / 1000);
                return 1;
            }
            if (DDS_DataWriter_get_publication_matched_status(probe_dw, &status) != DDS_RETCODE_OK) {
                fprintf(stderr, "FAIL: get_publication_matched_status(probe) failed\n");
                return 1;
            }
            if (status.current_count > 0) matched = true; else usleep(POLL_PERIOD_MS * 1000);
        }

        DDS_InstanceHandleSeq sub_handles;
        memset(&sub_handles, 0, sizeof(sub_handles));
        if (DDS_DataWriter_get_matched_subscriptions(probe_dw, &sub_handles) != DDS_RETCODE_OK || sub_handles._length == 0) {
            fprintf(stderr, "FAIL: get_matched_subscriptions(probe) returned no handles\n");
            return 1;
        }
        DDS_InstanceHandle_t reader_handle = sub_handles._buffer[0];
        DDS_InstanceHandleSeq_free(&sub_handles);
        if (DDS_DomainParticipant_ignore_subscription(dp, reader_handle) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: ignore_subscription() failed\n");
            return 1;
        }
        DDS_Publisher_delete_datawriter(pub, probe_dw);
        printf("Ignorer: ignore_subscription() applied via probe.\n");
        fflush(stdout);
    }
    DDS_DataWriter sub_ignored_dw = DDS_Publisher_create_datawriter(pub, sub_ignored_topic, &dw_qos, NULL, 0);
    if (!sub_ignored_dw) {
        fprintf(stderr, "FAIL: create_datawriter(real, SubscriptionIgnoredTopic) failed\n");
        return 1;
    }
    IgnoreEventDataWriter sub_ignored_writer;
    IgnoreEventDataWriter_init(&sub_ignored_writer, sub_ignored_dw, ZIDL_XCDR1);
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        IgnoreEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (IgnoreEventDataWriter_write(&sub_ignored_writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write(SubscriptionIgnoredTopic) failed at seq=%d\n", seq);
            return 1;
        }
    }

    /* Let everything settle: bystander's writer (created after its own
     * delay) gets a real chance to try (and fail) to announce; the
     * already-existing TopicIgnoredTopic writer gets a real chance to try
     * (and fail) to match the reader created above. */
    sleep(SETTLE_WINDOW_S);

    DDS_SubscriptionMatchedStatus topic_status;
    if (DDS_DataReader_get_subscription_matched_status(topic_ignored_dr, &topic_status) != DDS_RETCODE_OK || topic_status.current_count != 0) {
        fprintf(stderr, "FAIL: TopicIgnoredTopic reader matched despite ignore_topic() (current_count=%d)\n", topic_status.current_count);
        return 1;
    }
    DDS_SubscriptionMatchedStatus participant_status;
    if (DDS_DataReader_get_subscription_matched_status(participant_ignored_dr, &participant_status) != DDS_RETCODE_OK || participant_status.current_count != 0) {
        fprintf(stderr, "FAIL: ParticipantIgnoredTopic reader matched despite ignore_participant() (current_count=%d)\n", participant_status.current_count);
        return 1;
    }
    DDS_SubscriptionMatchedStatus pub_status;
    if (DDS_DataReader_get_subscription_matched_status(pub_ignored_dr, &pub_status) != DDS_RETCODE_OK || pub_status.current_count != 0) {
        fprintf(stderr, "FAIL: PublicationIgnoredTopic reader matched despite ignore_publication() (current_count=%d)\n", pub_status.current_count);
        return 1;
    }

    /* Confirm the real guarantee, not just the match-count field: peer's
     * writers for TopicIgnoredTopic and PublicationIgnoredTopic have been
     * writing continuously this whole time (see peer.c) and -- since
     * ignore_topic()/ignore_publication() are a strictly one-sided, local
     * filter (see this file's header comment) -- legitimately still
     * consider *themselves* matched from their own side. What must never
     * happen is this reader's own take() ever surfacing one of their
     * samples. */
    IgnoreEventDataReader topic_ignored_reader, pub_ignored_reader;
    IgnoreEventDataReader_init(&topic_ignored_reader, topic_ignored_dr);
    IgnoreEventDataReader_init(&pub_ignored_reader, pub_ignored_dr);
    for (int which = 0; which < 2; which++) {
        IgnoreEventDataReader *reader = which == 0 ? &topic_ignored_reader : &pub_ignored_reader;
        const char *label = which == 0 ? "TopicIgnoredTopic" : "PublicationIgnoredTopic";
        int taken_count = 0;
        for (;;) {
            IgnoreEvent value;
            DDS_SampleInfo info;
            memset(&value, 0, sizeof(value));
            memset(&info, 0, sizeof(info));
            uint8_t buf[512];
            size_t cdr_len = 0;
            int rc = IgnoreEventDataReader_take(reader, &value, &info, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                fprintf(stderr, "FAIL: take(%s) CDR error (rc=%d)\n", label, rc);
                return 1;
            }
            if (info.valid_data) taken_count++;
        }
        if (taken_count != 0) {
            fprintf(stderr, "FAIL: %s reader received %d samples, expected 0\n", label, taken_count);
            return 1;
        }
    }
    printf("Ignorer: all ignore checks passed.\n");
    fflush(stdout);

    /* -- Control: prove the apparatus itself works -- an unignored reader
     * must match and receive normally. -- */
    DDS_SubscriptionMatchedStatus control_status;
    bool control_matched = false;
    for (int waited_ms = 0; !control_matched; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: ControlTopic reader never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        if (DDS_DataReader_get_subscription_matched_status(control_dr, &control_status) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_subscription_matched_status(control) failed\n");
            return 1;
        }
        if (control_status.current_count > 0) control_matched = true; else usleep(POLL_PERIOD_MS * 1000);
    }

    IgnoreEventDataReader control_reader;
    IgnoreEventDataReader_init(&control_reader, control_dr);
    int received = 0;
    int32_t last_seq = -1;
    for (int waited_ms = 0; received < SAMPLE_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: ControlTopic did not receive all %d samples within %ds (got %d)\n", SAMPLE_COUNT, RECEIVE_TIMEOUT_MS / 1000, received);
            return 1;
        }
        IgnoreEvent value;
        DDS_SampleInfo info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;
        int rc = IgnoreEventDataReader_take(&control_reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_OK && info.valid_data) {
            if (value.seq != last_seq + 1) {
                fprintf(stderr, "FAIL: ControlTopic out-of-order sample, expected seq=%d got seq=%d\n", last_seq + 1, value.seq);
                return 1;
            }
            last_seq = value.seq;
            received++;
            continue;
        }
        if (rc != DDS_RETCODE_OK && rc != DDS_RETCODE_NO_DATA) {
            fprintf(stderr, "FAIL: take(ControlTopic) CDR error (rc=%d)\n", rc);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Ignorer: ControlTopic received all %d samples.\n", SAMPLE_COUNT);
    fflush(stdout);

    /* Standard teardown-safety: waiting for peer's ControlTopic writer to
     * observe us disconnect isn't this side's job -- peer waits on its own
     * matched-count-to-zero after we delete_participant() (see peer.c). */
    printf("Ignorer: done.\n");
    fflush(stdout);
    DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    zzdds_destroy_factory(factory);
    return 0;
}
