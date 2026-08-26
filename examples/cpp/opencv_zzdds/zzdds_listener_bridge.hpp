/*
 * zzdds_listener_bridge.hpp
 *
 * C++ base classes for DDS listener callbacks.
 *
 * The zzdds C ABI exposes listeners as C structs containing function pointers
 * and a void* user-data cookie.  This header provides thin C++ base classes
 * that let application code subclass and override only the callbacks it cares
 * about — the rest default to no-ops.  Call c_listener() to obtain the
 * DDS_*Listener struct required by the create_datawriter / create_datareader
 * functions.
 *
 * Lifetime: the DDS_*Listener struct returned by c_listener() points back into
 * this object.  The listener must outlive the entity it is attached to.
 */

#pragma once
#include "dcps.h"

// ── DataWriter listener ────────────────────────────────────────────────────

class DataWriterListenerBase {
public:
    virtual ~DataWriterListenerBase() = default;

    virtual void on_offered_deadline_missed(DDS_DataWriter, const DDS_OfferedDeadlineMissedStatus&) {}
    virtual void on_offered_incompatible_qos(DDS_DataWriter, const DDS_OfferedIncompatibleQosStatus&) {}
    virtual void on_liveliness_lost(DDS_DataWriter, const DDS_LivelinessLostStatus&) {}
    virtual void on_publication_matched(DDS_DataWriter, const DDS_PublicationMatchedStatus&) {}

    DDS_DataWriterListener c_listener() noexcept {
        return {
            this,
            s_on_offered_deadline_missed,
            s_on_offered_incompatible_qos,
            s_on_liveliness_lost,
            s_on_publication_matched,
        };
    }

private:
    static void s_on_offered_deadline_missed(DDS_DataWriter w, const DDS_OfferedDeadlineMissedStatus* s, void* d) {
        static_cast<DataWriterListenerBase*>(d)->on_offered_deadline_missed(w, *s);
    }
    static void s_on_offered_incompatible_qos(DDS_DataWriter w, const DDS_OfferedIncompatibleQosStatus* s, void* d) {
        static_cast<DataWriterListenerBase*>(d)->on_offered_incompatible_qos(w, *s);
    }
    static void s_on_liveliness_lost(DDS_DataWriter w, const DDS_LivelinessLostStatus* s, void* d) {
        static_cast<DataWriterListenerBase*>(d)->on_liveliness_lost(w, *s);
    }
    static void s_on_publication_matched(DDS_DataWriter w, const DDS_PublicationMatchedStatus* s, void* d) {
        static_cast<DataWriterListenerBase*>(d)->on_publication_matched(w, *s);
    }
};

// ── DataReader listener ────────────────────────────────────────────────────

class DataReaderListenerBase {
public:
    virtual ~DataReaderListenerBase() = default;

    virtual void on_requested_deadline_missed(DDS_DataReader, const DDS_RequestedDeadlineMissedStatus&) {}
    virtual void on_requested_incompatible_qos(DDS_DataReader, const DDS_RequestedIncompatibleQosStatus&) {}
    virtual void on_sample_rejected(DDS_DataReader, const DDS_SampleRejectedStatus&) {}
    virtual void on_liveliness_changed(DDS_DataReader, const DDS_LivelinessChangedStatus&) {}
    virtual void on_data_available(DDS_DataReader) {}
    virtual void on_subscription_matched(DDS_DataReader, const DDS_SubscriptionMatchedStatus&) {}
    virtual void on_sample_lost(DDS_DataReader, const DDS_SampleLostStatus&) {}

    DDS_DataReaderListener c_listener() noexcept {
        return {
            this,
            s_on_requested_deadline_missed,
            s_on_requested_incompatible_qos,
            s_on_sample_rejected,
            s_on_liveliness_changed,
            s_on_data_available,
            s_on_subscription_matched,
            s_on_sample_lost,
        };
    }

private:
    static void s_on_requested_deadline_missed(DDS_DataReader r, const DDS_RequestedDeadlineMissedStatus* s, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_requested_deadline_missed(r, *s);
    }
    static void s_on_requested_incompatible_qos(DDS_DataReader r, const DDS_RequestedIncompatibleQosStatus* s, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_requested_incompatible_qos(r, *s);
    }
    static void s_on_sample_rejected(DDS_DataReader r, const DDS_SampleRejectedStatus* s, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_sample_rejected(r, *s);
    }
    static void s_on_liveliness_changed(DDS_DataReader r, const DDS_LivelinessChangedStatus* s, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_liveliness_changed(r, *s);
    }
    static void s_on_data_available(DDS_DataReader r, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_data_available(r);
    }
    static void s_on_subscription_matched(DDS_DataReader r, const DDS_SubscriptionMatchedStatus* s, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_subscription_matched(r, *s);
    }
    static void s_on_sample_lost(DDS_DataReader r, const DDS_SampleLostStatus* s, void* d) {
        static_cast<DataReaderListenerBase*>(d)->on_sample_lost(r, *s);
    }
};
