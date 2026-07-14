//! Direct in-process discovery for deterministic DCPS testing.
//!
//! Replaces SPDP/SEDP (which require timer threads and network traffic) with
//! a shared in-process registry. When a writer or reader is announced, all
//! other registered participants are notified synchronously — no UDP, no
//! timer threads, no sleeps needed in tests.
//!
//! Participants share one DiscoveryBus (created by IntraProcessDelivery or
//! directly in tests). Each participant gets its own DirectDiscovery instance
//! pointing to the shared bus.
//!
//! Thread safety:
//!   DiscoveryBus.mu guards the entries list and endpoint announcement lists.
//!   Callbacks are fired WITHOUT holding the bus mutex to allow callbacks to
//!   re-enter the bus (e.g. a callback calling announceReader) without deadlock.
//!   participant.zig already calls announceWriter/announceReader outside its own
//!   participant.mu, so no mutex ordering issue arises there either.
//!
//! See also: transport/memory.zig, delivery/intraprocess.zig

const std = @import("std");
const disc_iface = @import("interface.zig");
const mutex_mod = @import("../util/mutex.zig");
const header_mod = @import("../rtps/message/header.zig");

pub const Discovery = disc_iface.Discovery;
pub const Callbacks = disc_iface.Callbacks;
pub const ParticipantAnnouncement = disc_iface.ParticipantAnnouncement;
pub const ParticipantData = disc_iface.ParticipantData;
pub const WriterAnnouncement = disc_iface.WriterAnnouncement;
pub const WriterData = disc_iface.WriterData;
pub const ReaderAnnouncement = disc_iface.ReaderAnnouncement;
pub const ReaderData = disc_iface.ReaderData;
pub const Guid = disc_iface.Guid;
pub const Locator = @import("../transport/interface.zig").Locator;

// ── DiscoveryBus ──────────────────────────────────────────────────────────────

