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

    // A reader listener that throws, reached through notify_datareaders from
    // its subscriber's on_data_on_readers: the bridge reports the failure and
    // notify_datareaders returns ERROR, with nothing thrown past the bridge.
    // TRANSIENT_LOCAL, so the sample written before the reader exists reaches
    // it once matched.
    static void checkFailingChildListener(Dcps.DDS.DomainParticipant dpWriter, Dcps.DDS.Publisher publisher,
                                          Dcps.DDS.DomainParticipant dpReader) throws Exception {
        Dcps.DDS.Topic wTopic = dpWriter.create_topic("JavaSmokeFailingChild", "BindingSmokeStatus", null, null, 0);
        Dcps.DDS.Topic rTopic = dpReader.create_topic("JavaSmokeFailingChild", "BindingSmokeStatus", null, null, 0);
        check(wTopic != null && rTopic != null, "failing-child topics created");
        Dcps.DDS.DataWriterQos wQos = new Dcps.DDS.DataWriterQos();
        publisher.get_default_datawriter_qos(wQos);
        wQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        wQos.get_durability().set_kind(Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS);
        Dcps.DDS.DataWriter rawWriter = publisher.create_datawriter(wTopic, wQos, null, 0);
        check(rawWriter != null, "failing-child writer created");
        Binding_smoke.BindingSmokeStatus sample = new Binding_smoke.BindingSmokeStatus();
        sample.set_id(11);
        sample.set_label("failing-child");
        check(new BindingSmokeStatusDataWriter(rawWriter).write(sample, 0L) == 0, "failing-child write rc == 0");

        final AtomicInteger notifyRc = new AtomicInteger(-1);
        final AtomicInteger thrown = new AtomicInteger();
        final CountDownLatch notified = new CountDownLatch(1);
        Dcps.DDS.SubscriberListener subListener = new Dcps.DDS.SubscriberListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
            public void on_data_on_readers(Dcps.DDS.Subscriber sub) {
                if (notified.getCount() == 0) return;
                notifyRc.set(sub.notify_datareaders());
                notified.countDown();
            }
        };
        final int DATA_ON_READERS = 1 << 9, DATA_AVAILABLE = 1 << 10;
        Dcps.DDS.Subscriber sub = dpReader.create_subscriber(null, subListener, DATA_ON_READERS);
        check(sub != null, "failing-child subscriber created");
        Dcps.DDS.DataReaderListener throwing = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {
                thrown.incrementAndGet();
                throw new IllegalStateException("failing child listener");
            }
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
        };
        Dcps.DDS.DataReaderQos rQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(rQos);
        rQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        rQos.get_durability().set_kind(Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS);
        Dcps.DDS.DataReader rawReader = sub.create_datareader(rTopic, rQos, throwing, DATA_AVAILABLE);
        check(rawReader != null, "failing-child reader created");

        check(notified.await(20, TimeUnit.SECONDS), "on_data_on_readers ran notify_datareaders within 20s");
        check(thrown.get() == 1, "the throwing reader listener ran once");
        check(notifyRc.get() == Dcps.DDS.RETCODE_ERROR.value,
              "notify_datareaders returns ERROR for a child listener that threw (rc " + notifyRc.get() + ")");

        check(sub.delete_contained_entities() == 0, "failing-child subscriber's delete_contained_entities rc == 0");
        check(dpReader.delete_subscriber(sub) == 0, "failing-child subscriber deleted");
        check(publisher.delete_datawriter(rawWriter) == 0, "failing-child writer deleted");
        check(dpWriter.delete_topic(wTopic) == 0 && dpReader.delete_topic(rTopic) == 0, "failing-child topics deleted");
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

    // WaitSet and GuardCondition come from their generated constructors, and
    // wait() hands back the same GuardCondition object that was attached.
    /** get_key_value. Its raw path returns a DDS return code and the key the
     * instance keeps, key-only CDR when the type has a key projection, which
     * the generated types register. The generated wrappers fill a key
     * holder's key fields from it, also for an instance only registered, and
     * leave the holder's other fields alone. */
    static void checkGetKeyValue(Dcps.DDS.DataWriter rawWriter, Dcps.DDS.DataReader rawReader,
                                 BindingSmokeStatusDataWriter writer, BindingSmokeStatusDataReader reader,
                                 Binding_smoke.BindingSmokeStatus sample, long readerHandle,
                                 Dcps.DDS.DomainParticipant dp, Dcps.DDS.Publisher publisher) {
        final int ok = Dcps.DDS.RETCODE_OK.value;
        final int badParameter = Dcps.DDS.RETCODE_BAD_PARAMETER.value;
        byte[][] out = new byte[1][];
        boolean[] keyOnly = new boolean[1];
        long writerHandle = io.zzdds.runtime.ZzddsRuntime.lookupInstanceWriterRaw(rawWriter, sample.computeKeyHash());
        check(writerHandle != 0, "lookupInstanceWriterRaw() found the written instance");
        check(io.zzdds.runtime.ZzddsRuntime.getKeyValueWriter(rawWriter, writerHandle, out, keyOnly) == ok, "getKeyValueWriter() rc == OK");
        check(out[0] != null && keyOnly[0], "the writer keeps the instance's key-only CDR");
        out[0] = null;
        keyOnly[0] = false;
        check(io.zzdds.runtime.ZzddsRuntime.getKeyValueReader(rawReader, readerHandle, out, keyOnly) == ok, "getKeyValueReader() rc == OK");
        check(out[0] != null && keyOnly[0], "the reader keeps the instance's key-only CDR");
        check(io.zzdds.runtime.ZzddsRuntime.getKeyValueWriter(rawWriter, 0L, out, null) == badParameter, "getKeyValueWriter() of HANDLE_NIL is BAD_PARAMETER");
        check(io.zzdds.runtime.ZzddsRuntime.getKeyValueReader(rawReader, 0L, out, null) == badParameter, "getKeyValueReader() of HANDLE_NIL is BAD_PARAMETER");

        // The generated wrappers: only the key fields change.
        Binding_smoke.BindingSmokeStatus holder = new Binding_smoke.BindingSmokeStatus();
        holder.set_count(99);
        holder.set_label("kept");
        check(writer.get_key_value(holder, writerHandle) == ok, "writer.get_key_value() rc == OK");
        check(holder.get_id() == sample.get_id(), "writer.get_key_value() filled the key");
        check(holder.get_count() == 99 && "kept".equals(holder.get_label()), "writer.get_key_value() left the other fields alone");
        holder.set_id(0);
        check(reader.get_key_value(holder, readerHandle) == ok, "reader.get_key_value() rc == OK");
        check(holder.get_id() == sample.get_id(), "reader.get_key_value() filled the key");
        check(writer.get_key_value(holder, 0L) == badParameter, "writer.get_key_value() of HANDLE_NIL is BAD_PARAMETER");
        check(writer.get_key_value(null, writerHandle) == badParameter, "writer.get_key_value() of a null holder is BAD_PARAMETER");
        // An instance only registered has its key too.
        Binding_smoke.BindingSmokeStatus other = new Binding_smoke.BindingSmokeStatus();
        other.set_id(31);
        long registered = writer.register_instance(other);
        check(registered != 0, "writer.register_instance() returned a handle");
        check(writer.get_key_value(holder, registered) == ok && holder.get_id() == 31, "get_key_value() of an instance only registered");

        // A large sample: its instance keeps only the key, so no reader is needed.
        check(BindingSmokeBlobTypeSupport.register(dp, null) == 0, "TypeSupport.register (blob)");
        Dcps.DDS.Topic blobTopic = dp.create_topic("JavaSmokeBlob", "BindingSmokeBlob", null, null, 0);
        Dcps.DDS.DataWriter blobRaw = publisher.create_datawriter(blobTopic, null, null, 0);
        check(blobTopic != null && blobRaw != null, "create_topic/create_datawriter (blob)");
        BindingSmokeBlobDataWriter blobWriter = new BindingSmokeBlobDataWriter(blobRaw);
        Binding_smoke.BindingSmokeBlob blob = new Binding_smoke.BindingSmokeBlob();
        blob.set_id(3);
        java.util.List<Byte> data = new java.util.ArrayList<>();
        for (int i = 0; i < 6000; i++) data.add((byte) i);
        blob.set_data(data);
        check(blobWriter.write(blob, 0L) == 0, "blob write() rc == 0");
        long blobHandle = io.zzdds.runtime.ZzddsRuntime.lookupInstanceWriterRaw(blobRaw, blob.computeKeyHash());
        out[0] = null;
        check(io.zzdds.runtime.ZzddsRuntime.getKeyValueWriter(blobRaw, blobHandle, out, keyOnly) == ok, "getKeyValueWriter() of a 6000-byte sample rc == OK");
        check(out[0] != null && keyOnly[0] && out[0].length < 64, "a 6000-byte sample's instance keeps only its key");
        Binding_smoke.BindingSmokeBlob blobKey = new Binding_smoke.BindingSmokeBlob();
        check(blobWriter.get_key_value(blobKey, blobHandle) == ok && blobKey.get_id() == 3, "blob get_key_value() filled the key");
        check(publisher.delete_datawriter(blobRaw) == 0, "delete_datawriter (blob)");
        check(dp.delete_topic(blobTopic) == 0, "delete_topic (blob)");

        // A key over 4096 bytes: the projection and the Java runtime each
        // ask again at the size needed.
        check(BindingSmokeBigKeyTypeSupport.register(dp, null) == 0, "TypeSupport.register (big key)");
        Dcps.DDS.Topic bigTopic = dp.create_topic("JavaSmokeBigKey", "BindingSmokeBigKey", null, null, 0);
        Dcps.DDS.DataWriter bigRaw = publisher.create_datawriter(bigTopic, null, null, 0);
        check(bigTopic != null && bigRaw != null, "create_topic/create_datawriter (big key)");
        BindingSmokeBigKeyDataWriter bigWriter = new BindingSmokeBigKeyDataWriter(bigRaw);
        Binding_smoke.BindingSmokeBigKey big = new Binding_smoke.BindingSmokeBigKey();
        StringBuilder name = new StringBuilder();
        for (int i = 0; i < 5000; i++) name.append((char) ('a' + i % 26));
        big.set_name(name.toString());
        big.set_value(7);
        check(bigWriter.write(big, 0L) == 0, "big key write() rc == 0");
        long bigHandle = io.zzdds.runtime.ZzddsRuntime.lookupInstanceWriterRaw(bigRaw, big.computeKeyHash());
        out[0] = null;
        keyOnly[0] = false;
        check(io.zzdds.runtime.ZzddsRuntime.getKeyValueWriter(bigRaw, bigHandle, out, keyOnly) == ok, "getKeyValueWriter() of a 5000-byte key rc == OK");
        check(out[0] != null && keyOnly[0] && out[0].length > 5000, "a 5000-byte key is kept key-only, whole");
        Binding_smoke.BindingSmokeBigKey bigKey = new Binding_smoke.BindingSmokeBigKey();
        check(bigWriter.get_key_value(bigKey, bigHandle) == ok, "big key get_key_value() rc == OK");
        check(name.toString().equals(bigKey.get_name()) && bigKey.get_value() == 0, "big key get_key_value() filled the key, and only the key");
        check(publisher.delete_datawriter(bigRaw) == 0, "delete_datawriter (big key)");
        check(dp.delete_topic(bigTopic) == 0, "delete_topic (big key)");
    }

    static void checkGeneratedConstruction() {
        int ok = Dcps.DDS.RETCODE_OK.value;
        Dcps.DDS.WaitSet ws = Dcps.DDS.WaitSet.create();
        Dcps.DDS.GuardCondition gc = Dcps.DDS.GuardCondition.create();
        check(ws != null && gc != null, "WaitSet.create()/GuardCondition.create() returned non-null");
        check(ws.attach_condition(gc) == ok, "attach_condition() of a created GuardCondition");
        check(gc.set_trigger_value(true) == ok, "set_trigger_value(true)");
        Dcps.DDS.Duration_t timeout = new Dcps.DDS.Duration_t();
        timeout.set_sec(1);
        java.util.ArrayList<Dcps.DDS.Condition> active = new java.util.ArrayList<>();
        check(ws.wait(active, timeout) == ok, "wait() on a triggered GuardCondition");
        check(active.size() == 1 && active.get(0) == gc, "wait() returns the GuardCondition object that was attached");
        java.util.ArrayList<Dcps.DDS.Condition> attached = new java.util.ArrayList<>();
        check(ws.get_conditions(attached) == ok && attached.size() == 1 && attached.get(0) == gc,
              "get_conditions() returns the GuardCondition object that was attached");
        check(gc.set_trigger_value(false) == ok, "set_trigger_value(false)");
        timeout.set_sec(0);
        check(ws.wait(active, timeout) == Dcps.DDS.RETCODE_TIMEOUT.value && active.isEmpty(),
              "a timed-out wait() leaves no conditions");
        check(gc.destroy() == ok, "GuardCondition.destroy()");
        check(gc.destroy() == Dcps.DDS.RETCODE_ALREADY_DELETED.value, "a second destroy() is refused");
        ws.close();
    }

    // A factory of one's own is AutoCloseable and owned: its strict destroy()
    // refuses while a participant remains, and close() deletes it. The
    // process-wide factory is borrowed: one wrapper until delete_instance(),
    // which refuses while it has participants.
    static void checkFactoryConstruction(int domain) {
        int ok = Dcps.DDS.RETCODE_OK.value;
        int refused = Dcps.DDS.RETCODE_PRECONDITION_NOT_MET.value;
        try (Zzdds.zzdds.DomainParticipantFactory own = Zzdds.zzdds.DomainParticipantFactory.create()) {
            check(own != null, "zzdds DomainParticipantFactory.create() returned non-null");
            check(own.create_participant(domain, null, null, 0) != null, "create_participant on an own factory");
            check(own.destroy() == refused, "destroy() refuses a factory with a participant");
        }
        check(Dcps.DDS.DomainParticipantFactory.delete_instance() == ok, "delete_instance() with no instance");
        Dcps.DDS.DomainParticipantFactory inst = Dcps.DDS.DomainParticipantFactory.get_instance();
        check(inst != null, "get_instance() returned non-null");
        check(Dcps.DDS.DomainParticipantFactory.get_instance() == inst, "get_instance() returns the same wrapper");
        check(inst.create_participant(domain, null, null, 0) != null, "create_participant on the process-wide factory");
        check(Dcps.DDS.DomainParticipantFactory.delete_instance() == refused, "delete_instance() refuses while a participant remains");
        check(inst.delete_contained_entities() == ok, "delete_contained_entities() on the process-wide factory");
        check(Dcps.DDS.DomainParticipantFactory.delete_instance() == ok, "delete_instance()");
    }

    // A loan outlives the cascade that deletes its writer: closing the owner
    // deletes the writer, whose wrapper still returns the loan, freeing it.
    static void checkLoanOutlivesCascade(int domain) {
        Dcps.DDS.DataWriter loaned;
        java.nio.ByteBuffer loan;
        try (Zzdds.zzdds.DomainParticipantFactory own = Zzdds.zzdds.DomainParticipantFactory.create()) {
            Dcps.DDS.DomainParticipant dp = own.create_participant(domain, null, null, 0);
            check(dp != null, "create_participant for the loan cascade");
            Dcps.DDS.Topic t = dp.create_topic("JavaLoanCascade", "JavaLoanCascadeType", null, null, 0);
            Dcps.DDS.Publisher p = dp.create_publisher(null, null, 0);
            check(t != null && p != null, "create_topic/create_publisher for the loan cascade");
            loaned = p.create_datawriter(t, null, null, 0);
            check(loaned != null, "create_datawriter for the loan cascade");
            loan = loaned.loan_raw(4);
            check(loan != null, "loan_raw() before the cascade");
        }
        check(loaned.get_publisher() == null, "a writer deleted with a loan out has no publisher");
        check(loaned.assert_liveliness() == Dcps.DDS.RETCODE_ALREADY_DELETED.value, "a writer deleted with a loan out refuses other operations");
        check(loaned.return_loan_raw(loan) == Dcps.DDS.RETCODE_OK.value, "return_loan_raw() after the cascade");
    }

    public static void main(String[] args) throws Exception {
        System.out.println("Java binding smoke test:");
        checkGeneratedConstruction();
        checkFactoryConstruction(0);
        checkLoanOutlivesCascade(0);

        Dcps.DDS.DomainParticipantFactory factory =
            io.zzdds.ext.Zzdds.zzdds.DomainParticipantFactory.create();
        check(factory != null, "DomainParticipantFactory.create() returned non-null");

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

        checkGetKeyValue(rawWriter, rawReader, writer, reader, sample, got.instanceHandle, dpWriter, publisher);
        System.out.println("  get_key_value: return codes, key-only storage, key holders: OK");

        checkOneIdentity(zdSubscriber, topicReader, readerQos, writer, sample);
        System.out.println("  one listener object runs one callback at a time across readers: OK");
        checkRejectedRegistrations(zdPublisher, topicWriter, writerQos);
        System.out.println("  rejected listener registrations are released: OK");
        checkFailingChildListener(dpWriter, publisher, dpReader);
        System.out.println("  a throwing child listener makes notify_datareaders return ERROR: OK");

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
