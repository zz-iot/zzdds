//! Phase 32 ContentFilteredTopic tests: filter expression parser and evaluator.
//!
//! Tests are organized in three layers:
//!   1. Parser — verify the AST structure produced for various expressions.
//!   2. Evaluator — verify correct boolean results with mock FieldAccessors.
//!   3. Integration — CFT DataReader lifecycle and end-to-end sample filtering.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const filter = zzdds.dcps.filter;
const FilterValue = filter.FilterValue;
const FieldAccessor = filter.FieldAccessor;
const AstNode = filter.AstNode;
const ContentFilteredTopicImpl = zzdds.dcps.ContentFilteredTopicImpl;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;
const TakenSample = zzdds.dcps.TakenSample;

const testing = std.testing;

// CDR encap header (little-endian) + one byte payload.
const NIL_KEY: [16]u8 = std.mem.zeroes([16]u8);
const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;

// ── Parser tests ──────────────────────────────────────────────────────────────

test "parse: empty expression returns null" {
    const alloc = testing.allocator;
    const result = try filter.parse(alloc, "");
    try testing.expectEqual(@as(?*AstNode, null), result);
}

test "parse: whitespace-only expression returns null" {
    const alloc = testing.allocator;
    const result = try filter.parse(alloc, "   ");
    try testing.expectEqual(@as(?*AstNode, null), result);
}

test "parse: simple equality produces compare node" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = 5")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .compare);
    try testing.expect(ast.compare.left == .field);
    try testing.expectEqualStrings("x", ast.compare.left.field);
    try testing.expectEqual(filter.RelOp.eq, ast.compare.op);
    try testing.expect(ast.compare.right == .literal);
    try testing.expectEqual(@as(i64, 5), ast.compare.right.literal.int);
}

test "parse: dotted field name" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "outer.inner = 1")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .compare);
    try testing.expectEqualStrings("outer.inner", ast.compare.left.field);
}

test "parse: BETWEEN expression" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x BETWEEN 1 AND 10")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .between);
    try testing.expectEqualStrings("x", ast.between.field);
    try testing.expect(!ast.between.negated);
    try testing.expectEqual(@as(i64, 1), ast.between.lo.literal.int);
    try testing.expectEqual(@as(i64, 10), ast.between.hi.literal.int);
}

test "parse: NOT BETWEEN expression" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x NOT BETWEEN 1 AND 10")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .between);
    try testing.expect(ast.between.negated);
}

test "parse: AND/OR precedence (AND binds tighter)" {
    const alloc = testing.allocator;
    // "a = 1 OR b = 2 AND c = 3" should be "a=1 OR (b=2 AND c=3)"
    const ast = (try filter.parse(alloc, "a = 1 OR b = 2 AND c = 3")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .logical_or);
    try testing.expect(ast.logical_or[0].* == .compare); // a = 1
    try testing.expect(ast.logical_or[1].* == .logical_and); // b=2 AND c=3
}

test "parse: NOT negation" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "NOT x = 5")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .logical_not);
    try testing.expect(ast.logical_not.* == .compare);
}

test "parse: parenthesized expression" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "(a = 1 OR b = 2) AND c = 3")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .logical_and);
    try testing.expect(ast.logical_and[0].* == .logical_or);
    try testing.expect(ast.logical_and[1].* == .compare);
}

test "parse: parameter operand %0" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = %0")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.compare.right == .param);
    try testing.expectEqual(@as(u8, 0), ast.compare.right.param);
}

test "parse: string literal" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "name = 'hello'")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.compare.right == .literal);
    try testing.expectEqualStrings("hello", ast.compare.right.literal.string);
}

test "parse: LIKE operator" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "name LIKE 'foo%'")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    try testing.expect(ast.* == .compare);
    try testing.expectEqual(filter.RelOp.like, ast.compare.op);
}

test "parse: invalid expression returns error" {
    const alloc = testing.allocator;
    try testing.expectError(error.ParseError, filter.parse(alloc, "x ="));
}

test "parse: trailing garbage returns error" {
    const alloc = testing.allocator;
    try testing.expectError(error.ParseError, filter.parse(alloc, "x = 5 garbage"));
}

// ── Evaluator tests ───────────────────────────────────────────────────────────

// Mock accessor: maps field names to FilterValues from a comptime-known table.
const FieldEntry = struct { name: []const u8, value: FilterValue };

fn makeAccessor(fields: []const FieldEntry) FieldAccessor {
    return .{
        .ctx = @ptrCast(@constCast(fields.ptr)),
        .get = struct {
            fn get(ctx: *anyopaque, name: []const u8) ?FilterValue {
                // Recover slice from the pointer — length is embedded via a different mechanism.
                // Use a simpler approach: a fixed-size table wrapper.
                _ = ctx;
                _ = name;
                return null;
            }
        }.get,
    };
}

