// java/waitset -- subscriber. Direct Java port of
// zig/waitset/subscriber.zig / c/waitset/src/subscriber.c /
// cpp/waitset/src/subscriber.cpp; see docs/design/waitset-reference-app.md
// at the repo root for the full spec.
//
// One WaitSet, four conditions attached simultaneously:
//
//   - StatusCondition (SUBSCRIPTION_MATCHED_STATUS) -- logs the match.
//   - QueryCondition ("priority > %0", param "4") -- real attach/trigger/
//     query-expression/parameters exercise. Drained via the generated
//     WaitsetSampleDataReader.take_w_condition (what the OMG spec calls
//     take_w_condition, and part of the typed DataReader's implicit IDL on
//     every binding -- see zidl's roadmap for the fuller writeup on closing
//     this gap). QueryCondition satisfies ReadCondition directly via Java's
//     own interface inheritance -- no upcast needed, unlike C/C++'s
//     as_ReadCondition()/native_handle() dance.
//   - ReadCondition (any sample/view/instance state) -- same trigger
//     condition as QueryCondition above.
//   - GuardCondition -- same watchdog-thread pattern as the publisher.
//
// Like publisher.java, branches on each held condition's own
// get_trigger_value() directly rather than membership in wait()'s returned
// active_conditions list.
//
// Required stdout markers: "Create topic:", "Create reader for topic:",
// "Subscriber: writer matched", "Subscriber: high-priority count=",
// "Subscriber: low-priority count=", "Subscriber: received all 10
// samples.", "Subscriber: done." Any failure path prints a line starting
// "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;