/// Shared endpoint registry for a set of DirectDiscovery instances.
/// One bus per IntraProcessDelivery (or per test scenario).
pub const DiscoveryBus = struct {
    alloc: std.mem.Allocator,
    mu: mutex_mod.Mutex,
    entries: std.ArrayListUnmanaged(Entry),

    const Entry = struct {
        participant_guid: Guid,
        domain_id: u32,
        callbacks: Callbacks,
        /// Heap-owned copy of ParticipantAnnouncement.default_unicast_locators.
        /// Used to populate WriterData/ReaderData.unicast_locators on behalf of
        /// this participant's endpoints.
        data_locators: []Locator,
        writers: std.ArrayListUnmanaged(WriterAnnouncement),
        readers: std.ArrayListUnmanaged(ReaderAnnouncement),

        fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
            alloc.free(self.data_locators);
            self.writers.deinit(alloc);
            self.readers.deinit(alloc);
        }
    };

    pub fn init(alloc: std.mem.Allocator) !*DiscoveryBus {
        const self = try alloc.create(DiscoveryBus);
        self.* = .{
            .alloc = alloc,
            .mu = .{},
            .entries = .empty,
        };
        return self;
    }

    pub fn deinit(self: *DiscoveryBus) void {
        for (self.entries.items) |*e| e.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // ── Internal: called by DirectDiscovery vtable functions ─────────────────

    fn busStart(
        self: *DiscoveryBus,
        local: *const ParticipantAnnouncement,
        callbacks: *const Callbacks,
    ) !void {
        // Copy data locators — the announcement's slices are stack-allocated
        // in participant.zig:start() and freed after the call returns.
        const locs_copy = try self.alloc.dupe(Locator, local.default_unicast_locators);
        errdefer self.alloc.free(locs_copy);

        // Snapshot existing entries in the same domain before adding the new one.
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.entries.items) |*e| {
                if (e.domain_id != local.domain_id) continue;
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.from(e);
                    snap_count += 1;
                }
            }
            try self.entries.append(self.alloc, .{
                .participant_guid = local.guid,
                .domain_id = local.domain_id,
                .callbacks = callbacks.*,
                .data_locators = locs_copy,
                .writers = .empty,
                .readers = .empty,
            });
        }

        // Notify the new participant about all existing writers and readers.
        const new_callbacks = callbacks;
        for (snapshots[0..snap_count]) |snap| {
            // Participant-level notification.
            const pd = ParticipantData{
                .guid = snap.participant_guid,
                .domain_id = snap.domain_id,
                .name = "",
                .metatraffic_unicast_locators = &.{},
                .metatraffic_multicast_locators = &.{},
                .default_unicast_locators = snap.data_locators,
                .default_multicast_locators = &.{},
                .lease_duration_ms = std.math.maxInt(u32),
                .builtin_endpoint_set = 0,
                .vendor_id = header_mod.VENDOR_ID,
            };
            new_callbacks.on_participant_discovered(new_callbacks.ctx, &pd);

            for (snap.writers[0..snap.writer_count]) |w| {
                const wd = makeWriterData(&w, snap.data_locators);
                new_callbacks.on_writer_discovered(new_callbacks.ctx, &wd);
            }
            for (snap.readers[0..snap.reader_count]) |r| {
                const rd = makeReaderData(&r, snap.data_locators);
                new_callbacks.on_reader_discovered(new_callbacks.ctx, &rd);
            }
        }

        // Notify all existing participants about the new participant.
        const new_pd = ParticipantData{
            .guid = local.guid,
            .domain_id = local.domain_id,
            .name = local.name,
            .metatraffic_unicast_locators = &.{},
            .metatraffic_multicast_locators = &.{},
            .default_unicast_locators = locs_copy,
            .default_multicast_locators = &.{},
            .lease_duration_ms = local.lease_duration_ms,
            .builtin_endpoint_set = local.builtin_endpoint_set,
            .vendor_id = header_mod.VENDOR_ID,
        };
        for (snapshots[0..snap_count]) |snap| {
            snap.callbacks.on_participant_discovered(snap.callbacks.ctx, &new_pd);
        }
    }

    fn busStop(self: *DiscoveryBus, participant_guid: Guid) void {
        // Snapshot the entry's writers and readers + collect other entries' callbacks.
        var lost_writers: [64]WriterAnnouncement = undefined;
        var lost_readers: [64]ReaderAnnouncement = undefined;
        var lost_w_count: usize = 0;
        var lost_r_count: usize = 0;
        var other_entries: [64]EntrySnapshot = undefined;
        var other_count: usize = 0;
        var entry_data_locs: []Locator = &.{};
        var own_domain_id: u32 = 0;

        self.mu.lock();
        var found_idx: ?usize = null;
        for (self.entries.items, 0..) |*e, i| {
            if (e.participant_guid.eql(participant_guid)) {
                found_idx = i;
                own_domain_id = e.domain_id;
                const n_w = @min(e.writers.items.len, lost_writers.len);
                @memcpy(lost_writers[0..n_w], e.writers.items[0..n_w]);
                lost_w_count = n_w;
                const n_r = @min(e.readers.items.len, lost_readers.len);
                @memcpy(lost_readers[0..n_r], e.readers.items[0..n_r]);
                lost_r_count = n_r;
                entry_data_locs = e.data_locators;
            } else {
                if (other_count < other_entries.len) {
                    other_entries[other_count] = EntrySnapshot.from(e);
                    other_count += 1;
                }
            }
        }
        if (found_idx) |idx| {
            var e = self.entries.swapRemove(idx);
            e.writers.deinit(self.alloc);
            e.readers.deinit(self.alloc);
            self.alloc.free(entry_data_locs);
        }
        self.mu.unlock();

        // Filter to same-domain peers.
        var filtered: usize = 0;
        for (other_entries[0..other_count]) |snap| {
            if (snap.domain_id == own_domain_id) {
                other_entries[filtered] = snap;
                filtered += 1;
            }
        }
        other_count = filtered;

        // Notify all remaining participants about lost endpoints.
        for (other_entries[0..other_count]) |snap| {
            for (lost_writers[0..lost_w_count]) |w| {
                snap.callbacks.on_writer_lost(snap.callbacks.ctx, w.guid);
            }
            for (lost_readers[0..lost_r_count]) |r| {
                snap.callbacks.on_reader_lost(snap.callbacks.ctx, r.guid);
            }
            snap.callbacks.on_participant_lost(snap.callbacks.ctx, participant_guid);
        }
    }

    fn busAnnounceWriter(self: *DiscoveryBus, participant_guid: Guid, info: *const WriterAnnouncement) !void {
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        var writer_data_locs: []const Locator = &.{};
        var own_callbacks: ?Callbacks = null;
        var own_domain_id: u32 = 0;

        self.mu.lock();
        for (self.entries.items) |*e| {
            if (e.participant_guid.eql(participant_guid)) {
                try e.writers.append(self.alloc, info.*);
                writer_data_locs = e.data_locators;
                own_callbacks = e.callbacks;
                own_domain_id = e.domain_id;
            } else {
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.from(e);
                    snap_count += 1;
                }
            }
        }
        self.mu.unlock();

        // Filter to same-domain peers.
        var filtered: usize = 0;
        for (snapshots[0..snap_count]) |snap| {
            if (snap.domain_id == own_domain_id) {
                snapshots[filtered] = snap;
                filtered += 1;
            }
        }
        snap_count = filtered;

        // Tell other participants about this new writer.
        const wd = makeWriterData(info, writer_data_locs);
        for (snapshots[0..snap_count]) |snap| {
            snap.callbacks.on_writer_discovered(snap.callbacks.ctx, &wd);
        }
        // Tell the announcing participant about all existing readers on other
        // participants so it can add reader proxies to the new writer.
        if (own_callbacks) |cb| {
            for (snapshots[0..snap_count]) |snap| {
                for (snap.readers[0..snap.reader_count]) |r| {
                    const rd = makeReaderData(&r, snap.data_locators);
                    cb.on_reader_discovered(cb.ctx, &rd);
                }
            }
        }
    }

    fn busRetractWriter(self: *DiscoveryBus, participant_guid: Guid, guid: Guid) void {
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        var own_domain_id: u32 = 0;

        self.mu.lock();
        for (self.entries.items) |*e| {
            if (e.participant_guid.eql(participant_guid)) {
                own_domain_id = e.domain_id;
                var i = e.writers.items.len;
                while (i > 0) {
                    i -= 1;
                    if (e.writers.items[i].guid.eql(guid)) {
                        _ = e.writers.swapRemove(i);
                        break;
                    }
                }
            } else {
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.from(e);
                    snap_count += 1;
                }
            }
        }
        self.mu.unlock();

        var filtered: usize = 0;
        for (snapshots[0..snap_count]) |snap| {
            if (snap.domain_id == own_domain_id) {
                snapshots[filtered] = snap;
                filtered += 1;
            }
        }
        snap_count = filtered;

        for (snapshots[0..snap_count]) |snap| {
            snap.callbacks.on_writer_lost(snap.callbacks.ctx, guid);
        }
    }

    fn busAnnounceReader(self: *DiscoveryBus, participant_guid: Guid, info: *const ReaderAnnouncement) !void {
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        var reader_data_locs: []const Locator = &.{};
        var own_callbacks: ?Callbacks = null;
        var own_domain_id: u32 = 0;

        self.mu.lock();
        for (self.entries.items) |*e| {
            if (e.participant_guid.eql(participant_guid)) {
                try e.readers.append(self.alloc, info.*);
                reader_data_locs = e.data_locators;
                own_callbacks = e.callbacks;
                own_domain_id = e.domain_id;
            } else {
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.from(e);
                    snap_count += 1;
                }
            }
        }
        self.mu.unlock();

        // Filter to same-domain peers.
        var filtered: usize = 0;
        for (snapshots[0..snap_count]) |snap| {
            if (snap.domain_id == own_domain_id) {
                snapshots[filtered] = snap;
                filtered += 1;
            }
        }
        snap_count = filtered;

        // Tell the announcing participant about all existing writers on other
        // participants FIRST so it has WriterProxies in place before the writer
        // side fires on_reader_discovered (which may trigger synchronous history
        // replay via MemoryTransport — the reader must pass isWriterMatched).
        if (own_callbacks) |cb| {
            for (snapshots[0..snap_count]) |snap| {
                for (snap.writers[0..snap.writer_count]) |w| {
                    const wd = makeWriterData(&w, snap.data_locators);
                    cb.on_writer_discovered(cb.ctx, &wd);
                }
            }
        }
        // Tell other participants about this new reader.
        const rd = makeReaderData(info, reader_data_locs);
        for (snapshots[0..snap_count]) |snap| {
            snap.callbacks.on_reader_discovered(snap.callbacks.ctx, &rd);
        }
    }

    fn busRetractReader(self: *DiscoveryBus, participant_guid: Guid, guid: Guid) void {
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        var own_domain_id: u32 = 0;

        self.mu.lock();
        for (self.entries.items) |*e| {
            if (e.participant_guid.eql(participant_guid)) {
                own_domain_id = e.domain_id;
                var i = e.readers.items.len;
                while (i > 0) {
                    i -= 1;
                    if (e.readers.items[i].guid.eql(guid)) {
                        _ = e.readers.swapRemove(i);
                        break;
                    }
                }
            } else {
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.from(e);
                    snap_count += 1;
                }
            }
        }
        self.mu.unlock();

        var filtered: usize = 0;
        for (snapshots[0..snap_count]) |snap| {
            if (snap.domain_id == own_domain_id) {
                snapshots[filtered] = snap;
                filtered += 1;
            }
        }
        snap_count = filtered;

        for (snapshots[0..snap_count]) |snap| {
            snap.callbacks.on_reader_lost(snap.callbacks.ctx, guid);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Small snapshot of an entry taken under the bus lock.
    /// Borrows writer/reader slices — valid while the entry exists in the bus.
    const EntrySnapshot = struct {
        participant_guid: Guid,
        domain_id: u32,
        callbacks: Callbacks,
        data_locators: []const Locator,
        writers: [32]WriterAnnouncement,
        writer_count: usize,
        readers: [32]ReaderAnnouncement,
        reader_count: usize,

        fn from(e: *const Entry) EntrySnapshot {
            var snap = EntrySnapshot{
                .participant_guid = e.participant_guid,
                .domain_id = e.domain_id,
                .callbacks = e.callbacks,
                .data_locators = e.data_locators,
                .writers = undefined,
                .writer_count = 0,
                .readers = undefined,
                .reader_count = 0,
            };
            snap.writer_count = @min(e.writers.items.len, snap.writers.len);
            @memcpy(snap.writers[0..snap.writer_count], e.writers.items[0..snap.writer_count]);
            snap.reader_count = @min(e.readers.items.len, snap.readers.len);
            @memcpy(snap.readers[0..snap.reader_count], e.readers.items[0..snap.reader_count]);
            return snap;
        }
    };
};

