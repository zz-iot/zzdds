#ifndef ZZDDS_C_H
#define ZZDDS_C_H

/*
 * Low-level support ABI used by zidl-generated zzdds topic wrappers.
 *
 * Prefer the generated DDS/zzdds language bindings for application code. This
 * header intentionally stays small and byte-oriented: it bridges generated CDR
 * TypeSupport/DataWriter/DataReader wrappers to the hand-written zzdds runtime.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "dcps.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum zzdds_write_kind {
    ZZDDS_WRITE_ALIVE = 0,
    ZZDDS_WRITE_DISPOSE = 1,
    ZZDDS_WRITE_UNREGISTER = 2,
} zzdds_write_kind;

typedef struct zzdds_sample_info {
    bool valid_data;
    uint32_t instance_state;
    DDS_InstanceHandle_t instance_handle;
} zzdds_sample_info;

typedef struct zzdds_loaned_sample {
    const uint8_t *data;
    size_t data_len;
    void *owner;
} zzdds_loaned_sample;

typedef int (*zzdds_compute_key_hash_fn)(const uint8_t *payload, size_t len, uint8_t hash_out[16]);

DDS_DomainParticipant zzdds_create_participant_udp(uint32_t domain_id, const DDS_DomainParticipantListener *listener);
void zzdds_destroy_participant(DDS_DomainParticipant participant);
DDS_TopicDescription zzdds_topic_as_description(DDS_Topic topic);

int zzdds_register_type_support_c(
    DDS_DomainParticipant participant,
    const char *type_name,
    zzdds_compute_key_hash_fn compute_key_hash_fn
);

DDS_ReturnCode_t zzdds_write_raw(
    DDS_DataWriter writer,
    const uint8_t key_hash[16],
    const uint8_t *data,
    size_t data_len
);

DDS_ReturnCode_t zzdds_write_raw_kind(
    DDS_DataWriter writer,
    zzdds_write_kind kind,
    const uint8_t key_hash[16],
    const uint8_t *data,
    size_t data_len
);

int zzdds_take_one_raw(
    DDS_DataReader reader,
    uint8_t *cdr_buf,
    size_t buf_size,
    size_t *cdr_len_out,
    zzdds_sample_info *info_out
);

int zzdds_take_one_raw_instance(
    DDS_DataReader reader,
    DDS_InstanceHandle_t prev_instance_handle,
    uint8_t *cdr_buf,
    size_t buf_size,
    size_t *cdr_len_out,
    zzdds_sample_info *info_out
);

int zzdds_take_loaned_raw(
    DDS_DataReader reader,
    zzdds_loaned_sample *loan_out,
    zzdds_sample_info *info_out
);

void zzdds_return_loaned_raw(DDS_DataReader reader, zzdds_loaned_sample *loan);

#ifdef __cplusplus
}
#endif

#endif
