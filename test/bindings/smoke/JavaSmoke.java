// Java binding smoke test — unlike c_smoke.c/cpp_smoke.cpp/zig_smoke.zig
// (which only round-trip CDR against a NULL writer/reader), this one is a
// genuine end-to-end run: two real DomainParticipants, real UDP-based
// SPDP/SEDP discovery, a DataReaderListener registered from Java whose
// callbacks fire on zzdds's own background network thread, and a real
// sample written and read back. The Java JNI bridge's failure modes (entity
// box/unbox, QoS/status struct marshaling, listener upcalls) only show up
// under real execution, not by inspecting generated source — see zidl's
// Java backend history for the bugs this exact shape of test caught.
//
// Compiled and run by `zig build -Djava-binding=true test-bindings`.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class JavaSmoke {
    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Java binding smoke test:");

        Dcps.DDS.DomainParticipantFactory factory =
            (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
        check(factory != null, "createFactory() returned non-null");

        Dcps.DDS.DomainParticipant dpWriter = factory.create_participant(0, null, null, 0);
        Dcps.DDS.DomainParticipant dpReader = factory.create_participant(0, null, null, 0);
        check(dpWriter != null && dpReader != null, "create_participant() returned non-null");

        check(BindingSmokeStatusTypeSupport.register(dpWriter, null) == 0, "TypeSupport.register (writer side)");
        check(BindingSmokeStatusTypeSupport.register(dpReader, null) == 0, "TypeSupport.register (reader side)");

        Dcps.DDS.Topic topicWriter = dpWriter.create_topic("JavaSmokeTopic", "BindingSmokeStatus", null, null, 0);
        Dcps.DDS.Topic topicReader = dpReader.create_topic("JavaSmokeTopic", "BindingSmokeStatus", null, null, 0);
        check(topicWriter != null && topicReader != null, "create_topic() returned non-null");

        Dcps.DDS.Publisher publisher = dpWriter.create_publisher(null, null, 0);
        Dcps.DDS.Subscriber subscriber = dpReader.create_subscriber(null, null, 0);
        check(publisher != null && subscriber != null, "create_publisher/create_subscriber() returned non-null");

        // RELIABLE on both sides: this test's whole point is "can we
        // reliably get the data", and a RELIABLE reader can't match a
        // BEST_EFFORT writer at all (QoS offered/requested incompatibility)
        // — see zzdds/src/dcps/qos_match.zig.
        Dcps.DDS.DataWriterQos writerQos = new Dcps.DDS.DataWriterQos();
        publisher.get_default_datawriter_qos(writerQos);
        writerQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);

        Dcps.DDS.DataWriter rawWriter = publisher.create_datawriter(topicWriter, writerQos, null, 0);
        check(rawWriter != null, "create_datawriter() returned non-null");

        // Narrow to zzdds's own extension view to reach set_listener_ex —
        // same underlying writer, see ZzddsRuntime.asZzddsDataWriter's javadoc.
        Zzdds.zzdds.DataWriter zdWriter =
            (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(rawWriter);
        check(zdWriter != null, "asZzddsDataWriter() returned non-null");

        final CountDownLatch readerReady = new CountDownLatch(1);
        final CountDownLatch dataAvailable = new CountDownLatch(1);

        // Protocol-ready RELIABLE readiness signal — deliberately not
        // on_publication_matched (fires on bare SEDP discovery, before the
        // reader can actually receive anything reliably). See
        // zzdds/idl/zzdds.idl's DataWriterListenerEx doc comment.
        Zzdds.zzdds.DataWriterListenerEx writerListener = new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}
            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {}
            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) readerReady.countDown();
            }
        };
        check(zdWriter.set_listener_ex(writerListener, 0xFFFFFFFF) == 0, "set_listener_ex() rc == 0");

        Dcps.DDS.DataReaderQos readerQos = new Dcps.DDS.DataReaderQos();
        subscriber.get_default_datareader_qos(readerQos);
        readerQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) { dataAvailable.countDown(); }
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
        };

        Dcps.DDS.DataReader rawReader = subscriber.create_datareader(topicReader, readerQos, listener, 0xFFFFFFFF);
        check(rawReader != null, "create_datareader() returned non-null");

        check(readerReady.await(20, TimeUnit.SECONDS), "on_reliable_reader_ready fired within 20s (real UDP discovery + RELIABLE handshake)");
        System.out.println("  reliable reader ready: OK");

        BindingSmokeStatusDataWriter writer = new BindingSmokeStatusDataWriter(rawWriter);
        BindingSmokeStatusDataReader reader = new BindingSmokeStatusDataReader(rawReader);

        Binding_smoke.BindingSmokeStatus sample = new Binding_smoke.BindingSmokeStatus();
        sample.set_id(7);
        sample.set_count(42);
        sample.set_label("java-smoke");

        check(writer.write(sample, 0L) == 0, "writer.write() rc == 0");

        check(dataAvailable.await(10, TimeUnit.SECONDS), "on_data_available fired within 10s");
        System.out.println("  listener fired: OK");

        BindingSmokeStatusDataReader.Sample got = null;
        for (int i = 0; i < 50 && got == null; i++) {
            got = reader.take();
            if (got == null) Thread.sleep(100);
        }
        check(got != null, "reader.take() returned a sample");
        check(got.validData, "sample has valid data");
        check(got.data.get_id() == 7, "id round-tripped");
        check(got.data.get_count() == 42, "count round-tripped");
        check("java-smoke".equals(got.data.get_label()), "label round-tripped");
        System.out.println("  round-tripped sample: id=" + got.data.get_id()
            + " count=" + got.data.get_count() + " label=" + got.data.get_label());

        // Sanity/link-level regression guard for zidl PR #39's Greptile
        // MUST-FIX (StatusCondition.get_entity() returning a bare DDS.Entity
        // instead of the real concrete type) and the zzdds-side companion
        // fix it required (extensions.zig's DDS_Entity_as_DDS_* checked
        // downcasts -- previously declared in dcps.h but never defined,
        // caught as an UnsatisfiedLinkError at JNI load, not a compile
        // error). dpWriter's handle is already cache-populated (by
        // create_participant's own concrete box) by the time get_entity()
        // runs here, so this specific call doesn't exercise the
        // first-ever-box-through-the-bare-type miss the bug actually needed
        // -- verified separately via a GC/weak-ref-forced cache-miss
        // reproduction (deliberately re-broken and confirmed to throw
        // ClassCastException, then confirmed fixed), not committed here
        // since it's inherently GC-timing-dependent. This check still earns
        // its place: it's what actually caught the real DDS_Entity_as_DDS_*
        // link failure above, and confirms the Entity-family narrowing
        // conversions are wired correctly end-to-end.
        Dcps.DDS.StatusCondition sc = dpWriter.get_statuscondition();
        check(sc != null, "get_statuscondition() returned non-null");
        Dcps.DDS.Entity entityView = sc.get_entity();
        check(entityView != null, "StatusCondition.get_entity() returned non-null");
        Dcps.DDS.DomainParticipant dpFromEntity = (Dcps.DDS.DomainParticipant) entityView;
        check(dpFromEntity == dpWriter, "get_entity() boxed the SAME identity-cached DomainParticipant, not a bare Entity");
        System.out.println("  StatusCondition.get_entity() most-derived box: OK");

        System.out.println("All Java binding smoke checks passed.");
    }
}
