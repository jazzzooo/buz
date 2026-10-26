const Cancellation = @This();

requested: std.atomic.Value(bool) = .init(false),

pub fn request(this: *Cancellation) void {
    this.requested.store(true, .release);
}

pub fn isRequested(this: *const Cancellation) bool {
    return this.requested.load(.acquire);
}

const std = @import("std");
