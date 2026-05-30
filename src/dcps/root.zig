//! Zenzen DDS DCPS public API surface.
//!
//! Import via:  const dcps = @import("zzdds").dcps;

pub const DomainParticipantFactoryImpl = @import("factory.zig").DomainParticipantFactoryImpl;
pub const DomainParticipantImpl = @import("participant.zig").DomainParticipantImpl;
pub const TypeSupport = @import("participant.zig").TypeSupport;
pub const PublisherImpl = @import("publisher.zig").PublisherImpl;
pub const SubscriberImpl = @import("subscriber.zig").SubscriberImpl;
pub const DataWriterImpl = @import("writer.zig").DataWriterImpl;
pub const guidToHandle = @import("writer.zig").guidToHandle;
pub const DataReaderImpl = @import("reader.zig").DataReaderImpl;
pub const TakenSample = @import("reader.zig").TakenSample;
pub const TopicImpl = @import("topic.zig").TopicImpl;
pub const ContentFilteredTopicImpl = @import("topic.zig").ContentFilteredTopicImpl;
pub const filter = @import("filter.zig");
pub const WaitSetImpl = @import("waitset.zig").WaitSetImpl;
pub const GuardConditionImpl = @import("waitset.zig").GuardConditionImpl;
pub const StatusConditionImpl = @import("waitset.zig").StatusConditionImpl;
pub const ReadConditionImpl = @import("waitset.zig").ReadConditionImpl;
pub const QueryConditionImpl = @import("waitset.zig").QueryConditionImpl;
pub const DataNotifyFn = @import("waitset.zig").DataNotifyFn;
pub const WakeupHandle = @import("waitset.zig").WakeupHandle;

// Nil (no-op) listener singletons — pass these wherever a listener is required
// but no callbacks are needed.
pub const nil_dp_listener = @import("nil.zig").nil_dp_listener;
pub const nil_pub_listener = @import("nil.zig").nil_pub_listener;
pub const nil_sub_listener = @import("nil.zig").nil_sub_listener;
pub const nil_topic_listener = @import("nil.zig").nil_topic_listener;
pub const nil_dw_listener = @import("nil.zig").nil_dw_listener;
pub const nil_dr_listener = @import("nil.zig").nil_dr_listener;
