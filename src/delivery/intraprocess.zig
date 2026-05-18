//! IntraProcessDelivery — in-process DDS delivery bundle for DCPS conformance testing.
//!
//! Bundles MemoryBus (synchronous in-process transport) and DiscoveryBus
//! (direct endpoint-matching without SPDP/SEDP timer threads).
//!
//! Usage:
//!   var delivery = try IntraProcessDelivery.init(alloc);
//!   defer delivery.deinit();
//!
//!   // Each participant needs its own transport and discovery instances.
//!   const t_w = try delivery.newTransport();
//!   const d_w = try delivery.newDiscovery();
//!   var factory_w = try DomainParticipantFactoryImpl.init(
//!       alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .random, .{});
//!   defer { factory_w.deinit(); d_w.deinit(); t_w.deinit(); }
//!
//!   const t_r = try delivery.newTransport();
//!   const d_r = try delivery.newDiscovery();
//!   var factory_r = try DomainParticipantFactoryImpl.init(
//!       alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .random, .{});
//!   defer { factory_r.deinit(); d_r.deinit(); t_r.deinit(); }
//!
//! Endpoint matching is immediate and synchronous when writers/readers are created.
//! Data delivery is synchronous — no deliverAll() pump is needed.
//! BEST_EFFORT QoS is fully supported. RELIABLE QoS is safe but lacks inline
//! Heartbeat feedback; use MockTransport for RELIABLE protocol-level tests.
//!
//! See also: transport/memory.zig, discovery/direct.zig

const std = @import("std");
const memory_mod = @import("../transport/memory.zig");
const direct_mod = @import("../discovery/direct.zig");

pub const MemoryBus = memory_mod.MemoryBus;
pub const MemoryTransport = memory_mod.MemoryTransport;
pub const DiscoveryBus = direct_mod.DiscoveryBus;
pub const DirectDiscovery = direct_mod.DirectDiscovery;

pub const IntraProcessDelivery = struct {
    alloc: std.mem.Allocator,
    mem_bus: *MemoryBus,
    disc_bus: *DiscoveryBus,

    pub fn init(alloc: std.mem.Allocator) !IntraProcessDelivery {
        const mem_bus = try MemoryBus.init(alloc);
        errdefer mem_bus.deinit();
        const disc_bus = try DiscoveryBus.init(alloc);
        return .{
            .alloc = alloc,
            .mem_bus = mem_bus,
            .disc_bus = disc_bus,
        };
    }

    pub fn deinit(self: *IntraProcessDelivery) void {
        self.disc_bus.deinit();
        self.mem_bus.deinit();
    }

    /// Create a new MemoryTransport connected to this delivery's shared bus.
    /// Caller owns the result; call deinit() when done.
    pub fn newTransport(self: *IntraProcessDelivery) !*MemoryTransport {
        return self.mem_bus.createTransport();
    }

    /// Create a new DirectDiscovery connected to this delivery's shared bus.
    /// Each participant must have its own DirectDiscovery instance.
    /// Caller owns the result; call deinit() when done.
    pub fn newDiscovery(self: *IntraProcessDelivery) !*DirectDiscovery {
        return DirectDiscovery.init(self.alloc, self.disc_bus);
    }
};
