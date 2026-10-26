const Signals = @This();

header_progress: ?*std.atomic.Value(bool) = null,
response_body_streaming: ?*std.atomic.Value(bool) = null,
response_body_backpressure: ?*std.atomic.Value(bool) = null,
response_buffered_bytes: ?*std.atomic.Value(usize) = null,
aborted: ?*std.atomic.Value(bool) = null,
cert_errors: ?*std.atomic.Value(bool) = null,
upgraded: ?*std.atomic.Value(bool) = null,
pub fn isEmpty(this: *const Signals) bool {
    inline for (@typeInfo(Signals).@"struct".field_names) |name| {
        if (@field(this, name) != null) return false;
    }
    return true;
}

pub const response_buffer_high_water: usize = 256 * 1024;

pub fn shouldPauseResponse(this: Signals) bool {
    if (!this.get(.response_body_backpressure)) return false;
    const buffered = this.response_buffered_bytes orelse return false;
    return buffered.load(.acquire) >= response_buffer_high_water;
}

pub const Store = struct {
    header_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    response_body_streaming: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    response_body_backpressure: std.atomic.Value(bool) = .init(false),
    response_buffered_bytes: std.atomic.Value(usize) = .init(0),
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cert_errors: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    upgraded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn to(this: *Store) Signals {
        var signals: Signals = undefined;
        inline for (@typeInfo(Signals).@"struct".field_names) |name| {
            @field(signals, name) = &@field(this, name);
        }
        return signals;
    }
};

pub fn get(this: Signals, comptime field: std.meta.FieldEnum(Signals)) bool {
    var ptr: *std.atomic.Value(bool) = @field(this, @tagName(field)) orelse return false;
    return ptr.load(.monotonic);
}

const std = @import("std");