fn makeWriterData(ann: *const WriterAnnouncement, data_locs: []const Locator) WriterData {
    return .{
        .guid = ann.guid,
        .participant_guid = ann.participant_guid,
        .topic_name = ann.topic_name,
        .type_name = ann.type_name,
        .qos = ann.qos,
        .unicast_locators = data_locs,
        .multicast_locators = &.{},
        .type_object = ann.type_object,
    };
}

fn makeReaderData(ann: *const ReaderAnnouncement, data_locs: []const Locator) ReaderData {
    return .{
        .guid = ann.guid,
        .participant_guid = ann.participant_guid,
        .topic_name = ann.topic_name,
        .type_name = ann.type_name,
        .qos = ann.qos,
        .unicast_locators = data_locs,
        .multicast_locators = &.{},
    };
}

// ── DirectDiscovery ───────────────────────────────────────────────────────────

/// Per-participant discovery plugin backed by a shared DiscoveryBus.
/// Create via IntraProcessDelivery.newDiscovery() or DiscoveryBus directly.
/// Caller owns this object; call deinit() to free.
pub const DirectDiscovery = struct {
    alloc: std.mem.Allocator,
    bus: *DiscoveryBus,
    participant_guid: Guid,
    started: bool,

    pub fn init(alloc: std.mem.Allocator, bus: *DiscoveryBus) !*DirectDiscovery {
        const self = try alloc.create(DirectDiscovery);
        self.* = .{
            .alloc = alloc,
            .bus = bus,
            .participant_guid = Guid.unknown,
            .started = false,
        };
        return self;
    }

    pub fn deinit(self: *DirectDiscovery) void {
        self.alloc.destroy(self);
    }

    pub fn toDiscovery(self: *DirectDiscovery) Discovery {
        return .{ .ctx = self, .vtable = &direct_vtable };
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtStart(
        ctx: *anyopaque,
        local: *const ParticipantAnnouncement,
        callbacks: *const Callbacks,
    ) anyerror!void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.participant_guid = local.guid;
        self.started = true;
        try self.bus.busStart(local, callbacks);
    }

    fn vtStop(ctx: *anyopaque) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        if (self.started) {
            self.bus.busStop(self.participant_guid);
            self.started = false;
        }
    }

    fn vtAnnounceWriter(ctx: *anyopaque, info: *const WriterAnnouncement) anyerror!void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        try self.bus.busAnnounceWriter(self.participant_guid, info);
    }

    fn vtRetractWriter(ctx: *anyopaque, guid: Guid) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.bus.busRetractWriter(self.participant_guid, guid);
    }

    fn vtAnnounceReader(ctx: *anyopaque, info: *const ReaderAnnouncement) anyerror!void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        try self.bus.busAnnounceReader(self.participant_guid, info);
    }

    fn vtRetractReader(ctx: *anyopaque, guid: Guid) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.bus.busRetractReader(self.participant_guid, guid);
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

