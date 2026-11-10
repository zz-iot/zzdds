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

import java.lang.ref.WeakReference;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class JavaSmoke {
    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    // On the shared runtime one listener identity runs one invocation at a
    // time wherever it is installed. A Java listener object set on two
    // readers must be one identity: while its callback for one reader is
    // blocked, its callback for the other must wait, not run alongside. With
    // a native context per registration (one identity each), it would.
    static void checkOneIdentity(Zzdds.zzdds.Subscriber zdSubscriber, Dcps.DDS.Topic topic,
                                 Dcps.DDS.DataReaderQos qos, BindingSmokeStatusDataWriter writer,
                                 Binding_smoke.BindingSmokeStatus sample) throws Exception {
        final CountDownLatch ready = new CountDownLatch(2);
        final CountDownLatch firstEntered = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final CountDownLatch secondEntered = new CountDownLatch(1);
        final AtomicBoolean first = new AtomicBoolean(true);
        final AtomicInteger active = new AtomicInteger();
        final AtomicBoolean overlapped = new AtomicBoolean(false);

        Zzdds.zzdds.DataReaderListenerEx shared = new Zzdds.zzdds.DataReaderListenerEx() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {
                if (active.incrementAndGet() > 1) overlapped.set(true);
                try {
                    if (first.getAndSet(false)) {
                        firstEntered.countDown();
                        release.await(10, TimeUnit.SECONDS);
                    } else {
                        secondEntered.countDown();
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    active.decrementAndGet();
                }
            }
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
            public void on_reliable_writer_ready(int writerHandle, boolean isReady) {
                if (isReady) ready.countDown();
            }
        };
        Dcps.DDS.DataReader a = zdSubscriber.create_datareader_ex(topic, qos, shared, 0xFFFFFFFF);
        Dcps.DDS.DataReader b = zdSubscriber.create_datareader_ex(topic, qos, shared, 0xFFFFFFFF);
        check(a != null && b != null, "create_datareader_ex() of two readers sharing a listener returned non-null");
        check(ready.await(20, TimeUnit.SECONDS), "both readers sharing a listener became reliable-ready within 20s");

        check(writer.write(sample, 0L) == 0, "writer.write() to the readers sharing a listener rc == 0");
        check(firstEntered.await(10, TimeUnit.SECONDS), "the shared listener's first on_data_available fired within 10s");
        // The other reader's callback is due now; it must not start while
        // the first is blocked.
        check(!secondEntered.await(1, TimeUnit.SECONDS), "the shared listener ran for the second reader while blocked for the first");
        release.countDown();
        check(secondEntered.await(10, TimeUnit.SECONDS), "the shared listener ran for the second reader once the first returned");
        check(!overlapped.get(), "the shared listener's callbacks never overlapped");

        Dcps.DDS.Subscriber subscriber = a.get_subscriber();
        check(subscriber.delete_datareader(a) == 0, "delete_datareader(a) rc == 0");
        check(subscriber.delete_datareader(b) == 0, "delete_datareader(b) rc == 0");
    }

    // A call that registers a listener and fails leaves the registration with
    // the caller, so the binding must drop the reference it took on the
    // listener. set_listener and set_listener_ex on a writer whose deletion has
    // begun return ALREADY_DELETED from the core. On the shared runtime,
    // deleting a writer waits for its running callback before retiring the
    // wrapper, so a call from that callback still reaches the core. The
    // callback retries until the core rejects; each rejected listener must
    // then be collectable. (A writer, since Java reaches set_listener_ex only
    // through ZzddsRuntime.asZzddsDataWriter; the C++ test covers a reader.)
    static class Probe implements Dcps.DDS.DataWriterListener {
        public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
        public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
        public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}
        public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {}
    }

    static class ProbeEx extends Probe implements Zzdds.zzdds.DataWriterListenerEx {
        public void on_reliable_reader_ready(int readerHandle, boolean isReady) {}
    }

    static final class Rejection {
        final CountDownLatch entered = new CountDownLatch(1);
        final CountDownLatch deleting = new CountDownLatch(1);
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicBoolean first = new AtomicBoolean(true);
        volatile Zzdds.zzdds.DataWriter writer;
        volatile int plainRc = -1;
        volatile int exRc = -1;
        final WeakReference<?>[] plainRejected = new WeakReference<?>[1];
        final WeakReference<?>[] exRejected = new WeakReference<?>[1];
    }

    // The probe is reachable only through `rejected` and the binding once this returns.
    static int setProbe(Zzdds.zzdds.DataWriter w, boolean ex, WeakReference<?>[] rejected) {
        int mask = Dcps.DDS.PUBLICATION_MATCHED_STATUS.value;
        if (ex) {
            ProbeEx p = new ProbeEx();
            rejected[0] = new WeakReference<>(p);
            return w.set_listener_ex(p, mask);
        }
        Probe p = new Probe();
        rejected[0] = new WeakReference<>(p);
        return w.set_listener(p, mask);
    }

    static int setUntilRejected(Zzdds.zzdds.DataWriter w, boolean ex, WeakReference<?>[] rejected) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20);
        while (System.nanoTime() < deadline) {
            int rc = setProbe(w, ex, rejected);
            if (rc != 0) return rc;
            Thread.sleep(1);
        }
        return -1;
    }

    static boolean collected(WeakReference<?> ref) throws InterruptedException {
        for (int i = 0; i < 100 && ref.get() != null; i++) {
            System.gc();
            Thread.sleep(50);
        }
        return ref.get() == null;
    }

    static void checkRejectedRegistrations(Zzdds.zzdds.Publisher zdPublisher, Dcps.DDS.Topic topic,
                                           Dcps.DDS.DataWriterQos qos) throws Exception {
        final Rejection rej = new Rejection();
        ProbeEx gate = new ProbeEx() {
            @Override
            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                if (s.get_current_count() == 0 || !rej.first.getAndSet(false)) return;
                rej.entered.countDown();
                try {
                    if (!rej.deleting.await(20, TimeUnit.SECONDS)) return;
                    rej.plainRc = setUntilRejected(rej.writer, false, rej.plainRejected);
                    rej.exRc = setUntilRejected(rej.writer, true, rej.exRejected);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    rej.done.countDown();
                }
            }
        };
        Dcps.DDS.DataWriter raw = zdPublisher.create_datawriter_ex(topic, qos, gate, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value);
        check(raw != null, "create_datawriter_ex() of the rejecting writer returned non-null");
        rej.writer = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(raw);
        check(rej.writer != null, "asZzddsDataWriter() of the rejecting writer returned non-null");
        gate = null;
        check(rej.entered.await(20, TimeUnit.SECONDS), "the rejecting writer matched within 20s");
        rej.deleting.countDown();
        // Returns once the callback has returned.
        check(raw.get_publisher().delete_datawriter(raw) == 0, "delete_datawriter() of the rejecting writer rc == 0");
        check(rej.done.await(10, TimeUnit.SECONDS), "the rejecting callback finished");
        int deleted = Dcps.DDS.RETCODE_ALREADY_DELETED.value;
        check(rej.plainRc == deleted, "set_listener() on a writer being deleted returns ALREADY_DELETED, got " + rej.plainRc);
        check(rej.exRc == deleted, "set_listener_ex() on a writer being deleted returns ALREADY_DELETED, got " + rej.exRc);
        check(collected(rej.plainRejected[0]), "a listener set_listener() rejected is released");
        check(collected(rej.exRejected[0]), "a listener set_listener_ex() rejected is released");
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

        // Narrow to zzdds's own extension views to reach create_datawriter_ex /
        // create_datareader_ex: the extended listeners are installed as the
        // entities are created, so no match during creation is missed.
        Zzdds.zzdds.Publisher zdPublisher =
            (Zzdds.zzdds.Publisher) io.zzdds.runtime.ZzddsRuntime.asZzddsPublisher(publisher);
        Zzdds.zzdds.Subscriber zdSubscriber =
            (Zzdds.zzdds.Subscriber) io.zzdds.runtime.ZzddsRuntime.asZzddsSubscriber(subscriber);
        check(zdPublisher != null && zdSubscriber != null, "asZzddsPublisher/asZzddsSubscriber() returned non-null");

        final CountDownLatch readerReady = new CountDownLatch(1);
        final CountDownLatch writerReady = new CountDownLatch(1);
        final CountDownLatch dataAvailable = new CountDownLatch(1);
        final AtomicInteger dataCount = new AtomicInteger();

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
        Dcps.DDS.DataWriter rawWriter = zdPublisher.create_datawriter_ex(topicWriter, writerQos, writerListener, 0xFFFFFFFF);
        check(rawWriter != null, "create_datawriter_ex() returned non-null");
        // The writer still narrows to its own extension view (set_listener_ex etc.).
        check(io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(rawWriter) != null, "asZzddsDataWriter() returned non-null");

        Dcps.DDS.DataReaderQos readerQos = new Dcps.DDS.DataReaderQos();
        subscriber.get_default_datareader_qos(readerQos);
        readerQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);

        Zzdds.zzdds.DataReaderListenerEx listener = new Zzdds.zzdds.DataReaderListenerEx() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) { dataCount.incrementAndGet(); dataAvailable.countDown(); }
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
            public void on_reliable_writer_ready(int writerHandle, boolean isReady) {
                if (isReady) writerReady.countDown();
            }
        };

        Dcps.DDS.DataReader rawReader = zdSubscriber.create_datareader_ex(topicReader, readerQos, listener, 0xFFFFFFFF);
        check(rawReader != null, "create_datareader_ex() returned non-null");

        check(readerReady.await(20, TimeUnit.SECONDS), "on_reliable_reader_ready fired within 20s (real UDP discovery + RELIABLE handshake)");
        System.out.println("  reliable reader ready: OK");
        check(writerReady.await(20, TimeUnit.SECONDS), "on_reliable_writer_ready fired within 20s");
        System.out.println("  reliable writer ready: OK");

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

        // One native context per Java listener object, shared by all of its
        // registrations and released once per registration: registering
        // `listener` on a second reader and deleting that reader drops one
        // reference, leaving the first reader's registration working (the
        // dispose below still reaches on_data_available).
        Dcps.DDS.DataReader second = subscriber.create_datareader(topicReader, readerQos, null, 0);
        check(second != null, "second create_datareader() returned non-null");
        check(second.set_listener(listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value) == 0, "set_listener() of an already-registered listener rc == 0");
        check(second.get_listener() == listener, "get_listener() returns the installed listener object");
        check(subscriber.delete_datareader(second) == 0, "delete_datareader(second) rc == 0");
        // The core reports the freed handle and the binding retires the
        // wrapper: it no longer reaches the core.
        check(second.enable() == Dcps.DDS.RETCODE_ALREADY_DELETED.value, "a deleted reader's enable() returns ALREADY_DELETED");
        check(second.get_listener() == null, "a deleted reader has no listener");
        final int dataBeforeDispose = dataCount.get();

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

        // Regression coverage for the generic loan_raw/publish_loan_raw JNI
        // bridge (java.zig's isWriteLoanBufferOp) that writer.write() above
        // already exercises implicitly: a real, previously-unexercised bug
        // in the generic per-op codegen lost the loaned native buffer's
        // identity across the loan_raw()->publish_loan_raw() call pair
        // (Java's normal List<Byte> marshaling copies through a *fresh*
        // native buffer on every JNI boundary crossing), leaking both the
        // buffer and the writer's outstanding-loan count permanently --
        // confirmed by generating and reading the actual JNI bridge output
        // before the fix existed. Fixed via java.nio.ByteBuffer
        // (NewDirectByteBuffer/GetDirectBufferAddress correctly preserve
        // that identity). dispose()'s key-only branch exercises writeViaLoan
        // with keyOnly=true (a different toPayload() call than write()'s);
        // delete_datawriter() succeeding afterward is the real regression
        // check for the leak -- it would return PRECONDITION_NOT_MET forever
        // if any prior loan_raw call's outstanding-loan count was never
        // cleared.
        check(writer.dispose(sample, 0L) == 0, "writer.dispose() rc == 0");
        // Wait for the listener before taking: a take() that consumes the
        // sample first clears DATA_AVAILABLE, and the core then skips the
        // callback.
        for (int i = 0; i < 50 && dataCount.get() == dataBeforeDispose; i++) Thread.sleep(100);
        check(dataCount.get() > dataBeforeDispose, "the listener still fires after its other registration was released");
        BindingSmokeStatusDataReader.Sample disposed = null;
        for (int i = 0; i < 50 && disposed == null; i++) {
            disposed = reader.take();
            if (disposed == null) Thread.sleep(100);
        }
        check(disposed != null, "reader.take() returned the dispose sample");
        check(!disposed.validData, "dispose sample has valid_data == false");
        check(disposed.instanceState == Dcps.DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE.value,
            "dispose sample instance_state == NOT_ALIVE_DISPOSED_INSTANCE_STATE");
        System.out.println("  writer.dispose() via loan path: OK");
        System.out.println("  listener shared by two readers, one deleted: OK");

        if (Boolean.getBoolean("zzdds.sharedRuntime")) {
            checkOneIdentity(zdSubscriber, topicReader, readerQos, writer, sample);
            System.out.println("  one listener object runs one callback at a time across readers: OK");
            checkRejectedRegistrations(zdPublisher, topicWriter, writerQos);
            System.out.println("  rejected listener registrations are released: OK");
        }

        int deleteRc = publisher.delete_datawriter(rawWriter);
        check(deleteRc == 0, "delete_datawriter() rc == 0 (would be PRECONDITION_NOT_MET if any loan_raw call above leaked its outstanding-loan count)");
        System.out.println("  delete_datawriter() after loan-backed writes: OK (no outstanding-loan leak)");

        // zzdds::ContentFilteredTopic.set_filter_expression changes the filter
        // expression in place (DDS only allows changing its parameters).
        Dcps.DDS.ContentFilteredTopic cft = dpReader.create_contentfilteredtopic(
            "JavaSmokeFiltered", topicReader, "id > 10", java.util.Collections.emptyList());
        check(cft != null, "create_contentfilteredtopic() returned non-null");
        Zzdds.zzdds.ContentFilteredTopic zCft =
            (Zzdds.zzdds.ContentFilteredTopic) io.zzdds.runtime.ZzddsRuntime.asZzddsContentFilteredTopic(cft);
        check(zCft != null, "asZzddsContentFilteredTopic() returned non-null");
        check(zCft.set_filter_expression("id < %0", java.util.Arrays.asList("5")) == 0,
              "set_filter_expression() rc == 0");
        check("id < %0".equals(cft.get_filter_expression()), "get_filter_expression() reports the new expression");
        check(zCft.set_filter_expression("id < < 5", java.util.Collections.emptyList())
                  == Dcps.DDS.RETCODE_BAD_PARAMETER.value,
              "malformed expression rejected with BAD_PARAMETER");
        check("id < %0".equals(cft.get_filter_expression()), "rejected expression left the filter unchanged");
        check(dpReader.delete_contentfilteredtopic(cft) == 0, "delete_contentfilteredtopic() rc == 0");
        System.out.println("  ContentFilteredTopic.set_filter_expression: OK");

        // Entities a cascading delete takes never pass through the binding;
        // their wrappers are retired all the same, and a new entity gets a
        // wrapper of its own even at a reused address.
        check(rawWriter.enable() == Dcps.DDS.RETCODE_ALREADY_DELETED.value, "a deleted writer's enable() returns ALREADY_DELETED");
        Dcps.DDS.Subscriber extraSub = dpReader.create_subscriber(null, null, 0);
        Dcps.DDS.DataReader extraReader = extraSub.create_datareader(topicReader, readerQos, null, 0);
        check(extraReader != null, "extra create_datareader() returned non-null");
        check(extraSub.delete_contained_entities() == 0, "delete_contained_entities() rc == 0");
        check(extraReader.enable() == Dcps.DDS.RETCODE_ALREADY_DELETED.value,
              "a reader deleted by its subscriber's delete_contained_entities() is retired");
        Dcps.DDS.DataReader nextReader = extraSub.create_datareader(topicReader, readerQos, null, 0);
        check(nextReader != null && nextReader != extraReader, "a new reader gets a wrapper of its own");
        check(nextReader.enable() == 0, "the new reader reaches the core");
        check(extraSub.delete_contained_entities() == 0, "second delete_contained_entities() rc == 0");
        check(dpReader.delete_subscriber(extraSub) == 0, "delete_subscriber(extraSub) rc == 0");
        System.out.println("  deleted entities' wrappers are retired: OK");

        System.out.println("All Java binding smoke checks passed.");
    }
}
