// Integration test for generated Java types + CDR serialization.
// Compiled and run by `zig build integration-test`.

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;

public class Test {

    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    static void checkEq(long expected, long actual, String msg) {
        if (expected != actual)
            throw new AssertionError("FAIL: " + msg + ": expected " + expected + " got " + actual);
    }

    static void checkEq(String expected, String actual, String msg) {
        if (!expected.equals(actual))
            throw new AssertionError("FAIL: " + msg + ": expected '" + expected + "' got '" + actual + "'");
    }

    static void checkApprox(double expected, double actual, double tol, String msg) {
        if (Math.abs(expected - actual) > tol)
            throw new AssertionError("FAIL: " + msg + ": expected ~" + expected + " got " + actual);
    }

    // Write a 4-byte XCDR2 LE encapsulation header (CDR2_LE = 0x0007).
    static void writeEncapHeader(ByteBuffer buf) {
        buf.put((byte)0x00);
        buf.put((byte)0x07);
        buf.put((byte)0x00);
        buf.put((byte)0x00);
    }

    // ── roundtrip: Sample (@final) ────────────────────────────────────────

    static void testSampleRoundtrip() {
        ByteBuffer buf = ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN);
        writeEncapHeader(buf);
        int cdrBase = buf.position();

        Types.Sample s = new Types.Sample();
        s.set_id(42);
        s.set_b(true);
        s.set_u8_val((byte)0xFF);
        s.set_s16_val((short)-1000);
        s.set_u16_val((short)65000);
        s.set_s32_val(-2000000);
        s.set_u32_val(4000000);
        s.set_s64_val(-9000000000L);
        s.set_u64_val(18000000000L);
        s.set_f32_val(3.14f);
        s.set_f64_val(2.718281828);
        s.set_str("hello world");
        s.set_bstr("bounded");
        s.set_nums(new java.util.ArrayList<>());
        s.set_arr(new int[]{10, 20, 30});
        s.set_clr(Types.Color.GREEN);
        s.set_nested(new Types.Point(7, -3));

        s.serialize(buf, cdrBase);

        buf.flip();
        buf.position(4); // skip encap header
        Types.Sample s2 = Types.Sample.deserializeFrom(buf, cdrBase);

        checkEq(42,         s2.get_id(),        "id");
        check(s2.get_b(),                        "b");
        checkEq(-1000,      s2.get_s16_val(),    "s16_val");
        checkEq(-2000000,   s2.get_s32_val(),    "s32_val");
        checkEq(4000000,    s2.get_u32_val(),    "u32_val");
        checkEq(-9000000000L, s2.get_s64_val(),  "s64_val");
        checkEq(18000000000L, s2.get_u64_val(),  "u64_val");
        checkApprox(3.14,   s2.get_f32_val(),    1e-5,  "f32_val");
        checkApprox(2.718281828, s2.get_f64_val(), 1e-12, "f64_val");
        checkEq("hello world", s2.get_str(),     "str");
        checkEq("bounded",   s2.get_bstr(),      "bstr");
        check(Arrays.equals(new int[]{10,20,30}, s2.get_arr()), "arr");
        check(s2.get_clr() == Types.Color.GREEN, "clr");
        checkEq(7,  s2.get_nested().get_x(),     "nested.x");
        checkEq(-3, s2.get_nested().get_y(),     "nested.y");

        System.out.println("  testSampleRoundtrip: OK");
    }

    // ── roundtrip: Frame (@appendable, DHEADER) ───────────────────────────

    static void testFrameRoundtrip() {
        ByteBuffer buf = ByteBuffer.allocate(256).order(ByteOrder.LITTLE_ENDIAN);
        writeEncapHeader(buf);
        int cdrBase = buf.position();

        Types.Frame f = new Types.Frame();
        f.set_seq_num(7);
        f.set_topic("/sensors/imu");

        f.serialize(buf, cdrBase);

        buf.flip();
        buf.position(4);
        Types.Frame f2 = Types.Frame.deserializeFrom(buf, cdrBase);

        checkEq(7,              f2.get_seq_num(), "seq_num");
        checkEq("/sensors/imu", f2.get_topic(),   "topic");

        System.out.println("  testFrameRoundtrip: OK");
    }

    // ── key serialization ─────────────────────────────────────────────────

    static void testSampleKey() {
        ByteBuffer buf = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN);
        writeEncapHeader(buf);
        int cdrBase = buf.position();

        Types.Sample s = new Types.Sample();
        s.set_id(99);
        s.serializeKey(buf, cdrBase);

        check(Types.Sample.HAS_KEY,  "Sample must have key");
        check(!Types.Frame.HAS_KEY,  "Frame must not have key");

        System.out.println("  testSampleKey: OK");
    }

    static void testSampleDeserializeKey() {
        ByteBuffer buf = ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN);
        writeEncapHeader(buf);
        int cdrBase = buf.position();

        Types.Sample s = new Types.Sample();
        s.set_id(0x01020304);
        s.set_b(true);
        s.set_str("non-key payload");
        s.set_arr(new int[]{1, 2, 3});
        s.set_nested(new Types.Point(10, 20));
        s.serialize(buf, cdrBase);

        buf.flip();
        buf.position(4);
        Types.Sample key = Types.Sample.deserializeKey(buf, cdrBase);
        checkEq(s.get_id(), key.get_id(), "key.id");
        check(!key.get_b(), "key.b default");
        checkEq("", key.get_str(), "key.str default");
        checkEq(0, key.get_nested().get_x(), "key.nested.x default");
        check(!buf.hasRemaining(), "deserializeKey consumed full sample");

        System.out.println("  testSampleDeserializeKey: OK");
    }

    static void testSampleComputeKeyHash() {
        Types.Sample s = new Types.Sample();
        s.set_id(0x01020304);

        byte[] hash = s.computeKeyHash();
        byte[] expected = new byte[] {
            0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        };
        check(Arrays.equals(expected, hash), "computeKeyHash");

        System.out.println("  testSampleComputeKeyHash: OK");
    }

    public static void main(String[] args) {
        System.out.println("Java integration tests:");
        testSampleRoundtrip();
        testFrameRoundtrip();
        testSampleKey();
        testSampleDeserializeKey();
        testSampleComputeKeyHash();
        System.out.println("All Java integration tests passed.");
    }
}
