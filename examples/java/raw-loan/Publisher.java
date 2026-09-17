// java/raw-loan -- publisher. Direct Java port of
// zig/raw-loan/publisher.zig / c/raw-loan/src/publisher.c /
// cpp/raw-loan/src/publisher.cpp; see
// docs/design/raw-loan-reference-app.md at the repo root for the full
// spec. Bypasses TypeSupport marshaling entirely: every published sample
// goes through loan_raw() -> serialize into it -> publish_loan_raw(),
// instead of the generated typed DataWriter.write() a normal example
// would use. Also demonstrates the cancel path -- loan_raw() then
// return_loan_raw() without ever publishing.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// writer for topic:", "Publisher: published (loan) sequence=", "Publisher:
// cancelling loan for sequence=", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int SAMPLE_COUNT = 5;
    static final int CANCELLED_SEQ_NUM = -1;
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    // Serializes `value` into a plain heap buffer, growing (doubling +
    // retry) until it fits -- same technique the generated typed writer's
    // own toPayload() uses. There's no "counting" CDR writer mode in this
    // backend (unlike C's zidl_cdr), so this example can't serialize
    // directly into the loaned buffer the way c/raw-loan does -- it learns
    // the size first, then copies into the loan. Same honest gap
    // zig/raw-loan documents for the same underlying reason.
    static byte[] toPayload(Loaned_ping.LoanedPing value, int xcdrVersion) {
        int cap = 64;
        while (true) {
            java.nio.ByteBuffer buf = java.nio.ByteBuffer.allocate(cap).order(java.nio.ByteOrder.LITTLE_ENDIAN);
            try {
                if (xcdrVersion == 1) { buf.put((byte) 0x00); buf.put((byte) 0x01); buf.put((byte) 0x00); buf.put((byte) 0x00); }
                else { buf.put((byte) 0x00); buf.put((byte) 0x07); buf.put((byte) 0x00); buf.put((byte) 0x00); }
                value.serialize(buf, 4, xcdrVersion);
                byte[] out = new byte[buf.position()];
                buf.rewind();
                buf.get(out);
                return out;
            } catch (java.nio.BufferOverflowException e) {
                cap *= 2;
            }
        }
    }

    static java.util.List<Byte> toByteList(byte[] b) {
        java.util.ArrayList<Byte> l = new java.util.ArrayList<>(b.length);
        for (byte x : b) l.add(x);
        return l;
    }

    // Real write-loan path: loan_raw() -> copy the serialized payload into
    // the loaned buffer -> publish_loan_raw(). Returns true on success.
    static boolean publishLoaned(Dcps.DDS.DataWriter writer, Loaned_ping.LoanedPing value, int xcdrVersion) {
        byte[] payload = toPayload(value, xcdrVersion);
        java.nio.ByteBuffer loan = writer.loan_raw(payload.length);
        if (loan == null) return false;
        loan.put(payload);
        byte[] hash = value.computeKeyHash();
        int rc = writer.publish_loan_raw(loan, toByteList(hash), 0, Dcps.DDS.WriteKind.ALIVE_WRITE_KIND);
        return rc == Dcps.DDS.RETCODE_OK.value;
    }

    // Loan a buffer, serialize into it, then explicitly cancel instead of
    // publishing -- proves return_loan_raw() genuinely prevents the sample
    // from reaching the wire.
    static boolean loanAndCancel(Dcps.DDS.DataWriter writer, Loaned_ping.LoanedPing value, int xcdrVersion) {
        byte[] payload = toPayload(value, xcdrVersion);
        java.nio.ByteBuffer loan = writer.loan_raw(payload.length);
        if (loan == null) return false;
        loan.put(payload);
        int rc = writer.return_loan_raw(loan);
        return rc == Dcps.DDS.RETCODE_OK.value;
    }

    public static void main(String[] args) throws Exception {
        int domainId = parseDomain(args);

        Dcps.DDS.DomainParticipantFactory factory =
            (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (factory == null) {
            System.err.println("FAIL: createFactory() failed");
            System.exit(1);
        }

        Dcps.DDS.DomainParticipant dp = factory.create_participant(domainId, null, null, 0);
        if (dp == null) {
            System.err.println("FAIL: create_participant() failed on domain " + domainId);
            System.exit(1);
        }

        if (LoanedPingTypeSupport.register(dp, "LoanedPing") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("LoanedPing", "LoanedPing", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: LoanedPing");

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter rawWriter = pub.create_datawriter(topic, dwQos, null, 0);
        if (rawWriter == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: LoanedPing");

        final AtomicBoolean readerReady = new AtomicBoolean(false);
        final AtomicBoolean everMatched = new AtomicBoolean(false);
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);

        Zzdds.zzdds.DataWriter zdWriter =
            (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(rawWriter);
        if (zdWriter == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }

        Zzdds.zzdds.DataWriterListenerEx writerListener = new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) everMatched.set(true);
                System.out.println("on_publication_matched() current_count=" + s.get_current_count());
            }

            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) readerReady.set(true);
                System.out.println("on_reliable_reader_ready() is_ready=" + isReady);
            }
        };
        if (zdWriter.set_listener_ex(writerListener, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener_ex failed");
            System.exit(1);
        }

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // XCDR1, matching every other binding's PresenceBeacon/LoanedPing default.
        final int XCDR1 = 1;

        // -- Write-loan phase --
        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Loaned_ping.LoanedPing sample = new Loaned_ping.LoanedPing();
            sample.set_seq_num(seq);
            if (!publishLoaned(rawWriter, sample, XCDR1)) {
                System.err.println("FAIL: publishLoaned() failed at sequence=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: published (loan) sequence=" + seq);
        }

        // -- Cancel phase --
        Loaned_ping.LoanedPing cancelled = new Loaned_ping.LoanedPing();
        cancelled.set_seq_num(CANCELLED_SEQ_NUM);
        if (!loanAndCancel(rawWriter, cancelled, XCDR1)) {
            System.err.println("FAIL: loanAndCancel() failed");
            System.exit(1);
        }
        System.out.println("Publisher: cancelling loan for sequence=" + CANCELLED_SEQ_NUM + " (never published)");

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (!(everMatched.get() && matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // Every loan above was either published or explicitly cancelled --
        // an outstanding loan would make delete_datawriter fail with
        // PRECONDITION_NOT_MET.
        if (pub.delete_datawriter(rawWriter) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: delete_datawriter() did not return RETCODE_OK -- an outstanding loan leaked");
            System.exit(1);
        }

        System.out.println("Publisher: done.");
    }
}
