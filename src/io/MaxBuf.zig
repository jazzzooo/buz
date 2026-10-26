const MaxBuf = @This();

owner: ?*Owner,
on_exceeded: *const fn (*Owner, Kind) void,
kind: Kind,
// null after pipereader finalize
owned_by_reader: bool,
remaining_bytes: i64,
// (once both are null, it is freed)

pub const Owner = opaque {};

pub fn createForOwner(
    owner: *Owner,
    on_exceeded: *const fn (*Owner, Kind) void,
    kind: Kind,
    ptr: *?*MaxBuf,
    initial: ?i64,
) bun.OOM!void {
    if (initial == null) {
        ptr.* = null;
        return;
    }
    const maxbuf = try bun.default_allocator.create(MaxBuf);
    maxbuf.* = .{
        .owner = owner,
        .on_exceeded = on_exceeded,
        .kind = kind,
        .owned_by_reader = false,
        .remaining_bytes = initial.?,
    };
    ptr.* = maxbuf;
}
fn disowned(this: *MaxBuf) bool {
    return this.owner == null and this.owned_by_reader == false;
}
fn destroy(this: *MaxBuf) void {
    bun.assert(this.disowned());
    bun.default_allocator.destroy(this);
}
pub fn removeFromOwner(ptr: *?*MaxBuf) void {
    if (ptr.* == null) return;
    const this = ptr.*.?;
    bun.assert(this.owner != null);
    this.owner = null;
    ptr.* = null;
    if (this.disowned()) {
        this.destroy();
    }
}
pub fn addToPipereader(value: ?*MaxBuf, ptr: *?*MaxBuf) void {
    if (value == null) return;
    bun.assert(ptr.* == null);
    ptr.* = value;
    bun.assert(!value.?.owned_by_reader);
    value.?.owned_by_reader = true;
}
pub fn removeFromPipereader(ptr: *?*MaxBuf) void {
    if (ptr.* == null) return;
    const this = ptr.*.?;
    bun.assert(this.owned_by_reader);
    this.owned_by_reader = false;
    ptr.* = null;
    if (this.disowned()) {
        this.destroy();
    }
}
pub fn transferToPipereader(prev: *?*MaxBuf, next: *?*MaxBuf) void {
    if (prev.* == null) return;
    next.* = prev.*;
    prev.* = null;
}
pub fn onReadBytes(this: *MaxBuf, bytes: u64) void {
    this.remaining_bytes = std.math.sub(i64, this.remaining_bytes, std.math.cast(i64, bytes) orelse 0) catch -1;
    if (this.remaining_bytes < 0) {
        if (this.owner) |owner| this.on_exceeded(owner, this.kind);
    }
}

pub const Kind = enum {
    stdout,
    stderr,
};

const bun = @import("bun");
const std = @import("std");
