/*
 * integration-tests/c/coherent-sets -- subscriber.
 *
 * One Subscriber (PRESENTATION access_scope=GROUP, coherent_access=true,
 * ordered_access=true), two DataReaders (Position, Velocity), one WaitSet
 * with a ReadCondition per reader. `on_data_on_readers` is NOT used here --
 * it has zero firing sites in zzdds today (see docs/roadmap.md) -- a
 * WaitSet is the proven, already-implemented mechanism (see the `waitset`
 * example).
 *
 * The core assertion: after every begin_access()/end_access() bracket, the
 * two parallel arrays of group_ids taken so far (`position_order`,
 * `velocity_order`) must be exactly the same length and pairwise equal. A
 * mismatch means one reader made a group_id visible to the application
 * without its paired sample on the other reader also being visible in that
 * same access window -- a direct violation of GROUP coherent-access
 * atomicity, not a count-per-time-window guess (see
 * docs/design/integration-test-tier.md's note on the dds-rtps CoherentSets
 * flake history). ordered_access is checked by the final content being
 * exactly [0, 1, ..., GROUP_COUNT-1] on both sides -- the publisher writes
 * strictly increasing group_ids, so anything else is either loss, dup, or
 * reordering.
 *
 * Required stdout markers: "Create topic:" x2, "Create reader for topic:"
 * x2, "Subscriber: group N paired (position+velocity).", "Subscriber:
 * received all 20 groups, atomic and ordered." Any failure path prints a
 * line starting "FAIL:" and exits nonzero.
 */
