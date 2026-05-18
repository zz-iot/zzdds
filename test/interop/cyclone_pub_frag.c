/*
 * cyclone_pub_frag.c — Cyclone DDS interop publisher (DATA_FRAG path).
 *
 * Sends a HelloWorldData::Msg with a 2000-byte message string — well above
 * Cyclone's default FragmentSize of 1344 bytes — so Cyclone must emit
 * DATA_FRAG submessages.  Exercises Zenzen DDS's DATA_FRAG reassembly path.
 *
 * Test scenario 4:  ./zzdds_interop_sub  &  ./cyclone_pub_frag
 * Expected result:  zzdds_interop_sub reassembles fragments, prints the
 *                   message, and exits 0.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dds/dds.h"
#include "HelloWorldData.h"

#define MSG_LEN 2000

int main(void)
{
    dds_entity_t participant, topic, publisher, writer;
    dds_qos_t   *qos;
    dds_return_t rc;

    participant = dds_create_participant(0, NULL, NULL);
    if (participant < 0) {
        fprintf(stderr, "cyclone_pub_frag: dds_create_participant failed: %s\n",
                dds_strretcode(-participant));
        return 1;
    }

    topic = dds_create_topic(participant, &HelloWorldData_Msg_desc,
                             "HelloWorldTopic", NULL, NULL);
    if (topic < 0) {
        fprintf(stderr, "cyclone_pub_frag: dds_create_topic failed: %s\n",
                dds_strretcode(-topic));
        return 1;
    }

    qos = dds_create_qos();
    dds_qset_reliability(qos, DDS_RELIABILITY_RELIABLE, DDS_SECS(1));

    publisher = dds_create_publisher(participant, NULL, NULL);
    writer    = dds_create_writer(publisher, topic, qos, NULL);
    dds_delete_qos(qos);
    if (writer < 0) {
        fprintf(stderr, "cyclone_pub_frag: dds_create_writer failed: %s\n",
                dds_strretcode(-writer));
        return 1;
    }

    /* Wait for at least one matching reader (up to 5 s). */
    dds_publication_matched_status_t status;
    for (int i = 0; i < 50; i++) {
        dds_get_publication_matched_status(writer, &status);
        if (status.current_count > 0) break;
        dds_sleepfor(DDS_MSECS(100));
    }
    if (status.current_count == 0) {
        fprintf(stderr, "cyclone_pub_frag: no matching reader found within 5s\n");
        dds_delete(participant);
        return 1;
    }

    /* Build a 2000-char message: prefix + '.' padding + NUL. */
    char message[MSG_LEN + 1];
    const char *prefix = "Hello from Cyclone (frag test) ";
    size_t plen = strlen(prefix);
    memcpy(message, prefix, plen);
    memset(message + plen, '.', MSG_LEN - plen);
    message[MSG_LEN] = '\0';

    HelloWorldData_Msg msg = { .userID = 43, .message = message };
    rc = dds_write(writer, &msg);
    if (rc != DDS_RETCODE_OK) {
        fprintf(stderr, "cyclone_pub_frag: dds_write failed: %s\n",
                dds_strretcode(-rc));
        dds_delete(participant);
        return 1;
    }

    printf("cyclone_pub_frag: sent userID=%d message[0..30]=\"%.30s...\"\n",
           msg.userID, msg.message);

    dds_sleepfor(DDS_MSECS(2000)); /* allow reliable delivery + NACK_FRAG exchange */
    dds_delete(participant);
    return 0;
}