public class Subscriber {
    static final int EXPECTED_SAMPLES = 10;
    static final String HIGH_PRIORITY_THRESHOLD = "4"; // priority > 4 => count 5..9
    static final int WAIT_STEP_SEC = 1;
    static final int OVERALL_DEADLINE_MS = 30000;
    static final int WATCHDOG_POLL_MS = 50;

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    static class Watchdog implements Runnable {
        final Dcps.DDS.GuardCondition gc;
        final AtomicBoolean stop = new AtomicBoolean(false);

        Watchdog(Dcps.DDS.GuardCondition gc) { this.gc = gc; }

        public void run() {
            int elapsedMs = 0;
            while (!stop.get()) {
                if (elapsedMs >= OVERALL_DEADLINE_MS) {
                    System.out.println("Watchdog: overall deadline exceeded, triggering GuardCondition");
                    gc.set_trigger_value(true);
                    return;
                }
                try {
                    Thread.sleep(WATCHDOG_POLL_MS);
                } catch (InterruptedException e) {
                    return;
                }
                elapsedMs += WATCHDOG_POLL_MS;
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

        // Unlike hello_world, this registration's get_field callback
        // actually matters here -- the QueryCondition's "priority > %0"
        // expression needs field-level access to evaluate.
        if (WaitsetSampleTypeSupport.register(dp, "WaitsetSample") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("WaitsetSample", "WaitsetSample", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: WaitsetSample");

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        // Topic extends TopicDescription directly in Java's interface
        // hierarchy (unlike C++, which needs an explicit upcast) -- no
        // conversion needed.
        Dcps.DDS.DataReader dr = sub.create_datareader(topic, drQos, null, 0);
        if (dr == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: WaitsetSample");

        // ── WaitSet setup: all four condition types on one WaitSet ──

        Dcps.DDS.WaitSet ws = (Dcps.DDS.WaitSet) io.zzdds.runtime.ZzddsRuntime.createWaitSet();
        if (ws == null) {
            System.err.println("FAIL: createWaitSet() failed");
            System.exit(1);
        }

        Dcps.DDS.StatusCondition sc = dr.get_statuscondition();
        if (sc.set_enabled_statuses(Dcps.DDS.SUBSCRIPTION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_enabled_statuses() failed");
            System.exit(1);
        }

        Dcps.DDS.ReadCondition rcCond = dr.create_readcondition(
            Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        if (rcCond == null) {
            System.err.println("FAIL: create_readcondition() failed");
            System.exit(1);
        }

        Dcps.DDS.QueryCondition qcCond = dr.create_querycondition(
            Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value,
            "priority > %0", Arrays.asList(HIGH_PRIORITY_THRESHOLD));
        if (qcCond == null) {
            System.err.println("FAIL: create_querycondition() failed");
            System.exit(1);
        }

        Dcps.DDS.GuardCondition gc = (Dcps.DDS.GuardCondition) io.zzdds.runtime.ZzddsRuntime.createGuardCondition();
        if (gc == null) {
            System.err.println("FAIL: createGuardCondition() failed");
            System.exit(1);
        }

        if (ws.attach_condition(sc) != 0 ||
            ws.attach_condition(rcCond) != 0 ||
            ws.attach_condition(qcCond) != 0 ||
            ws.attach_condition(gc) != 0)
        {
            System.err.println("FAIL: attach_condition() failed");
            System.exit(1);
        }

        Watchdog watchdog = new Watchdog(gc);
        Thread watchdogThread = new Thread(watchdog);
        watchdogThread.start();

        // ── Main loop: wait, branch on which conditions triggered ──

        WaitsetSampleDataReader reader = new WaitsetSampleDataReader(dr);
        Dcps.DDS.Duration_t waitStep = new Dcps.DDS.Duration_t();
        waitStep.set_sec(WAIT_STEP_SEC);
        waitStep.set_nanosec(0);

        int received = 0;
        boolean matchedLogged = false;
        while (received < EXPECTED_SAMPLES) {
            ArrayList<Dcps.DDS.Condition> active = new ArrayList<>();
            int wr = ws.wait(active, waitStep);
            if (wr == Dcps.DDS.RETCODE_TIMEOUT.value) continue;
            if (wr != 0) {
                System.err.println("FAIL: WaitSet.wait() returned " + wr);
                System.exit(1);
            }
            if (gc.get_trigger_value()) {
                System.err.println("FAIL: watchdog fired -- only received " + received + "/" + EXPECTED_SAMPLES + " samples");
                System.exit(1);
            }
            if (!matchedLogged && sc.get_trigger_value()) {
                Dcps.DDS.SubscriptionMatchedStatus status = new Dcps.DDS.SubscriptionMatchedStatus();
                dr.get_subscription_matched_status(status);
                if (status.get_current_count() > 0) {
                    System.out.println("Subscriber: writer matched");
                    matchedLogged = true;
                }
            }

            boolean queryTriggered = qcCond.get_trigger_value();
            boolean readTriggered = rcCond.get_trigger_value();
            if (!queryTriggered && !readTriggered) continue;

            // Drain the high-priority subset first via take_w_condition,
            // then whatever's left via a plain take_n. These are two
            // separate calls, each independently locking/unlocking the
            // reader -- a sample can arrive (from the RTPS receive thread)
            // in the gap between them, missing the first (query) take and
            // getting swept up by the second (unfiltered) one. Confirmed as
            // a real, reproducible race in zig/waitset (not just in
            // theory): a high-priority sample occasionally printed as
            // "low-priority" (still correctly *received*, just mislabeled)
            // despite take_w_condition's own filtering being correct at the
            // instant it ran. So: still call both -- take_w_condition is
            // still genuinely exercised, and still does the real draining
            // -- but decide the *label* from each sample's own
            // already-deserialized `priority` field rather than trusting
            // which call it came from.
            WaitsetSampleDataReader.Sample[] highSamples = reader.take_w_condition(qcCond, EXPECTED_SAMPLES);
            WaitsetSampleDataReader.Sample[] lowSamples = reader.take_n(
                EXPECTED_SAMPLES, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (WaitsetSampleDataReader.Sample s : highSamples) {
                if (!s.validData) continue;
                if (s.data.get_priority() > 4) {
                    System.out.println("Subscriber: high-priority count=" + s.data.get_count() + " priority=" + s.data.get_priority());
                } else {
                    System.out.println("Subscriber: low-priority count=" + s.data.get_count() + " priority=" + s.data.get_priority());
                }
                received++;
            }
            for (WaitsetSampleDataReader.Sample s : lowSamples) {
                if (!s.validData) continue;
                if (s.data.get_priority() > 4) {
                    System.out.println("Subscriber: high-priority count=" + s.data.get_count() + " priority=" + s.data.get_priority());
                } else {
                    System.out.println("Subscriber: low-priority count=" + s.data.get_count() + " priority=" + s.data.get_priority());
                }
                received++;
            }
        }

        System.out.println("Subscriber: received all " + EXPECTED_SAMPLES + " samples.");

        watchdog.stop.set(true);
        watchdogThread.join();

        // Well-behaved cleanup: detach and delete every condition explicitly
        // before tearing the reader down (contrast with publisher.java,
        // which deliberately does *not* do this for its StatusCondition).
        ws.detach_condition(sc);
        ws.detach_condition(rcCond);
        ws.detach_condition(qcCond);
        ws.detach_condition(gc);
        dr.delete_readcondition(rcCond);
        dr.delete_readcondition(qcCond);
        sub.delete_datareader(dr);

        io.zzdds.runtime.ZzddsRuntime.destroyGuardCondition(gc);
        io.zzdds.runtime.ZzddsRuntime.destroyWaitSet(ws);

        System.out.println("Subscriber: done.");
    }
}
