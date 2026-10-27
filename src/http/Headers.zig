const Headers = @This();

pub const Entry = struct {
    name: api.StringPointer,
    value: api.StringPointer,

    pub const List = std.MultiArrayList(Entry);
};

entries: Entry.List = .empty,
buf: std.ArrayList(u8) = .empty,
allocator: std.mem.Allocator,

pub fn memoryCost(this: *const Headers) usize {
    return this.buf.items.len + Entry.List.capacityInBytes(this.entries.capacity);
}

pub fn clone(this: *Headers) !Headers {
    var entries = try this.entries.clone(this.allocator);
    errdefer entries.deinit(this.allocator);
    return Headers{
        .entries = entries,
        .buf = try this.buf.clone(this.allocator),
        .allocator = this.allocator,
    };
}

pub fn get(this: *const Headers, name: []const u8) ?[]const u8 {
    const entries = this.entries.slice();
    const names = entries.items(.name);
    const values = entries.items(.value);
    for (names, 0..) |name_ptr, i| {
        if (bun.strings.eqlCaseInsensitiveASCII(this.asStr(name_ptr), name, true)) {
            return this.asStr(values[i]);
        }
    }

    return null;
}

pub fn remove(this: *Headers, name: []const u8) void {
    var index: usize = 0;
    while (index < this.entries.len) {
        const name_ptr = this.entries.items(.name)[index];
        if (bun.strings.eqlCaseInsensitiveASCII(this.asStr(name_ptr), name, true)) {
            this.entries.orderedRemove(index);
        } else {
            index += 1;
        }
    }
}

pub fn append(this: *Headers, name: []const u8, value: []const u8) bun.OOM!void {
    if (this.entries.len >= std.math.maxInt(u32)) return error.OutOfMemory;
    const end = try byteLengthAfterAppend(this.buf.items.len, name.len, value.len);
    const value_offset = this.buf.items.len + name.len;
    const name_alias = this.bufferOffset(name);
    const value_alias = this.bufferOffset(value);
    try this.entries.ensureUnusedCapacity(this.allocator, 1);
    try this.buf.ensureTotalCapacity(this.allocator, end);
    const name_ptr = api.StringPointer{
        .offset = @intCast(this.buf.items.len),
        .length = @intCast(name.len),
    };
    this.buf.appendSliceAssumeCapacity(if (name_alias) |offset| this.buf.items[offset..][0..name.len] else name);
    this.buf.appendSliceAssumeCapacity(if (value_alias) |offset| this.buf.items[offset..][0..value.len] else value);

    const value_ptr = api.StringPointer{
        .offset = @intCast(value_offset),
        .length = @intCast(value.len),
    };
    this.entries.appendAssumeCapacity(.{
        .name = name_ptr,
        .value = value_ptr,
    });
}

pub fn appendFmt(this: *Headers, name: []const u8, comptime fmt: []const u8, args: anytype) bun.OOM!void {
    const value = try std.fmt.allocPrint(this.allocator, fmt, args);
    defer this.allocator.free(value);
    try this.append(name, value);
}

fn byteLengthAfterAppend(current: usize, name_length: usize, value_length: usize) bun.OOM!usize {
    const max_length = std.math.maxInt(u32);
    if (current > max_length or name_length > max_length - current) return error.OutOfMemory;
    const value_offset = current + name_length;
    if (value_length > max_length - value_offset) return error.OutOfMemory;
    return value_offset + value_length;
}

fn bufferOffset(this: *const Headers, bytes: []const u8) ?usize {
    if (this.buf.items.len == 0 or bytes.len == 0 or @intFromPtr(bytes.ptr) < @intFromPtr(this.buf.items.ptr)) return null;
    const offset = @intFromPtr(bytes.ptr) - @intFromPtr(this.buf.items.ptr);
    if (offset > this.buf.items.len or bytes.len > this.buf.items.len - offset) return null;
    return offset;
}

pub fn deinit(this: *Headers) void {
    this.entries.deinit(this.allocator);
    this.buf.clearAndFree(this.allocator);
}

pub fn take(this: *Headers) Headers {
    const value = this.*;
    this.* = .{ .allocator = this.allocator };
    return value;
}

pub fn getContentDisposition(this: *const Headers) ?[]const u8 {
    return this.get("content-disposition");
}
pub fn getContentEncoding(this: *const Headers) ?[]const u8 {
    return this.get("content-encoding");
}
pub fn getContentType(this: *const Headers) ?[]const u8 {
    return this.get("content-type");
}
pub fn asStr(this: *const Headers, ptr: api.StringPointer) []const u8 {
    bun.assert(ptr.offset <= this.buf.items.len and ptr.length <= this.buf.items.len - ptr.offset);
    return this.buf.items[ptr.offset..][0..ptr.length];
}

pub fn fromPicoHttpHeaders(headers: []const bun.picohttp.Header, allocator: std.mem.Allocator) bun.OOM!Headers {
    if (headers.len > std.math.maxInt(u32)) return error.OutOfMemory;
    var byte_length: usize = 0;
    for (headers) |header| {
        byte_length = try byteLengthAfterAppend(byte_length, header.name.len, header.value.len);
    }
    var result = Headers{ .allocator = allocator };
    errdefer result.deinit();
    try result.entries.ensureTotalCapacity(allocator, headers.len);
    try result.buf.ensureTotalCapacityPrecise(allocator, byte_length);
    for (headers) |header| try result.append(header.name, header.value);
    return result;
}

const std = @import("std");

const bun = @import("bun");
const api = bun.schema.api;
