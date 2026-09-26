/*
 * integration-tests/c/liveliness-lost -- subscriber. Independently confirms
 * the same AUTOMATIC-vs-MANUAL_BY_PARTICIPANT distinction from the
 * receiving side's own on_liveliness_changed(), extending `presence`'s
 * (MANUAL_BY_TOPIC-only) reader-side coverage to these two kinds too --
 * see publisher.c's header comment for the full scenario rationale.
 *
 * Two DataReaders, matching each writer's kind and lease_duration:
 * - AUTOMATIC reader: alive_count must stay at 1 (never drop to 0) for the
 *   whole run -- the writer's continuous write()s should keep it alive.
 * - MANUAL_BY_PARTICIPANT reader: alive_count must drop to 0 at least once
 *   -- the writer's continuous write()s should NOT keep it alive for this
 *   kind, despite looking identical on the wire from a data-flow
 *   perspective.
 *
 * Required stdout markers: "Create topic:" x2, "Create reader for topic:"
 * x2, "Subscriber: both writers matched.", "Subscriber: AUTOMATIC reader
 * never observed NOT_ALIVE, as expected.", "Subscriber: MANUAL_BY_PARTICIPANT
 * reader observed NOT_ALIVE at least once, as expected.", "Subscriber:
 * done." Any failure path prints a line starting "FAIL:" and exits
 * nonzero.
 */
#include "liveliness_event.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LEASE_DURATION_SEC 2
/* Comfortably longer than the publisher's own ~8s write loop (16 writes *
 * 500ms), so the observation window covers the whole thing. */
#define OBSERVE_WINDOW_S 12
/* 40s, not the 20s every other match-wait in this tier uses -- see
 * publisher.c's matching comment. */
#define MATCH_TIMEOUT_MS 40000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_int matched_current_count;
    atomic_int alive_count;
    atomic_bool ever_not_alive;
} ReaderState;

static void on_subscription_matched(DDS_DataReader the_reader, const DDS_SubscriptionMatchedStatus *status, void *listener_data) {
    (void)the_reader;
    ReaderState *state = (ReaderState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
}

static void on_liveliness_changed(DDS_DataReader the_reader, const DDS_LivelinessChangedStatus *status, void *listener_data) {
    (void)the_reader;
    ReaderState *state = (ReaderState *)listener_data;
    atomic_store(&state->alive_count, status->alive_count);
    if (status->alive_count == 0) atomic_store(&state->ever_not_alive, true);
}

static uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) {
            return (uint32_t)strtoul(argv[i + 1], NULL, 10);
        }
    }
    return 0;
}

static DDS_DataReader create_reader(DDS_DomainParticipant dp, DDS_Subscriber sub, const char *topic_name,
                                     DDS_LivelinessQosPolicyKind kind, ReaderState *state) {
    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, topic_name, "LivelinessEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic(%s) failed\n", topic_name);
        return NULL;
    }
    printf("Create topic: %s\n", topic_name);
    fflush(stdout);

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    dr_qos.liveliness.kind = kind;
    dr_qos.liveliness.lease_duration.sec = LEASE_DURATION_SEC;
    dr_qos.liveliness.lease_duration.nanosec = 0;

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader(%s) failed\n", topic_name);
        return NULL;
    }
    printf("Create reader for topic: %s\n", topic_name);
    fflush(stdout);

    atomic_init(&state->matched_current_count, 0);
    atomic_init(&state->alive_count, 0);
    atomic_init(&state->ever_not_alive, false);
    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = state;
    listener.on_subscription_matched = on_subscription_matched;
    listener.on_liveliness_changed = on_liveliness_changed;
    if (DDS_DataReader_set_listener(dr, &listener, DDS_SUBSCRIPTION_MATCHED_STATUS | DDS_LIVELINESS_CHANGED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener(%s) failed\n", topic_name);
        return NULL;
    }
    return dr;
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

    if (LivelinessEventTypeSupport_register(dp, "LivelinessEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    ReaderState auto_state, manual_state;
    DDS_DataReader auto_dr = create_reader(dp, sub, "AutomaticLivelinessTopic", DDS_LivelinessQosPolicyKind_AUTOMATIC_LIVELINESS_QOS, &auto_state);
    if (!auto_dr) return 1;
    DDS_DataReader manual_dr = create_reader(dp, sub, "ManualByParticipantLivelinessTopic", DDS_LivelinessQosPolicyKind_MANUAL_BY_PARTICIPANT_LIVELINESS_QOS, &manual_state);
    if (!manual_dr) return 1;

    for (int waited_ms = 0; atomic_load(&auto_state.matched_current_count) < 1 || atomic_load(&manual_state.matched_current_count) < 1; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: writers never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Subscriber: both writers matched.\n");
    fflush(stdout);

    sleep(OBSERVE_WINDOW_S);

    if (atomic_load(&auto_state.ever_not_alive)) {
        fprintf(stderr, "FAIL: AUTOMATIC reader observed NOT_ALIVE (alive_count dropped to 0) at some point, expected never\n");
        return 1;
    }
    printf("Subscriber: AUTOMATIC reader never observed NOT_ALIVE, as expected.\n");
    fflush(stdout);

    if (!atomic_load(&manual_state.ever_not_alive)) {
        fprintf(stderr, "FAIL: MANUAL_BY_PARTICIPANT reader never observed NOT_ALIVE despite the writer never asserting liveliness, expected at least once\n");
        return 1;
    }
    printf("Subscriber: MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as expected.\n");
    fflush(stdout);

    printf("Subscriber: done.\n");
    fflush(stdout);
    zzdds_destroy_factory(factory);
    return 0;
}
