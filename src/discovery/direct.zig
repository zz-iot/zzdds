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
const disc_adapter = @import("qos_adapter.zig");
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
        /// Endpoints prepared and not yet announced: `writers` and `readers`
        /// keep capacity for them on top of their items.
        reserved_writers: usize = 0,
        reserved_readers: usize = 0,

        fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
            alloc.free(self.data_locators);
            for (self.writers.items) |*w| w.deinit(alloc);
            self.writers.deinit(alloc);
            for (self.readers.items) |*r| r.deinit(alloc);
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
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.entries.items) |*e| {
                if (e.domain_id != local.domain_id) continue;
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = try EntrySnapshot.copy(e, arena.allocator(), .{ .writers = true, .readers = true });
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

            for (snap.writers) |w| {
                var wq = disc_adapter.writerDiscoveredData(w.qos, w.presentation);
                const wd = makeWriterData(&w, &wq, snap.data_locators);
                new_callbacks.on_writer_discovered(new_callbacks.ctx, &wd);
            }
            for (snap.readers) |r| {
                var rq = disc_adapter.readerDiscoveredData(r.qos, r.presentation);
                const rd = makeReaderData(&r, &rq, snap.data_locators);
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
                    other_entries[other_count] = EntrySnapshot.identity(e);
                    other_count += 1;
                }
            }
        }
        if (found_idx) |idx| {
            var e = self.entries.swapRemove(idx);
            // Only the lost endpoints' GUIDs are used below.
            e.deinit(self.alloc);
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

    const Kind = enum { writers, readers };

    /// Makes room in participant `participant_guid`'s entry for `n` endpoints
    /// of `kind`, announced later without allocating.
    fn busReserve(self: *DiscoveryBus, participant_guid: Guid, comptime kind: Kind, n: usize) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(participant_guid) orelse return;
        const list = &@field(e, @tagName(kind));
        const reserved = &@field(e, "reserved_" ++ @tagName(kind));
        try list.ensureTotalCapacity(self.alloc, list.items.len + reserved.* + n);
        reserved.* += n;
    }

    /// Gives back room for `n` endpoints of `kind` never announced.
    fn busRelease(self: *DiscoveryBus, participant_guid: Guid, comptime kind: Kind, n: usize) void {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(participant_guid) orelse return;
        @field(e, "reserved_" ++ @tagName(kind)) -= n;
    }

    /// Stores `owned` in its participant's entry, in the room `busReserve`
    /// made when `first` (otherwise in place of its earlier copy), and tells
    /// the other participants. Telling them needs copies, so out of memory
    /// it may miss some, which in-process delivery cannot repair.
    fn busAnnounceWriter(self: *DiscoveryBus, participant_guid: Guid, owned: WriterAnnouncement, first: bool) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        var writer_data_locs: []const Locator = &.{};
        var own_callbacks: ?Callbacks = null;
        var info: ?WriterAnnouncement = null;

        {
            self.mu.lock();
            defer self.mu.unlock();
            const e = self.findLocked(participant_guid) orelse {
                var o = owned;
                o.deinit(self.alloc);
                return;
            };
            storeEndpoint(WriterAnnouncement, self.alloc, &e.writers, &e.reserved_writers, owned, first);
            // A copy to tell from: the stored one is the entry's.
            info = owned.clone(arena.allocator()) catch null;
            writer_data_locs = arena.allocator().dupe(Locator, e.data_locators) catch &.{};
            own_callbacks = e.callbacks;
            // Same-domain peers.
            for (self.entries.items) |*peer| {
                if (peer == e or peer.domain_id != e.domain_id) continue;
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.copy(peer, arena.allocator(), .{ .writers = false, .readers = true }) catch continue;
                    snap_count += 1;
                }
            }
        }
        const ann = info orelse return;

        // Tell other participants about this new writer.
        var wq = disc_adapter.writerDiscoveredData(ann.qos, ann.presentation);
        const wd = makeWriterData(&ann, &wq, writer_data_locs);
        for (snapshots[0..snap_count]) |snap| {
            snap.callbacks.on_writer_discovered(snap.callbacks.ctx, &wd);
        }
        // Tell the announcing participant about all existing readers on other
        // participants so it can add reader proxies to the new writer.
        if (own_callbacks) |cb| {
            for (snapshots[0..snap_count]) |snap| {
                for (snap.readers) |r| {
                    var rq = disc_adapter.readerDiscoveredData(r.qos, r.presentation);
                    const rd = makeReaderData(&r, &rq, snap.data_locators);
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
                        var removed = e.writers.swapRemove(i);
                        removed.deinit(self.alloc);
                        break;
                    }
                }
            } else {
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.identity(e);
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

    /// `busAnnounceWriter`, for a reader.
    fn busAnnounceReader(self: *DiscoveryBus, participant_guid: Guid, owned: ReaderAnnouncement, first: bool) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var snapshots: [64]EntrySnapshot = undefined;
        var snap_count: usize = 0;
        var reader_data_locs: []const Locator = &.{};
        var own_callbacks: ?Callbacks = null;
        var info: ?ReaderAnnouncement = null;

        {
            self.mu.lock();
            defer self.mu.unlock();
            const e = self.findLocked(participant_guid) orelse {
                var o = owned;
                o.deinit(self.alloc);
                return;
            };
            storeEndpoint(ReaderAnnouncement, self.alloc, &e.readers, &e.reserved_readers, owned, first);
            info = owned.clone(arena.allocator()) catch null;
            reader_data_locs = arena.allocator().dupe(Locator, e.data_locators) catch &.{};
            own_callbacks = e.callbacks;
            for (self.entries.items) |*peer| {
                if (peer == e or peer.domain_id != e.domain_id) continue;
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.copy(peer, arena.allocator(), .{ .writers = true, .readers = false }) catch continue;
                    snap_count += 1;
                }
            }
        }
        const ann = info orelse return;

        // Tell the announcing participant about all existing writers on other
        // participants FIRST so it has WriterProxies in place before the writer
        // side fires on_reader_discovered (which may trigger synchronous history
        // replay via MemoryTransport — the reader must pass isWriterMatched).
        if (own_callbacks) |cb| {
            for (snapshots[0..snap_count]) |snap| {
                for (snap.writers) |w| {
                    var wq = disc_adapter.writerDiscoveredData(w.qos, w.presentation);
                    const wd = makeWriterData(&w, &wq, snap.data_locators);
                    cb.on_writer_discovered(cb.ctx, &wd);
                }
            }
        }
        // Tell other participants about this new reader.
        var rq = disc_adapter.readerDiscoveredData(ann.qos, ann.presentation);
        const rd = makeReaderData(&ann, &rq, reader_data_locs);
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
                        var removed = e.readers.swapRemove(i);
                        removed.deinit(self.alloc);
                        break;
                    }
                }
            } else {
                if (snap_count < snapshots.len) {
                    snapshots[snap_count] = EntrySnapshot.identity(e);
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

    /// Puts `owned` in `list` without allocating: in a reserved slot when
    /// `first`, else in place of the copy with its GUID.
    fn storeEndpoint(
        comptime T: type,
        alloc: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(T),
        reserved: *usize,
        owned: T,
        first: bool,
    ) void {
        if (!first) for (list.items) |*item| {
            if (item.guid.eql(owned.guid)) {
                item.deinit(alloc);
                item.* = owned;
                return;
            }
        };
        reserved.* -= 1;
        list.appendAssumeCapacity(owned);
    }

    fn findLocked(self: *DiscoveryBus, participant_guid: Guid) ?*Entry {
        for (self.entries.items) |*e| {
            if (e.participant_guid.eql(participant_guid)) return e;
        }
        return null;
    }

    /// An entry as a bus call uses it after releasing the bus lock, taken
    /// under the lock. A retract or stop on another thread may free the
    /// entry's own locators and announcements once the lock is released, so
    /// a snapshot never borrows them: `copy` puts its own copies in the
    /// call's arena, and `identity` takes none.
    const EntrySnapshot = struct {
        participant_guid: Guid,
        domain_id: u32,
        callbacks: Callbacks,
        data_locators: []const Locator = &.{},
        writers: []const WriterAnnouncement = &.{},
        readers: []const ReaderAnnouncement = &.{},

        fn identity(e: *const Entry) EntrySnapshot {
            return .{
                .participant_guid = e.participant_guid,
                .domain_id = e.domain_id,
                .callbacks = e.callbacks,
            };
        }

        /// The endpoint lists a `copy` takes; the others stay empty.
        const Endpoints = struct { writers: bool, readers: bool };

        fn copy(e: *const Entry, arena: std.mem.Allocator, comptime endpoints: Endpoints) !EntrySnapshot {
            var snap = identity(e);
            snap.data_locators = try arena.dupe(Locator, e.data_locators);
            if (endpoints.writers) {
                const writers = try arena.alloc(WriterAnnouncement, e.writers.items.len);
                for (writers, e.writers.items) |*w, src| w.* = try src.clone(arena);
                snap.writers = writers;
            }
            if (endpoints.readers) {
                const readers = try arena.alloc(ReaderAnnouncement, e.readers.items.len);
                for (readers, e.readers.items) |*r, src| r.* = try src.clone(arena);
                snap.readers = readers;
            }
            return snap;
        }
    };
};

fn makeWriterData(
    ann: *const WriterAnnouncement,
    qos: *const disc_iface.DiscoveredWriterData,
    data_locs: []const Locator,
) WriterData {
    return .{
        .guid = ann.guid,
        .participant_guid = ann.participant_guid,
        .topic_name = ann.topic_name,
        .type_name = ann.type_name,
        .qos = qos,
        .partition_names = ann.partition_names,
        .unicast_locators = data_locs,
        .multicast_locators = &.{},
        .type_object = ann.type_object,
    };
}

fn makeReaderData(
    ann: *const ReaderAnnouncement,
    qos: *const disc_iface.DiscoveredReaderData,
    data_locs: []const Locator,
) ReaderData {
    return .{
        .guid = ann.guid,
        .participant_guid = ann.participant_guid,
        .topic_name = ann.topic_name,
        .type_name = ann.type_name,
        .qos = qos,
        .partition_names = ann.partition_names,
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
    mu: mutex_mod.Mutex = .{},
    /// Guarded by `mu`: the bus has this participant's entry, in which each
    /// prepared endpoint has room reserved.
    joined: bool = false,
    /// Guarded by `mu`: the local endpoints prepared and not yet retracted
    /// (docs/design/concurrency/architecture.md#local-endpoint-publication-announcement-and-disposal).
    writers: std.AutoHashMapUnmanaged(Guid, Prepared(WriterAnnouncement)) = .empty,
    readers: std.AutoHashMapUnmanaged(Guid, Prepared(ReaderAnnouncement)) = .empty,

    fn Prepared(comptime T: type) type {
        return struct {
            /// To store on the next announce, until stored.
            pending: ?T,
            /// Room is reserved for it in the bus entry.
            slot: bool,
            announced: bool = false,
        };
    }

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
        inline for (.{ &self.writers, &self.readers }) |map| {
            var it = map.valueIterator();
            while (it.next()) |p| if (p.pending) |*a| a.deinit(self.alloc);
            map.deinit(self.alloc);
        }
        self.mu.deinit();
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
        // Another participant's: one at a time.
        if (self.started) return error.AlreadyStarted;
        self.started = true;
        // The participant stops only what started.
        errdefer self.started = false;
        try self.bus.busStart(local, callbacks);
        errdefer self.bus.busStop(local.guid);
        try self.join(local.guid);
    }

    /// Reserves room in the new bus entry for what was prepared before it.
    fn join(self: *DirectDiscovery, participant_guid: Guid) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const n_w = unslotted(&self.writers);
        const n_r = unslotted(&self.readers);
        try self.bus.busReserve(participant_guid, .writers, n_w);
        errdefer self.bus.busRelease(participant_guid, .writers, n_w);
        try self.bus.busReserve(participant_guid, .readers, n_r);
        inline for (.{ &self.writers, &self.readers }) |map| {
            var it = map.valueIterator();
            while (it.next()) |p| p.slot = true;
        }
        self.participant_guid = participant_guid;
        self.joined = true;
    }

    fn unslotted(map: anytype) usize {
        var n: usize = 0;
        var it = map.valueIterator();
        while (it.next()) |p| n += @intFromBool(!p.slot);
        return n;
    }

    fn vtStop(ctx: *anyopaque) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        if (self.started) {
            self.bus.busStop(self.participant_guid);
            self.mu.lock();
            defer self.mu.unlock();
            // Its room went with the entry.
            self.joined = false;
            inline for (.{ &self.writers, &self.readers }) |map| {
                var it = map.valueIterator();
                while (it.next()) |p| p.slot = false;
            }
            self.started = false;
        }
    }

    fn prepare(self: *DirectDiscovery, comptime kind: DiscoveryBus.Kind, info: anytype) !void {
        var owned = try info.clone(self.alloc);
        errdefer owned.deinit(self.alloc);
        self.mu.lock();
        defer self.mu.unlock();
        const map = &@field(self, @tagName(kind));
        const gop = try map.getOrPut(self.alloc, info.guid);
        if (gop.found_existing) {
            if (gop.value_ptr.pending) |*old| old.deinit(self.alloc);
            gop.value_ptr.pending = owned;
            return;
        }
        if (self.joined) self.bus.busReserve(self.participant_guid, kind, 1) catch |err| {
            map.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = .{ .pending = owned, .slot = self.joined };
    }

    fn announce(self: *DirectDiscovery, comptime kind: DiscoveryBus.Kind, guid: Guid) void {
        const map = &@field(self, @tagName(kind));
        var first = false;
        var participant_guid = Guid.unknown;
        var owned = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            const p = map.getPtr(guid) orelse return;
            const a = p.pending orelse return;
            p.pending = null;
            // Not joined: there is no one to tell.
            if (!p.slot) break :blk a;
            first = !p.announced;
            p.announced = true;
            participant_guid = self.participant_guid;
            break :blk a;
        };
        if (participant_guid.eql(Guid.unknown)) return owned.deinit(self.alloc);
        switch (kind) {
            .writers => self.bus.busAnnounceWriter(participant_guid, owned, first),
            .readers => self.bus.busAnnounceReader(participant_guid, owned, first),
        }
    }

    fn retract(self: *DirectDiscovery, comptime kind: DiscoveryBus.Kind, guid: Guid) void {
        const map = &@field(self, @tagName(kind));
        var participant_guid = Guid.unknown;
        const kv = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            participant_guid = self.participant_guid;
            break :blk map.fetchRemove(guid);
        } orelse return;
        var p = kv.value;
        if (p.pending) |*a| a.deinit(self.alloc);
        if (p.announced) switch (kind) {
            .writers => self.bus.busRetractWriter(participant_guid, guid),
            .readers => self.bus.busRetractReader(participant_guid, guid),
        } else if (p.slot) self.bus.busRelease(participant_guid, kind, 1);
    }

    fn vtPrepareWriter(ctx: *anyopaque, info: *const WriterAnnouncement) anyerror!void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        try self.prepare(.writers, info);
    }

    fn vtAnnounceWriter(ctx: *anyopaque, guid: Guid) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.announce(.writers, guid);
    }

    fn vtRetractWriter(ctx: *anyopaque, guid: Guid) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.retract(.writers, guid);
    }

    fn vtPrepareReader(ctx: *anyopaque, info: *const ReaderAnnouncement) anyerror!void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        try self.prepare(.readers, info);
    }

    fn vtAnnounceReader(ctx: *anyopaque, guid: Guid) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.announce(.readers, guid);
    }

    fn vtRetractReader(ctx: *anyopaque, guid: Guid) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.retract(.readers, guid);
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *DirectDiscovery = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

