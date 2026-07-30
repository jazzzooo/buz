const PinnedThreadDomain = @This();

/// Process-lifetime concurrency shared by pinned JSC threads and their owners.
background_executor: bun.BackgroundExecutor,

pub fn init(runtime_io: std.Io) PinnedThreadDomain {
    return .{
        .background_executor = .init(runtime_io, bun.getThreadCount()),
    };
}

pub fn io(this: *const PinnedThreadDomain) std.Io {
    return this.background_executor.io;
}

pub fn backgroundExecutor(this: *PinnedThreadDomain) *bun.BackgroundExecutor {
    return &this.background_executor;
}

pub fn deinit(this: *PinnedThreadDomain) void {
    this.background_executor.deinit();
}

const std = @import("std");
const bun = @import("bun");