// A simpler accessor approach using a static helper struct.
const MockAccessor = struct {
    fields: []const FieldEntry,

    fn accessor(self: *const MockAccessor) FieldAccessor {
        return .{
            .ctx = @ptrCast(@constCast(self)),
            .get = &get,
        };
    }

    fn get(ctx: *anyopaque, name: []const u8) ?FilterValue {
        const self: *const MockAccessor = @ptrCast(@alignCast(ctx));
        for (self.fields) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};

test "eval: integer equality match" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = 42")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 42 } }};
    const mock = MockAccessor{ .fields = &fields };
    try testing.expect(filter.eval(ast, mock.accessor(), &.{}));
}

test "eval: integer equality no-match" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = 42")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 99 } }};
    const mock = MockAccessor{ .fields = &fields };
    try testing.expect(!filter.eval(ast, mock.accessor(), &.{}));
}

test "eval: BETWEEN inclusive bounds" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x BETWEEN 1 AND 10")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields_in = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 5 } }};
    const mock_in = MockAccessor{ .fields = &fields_in };
    try testing.expect(filter.eval(ast, mock_in.accessor(), &.{}));
    // Boundary values
    const fields_lo = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 1 } }};
    const mock_lo = MockAccessor{ .fields = &fields_lo };
    try testing.expect(filter.eval(ast, mock_lo.accessor(), &.{}));
    const fields_hi = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 10 } }};
    const mock_hi = MockAccessor{ .fields = &fields_hi };
    try testing.expect(filter.eval(ast, mock_hi.accessor(), &.{}));
    // Out of range
    const fields_out = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 11 } }};
    const mock_out = MockAccessor{ .fields = &fields_out };
    try testing.expect(!filter.eval(ast, mock_out.accessor(), &.{}));
}

test "eval: NOT BETWEEN" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x NOT BETWEEN 1 AND 10")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields_in = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 5 } }};
    const mock_in = MockAccessor{ .fields = &fields_in };
    try testing.expect(!filter.eval(ast, mock_in.accessor(), &.{}));
    const fields_out = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 11 } }};
    const mock_out = MockAccessor{ .fields = &fields_out };
    try testing.expect(filter.eval(ast, mock_out.accessor(), &.{}));
}

test "eval: AND requires both conditions" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x > 0 AND y < 10")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields_both = [_]FieldEntry{
        .{ .name = "x", .value = .{ .int = 5 } },
        .{ .name = "y", .value = .{ .int = 3 } },
    };
    const mock_both = MockAccessor{ .fields = &fields_both };
    try testing.expect(filter.eval(ast, mock_both.accessor(), &.{}));
    const fields_one = [_]FieldEntry{
        .{ .name = "x", .value = .{ .int = 5 } },
        .{ .name = "y", .value = .{ .int = 15 } }, // fails
    };
    const mock_one = MockAccessor{ .fields = &fields_one };
    try testing.expect(!filter.eval(ast, mock_one.accessor(), &.{}));
}

test "eval: OR requires at least one condition" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = 1 OR x = 2")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields1 = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 1 } }};
    const mock1 = MockAccessor{ .fields = &fields1 };
    try testing.expect(filter.eval(ast, mock1.accessor(), &.{}));
    const fields2 = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 2 } }};
    const mock2 = MockAccessor{ .fields = &fields2 };
    try testing.expect(filter.eval(ast, mock2.accessor(), &.{}));
    const fields3 = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 3 } }};
    const mock3 = MockAccessor{ .fields = &fields3 };
    try testing.expect(!filter.eval(ast, mock3.accessor(), &.{}));
}

test "eval: NOT negates condition" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "NOT x = 5")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields_match = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 5 } }};
    const mock_match = MockAccessor{ .fields = &fields_match };
    try testing.expect(!filter.eval(ast, mock_match.accessor(), &.{}));
    const fields_no = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 99 } }};
    const mock_no = MockAccessor{ .fields = &fields_no };
    try testing.expect(filter.eval(ast, mock_no.accessor(), &.{}));
}

test "eval: parameter substitution" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = %0")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields = [_]FieldEntry{.{ .name = "x", .value = .{ .int = 7 } }};
    const mock = MockAccessor{ .fields = &fields };
    // param "7" should be parsed as numeric and compared to int 7
    try testing.expect(filter.eval(ast, mock.accessor(), &.{"7"}));
    try testing.expect(!filter.eval(ast, mock.accessor(), &.{"99"}));
}

