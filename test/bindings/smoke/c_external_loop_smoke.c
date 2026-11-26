/* An application's own event loop driving zzdds from C
 * (zzdds_ExecutionRuntime_attach_external_loop): a poll() loop waits on the
 * sockets zzdds asks it to watch, until the deadline zzdds reports, and
 * services the runtime; two participants on it discover each other. Every
 * socket is unwatched before it closes, and the loop is released once the
 * runtime stops. Compiled and run by `zig build test-bindings -Dc-binding=true`. */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include "zzdds_c.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
#include <winsock2.h>
#define poll_fn WSAPoll
typedef WSAPOLLFD pollfd_t;
#else
#include <poll.h>
#define poll_fn poll
typedef struct pollfd pollfd_t;
#endif

#define MAX_WATCHED 64

typedef struct {
    zzdds_socket_t socket[MAX_WATCHED];
    uint32_t events[MAX_WATCHED];
    int count;
    int wakes;
    int released;
} Loop;

static void loop_wake(void *ctx) { ((Loop *)ctx)->wakes++; }

static void loop_watch(void *ctx, zzdds_socket_t s, uint32_t events) {
    Loop *l = (Loop *)ctx;
    for (int i = 0; i < l->count; i++) {
        if (l->socket[i] != s) continue;
        if (events == 0) {
            l->socket[i] = l->socket[l->count - 1];
            l->events[i] = l->events[l->count - 1];
            l->count--;
        } else {
            l->events[i] = events;
        }
        return;
    }
    assert(events != 0);
    assert(l->count < MAX_WATCHED);
    l->socket[l->count] = s;
    l->events[l->count] = events;
    l->count++;
}

static void loop_release(void *ctx) { ((Loop *)ctx)->released++; }

/* One round: prepare, wait on the watched sockets until the deadline (at
 * most 20 ms), service. */
static void loop_round(Loop *l, zzdds_ExecutionRuntime rt) {
    zzdds_ExternalWait w;
    assert(zzdds_ExecutionRuntime_prepare_wait(rt, &w) == DDS_RETCODE_OK);
    if (!w.immediate_work) {
        int timeout = 20;
        if (w.has_deadline) {
            int64_t left_ms = (w.deadline_ns - zzdds_ExecutionRuntime_now(rt) + 999999) / 1000000;
            if (left_ms < timeout) timeout = left_ms < 0 ? 0 : (int)left_ms;
        }
        pollfd_t fds[MAX_WATCHED];
        for (int i = 0; i < l->count; i++) {
            fds[i].fd = l->socket[i];
            fds[i].events = (short)(((l->events[i] & ZZDDS_WATCH_READ) ? POLLIN : 0) |
                                    ((l->events[i] & ZZDDS_WATCH_WRITE) ? POLLOUT : 0));
            fds[i].revents = 0;
        }
        if (l->count > 0) (void)poll_fn(fds, (unsigned)l->count, timeout);
    }
    zzdds_DriveResult result;
    assert(zzdds_ExecutionRuntime_service(rt, 64, &result) == DDS_RETCODE_OK);
}

static uint32_t test_domain(void) {
    const char *base = getenv("ZZDDS_TEST_DOMAIN_BASE");
    return base != NULL ? (uint32_t)strtoul(base, NULL, 10) : 99u;
}

static int matched(DDS_DataWriter dw) {
    DDS_PublicationMatchedStatus status;
    if (DDS_DataWriter_get_publication_matched_status(dw, &status) != DDS_RETCODE_OK) return 0;
    return status.current_count == 1;
}

int main(void) {
    zzdds_RuntimeConfig config = { zzdds_RuntimeMode_RUNTIME_MODE_MANUAL, 0, 8 };
    zzdds_ExecutionRuntime rt = zzdds_ExecutionRuntime_create(&config);
    assert(rt != NULL);
    Loop loop = { .count = 0 };
    zzdds_ExternalLoop adapter = { &loop, loop_wake, loop_watch, NULL, loop_release };
    zzdds_ExternalLoop no_watch = adapter;
    no_watch.watch = NULL;
    assert(zzdds_ExecutionRuntime_attach_external_loop(rt, &no_watch) == DDS_RETCODE_BAD_PARAMETER);
    assert(zzdds_ExecutionRuntime_attach_external_loop(rt, &adapter) == DDS_RETCODE_OK);
    DDS_Duration_t no_wait = { 0, 0 };
    zzdds_DriveResult result;
    assert(zzdds_ExecutionRuntime_drive(rt, 1, &no_wait, &result) == DDS_RETCODE_PRECONDITION_NOT_MET);

    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create();
    assert(factory != NULL);
    assert(zzdds_DomainParticipantFactory_set_default_runtime(factory, rt) == DDS_RETCODE_OK);
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
    DDS_DomainParticipant dp_w = DDS_DomainParticipantFactory_create_participant(dds_factory, test_domain(), NULL, NULL, 0);
    DDS_DomainParticipant dp_r = DDS_DomainParticipantFactory_create_participant(dds_factory, test_domain(), NULL, NULL, 0);
    assert(dp_w != NULL && dp_r != NULL);
    assert(loop.count > 0);
    DDS_Topic topic_w = DDS_DomainParticipant_create_topic(dp_w, "CExternalLoop", "CExternalLoopType", NULL, NULL, 0);
    DDS_Topic topic_r = DDS_DomainParticipant_create_topic(dp_r, "CExternalLoop", "CExternalLoopType", NULL, NULL, 0);
    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp_w, NULL, NULL, 0);
    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp_r, NULL, NULL, 0);
    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic_w, NULL, NULL, 0);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, zzdds_Topic_as_topic_description(DDS_Topic_as_zzdds_Topic(topic_r)), NULL, NULL, 0);
    assert(dw != NULL && dr != NULL);

    for (int rounds = 0; !matched(dw); rounds++) {
        assert(rounds < 2000); /* 40 s at most */
        loop_round(&loop, rt);
    }

    assert(zzdds_DomainParticipantFactory_set_default_runtime(factory, NULL) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipant_delete_contained_entities(dp_w) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipant_delete_contained_entities(dp_r) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_participant(dds_factory, dp_w) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_participant(dds_factory, dp_r) == DDS_RETCODE_OK);
    /* Every socket was unwatched before it closed. */
    assert(loop.count == 0);
    assert(loop.released == 0);
    zzdds_ExecutionRuntime_release(rt);
    assert(loop.released == 1);
    zzdds_DomainParticipantFactory_release(factory);
    printf("c_external_loop_smoke: OK\n");
    return 0;
}
