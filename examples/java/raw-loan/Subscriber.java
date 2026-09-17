// java/raw-loan -- subscriber. Direct Java port of
// zig/raw-loan/subscriber.zig / c/raw-loan/src/subscriber.c /
// cpp/raw-loan/src/subscriber.cpp; see
// docs/design/raw-loan-reference-app.md at the repo root for the full
// spec. Bypasses TypeSupport marshaling entirely: every sample is read
// via take_raw() in loan mode -> deserialize straight out of the borrowed
// bytes -> return_loan_raw(). Strict ordering check doubles as the
// assertion that the publisher's cancelled sample (see Publisher.java)
// never arrives.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// reader for topic:", "Subscriber: received (loan) sequence=",
// "Subscriber: received all N samples in order." Any failure path prints
// a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;

public class Subscriber {
    static final int SAMPLE_COUNT = 5;
    static final int RECEIVE_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    // Only ever touched from the listener's dispatch thread.
    static int expectedNext = 0;
    static final AtomicBoolean allReceived = new AtomicBoolean(false);

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    static void onDataAvailable(Dcps.DDS.DataReader reader) {
        for (;;) {
            // Empty lists on entry -> loan mode (the spec's own
            // inout-collection convention for "loan rather than copy").
            java.util.List<java.util.List<Byte>> payloads = new java.util.ArrayList<>();
            java.util.List<Byte> hashes = new java.util.ArrayList<>();
            java.util.List<Dcps.DDS.SampleInfo> infos = new java.util.ArrayList<>();
            java.nio.ByteBuffer[] loan = new java.nio.ByteBuffer[3];

            int rc = reader.take_raw(payloads, hashes, infos, Dcps.DDS.HANDLE_NIL.value, null,
                Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value,
                1, loan);
            if (rc != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: take_raw() returned " + rc);
                System.exit(1);
            }
            if (payloads.isEmpty()) break;

            Dcps.DDS.SampleInfo info = infos.get(0);
            if (info.get_valid_data()) {
                byte[] payload = new byte[payloads.get(0).size()];
                for (int i = 0; i < payload.length; i++) payload[i] = payloads.get(0).get(i);

                java.nio.ByteBuffer buf = java.nio.ByteBuffer.wrap(payload).order(java.nio.ByteOrder.LITTLE_ENDIAN);
                int id = ((payload[0] & 0xFF) << 8) | (payload[1] & 0xFF);
                int xcdrVersion = (id == 0x0001) ? 1 : (id == 0x0007) ? 2 : -1;
                if (xcdrVersion < 0) {
                    System.err.println("FAIL: unsupported CDR encapsulation id 0x" + Integer.toHexString(id));
                    System.exit(1);
                }
                buf.position(4);
                Loaned_ping.LoanedPing value = Loaned_ping.LoanedPing.deserializeFrom(buf, 4, xcdrVersion);

                if (value.get_seq_num() != expectedNext) {
                    System.err.println("FAIL: expected sequence=" + expectedNext + " but got sequence=" + value.get_seq_num());
                    System.exit(1);
                }
                System.out.println("Subscriber: received (loan) sequence=" + value.get_seq_num());
                expectedNext++;
                if (expectedNext == SAMPLE_COUNT) {
                    allReceived.set(true);
                }
            }

            if (reader.return_loan_raw(loan) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: return_loan_raw() failed");
                System.exit(1);
            }
        }
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

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) { onDataAvailable(r); }
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
        };

        Dcps.DDS.DataReader dr = sub.create_datareader(topic, drQos, listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value);
        if (dr == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: LoanedPing");

        System.out.println("Subscriber: waiting for " + SAMPLE_COUNT + " samples...");
        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (!allReceived.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: only received " + expectedNext + "/" + SAMPLE_COUNT + " samples within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // Tear the reader down immediately -- the publisher is blocked
        // waiting for our matched-reader count to drop back to zero.
        // Every loan above was released via return_loan_raw -- an
        // outstanding loan would make delete_datareader fail with
        // PRECONDITION_NOT_MET.
        if (sub.delete_datareader(dr) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: delete_datareader() did not return RETCODE_OK -- an outstanding loan leaked");
            System.exit(1);
        }

        System.out.println("Subscriber: received all " + SAMPLE_COUNT + " samples in order.");
    }
}
