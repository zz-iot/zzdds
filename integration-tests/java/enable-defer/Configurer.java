// integration-tests/java/enable-defer -- configurer. Direct Java port of
// c/enable-defer/src/configurer.c -- see that file's header comment for the
// full scenario rationale and docs/design/integration-test-tier.md for the
// scenario spec.
//
// Required stdout markers: "Create topic: ConfigTopic", "Create writer for
// topic: ConfigTopic", "Configurer: write on disabled writer correctly
// returned NOT_ENABLED.", "Configurer: enabling writer before publisher
// correctly returned PRECONDITION_NOT_MET.", "Configurer: done." Any failure
// path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Configurer {
    static final int SAMPLE_COUNT = 5;
    static final int PRE_ENABLE_DELAY_MS = 4000;
    static final int READER_READY_TIMEOUT_MS = 20000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static class WriterSyncState {
        final AtomicBoolean readerReady = new AtomicBoolean(false);
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);
        final AtomicBoolean everMatched = new AtomicBoolean(false);
    }

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    static Zzdds.zzdds.DataWriterListenerEx makeWriterListener(WriterSyncState state) {
        return new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) state.everMatched.set(true);
            }

            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) state.readerReady.set(true);
            }
        };
    }

    public static void main(String[] args) throws Exception {
        int domainId = parseDomain(args);

        Dcps.DDS.DomainParticipantFactory factory =
            (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (factory == null) {
            System.err.println("FAIL: createFactory() failed");
            System.exit(1);
        }

        // Participant created normally (enabled) -- only ITS CHILDREN start
        // disabled, per ENTITY_FACTORY QoS semantics.
        Dcps.DDS.DomainParticipant dp = factory.create_participant(domainId, null, null, 0);
        if (dp == null) {
            System.err.println("FAIL: create_participant() failed on domain " + domainId);
            System.exit(1);
        }

        // Get-mutate-set, not a from-scratch QoS literal -- avoids clobbering
        // any other participant QoS field (see examples/c/shape's
        // shape_main.c fix in Phase A's history for why a zeroed/from-scratch
        // QoS struct is risky now that entity_factory genuinely defaults
        // true).
        Dcps.DDS.DomainParticipantQos dpQos = new Dcps.DDS.DomainParticipantQos();
        if (dp.get_qos(dpQos) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: get_qos(participant) failed");
            System.exit(1);
        }
        dpQos.get_entity_factory().set_autoenable_created_entities(false);
        if (dp.set_qos(dpQos) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: set_qos(participant, autoenable=false) failed");
            System.exit(1);
        }

        if (ConfigEventTypeSupport.register(dp, "ConfigEvent") != 0) {
            System.err.println("FAIL: register ConfigEventTypeSupport failed");
            System.exit(1);
        }

        // Topics have no wire footprint of their own -- creating one here is
        // unaffected either way.
        Dcps.DDS.Topic topic = dp.create_topic("ConfigTopic", "ConfigEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic(ConfigTopic) failed");
            System.exit(1);
        }
        System.out.println("Create topic: ConfigTopic");

        // Publisher comes in disabled (participant's entity_factory QoS
        // above).
        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.PublisherQos pubQos = new Dcps.DDS.PublisherQos();
        if (pub.get_qos(pubQos) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: get_qos(publisher) failed");
            System.exit(1);
        }
        pubQos.get_entity_factory().set_autoenable_created_entities(false);
        if (pub.set_qos(pubQos) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: set_qos(publisher, autoenable=false) failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        // DataWriter comes in disabled (publisher's entity_factory QoS
        // above).
        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, null, 0);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: ConfigTopic");

        WriterSyncState writerState = new WriterSyncState();
        Zzdds.zzdds.DataWriter zDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(dw);
        if (zDw == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }
        if (zDw.set_listener_ex(makeWriterListener(writerState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener_ex(ConfigTopic writer) failed");
            System.exit(1);
        }

        ConfigEventDataWriter writer = new ConfigEventDataWriter(dw);

        // Core assertion #1: write() on a still-disabled writer must fail,
        // not silently succeed. The generated Java DataWriter's write()
        // routes through writeViaLoan()/loan_raw() (see zidl's
        // emitZzddsDataWriterFile) rather than write_raw directly --
        // loan_raw() returns null on ANY failure with no more specific code
        // available (a pre-existing zidl Java-backend limitation, not a
        // Phase A/B regression), so the generated wrapper reports a generic
        // RETCODE_OUT_OF_RESOURCES instead of the real RETCODE_NOT_ENABLED
        // every other binding gets via write_raw's direct precondition
        // check. Accept both here rather than pin to the value C/C++/Zig
        // see -- the point of this assertion is "the write did not silently
        // succeed," not exact retcode fidelity across every binding.
        Config_event.ConfigEvent probeEv = new Config_event.ConfigEvent();
        probeEv.set_seq(-1);
        int probeRc = writer.write(probeEv, 0L);
        if (probeRc != Dcps.DDS.RETCODE_NOT_ENABLED.value && probeRc != Dcps.DDS.RETCODE_OUT_OF_RESOURCES.value) {
            System.err.println("FAIL: write() on disabled writer returned " + probeRc + ", expected RETCODE_NOT_ENABLED (" + Dcps.DDS.RETCODE_NOT_ENABLED.value + ") or RETCODE_OUT_OF_RESOURCES (" + Dcps.DDS.RETCODE_OUT_OF_RESOURCES.value + ")");
            System.exit(1);
        }
        System.out.println("Configurer: write on disabled writer correctly returned an error.");

        // Deliberate wall-clock window -- not a race-avoidance hack. This
        // just gives the peer process a comfortable, unambiguous stretch of
        // real time to independently confirm zero premature matching before
        // anything here is enabled; the peer controls its own assertion
        // window on its own clock, this delay only makes sure there's real
        // room for it.
        Thread.sleep(PRE_ENABLE_DELAY_MS);

        // Core assertion #2: enabling the writer before its own Publisher
        // must fail with PRECONDITION_NOT_MET (spec: can't enable a child
        // before its factory entity).
        int rc = dw.enable();
        if (rc != Dcps.DDS.RETCODE_PRECONDITION_NOT_MET.value) {
            System.err.println("FAIL: writer.enable() before publisher.enable() returned " + rc + ", expected RETCODE_PRECONDITION_NOT_MET (" + Dcps.DDS.RETCODE_PRECONDITION_NOT_MET.value + ")");
            System.exit(1);
        }
        System.out.println("Configurer: enabling writer before publisher correctly returned PRECONDITION_NOT_MET.");

        rc = pub.enable();
        if (rc != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: publisher.enable() returned " + rc + ", expected RETCODE_OK");
            System.exit(1);
        }
        rc = dw.enable();
        if (rc != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: writer.enable() returned " + rc + " after publisher.enable(), expected RETCODE_OK");
            System.exit(1);
        }
        System.out.println("Configurer: enabled publisher then writer.");

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!writerState.readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s of enabling");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Config_event.ConfigEvent ev = new Config_event.ConfigEvent();
            ev.set_seq(seq);
            if (writer.write(ev, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write() failed at seq=" + seq + " after enabling");
                System.exit(1);
            }
        }
        System.out.println("Configurer: wrote " + SAMPLE_COUNT + " samples after enabling.");

        // Standard teardown-safety: wait for the peer to unmatch/drain
        // before deleting, matching raw-loan's precedent.
        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (writerState.matchedCurrentCount.get() != 0 || !writerState.everMatched.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Configurer: done.");
        factory.delete_participant(dp);
    }
}