test "eval: LIKE wildcard matching" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "name LIKE 'foo%'")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields_yes = [_]FieldEntry{.{ .name = "name", .value = .{ .string = "foobar" } }};
    const mock_yes = MockAccessor{ .fields = &fields_yes };
    try testing.expect(filter.eval(ast, mock_yes.accessor(), &.{}));
    const fields_no = [_]FieldEntry{.{ .name = "name", .value = .{ .string = "barfoo" } }};
    const mock_no = MockAccessor{ .fields = &fields_no };
    try testing.expect(!filter.eval(ast, mock_no.accessor(), &.{}));
}

test "eval: LIKE underscore wildcard" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "name LIKE 'f_o'")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    const fields_yes = [_]FieldEntry{.{ .name = "name", .value = .{ .string = "foo" } }};
    const mock_yes = MockAccessor{ .fields = &fields_yes };
    try testing.expect(filter.eval(ast, mock_yes.accessor(), &.{}));
    const fields_no = [_]FieldEntry{.{ .name = "name", .value = .{ .string = "fo" } }};
    const mock_no = MockAccessor{ .fields = &fields_no };
    try testing.expect(!filter.eval(ast, mock_no.accessor(), &.{}));
}

test "eval: unknown field passes through (err-open)" {
    const alloc = testing.allocator;
    const ast = (try filter.parse(alloc, "x = 5")) orelse return error.NullAst;
    defer filter.freeAst(alloc, ast);
    // Accessor returns null for all fields.
    const empty = [_]FieldEntry{};
    const mock = MockAccessor{ .fields = &empty };
    // On field-not-found, eval passes the sample through.
    try testing.expect(filter.eval(ast, mock.accessor(), &.{}));
}

test "eval: null AST always passes" {
    const fields = [_]FieldEntry{};
    const mock = MockAccessor{ .fields = &fields };
    try testing.expect(filter.eval(null, mock.accessor(), &.{}));
}

// ── Integration tests ─────────────────────────────────────────────────────────

// Fixture for the integration test (identical to other dcps test fixtures).
const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    t_w: *zzdds.intraprocess.MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,

    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("CftTopic", "CftType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("CftTopic", "CftType", .{}, null, 0);

        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .pub_w = pub_w,
            .topic_w = topic_w,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_r = sub_r,
            .topic_r = topic_r,
        };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }
};

// CDR accessor for our test payload:
//   bytes 0-3: CDR encap header (ignored)
//   byte  4:   u8 "value" field
const CdrCtx = struct { data: []const u8 };
fn cdrGet(ctx: *anyopaque, name: []const u8) ?FilterValue {
    const c: *const CdrCtx = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, name, "value")) {
        if (c.data.len > 4) return .{ .int = c.data[4] };
    }
    return null;
}

fn makeCdrAccessor(ctx: *CdrCtx) FieldAccessor {
    return .{ .ctx = ctx, .get = &cdrGet };
}

test "cft: ContentFilteredTopicImpl lifecycle and expression parsing" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create a ContentFilteredTopic with a filter expression.
    const cft_dds = fx.dp_r.create_contentfilteredtopic(
        "CftFiltered",
        fx.topic_r,
        "value = 66",
        &DDS.StringSeq{},
    );
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);

    // Retrieve the impl and verify the expression was stored.
    try testing.expectEqualStrings("value = 66", cft_dds.get_filter_expression());

    // The parsed_expr should be non-null (content_subscription_profile = true by default).
    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));
    try testing.expect(cft_impl.parsed_expr != null);
}

test "cft: matchSample evaluates filter against field accessor" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Filter: value = 66 (0x42).
    const cft_dds = fx.dp_r.create_contentfilteredtopic(
        "CftFiltered2",
        fx.topic_r,
        "value = 66",
        &DDS.StringSeq{},
    );
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);
    const cft: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));

    // Matching payload: byte 4 = 0x42 = 66.
    const match_payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x42 };
    var ctx_match = CdrCtx{ .data = &match_payload };
    try testing.expect(cft.matchSample(makeCdrAccessor(&ctx_match)));

    // Non-matching payload: byte 4 = 0x63 = 99.
    const no_match_payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x63 };
    var ctx_no = CdrCtx{ .data = &no_match_payload };
    try testing.expect(!cft.matchSample(makeCdrAccessor(&ctx_no)));
}

test "cft: end-to-end sample delivery with post-take filtering" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create CFT DataReader subscribed to topic_r via a ContentFilteredTopic.
    const cft_dds = fx.dp_r.create_contentfilteredtopic(
        "CftE2E",
        fx.topic_r,
        "value > 70",
        &DDS.StringSeq{},
    );
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);
    const cft: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));

    const cft_td = cft.toTopicDescription();
    const dr_raw = fx.sub_r.create_datareader(cft_td, .{}, null, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));

    // Write payload with value = 0x42 = 66 (should NOT pass "value > 70").
    const low_payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x42 }; // 66
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &low_payload);

    // Write payload with value = 0x80 = 128 (should pass "value > 70").
    const high_payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x80 }; // 128
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &high_payload);

    // Drain all samples, apply the CFT filter manually (typed-wrapper style).
    var passing = std.ArrayListUnmanaged(TakenSample).empty;
    defer {
        for (passing.items) |s| alloc.free(s.data);
        passing.deinit(alloc);
    }
    while (dr.takeRaw()) |sample| {
        var ctx = CdrCtx{ .data = sample.data };
        if (cft.matchSample(makeCdrAccessor(&ctx))) {
            try passing.append(alloc, sample);
        } else {
            alloc.free(sample.data);
        }
    }

    try testing.expectEqual(@as(usize, 1), passing.items.len);
    try testing.expectEqual(@as(u8, 0x80), passing.items[0].data[4]);
}

