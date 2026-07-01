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
#include "zzdds.h"

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

typedef struct zzdds_raw_sample {
    uint8_t *data;
    size_t data_len;
    zzdds_sample_info info;
} zzdds_raw_sample;

typedef struct zzdds_raw_sample_array {
    zzdds_raw_sample *samples;
    size_t count;
    size_t _alloc_capacity;
} zzdds_raw_sample_array;

typedef int (*zzdds_compute_key_hash_fn)(const uint8_t *payload, size_t len, uint8_t hash_out[16]);

zzdds_DomainParticipantFactory zzdds_create_factory(void);
bool zzdds_factory_is_nil(zzdds_DomainParticipantFactory factory);
void zzdds_destroy_factory(zzdds_DomainParticipantFactory factory);
DDS_DomainParticipantFactory zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(zzdds_DomainParticipantFactory factory);
zzdds_DomainParticipantFactory DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(DDS_DomainParticipantFactory factory);
DDS_DomainParticipant zzdds_DomainParticipant_as_DDS_DomainParticipant(zzdds_DomainParticipant participant);
/** NOTE: only valid for handles created by a zzdds FactoryOwner (zzdds_create_factory).
 *  Passing a handle from any other DDS implementation causes memory corruption. */
zzdds_DomainParticipant DDS_DomainParticipant_as_zzdds_DomainParticipant(DDS_DomainParticipant participant);
/** NOTE: only valid for topics owned by a zzdds FactoryOwner participant. */
zzdds_Topic DDS_Topic_as_zzdds_Topic(DDS_Topic topic);
DDS_Topic zzdds_Topic_as_DDS_Topic(zzdds_Topic topic);
DDS_DataWriter zzdds_DataWriter_as_DDS_DataWriter(zzdds_DataWriter writer);
/** NOTE: only valid for writers owned by a zzdds FactoryOwner participant. */
zzdds_DataWriter DDS_DataWriter_as_zzdds_DataWriter(DDS_DataWriter writer);
DDS_DataReader zzdds_DataReader_as_DDS_DataReader(zzdds_DataReader reader);
/** NOTE: only valid for readers owned by a zzdds FactoryOwner participant. */
zzdds_DataReader DDS_DataReader_as_zzdds_DataReader(DDS_DataReader reader);
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

DDS_InstanceHandle_t zzdds_register_instance_raw(DDS_DataWriter writer, const uint8_t key_hash[16]);

DDS_ReturnCode_t zzdds_write_raw_w_timestamp(
    DDS_DataWriter writer,
    zzdds_write_kind kind,
    const uint8_t key_hash[16],
    const uint8_t *data,
    size_t data_len,
    DDS_Time_t timestamp
);

int zzdds_get_key_value_writer(
    DDS_DataWriter writer,
    DDS_InstanceHandle_t handle,
    uint8_t *buf,
    size_t buf_size,
    size_t *len_out
);

DDS_InstanceHandle_t zzdds_lookup_instance_writer(DDS_DataWriter writer, const uint8_t key_hash[16]);

int zzdds_read_one_raw(
    DDS_DataReader reader,
    uint8_t *cdr_buf,
    size_t buf_size,
    size_t *cdr_len_out,
    zzdds_sample_info *info_out
);

int zzdds_read_one_raw_instance(
    DDS_DataReader reader,
    DDS_InstanceHandle_t prev,
    uint8_t *cdr_buf,
    size_t buf_size,
    size_t *cdr_len_out,
    zzdds_sample_info *info_out
);

int zzdds_take_n_raw(
    DDS_DataReader reader,
    uint32_t ss,
    uint32_t vs,
    uint32_t is,
    int max,
    zzdds_raw_sample_array *out
);

int zzdds_read_n_raw(
    DDS_DataReader reader,
    uint32_t ss,
    uint32_t vs,
    uint32_t is,
    int max,
    zzdds_raw_sample_array *out
);

void zzdds_return_raw_samples(DDS_DataReader reader, zzdds_raw_sample_array *arr);

int zzdds_get_key_value_reader(
    DDS_DataReader reader,
    DDS_InstanceHandle_t handle,
    uint8_t *buf,
    size_t buf_size,
    size_t *len_out
);

DDS_InstanceHandle_t zzdds_lookup_instance_reader(DDS_DataReader reader, const uint8_t key_hash[16]);

#ifdef __cplusplus
}
#endif

#endif
