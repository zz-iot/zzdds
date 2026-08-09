// java/waitset -- publisher. Direct Java port of zig/waitset/publisher.zig
// / c/waitset/src/publisher.c / cpp/waitset/src/publisher.cpp; see
// docs/design/waitset-reference-app.md at the repo root for the full spec.
//
// Drives its whole lifecycle through a single WaitSet with two conditions
// attached at once, instead of a listener:
//
//   - StatusCondition (PUBLICATION_MATCHED_STATUS) -- reused across two
//     separate wait phases: first waiting for a reader to match, later
//     waiting for it to disconnect again.
//   - GuardCondition -- a background "watchdog" thread sets this if the
//     whole run exceeds its overall deadline. Real cross-thread concurrency
//     on the same WaitSet/GuardCondition -- the same exercise zig/waitset's
//     own watchdog demonstrates.
//
// Like C++, Java's condition interfaces (GuardCondition, StatusCondition,
// ReadCondition, QueryCondition) all extend Condition directly in the type
// system, so attach_condition(sc)/attach_condition(gc) just work -- no
// as_Condition()-style workaround needed.
//
// Like cpp/waitset and c/waitset, branches on each held condition's own
// get_trigger_value() directly rather than membership in wait()'s returned
// active_conditions list -- see cpp/waitset/publisher.cpp's comment for the
// full reasoning (a real, found-while-building identity gap in the C++
// binding specifically; unverified whether Java shares it, but consistent
// either way).
//
// After the run completes, delete_datawriter() is called WITHOUT first
// detaching the writer's StatusCondition from the WaitSet -- deliberately,
// to demonstrate that this is safe.
//
// Required stdout markers: "Create topic:", "Create writer for topic:",
// "Publisher: reader matched", "Publisher: wrote count=", "Publisher:
// reader disconnected", "Publisher: StatusCondition remained attached
// through delete_datawriter (safe).", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicBoolean;

public class Publisher {
    static final int SAMPLE_COUNT = 10;
    static final int WAIT_STEP_SEC = 1;
    static final int OVERALL_DEADLINE_MS = 25000;
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

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, null, 0);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: WaitsetSample");

        // ── WaitSet setup: StatusCondition + GuardCondition together ──

        Dcps.DDS.WaitSet ws = (Dcps.DDS.WaitSet) io.zzdds.runtime.ZzddsRuntime.createWaitSet();
        if (ws == null) {
            System.err.println("FAIL: createWaitSet() failed");
            System.exit(1);
        }

        Dcps.DDS.StatusCondition sc = dw.get_statuscondition();
        if (sc.set_enabled_statuses(Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_enabled_statuses() failed");
            System.exit(1);
        }
        if (ws.attach_condition(sc) != 0) {
            System.err.println("FAIL: attach_condition(StatusCondition) failed");
            System.exit(1);
        }

        Dcps.DDS.GuardCondition gc = (Dcps.DDS.GuardCondition) io.zzdds.runtime.ZzddsRuntime.createGuardCondition();
        if (gc == null) {
            System.err.println("FAIL: createGuardCondition() failed");
            System.exit(1);
        }
        if (ws.attach_condition(gc) != 0) {
            System.err.println("FAIL: attach_condition(GuardCondition) failed");
            System.exit(1);
        }

        Watchdog watchdog = new Watchdog(gc);
        Thread watchdogThread = new Thread(watchdog);
        watchdogThread.start();

        // ── Wait for a reader to match ──

        Dcps.DDS.Duration_t waitStep = new Dcps.DDS.Duration_t();
        waitStep.set_sec(WAIT_STEP_SEC);
        waitStep.set_nanosec(0);

        boolean matched = false;
        while (!matched) {
            ArrayList<Dcps.DDS.Condition> active = new ArrayList<>();
            int rc = ws.wait(active, waitStep);
            if (rc == Dcps.DDS.RETCODE_TIMEOUT.value) continue;
            if (rc != 0) {
                System.err.println("FAIL: WaitSet.wait() returned " + rc);
                System.exit(1);
            }
            if (gc.get_trigger_value()) {
                System.err.println("FAIL: watchdog fired before any reader matched");
                System.exit(1);
            }
            if (sc.get_trigger_value()) {
                Dcps.DDS.PublicationMatchedStatus status = new Dcps.DDS.PublicationMatchedStatus();
                dw.get_publication_matched_status(status);
                if (status.get_current_count() > 0) {
                    System.out.println("Publisher: reader matched");
                    matched = true;
                }
            }
        }

        // ── Write samples: priority = count ──

        WaitsetSampleDataWriter writer = new WaitsetSampleDataWriter(dw);
        for (int i = 0; i < SAMPLE_COUNT; i++) {
            Waitset_sample.WaitsetSample sample = new Waitset_sample.WaitsetSample();
            sample.set_count(i);
            sample.set_priority(i);
            sample.set_message("Hello waitset!");

            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at count=" + i);
                System.exit(1);
            }
            System.out.println("Publisher: wrote count=" + i + " priority=" + i);
        }

        // ── Wait for the reader to disconnect again ──

        boolean disconnected = false;
        while (!disconnected) {
            ArrayList<Dcps.DDS.Condition> active = new ArrayList<>();
            int rc = ws.wait(active, waitStep);
            if (rc == Dcps.DDS.RETCODE_TIMEOUT.value) continue;
            if (rc != 0) {
                System.err.println("FAIL: WaitSet.wait() returned " + rc);
                System.exit(1);
            }
            if (gc.get_trigger_value()) {
                System.err.println("FAIL: watchdog fired before the reader disconnected");
                System.exit(1);
            }
            if (sc.get_trigger_value()) {
                Dcps.DDS.PublicationMatchedStatus status = new Dcps.DDS.PublicationMatchedStatus();
                dw.get_publication_matched_status(status);
                if (status.get_current_count() == 0) {
                    System.out.println("Publisher: reader disconnected");
                    disconnected = true;
                }
            }
        }

        watchdog.stop.set(true);
        watchdogThread.join();

        // Well-behaved cleanup for the GuardCondition...
        ws.detach_condition(gc);
        // ...but the StatusCondition is deliberately left attached through
        // delete_datawriter() below, to demonstrate that this is safe.
        System.out.println("Publisher: StatusCondition remained attached through delete_datawriter (safe).");
        pub.delete_datawriter(dw);

        io.zzdds.runtime.ZzddsRuntime.destroyGuardCondition(gc);
        io.zzdds.runtime.ZzddsRuntime.destroyWaitSet(ws);

        System.out.println("Publisher: done.");
    }
}
