const Self = @This();

/// The absolute time to fire this timer next.
next: timespec,
state: State = .PENDING,
tag: Tag,
/// Internal heap fields.
heap: bun.io.heap.IntrusiveField(Self) = .{},
in_heap: enum { none, regular, fake } = .none,

pub fn initPaused(tag: Tag) Self {
    return .{
        .next = .epoch,
        .tag = tag,
    };
}

pub const Tag = enum {
    TimerCallback,
    TimeoutObject,
    ImmediateObject,
    StatWatcher,
    UpgradedDuplex,
    DNSResolver,
    WindowsNamedPipe,
    WTFTimer,
    PostgresSQLConnectionTimeout,
    PostgresSQLConnectionMaxLifetime,
    MySQLConnectionTimeout,
    MySQLConnectionMaxLifetime,
    ValkeyConnectionTimeout,
    ValkeyConnectionReconnect,
    SubprocessTimeout,
    DevServerSweepSourceMaps,
    DevServerMemoryVisualizerTick,
    AbortSignalTimeout,
    DateHeaderTimer,
    BunTest,
    EventLoopDelayMonitor,
    CronJob,
    GarbageCollection,
    GarbageCollectionRepeat,

    pub fn allowFakeTimers(self: Tag) bool {
        return switch (self) {
            .WTFTimer, // internal
            .BunTest, // for test timeouts
            .EventLoopDelayMonitor, // probably important
            .StatWatcher,
            .CronJob, // calendar-anchored to real wall clock
            .DNSResolver, // c-ares deadlines use the operating system clock
            .GarbageCollection,
            .GarbageCollectionRepeat,
            => false,
            else => true,
        };
    }
};

pub const State = enum {
    /// The timer is waiting to be enabled.
    PENDING,

    /// The timer is active and will fire at the next time.
    ACTIVE,

    /// The timer has been cancelled and will not fire.
    CANCELLED,

    /// The timer has fired and the callback has been called.
    FIRED,
};

const bun = @import("bun");
const timespec = bun.timespec;
