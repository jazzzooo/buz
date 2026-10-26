const FetchProgress = @This();

io: std.Io,
lock: std.Io.Mutex = .init,
pending: ?Update = null,
scheduled: bool = false,
closed: bool = false,
ignore_data: bool = false,
allocation_failed: bool = false,

pub const Update = struct {
    has_result: bool = false,
    request_drained: bool = false,
    result: bun.http.HTTPClientResult = .{},
    body: bun.MutableString = .{ .allocator = bun.default_allocator, .list = .empty },

    pub fn deinit(this: *Update) void {
        if (this.result.metadata) |*metadata| metadata.deinit(bun.default_allocator);
        if (this.result.certificate_info) |*certificate| certificate.deinit(bun.default_allocator);
        this.body.deinit();
        this.* = .{};
    }
};

pub fn publish(this: *FetchProgress, result: bun.http.HTTPClientResult) bool {
    this.acquire();
    defer this.lock.unlock(this.io);
    const body = result.body;
    defer if (body) |buffer| buffer.reset();

    if (this.closed) {
        var discarded: Update = .{ .result = result };
        discarded.deinit();
        return false;
    }

    if (this.pending == null) this.pending = .{};
    const pending = &this.pending.?;
    pending.has_result = true;
    const previous = pending.result;
    pending.result = result;
    pending.result.body = null;
    pending.result.can_stream = result.can_stream or previous.can_stream;
    if (result.metadata == null) {
        pending.result.metadata = previous.metadata;
    } else if (previous.metadata) |old| {
        var metadata = old;
        metadata.deinit(bun.default_allocator);
    }
    if (result.certificate_info == null) {
        pending.result.certificate_info = previous.certificate_info;
    } else if (previous.certificate_info) |old| {
        old.deinit(bun.default_allocator);
    }
    if (!this.ignore_data and !this.allocation_failed and result.isSuccess()) {
        if (body) |buffer| {
            _ = pending.body.write(buffer.list.items) catch allocation_failure: {
                this.allocation_failed = true;
                pending.body.reset();
                break :allocation_failure 0;
            };
        }
    }
    if (this.allocation_failed) pending.result.fail = error.OutOfMemory;
    if (this.scheduled) return false;
    this.scheduled = true;
    return true;
}

pub fn requestDrain(this: *FetchProgress) bool {
    this.acquire();
    defer this.lock.unlock(this.io);
    if (this.closed) return false;
    if (this.pending == null) this.pending = .{};
    this.pending.?.request_drained = true;
    if (this.scheduled) return false;
    this.scheduled = true;
    return true;
}

pub fn take(this: *FetchProgress) Update {
    this.acquire();
    defer this.lock.unlock(this.io);
    bun.assert(this.scheduled);
    const update = this.pending orelse @panic("fetch delivery has no pending update");
    this.pending = null;
    return update;
}

pub fn finishDelivery(this: *FetchProgress) bool {
    this.acquire();
    defer this.lock.unlock(this.io);
    if (this.closed) return false;
    bun.assert(this.scheduled);
    // Updates received during a JS callback wait for another delivery.
    if (this.pending != null) return true;
    this.scheduled = false;
    return false;
}

pub fn ignoreData(this: *FetchProgress) void {
    this.acquire();
    defer this.lock.unlock(this.io);
    this.ignore_data = true;
    if (this.pending) |*pending| pending.body.reset();
}

pub fn failAllocation(this: *FetchProgress) void {
    this.acquire();
    defer this.lock.unlock(this.io);
    this.allocation_failed = true;
    if (this.pending) |*pending| pending.result.fail = error.OutOfMemory;
}

pub fn close(this: *FetchProgress) void {
    this.acquire();
    defer this.lock.unlock(this.io);
    this.closed = true;
    this.deinit();
}

pub fn deinit(this: *FetchProgress) void {
    if (this.pending) |*pending| pending.deinit();
    this.pending = null;
}

fn acquire(this: *FetchProgress) void {
    this.lock.lockUncancelable(this.io);
}

const bun = @import("bun");
const std = @import("std");
