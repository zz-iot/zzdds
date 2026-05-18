/*
 * cyclone_sub.c — Cyclone DDS interop subscriber.
 *
 * Waits up to 10 s for one HelloWorldData::Msg sample, prints it, and exits 0.
 * Exits 1 on timeout.
 *
 * Test scenario 2:  zdds_interop_pub  &  ./cyclone_sub
 * Expected result:  cyclone_sub receives the sample and exits 0.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dds/dds.h"
#include "HelloWorldData.h"

int main(void)
{
    dds_entity_t participant, topic, subscriber, reader;
    dds_qos_t   *qos;

    participant = dds_create_participant(0, NULL, NULL);
    if (participant < 0) {
        fprintf(stderr, "cyclone_sub: dds_create_participant failed: %s\n",
                dds_strretcode(-participant));
        return 1;
    }

    topic = dds_create_topic(participant,
                             &HelloWorldData_Msg_desc,
                             "HelloWorldTopic",
                             NULL, NULL);
    if (topic < 0) {
        fprintf(stderr, "cyclone_sub: dds_create_topic failed: %s\n",
                dds_strretcode(-topic));
        return 1;
    }

    qos = dds_create_qos();
    dds_qset_reliability(qos, DDS_RELIABILITY_RELIABLE, DDS_SECS(1));

    subscriber = dds_create_subscriber(participant, NULL, NULL);
    reader     = dds_create_reader(subscriber, topic, qos, NULL);
    dds_delete_qos(qos);
    if (reader < 0) {
        fprintf(stderr, "cyclone_sub: dds_create_reader failed: %s\n",
                dds_strretcode(-reader));
        return 1;
    }

    HelloWorldData_Msg *msg_ptr = NULL;
    dds_sample_info_t   info;
    void *samples[1] = { NULL };

    for (int i = 0; i < 200; i++) {   /* 200 × 50ms = 10s */
        dds_return_t n = dds_take(reader, samples, &info, 1, 1);
        if (n > 0 && info.valid_data) {
            msg_ptr = (HelloWorldData_Msg *)samples[0];
            printf("cyclone_sub: received userID=%d message=\"%s\"\n",
                   msg_ptr->userID, msg_ptr->message);
            dds_return_loan(reader, samples, n);
            dds_delete(participant);
            return 0;
        }
        if (n > 0) dds_return_loan(reader, samples, n);
        dds_sleepfor(DDS_MSECS(50));
    }

    fprintf(stderr, "cyclone_sub: timeout — no sample received\n");
    dds_delete(participant);
    return 1;
}
