/*
 * python/spike -- tiny C shim, NOT a Python binding.
 *
 * This whole directory is a throwaway probe for the "foreign-thread calls
 * into the GIL" and "ctx pointer lifetime" questions recorded in zidl's
 * roadmap ("Binding design review: interfaces vs. impls, inheritance, and
 * C-ABI identity"), before that review commits to a real Python backend
 * design. See README.md in this directory for what each probe script is
 * actually checking and why.
 *
 * ctypes can call zzdds's C-ABI directly for everything except two things
 * ctypes has no portable way to do from pure Python: (1) know the real
 * sizeof() of a QoS struct so a correctly-sized buffer can be allocated for
 * DDS_*Qos_default()/DDS_Subscriber_create_datareader() to read/write, and
 * (2) reach into a field nested several structs deep (DataReaderQos.deadline
 * .period.sec) without hand-replicating the ENTIRE preceding struct layout
 * in ctypes.Structure form just to compute an offset. Rather than
 * hand-replicate `dcps.h`'s ~13-field DDS_DataReaderQos in Python (exactly
 * the kind of brittle, easy-to-get-subtly-wrong busywork a real generated
 * Python backend would do mechanically and correctly), this shim does the
 * one or two struct-shaped things by compiling against the real header
 * instead -- letting the probe scripts focus on what they're actually
 * testing (GIL/callback/ctx behavior), not struct-layout archaeology.
 *
 * Deliberately NOT linked against libzzdds -- it only manipulates a struct
 * passed in by pointer and calls no DDS_* function itself, so it needs the
 * header for layout only, no symbols to resolve at link time.
 */
#include "dcps.h"

#include <stddef.h>

size_t spike_sizeof_reader_qos(void) {
    return sizeof(DDS_DataReaderQos);
}

void spike_set_reader_deadline(DDS_DataReaderQos *qos, int32_t sec, uint32_t nsec) {
    qos->deadline.period.sec = sec;
    qos->deadline.period.nanosec = nsec;
}

size_t spike_sizeof_writer_qos(void) {
    return sizeof(DDS_DataWriterQos);
}

void spike_set_writer_reliable_keep_all(DDS_DataWriterQos *qos) {
    qos->reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
}
