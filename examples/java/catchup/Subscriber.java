// java/catchup -- subscriber (the late joiner). Direct Java port of
// zig/catchup/subscriber.zig / c/catchup/src/subscriber.c /
// cpp/catchup/src/subscriber.cpp; see docs/design/catchup-reference-app.md
// at the repo root for the full spec. Starts after the publisher has
// already written its full historical batch (enforced by the harness, not
// this app). Immediately after creating the reader, calls
// wait_for_historical_data() -- the API this whole example exists to
// exercise -- before taking anything, then confirms the full historical
// batch was in fact replayed by the time that call returns, then continues
// taking live samples as they arrive.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// reader for topic:", "Subscriber: wait_for_historical_data() returned",
// "HISTORICAL BATCH COMPLETE (10 samples)", "LIVE SAMPLE seq_num=",
// "Subscriber: observed historical batch then live batch correctly." Any
// failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;

public class Subscriber {
    static final int HISTORICAL_COUNT = 10;
    static final int LIVE_COUNT = 5;
    static final int HISTORICAL_WAIT_TIMEOUT_S = 10;
    static final int RECEIVE_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    // Pure readiness check -- does NOT set allDone itself. Callers decide
    // when it's safe to actually commit the flag: main() deletes the
    // reader as soon as it observes allDone, so setting it while
    // on_data_available is still inside its take loop would let
    // delete_datareader() race that same invocation's next take() call.
    static boolean readyToFinish(AtomicBoolean historicalConfirmed, AtomicBoolean[] liveReceived) {
        if (!historicalConfirmed.get()) return false;
        for (AtomicBoolean v : liveReceived) {
            if (!v.get()) return false;
        }
        return true;
    }

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
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

        if (HistoryEventTypeSupport.register(dp, "HistoryEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("HistoryEvent", "HistoryEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: HistoryEvent");

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_durability().set_kind(Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        final Object[] readerBox = new Object[1]; // set right after create_datareader
        // AtomicBoolean, not plain boolean[] -- these are written by the
        // listener-dispatch thread and read by main() (after
        // wait_for_historical_data() returns) and by the listener thread
        // itself (checkAllDone()); plain array elements have no Java Memory
        // Model visibility guarantee across threads without real
        // synchronization, unlike a mutex-backed native call.
        final AtomicBoolean[] historicalReceived = new AtomicBoolean[HISTORICAL_COUNT];
        final AtomicBoolean[] liveReceived = new AtomicBoolean[LIVE_COUNT];
        for (int i = 0; i < HISTORICAL_COUNT; i++) historicalReceived[i] = new AtomicBoolean(false);
        for (int i = 0; i < LIVE_COUNT; i++) liveReceived[i] = new AtomicBoolean(false);
        final AtomicBoolean historicalConfirmed = new AtomicBoolean(false);
        final AtomicBoolean allDone = new AtomicBoolean(false);

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                HistoryEventDataReader reader = (HistoryEventDataReader) readerBox[0];
                // Deferred, not set directly inside the loop below: main()
                // deletes the reader as soon as it observes allDone, so
                // setting it mid-loop would let main()'s
                // delete_datareader() race this same invocation's next
                // take() call. Only commit the flag once this invocation's
                // take loop has fully drained and won't touch the reader
                // again.
                //
                // main() can also independently reach the same conclusion
                // (see readyToFinish() right after wait_for_historical_data()
                // returns below) and call delete_datareader() while this
                // invocation is still draining regardless. That's still
                // fine: zzdds's core EntityQuiesce mechanism (not anything
                // in this file) guarantees a delete_datareader() racing an
                // in-flight take() call is memory-safe -- the racing take()
                // either completes normally (started before teardown) or
                // cleanly sees "no data" (started after), never a crash.
                boolean becameDone = false;
                HistoryEventDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    if (!sample.validData) continue;
                    int seqNum = sample.data.get_seq_num();
                    if (seqNum >= 0 && seqNum < HISTORICAL_COUNT) {
                        historicalReceived[seqNum].set(true);
                    } else if (seqNum >= HISTORICAL_COUNT && seqNum < HISTORICAL_COUNT + LIVE_COUNT) {
                        System.out.println("LIVE SAMPLE seq_num=" + seqNum);
                        liveReceived[seqNum - HISTORICAL_COUNT].set(true);
                        if (!allDone.get() && !becameDone && readyToFinish(historicalConfirmed, liveReceived)) {
                            becameDone = true;
                        }
                    } else {
                        System.err.println("FAIL: unexpected seq_num=" + seqNum);
                        System.exit(1);
                    }
                }
                if (becameDone) {
                    allDone.set(true);
                }
            }
        };

        // Create with no listener attached yet: on_data_available fires on
        // a zzdds-internal dispatch thread as soon as the reader matches
        // the publisher's already-written historical batch, which can race
        // readerBox[0]'s own assignment below (a real, not hypothetical,
        // race given this example's whole point is data being ready before
        // the reader even exists). Attach the listener only once
        // readerBox[0] is set, via set_listener() below, closing the
        // window entirely.
        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, null, 0);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: HistoryEvent");

        readerBox[0] = new HistoryEventDataReader(rawReader);
        if (rawReader.set_listener(listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        // The API this whole example exists to exercise: block until the
        // TRANSIENT_LOCAL historical replay has actually landed, before
        // taking anything.
        Dcps.DDS.Duration_t maxWait = new Dcps.DDS.Duration_t();
        maxWait.set_sec(HISTORICAL_WAIT_TIMEOUT_S);
        maxWait.set_nanosec(0);
        int rc = rawReader.wait_for_historical_data(maxWait);
        if (rc != 0) {
            System.err.println("FAIL: wait_for_historical_data() returned " + rc);
            System.exit(1);
        }
        System.out.println("Subscriber: wait_for_historical_data() returned");

        // Confirm the real guarantee, not just the return code: every
        // historical sample must already have been delivered by now.
        // (Read on the main thread only after wait_for_historical_data()
        // returned -- zzdds's own internal locking on that call path
        // establishes a real happens-before with the listener's writes.)
        int historicalCount = 0;
        for (AtomicBoolean v : historicalReceived) {
            if (v.get()) historicalCount++;
        }
        if (historicalCount != HISTORICAL_COUNT) {
            System.err.println("FAIL: wait_for_historical_data() returned OK but only " + historicalCount + "/" + HISTORICAL_COUNT + " historical samples were actually received");
            System.exit(1);
        }
        System.out.println("HISTORICAL BATCH COMPLETE (" + HISTORICAL_COUNT + " samples)");
        historicalConfirmed.set(true);
        // readyToFinish() only gets re-evaluated when a *new* live sample
        // arrives on the listener thread -- if every live sample already
        // arrived (and each check found historicalConfirmed still false)
        // before this line ran, nothing would ever re-check again. Mirror
        // the same check here.
        if (readyToFinish(historicalConfirmed, liveReceived)) {
            allDone.set(true);
        }

        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (!allDone.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: did not observe the full live batch within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        sub.delete_datareader(rawReader);

        System.out.println("Subscriber: observed historical batch then live batch correctly.");
    }
}