const direct_vtable = Discovery.Vtable{
    .shared_runtime_ready = true,
    .start = DirectDiscovery.vtStart,
    .stop = DirectDiscovery.vtStop,
    .prepare_writer = DirectDiscovery.vtPrepareWriter,
    .announce_writer = DirectDiscovery.vtAnnounceWriter,
    .retract_writer = DirectDiscovery.vtRetractWriter,
    .prepare_reader = DirectDiscovery.vtPrepareReader,
    .announce_reader = DirectDiscovery.vtAnnounceReader,
    .retract_reader = DirectDiscovery.vtRetractReader,
    .deinit = DirectDiscovery.vtDeinit,
    // DirectDiscovery bypasses the wire entirely (see the module doc comment
    // at the top of this file) -- WLP has nothing to drive here.
    .wlp_tick = noopWlpTick,
};

fn noopWlpTick(_: *anyopaque, _: i64, _: disc_iface.WlpTickInfo) void {}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const guid_mod = @import("../rtps/guid.zig");

/// Prepares and commits a local writer's announcement.
fn announceWriterNow(d: Discovery, ann: *const WriterAnnouncement) !void {
    try d.prepareWriter(ann);
    d.announceWriter(ann.guid);
}

/// Prepares and commits a local reader's announcement.
fn announceReaderNow(d: Discovery, ann: *const ReaderAnnouncement) !void {
    try d.prepareReader(ann);
    d.announceReader(ann.guid);
}

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
            .on_wlp_alive = onWlpAlive,
        };
    }

    fn onWlpAlive(_: *anyopaque, _: disc_iface.GuidPrefix, _: u8) void {}

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
    try announceWriterNow(disc1.toDiscovery(), &WriterAnnouncement{
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
    try announceWriterNow(disc1.toDiscovery(), &WriterAnnouncement{
        .guid = writer_guid,
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try announceReaderNow(disc1.toDiscovery(), &ReaderAnnouncement{
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
    try announceWriterNow(disc1.toDiscovery(), &WriterAnnouncement{
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
    try announceWriterNow(disc0.toDiscovery(), &WriterAnnouncement{
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
    try announceReaderNow(disc1.toDiscovery(), &ReaderAnnouncement{
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

test "a plugin serving a participant refuses another's start, and serves the next once stopped" {
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
    var cbs1 = cb1.callbacks();
    var cbs2 = cb2.callbacks();

    var anns: [3]ParticipantAnnouncement = undefined;
    for (&anns, 1..) |*a, i| a.* = .{
        .guid = makeGuid(@intCast(i)),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    };
    try disc2.toDiscovery().start(&anns[1], &cbs2);
    try disc1.toDiscovery().start(&anns[0], &cbs1);
    try testing.expectError(error.AlreadyStarted, disc1.toDiscovery().start(&anns[2], &cbs1));

    // Still the first participant's: its writer reaches the peer.
    try announceWriterNow(disc1.toDiscovery(), &WriterAnnouncement{
        .guid = makeWriterGuid(1, 1),
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try testing.expectEqual(@as(usize, 1), cb2.writers_discovered.items.len);

    disc1.toDiscovery().stop();
    try disc1.toDiscovery().start(&anns[2], &cbs1);
    disc1.toDiscovery().stop();
    disc2.toDiscovery().stop();
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

    try announceWriterNow(disc1.toDiscovery(), &WriterAnnouncement{
        .guid = makeWriterGuid(1, 1),
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try announceReaderNow(disc1.toDiscovery(), &ReaderAnnouncement{
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

test "a peer's reader retracted from an announcement's callback is still reported from the call's own copy" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();
    const disc1 = try DirectDiscovery.init(alloc, bus);
    defer disc1.deinit();
    const disc2 = try DirectDiscovery.init(alloc, bus);
    defer disc2.deinit();

    // Once armed, participant 1's first on_reader_discovered retracts
    // participant 2's second reader, so the bus frees its copy while the
    // announcement that reported the first is still reporting the rest.
    const Probe = struct {
        disc2: *DirectDiscovery,
        retract: Guid,
        armed: bool = false,
        topics: [2][8]u8 = undefined,
        lens: [2]usize = .{ 0, 0 },
        n: usize = 0,

        fn onReaderDisc(ctx: *anyopaque, data: *const ReaderData) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.armed) return;
            if (self.n < 2) {
                const len = @min(data.topic_name.len, 8);
                @memcpy(self.topics[self.n][0..len], data.topic_name[0..len]);
                self.lens[self.n] = len;
            }
            self.n += 1;
            if (self.n == 1) self.disc2.toDiscovery().retractReader(self.retract);
        }
        fn onWriterDisc(_: *anyopaque, _: *const WriterData) void {}
        fn onLost(_: *anyopaque, _: Guid) void {}
    };
    var probe = Probe{ .disc2 = disc2, .retract = makeReaderGuid(2, 2) };
    var cbs1 = Callbacks{
        .ctx = &probe,
        .on_participant_discovered = TestCallbacks.onPart,
        .on_participant_lost = TestCallbacks.onPartLost,
        .on_writer_discovered = Probe.onWriterDisc,
        .on_writer_lost = Probe.onLost,
        .on_reader_discovered = Probe.onReaderDisc,
        .on_reader_lost = Probe.onLost,
        .on_wlp_alive = TestCallbacks.onWlpAlive,
    };
    var cb2 = TestCallbacks.init(alloc);
    defer cb2.deinit();
    var cbs2 = cb2.callbacks();
    const ann = ParticipantAnnouncement{
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
    try disc1.toDiscovery().start(&ann, &cbs1);
    var ann2 = ann;
    ann2.guid = makeGuid(2);
    try disc2.toDiscovery().start(&ann2, &cbs2);

    for ([_][]const u8{ "TopicA", "TopicB" }, 1..) |topic, key| {
        try announceReaderNow(disc2.toDiscovery(), &ReaderAnnouncement{
            .guid = makeReaderGuid(2, @intCast(key)),
            .participant_guid = makeGuid(2),
            .topic_name = topic,
            .type_name = "M",
            .qos = .{},
            .partition_names = &.{"P"},
            .type_info_cdr = &.{},
        });
    }

    probe.armed = true;
    try announceWriterNow(disc1.toDiscovery(), &WriterAnnouncement{
        .guid = makeWriterGuid(1, 1),
        .participant_guid = makeGuid(1),
        .topic_name = "TopicA",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });

    try testing.expectEqual(@as(usize, 2), probe.n);
    try testing.expectEqualStrings("TopicA", probe.topics[0][0..probe.lens[0]]);
    try testing.expectEqualStrings("TopicB", probe.topics[1][0..probe.lens[1]]);
}

test "an announcement's snapshot copies only the peer endpoint list it reports" {
    const alloc = testing.allocator;
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();
    const disc = try DirectDiscovery.init(alloc, bus);
    defer disc.deinit();

    var cb = TestCallbacks.init(alloc);
    defer cb.deinit();
    var cbs = cb.callbacks();
    const ann = ParticipantAnnouncement{
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
    try disc.toDiscovery().start(&ann, &cbs);
    try announceWriterNow(disc.toDiscovery(), &WriterAnnouncement{
        .guid = makeWriterGuid(2, 1),
        .participant_guid = makeGuid(2),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try announceReaderNow(disc.toDiscovery(), &ReaderAnnouncement{
        .guid = makeReaderGuid(2, 1),
        .participant_guid = makeGuid(2),
        .topic_name = "T",
        .type_name = "M",
        .qos = .{},
        .type_info_cdr = &.{},
    });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    bus.mu.lock();
    defer bus.mu.unlock();
    const e = bus.findLocked(makeGuid(2)).?;
    // As busAnnounceWriter takes it: the peer's readers only.
    const for_writer = try DiscoveryBus.EntrySnapshot.copy(e, arena.allocator(), .{ .writers = false, .readers = true });
    try testing.expectEqual(@as(usize, 0), for_writer.writers.len);
    try testing.expectEqual(@as(usize, 1), for_writer.readers.len);
    // As busAnnounceReader takes it: the peer's writers only.
    const for_reader = try DiscoveryBus.EntrySnapshot.copy(e, arena.allocator(), .{ .writers = true, .readers = false });
    try testing.expectEqual(@as(usize, 1), for_reader.writers.len);
    try testing.expectEqual(@as(usize, 0), for_reader.readers.len);
}

test "a prepared writer is stored and removed with no memory left, prepared before or after the start" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const bus = try DiscoveryBus.init(alloc);
    defer bus.deinit();
    const disc = try DirectDiscovery.init(alloc, bus);
    defer disc.deinit();
    var cb = TestCallbacks.init(testing.allocator);
    defer cb.deinit();
    var cbs = cb.callbacks();

    const before = makeWriterGuid(1, 1);
    const after = makeWriterGuid(1, 2);
    const ann = WriterAnnouncement{
        .guid = before,
        .participant_guid = makeGuid(1),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{},
        .partition_names = &.{"p"},
        .type_object = &.{},
        .type_info_cdr = &.{},
    };
    try disc.toDiscovery().prepareWriter(&ann);
    try disc.toDiscovery().start(&.{
        .guid = makeGuid(1),
        .domain_id = 0,
        .name = "p1",
        .metatraffic_unicast_locators = &.{},
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 30000,
        .builtin_endpoint_set = 0,
    }, &cbs);
    defer disc.toDiscovery().stop();
    var later = ann;
    later.guid = after;
    try disc.toDiscovery().prepareWriter(&later);

    // Every allocation fails from here.
    failing.fail_index = failing.alloc_index;
    const e = bus.findLocked(makeGuid(1)).?;
    disc.toDiscovery().announceWriter(before);
    disc.toDiscovery().announceWriter(after);
    try testing.expectEqual(@as(usize, 2), e.writers.items.len);
    disc.toDiscovery().retractWriter(before);
    disc.toDiscovery().retractWriter(after);
    try testing.expectEqual(@as(usize, 0), e.writers.items.len);
    try testing.expectEqual(@as(usize, 0), e.reserved_writers);
}