test "cft: set_expression_parameters updates params" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const cft_dds = fx.dp_r.create_contentfilteredtopic(
        "CftParams",
        fx.topic_r,
        "value = %0",
        &DDS.StringSeq{},
    );
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);

    // Update the parameter.
    var new_param_strs: [1][*:0]const u8 = .{"99"};
    var new_params = DDS.StringSeq{ ._buffer = @ptrCast(&new_param_strs), ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, cft_dds.vtable.set_expression_parameters(cft_dds.ptr, &new_params));

    const cft: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));
    try testing.expectEqual(@as(usize, 1), cft.expr_params.items.len);
    try testing.expectEqualStrings("99", cft.expr_params.items[0]);
}

test "cft: set_expression_parameters OOM mid-loop preserves old params" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const cft_dds = fx.dp_r.create_contentfilteredtopic(
        "CftOomParams",
        fx.topic_r,
        "value = %0 AND value = %1",
        &DDS.StringSeq{},
    );
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);

    // Establish initial params so there's something to preserve.
    var p0_strs = [1][*:0]const u8{"42"};
    var p0 = DDS.StringSeq{ ._buffer = @ptrCast(&p0_strs), ._length = 1, ._maximum = 1, ._release = false };
    _ = cft_dds.vtable.set_expression_parameters(cft_dds.ptr, &p0);

    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));
    try testing.expectEqual(@as(usize, 1), cft_impl.expr_params.items.len);

    // Inject a FailingAllocator: fail_index=0 fails the very first dupe in the loop,
    // exercising the path where no tmp allocations succeeded yet.
    var fa = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const saved_alloc = cft_impl.alloc;
    cft_impl.alloc = fa.allocator();

    var new_strs = [2][*:0]const u8{ "new_x", "new_y" };
    var new_params = DDS.StringSeq{ ._buffer = @ptrCast(&new_strs), ._length = 2, ._maximum = 2, ._release = false };
    const rc = cft_dds.vtable.set_expression_parameters(cft_dds.ptr, &new_params);

    cft_impl.alloc = saved_alloc; // restore before deinit

    try testing.expectEqual(DDS.RETCODE_OUT_OF_RESOURCES, rc);
    // Old params must be intact.
    try testing.expectEqual(@as(usize, 1), cft_impl.expr_params.items.len);
    try testing.expectEqualStrings("42", cft_impl.expr_params.items[0]);
}

test "cft: set_expression_parameters OOM after first string duped preserves old params" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const cft_dds = fx.dp_r.create_contentfilteredtopic(
        "CftOomMid",
        fx.topic_r,
        "value = %0 AND value = %1",
        &DDS.StringSeq{},
    );
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft_dds);

    var p0_strs = [1][*:0]const u8{"99"};
    var p0 = DDS.StringSeq{ ._buffer = @ptrCast(&p0_strs), ._length = 1, ._maximum = 1, ._release = false };
    _ = cft_dds.vtable.set_expression_parameters(cft_dds.ptr, &p0);

    const cft_impl: *ContentFilteredTopicImpl = @ptrCast(@alignCast(cft_dds.ptr));

    // fail_index=2: first dupe (alloc 0) and first append's capacity alloc (alloc 1) succeed,
    // second dupe (alloc 2) fails — exercises mid-loop cleanup of the partial tmp list.
    var fa = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 2 });
    const saved_alloc = cft_impl.alloc;
    cft_impl.alloc = fa.allocator();

    var new_strs = [2][*:0]const u8{ "new_a", "new_b" };
    var new_params = DDS.StringSeq{ ._buffer = @ptrCast(&new_strs), ._length = 2, ._maximum = 2, ._release = false };
    const rc = cft_dds.vtable.set_expression_parameters(cft_dds.ptr, &new_params);

    cft_impl.alloc = saved_alloc;

    try testing.expectEqual(DDS.RETCODE_OUT_OF_RESOURCES, rc);
    try testing.expectEqual(@as(usize, 1), cft_impl.expr_params.items.len);
    try testing.expectEqualStrings("99", cft_impl.expr_params.items[0]);
}
