//! RTPS message layer — parse and build RTPS messages.

pub const header = @import("header.zig");
pub const submessage = @import("submessage.zig");
pub const parser = @import("parser.zig");
pub const builder = @import("builder.zig");

// Top-level re-exports for convenience.
pub const Header = header.Header;
pub const ProtocolVersion = header.ProtocolVersion;
pub const VendorId = header.VendorId;
pub const PROTOCOL_VERSION = header.PROTOCOL_VERSION;
pub const VENDOR_ID = header.VENDOR_ID;

pub const SubMessage = submessage.SubMessage;
pub const SubMessageId = submessage.SubMessageId;
pub const SubMessageHeader = submessage.SubMessageHeader;
pub const SequenceNumberSet = submessage.SequenceNumberSet;
pub const FragmentNumberSet = submessage.FragmentNumberSet;
pub const InlineQos = submessage.InlineQos;
pub const InlineQosParam = submessage.InlineQosParam;
pub const ParameterId = submessage.ParameterId;

pub const MessageIterator = parser.MessageIterator;
pub const ParseError = parser.ParseError;

pub const MessageBuilder = builder.MessageBuilder;
pub const IoVec = builder.IoVec;
pub const SCRATCH_SIZE = builder.SCRATCH_SIZE;
pub const MAX_IOVECS = builder.MAX_IOVECS;