#include "pose_group.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GROUP_COUNT 20
#define WAIT_STEP_SEC 1
#define OVERALL_DEADLINE_MS 30000

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

    if (PositionTypeSupport_register(dp, "Position") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register PositionTypeSupport failed\n");
        return 1;
    }
    if (VelocityTypeSupport_register(dp, "Velocity") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register VelocityTypeSupport failed\n");
        return 1;
    }

    DDS_Topic position_topic = DDS_DomainParticipant_create_topic(dp, "Position", "Position", NULL, NULL, 0);
    if (!position_topic) {
        fprintf(stderr, "FAIL: create_topic(Position) failed\n");
        return 1;
    }
    printf("Create topic: Position\n");

    DDS_Topic velocity_topic = DDS_DomainParticipant_create_topic(dp, "Velocity", "Velocity", NULL, NULL, 0);
    if (!velocity_topic) {
        fprintf(stderr, "FAIL: create_topic(Velocity) failed\n");
        return 1;
    }
    printf("Create topic: Velocity\n");

    DDS_SubscriberQos sub_qos;
    DDS_DomainParticipant_get_default_subscriber_qos(dp, &sub_qos);
    sub_qos.presentation.access_scope = DDS_PresentationQosPolicyAccessScopeKind_GROUP_PRESENTATION_QOS;
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.ordered_access = true;

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, &sub_qos, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_TopicDescription position_desc = zzdds_topic_as_description(position_topic);
    DDS_DataReader position_dr = DDS_Subscriber_create_datareader(sub, position_desc, &dr_qos, NULL, 0);
    if (!position_dr) {
        fprintf(stderr, "FAIL: create_datareader(Position) failed\n");
        return 1;
    }
    printf("Create reader for topic: Position\n");

    DDS_TopicDescription velocity_desc = zzdds_topic_as_description(velocity_topic);
    DDS_DataReader velocity_dr = DDS_Subscriber_create_datareader(sub, velocity_desc, &dr_qos, NULL, 0);
    if (!velocity_dr) {
        fprintf(stderr, "FAIL: create_datareader(Velocity) failed\n");
        return 1;
    }
    printf("Create reader for topic: Velocity\n");

    PositionDataReader position_reader;
    PositionDataReader_init(&position_reader, position_dr);
    VelocityDataReader velocity_reader;
    VelocityDataReader_init(&velocity_reader, velocity_dr);

    DDS_WaitSet ws = zzdds_create_waitset();
    if (zzdds_waitset_is_nil(ws)) {
        fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }

    DDS_ReadCondition position_rc = DDS_DataReader_create_readcondition(position_dr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
    DDS_ReadCondition velocity_rc = DDS_DataReader_create_readcondition(velocity_dr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
    if (!position_rc || !velocity_rc) {
        fprintf(stderr, "FAIL: create_readcondition() failed\n");
        return 1;
    }
    DDS_Condition position_cond = DDS_ReadCondition_as_DDS_Condition(position_rc);
    DDS_Condition velocity_cond = DDS_ReadCondition_as_DDS_Condition(velocity_rc);

    if (DDS_WaitSet_attach_condition(ws, position_cond) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, velocity_cond) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: attach_condition() failed\n");
        return 1;
    }

    int position_order[GROUP_COUNT];
    int velocity_order[GROUP_COUNT];
    int n_position = 0, n_velocity = 0;

    Position position_values[GROUP_COUNT];
    DDS_SampleInfo position_infos[GROUP_COUNT];
    Velocity velocity_values[GROUP_COUNT];
    DDS_SampleInfo velocity_infos[GROUP_COUNT];

    DDS_Duration_t wait_step = {WAIT_STEP_SEC, 0};
    int overall_waited_ms = 0;

    while (n_position < GROUP_COUNT || n_velocity < GROUP_COUNT) {
        if (overall_waited_ms >= OVERALL_DEADLINE_MS) {
            fprintf(stderr, "FAIL: only received position=%d velocity=%d/%d within %ds\n",
                    n_position, n_velocity, GROUP_COUNT, OVERALL_DEADLINE_MS / 1000);
            return 1;
        }

        DDS_ConditionSeq active;
        memset(&active, 0, sizeof(active));
        DDS_ReturnCode_t wr = DDS_WaitSet_wait(ws, &active, &wait_step);
        if (wr == DDS_RETCODE_TIMEOUT) {
            overall_waited_ms += WAIT_STEP_SEC * 1000;
            continue;
        }
        if (wr != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", wr);
            return 1;
        }
        DDS_ConditionSeq_free(&active);

        if (DDS_Subscriber_begin_access(sub) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: begin_access() failed\n");
            return 1;
        }

        /* Bound each take_n by the REMAINING space in the cumulative
         * position_order/velocity_order arrays (fixed at GROUP_COUNT), not
         * GROUP_COUNT itself -- n_position/n_velocity accumulate across many
         * wait/take cycles, so a single take_n returning close to GROUP_COUNT
         * new samples while some were already buffered from an earlier cycle
         * would otherwise write past the end of these stack arrays (found via
         * PR #91 Greptile review). */
        int pos_capacity = GROUP_COUNT - n_position;
        int n_pos_taken = pos_capacity > 0
            ? PositionDataReader_take_n(&position_reader, position_values, position_infos,
                                         pos_capacity, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE)
            : 0;
        for (int i = 0; i < n_pos_taken; i++) {
            if (!position_infos[i].valid_data) continue;
            position_order[n_position++] = position_values[i].group_id;
        }

        int vel_capacity = GROUP_COUNT - n_velocity;
        int n_vel_taken = vel_capacity > 0
            ? VelocityDataReader_take_n(&velocity_reader, velocity_values, velocity_infos,
                                         vel_capacity, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE)
            : 0;
        for (int i = 0; i < n_vel_taken; i++) {
            if (!velocity_infos[i].valid_data) continue;
            velocity_order[n_velocity++] = velocity_values[i].group_id;
        }

        if (DDS_Subscriber_end_access(sub) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: end_access() failed\n");
            return 1;
        }

        /* The core atomicity assertion -- see file header comment. */
        if (n_position != n_velocity) {
            fprintf(stderr,
                    "FAIL: atomicity violated -- position and velocity readers diverged after an access bracket "
                    "(position count=%d velocity count=%d) -- a group became visible on one reader without its pair\n",
                    n_position, n_velocity);
            return 1;
        }
        for (int i = 0; i < n_position; i++) {
            if (position_order[i] != velocity_order[i]) {
                fprintf(stderr,
                        "FAIL: atomicity violated at index %d -- position group_id=%d but velocity group_id=%d\n",
                        i, position_order[i], velocity_order[i]);
                return 1;
            }
        }
        if (n_position > 0) {
            printf("Subscriber: group %d paired (position+velocity).\n", position_order[n_position - 1]);
        }
    }

    /* ordered_access: the publisher writes strictly increasing group_ids,
     * so anything but [0, 1, ..., GROUP_COUNT-1] is loss, dup, or
     * reordering. */
    for (int i = 0; i < GROUP_COUNT; i++) {
        if (position_order[i] != i || velocity_order[i] != i) {
            fprintf(stderr, "FAIL: ordered_access violated at index %d -- expected group_id=%d, got position=%d velocity=%d\n",
                    i, i, position_order[i], velocity_order[i]);
            return 1;
        }
    }

    printf("Subscriber: received all %d groups, atomic and ordered.\n", GROUP_COUNT);

    DDS_WaitSet_detach_condition(ws, position_cond);
    DDS_WaitSet_detach_condition(ws, velocity_cond);
    DDS_DataReader_delete_readcondition(position_dr, position_rc);
    DDS_DataReader_delete_readcondition(velocity_dr, velocity_rc);
    DDS_Subscriber_delete_datareader(sub, position_dr);
    DDS_Subscriber_delete_datareader(sub, velocity_dr);
    zzdds_destroy_waitset(ws);

    zzdds_destroy_factory(factory);
    return 0;
}