const direct_vtable = Discovery.Vtable{
    .start = DirectDiscovery.vtStart,
    .stop = DirectDiscovery.vtStop,
    .announce_writer = DirectDiscovery.vtAnnounceWriter,
    .retract_writer = DirectDiscovery.vtRetractWriter,
    .announce_reader = DirectDiscovery.vtAnnounceReader,
    .retract_reader = DirectDiscovery.vtRetractReader,
    .deinit = DirectDiscovery.vtDeinit,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const guid_mod = @import("../rtps/guid.zig");

fn makeGuid(prefix_byte: u8) guid_mod.Guid {
    var bytes: [12]u8 = std.mem.zeroes([12]u8);
    bytes[0] = prefix_byte;
    return .{
        .prefix = .{ .bytes = bytes },
        .entity_id = .{ .entity_key = .{ 0, 0, 0 }, .entity_kind = 1 },
    };
}

fn makeWriterGuid(prefix_byte: u8, key: u8) guid_mod.Guid {
    var bytes: [12]u8 = std.mem.zeroes([12]u8);
    bytes[0] = prefix_byte;
    return .{
        .prefix = .{ .bytes = bytes },
        .entity_id = .{ .entity_key = .{ key, 0, 0 }, .entity_kind = 2 },
    };
}

fn makeReaderGuid(prefix_byte: u8, key: u8) guid_mod.Guid {
    var bytes: [12]u8 = std.mem.zeroes([12]u8);
    bytes[0] = prefix_byte;
    return .{
        .prefix = .{ .bytes = bytes },
        .entity_id = .{ .entity_key = .{ key, 0, 0 }, .entity_kind = 4 },
    };
}

const TestCallbacks = struct {
    alloc: std.mem.Allocator,
    writers_discovered: std.ArrayListUnmanaged(Guid),
    readers_discovered: std.ArrayListUnmanaged(Guid),
    writers_lost: std.ArrayListUnmanaged(Guid),
    readers_lost: std.ArrayListUnmanaged(Guid),

    fn init(alloc: std.mem.Allocator) TestCallbacks {
        return .{
            .alloc = alloc,
            .writers_discovered = .empty,
            .readers_discovered = .empty,
            .writers_lost = .empty,
            .readers_lost = .empty,
        };
    }

    fn deinit(self: *TestCallbacks) void {
        self.writers_discovered.deinit(self.alloc);
        self.readers_discovered.deinit(self.alloc);
        self.writers_lost.deinit(self.alloc);
        self.readers_lost.deinit(self.alloc);
    }

    fn callbacks(self: *TestCallbacks) Callbacks {
        return .{
            .ctx = self,
            .on_participant_discovered = onPart,
            .on_participant_lost = onPartLost,
            .on_writer_discovered = onWriterDisc,
            .on_writer_lost = onWriterLost,
            .on_reader_discovered = onReaderDisc,
            .on_reader_lost = onReaderLost,
        };
    }

    fn onPart(_: *anyopaque, _: *const ParticipantData) void {}
    fn onPartLost(_: *anyopaque, _: Guid) void {}

    fn onWriterDisc(ctx: *anyopaque, data: *const WriterData) void {
        const self: *TestCallbacks = @ptrCast(@alignCast(ctx));
        self.writers_discovered.append(self.alloc, data.guid) catch {};
    }

    fn onWriterLost(ctx: *anyopaque, guid: Guid) void {
        const self: *TestCallbacks = @ptrCast(@alignCast(ctx));
        self.writers_lost.append(self.alloc, guid) catch {};
    }

    fn onReaderDisc(ctx: *anyopaque, data: *const ReaderData) void {
        const self: *TestCallbacks = @ptrCast(@alignCast(ctx));
        self.readers_discovered.append(self.alloc, data.guid) catch {};
    }

    fn onReaderLost(ctx: *anyopaque, guid: Guid) void {
        const self: *TestCallbacks = @ptrCast(@alignCast(ctx));
        self.readers_lost.append(self.alloc, guid) catch {};
    }
};

test "announce writer notifies other participant immediately" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();

    const disc1 = try DirectDiscovery.init(alloc, bus);
    defer disc1.deinit();
    const disc2 = try DirectDiscovery.init(alloc, bus);
    defer disc2.deinit();

    var cb1 = TestCallbacks.init(alloc);
    defer cb1.deinit();
    var cb2 = TestCallbacks.init(alloc);
    defer cb2.deinit();

    const ann1 = ParticipantAnnouncement{
        .guid = makeGuid(1),
        .domain_id = 0,
        .name = "p1",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    const ann2 = ParticipantAnnouncement{
        .guid = makeGuid(2),
        .domain_id = 0,
        .name = "p2",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };

    var cbs1 = cb1.callbacks();
    var cbs2 = cb2.callbacks();
    try disc1.toDiscovery().start(&ann1, &cbs1);
    try disc2.toDiscovery().start(&ann2, &cbs2);

    const writer_guid = makeWriterGuid(1, 1);
    try disc1.toDiscovery().announceWriter(&WriterAnnouncement{
        .guid = writer_guid,
        .participant_guid = makeGuid(1),
        .topic_name = "TestTopic",
        .type_name = "TestType",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });

    // cb2 should have received on_writer_discovered synchronously.
    try testing.expectEqual(@as(usize, 1), cb2.writers_discovered.items.len);
    try testing.expect(cb2.writers_discovered.items[0].eql(writer_guid));
    // cb1 (the announcing participant) should not see its own writer.
    try testing.expectEqual(@as(usize, 0), cb1.writers_discovered.items.len);
}

test "late joiner receives existing writers and readers" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();

    const disc1 = try DirectDiscovery.init(alloc, bus);
    defer disc1.deinit();
    const disc2 = try DirectDiscovery.init(alloc, bus);
    defer disc2.deinit();

    var cb1 = TestCallbacks.init(alloc);
    defer cb1.deinit();
    var cb2 = TestCallbacks.init(alloc);
    defer cb2.deinit();

    const ann1 = ParticipantAnnouncement{
        .guid = makeGuid(1),
        .domain_id = 0,
        .name = "p1",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    var cbs1 = cb1.callbacks();
    try disc1.toDiscovery().start(&ann1, &cbs1);

    // Announce writer on disc1 BEFORE disc2 joins.
    const writer_guid = makeWriterGuid(1, 1);
    const reader_guid = makeReaderGuid(1, 1);
    try disc1.toDiscovery().announceWriter(&WriterAnnouncement{
        .guid = writer_guid,
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try disc1.toDiscovery().announceReader(&ReaderAnnouncement{
        .guid = reader_guid,
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_info_cdr = &.{},
    });

    // Now disc2 joins — should immediately learn about the existing endpoints.
    const ann2 = ParticipantAnnouncement{
        .guid = makeGuid(2),
        .domain_id = 0,
        .name = "p2",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    var cbs2 = cb2.callbacks();
    try disc2.toDiscovery().start(&ann2, &cbs2);

    try testing.expectEqual(@as(usize, 1), cb2.writers_discovered.items.len);
    try testing.expect(cb2.writers_discovered.items[0].eql(writer_guid));
    try testing.expectEqual(@as(usize, 1), cb2.readers_discovered.items.len);
    try testing.expect(cb2.readers_discovered.items[0].eql(reader_guid));
}

test "retract writer fires on_writer_lost on peers" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();

    const disc1 = try DirectDiscovery.init(alloc, bus);
    defer disc1.deinit();
    const disc2 = try DirectDiscovery.init(alloc, bus);
    defer disc2.deinit();

    var cb1 = TestCallbacks.init(alloc);
    defer cb1.deinit();
    var cb2 = TestCallbacks.init(alloc);
    defer cb2.deinit();

    const ann1 = ParticipantAnnouncement{
        .guid = makeGuid(1),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    const ann2 = ParticipantAnnouncement{
        .guid = makeGuid(2),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    var cbs1 = cb1.callbacks();
    var cbs2 = cb2.callbacks();
    try disc1.toDiscovery().start(&ann1, &cbs1);
    try disc2.toDiscovery().start(&ann2, &cbs2);

    const writer_guid = makeWriterGuid(1, 1);
    try disc1.toDiscovery().announceWriter(&WriterAnnouncement{
        .guid = writer_guid,
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try testing.expectEqual(@as(usize, 1), cb2.writers_discovered.items.len);

    disc1.toDiscovery().retractWriter(writer_guid);
    try testing.expectEqual(@as(usize, 1), cb2.writers_lost.items.len);
    try testing.expect(cb2.writers_lost.items[0].eql(writer_guid));
}

test "participants on different domains do not discover each other" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();

    const disc0 = try DirectDiscovery.init(alloc, bus);
    defer disc0.deinit();
    const disc1 = try DirectDiscovery.init(alloc, bus);
    defer disc1.deinit();

    var cb0 = TestCallbacks.init(alloc);
    defer cb0.deinit();
    var cb1 = TestCallbacks.init(alloc);
    defer cb1.deinit();

    // disc0 on domain 0, disc1 on domain 1.
    const ann0 = ParticipantAnnouncement{
        .guid = makeGuid(1),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    const ann1 = ParticipantAnnouncement{
        .guid = makeGuid(2),
        .domain_id = 1,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    var cbs0 = cb0.callbacks();
    var cbs1 = cb1.callbacks();
    try disc0.toDiscovery().start(&ann0, &cbs0);
    try disc1.toDiscovery().start(&ann1, &cbs1);

    // Writer on domain 0 — domain-1 participant must not see it.
    const writer_guid = makeWriterGuid(1, 1);
    try disc0.toDiscovery().announceWriter(&WriterAnnouncement{
        .guid = writer_guid,
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try testing.expectEqual(@as(usize, 0), cb1.writers_discovered.items.len);

    // Reader on domain 1 — domain-0 participant must not see it.
    const reader_guid = makeReaderGuid(2, 1);
    try disc1.toDiscovery().announceReader(&ReaderAnnouncement{
        .guid = reader_guid,
        .participant_guid = makeGuid(2),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_info_cdr = &.{},
    });
    try testing.expectEqual(@as(usize, 0), cb0.readers_discovered.items.len);

    // Retract — should not fire on the cross-domain participant.
    disc0.toDiscovery().retractWriter(writer_guid);
    try testing.expectEqual(@as(usize, 0), cb1.writers_lost.items.len);

    disc1.toDiscovery().retractReader(reader_guid);
    try testing.expectEqual(@as(usize, 0), cb0.readers_lost.items.len);

    // Stop — cross-domain participant must not see the lost events.
    disc0.toDiscovery().stop();
    try testing.expectEqual(@as(usize, 0), cb1.writers_lost.items.len);
    try testing.expectEqual(@as(usize, 0), cb1.readers_lost.items.len);
}

test "stop retracts all local endpoints from peers" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();

    const disc1 = try DirectDiscovery.init(alloc, bus);
    defer disc1.deinit();
    const disc2 = try DirectDiscovery.init(alloc, bus);
    defer disc2.deinit();

    var cb1 = TestCallbacks.init(alloc);
    defer cb1.deinit();
    var cb2 = TestCallbacks.init(alloc);
    defer cb2.deinit();

    const ann1 = ParticipantAnnouncement{
        .guid = makeGuid(1),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    const ann2 = ParticipantAnnouncement{
        .guid = makeGuid(2),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    var cbs1 = cb1.callbacks();
    var cbs2 = cb2.callbacks();
    try disc1.toDiscovery().start(&ann1, &cbs1);
    try disc2.toDiscovery().start(&ann2, &cbs2);

    try disc1.toDiscovery().announceWriter(&WriterAnnouncement{
        .guid = makeWriterGuid(1, 1),
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try disc1.toDiscovery().announceReader(&ReaderAnnouncement{
        .guid = makeReaderGuid(1, 1),
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_info_cdr = &.{},
    });

    disc1.toDiscovery().stop();

    try testing.expectEqual(@as(usize, 1), cb2.writers_lost.items.len);
    try testing.expectEqual(@as(usize, 1), cb2.readers_lost.items.len);
}
