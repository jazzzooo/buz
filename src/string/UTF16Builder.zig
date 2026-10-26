const UTF16Builder = @This();

allocator: std.mem.Allocator,
units: std.ArrayListUnmanaged(u16) = .empty,
failed: bool = false,

pub fn init(allocator: std.mem.Allocator) UTF16Builder {
    return .{ .allocator = allocator };
}

pub fn deinit(this: *UTF16Builder) void {
    this.units.deinit(this.allocator);
}

const Append = enum {
    latin1,
    utf16,
    double,
    int,
    usize,
    string,
    text_view,
    lchar,
    uchar,

    pub fn Type(comptime this: Append) type {
        return switch (this) {
            .latin1 => []const u8,
            .utf16 => []const u16,
            .double => f64,
            .int => i32,
            .usize => usize,
            .string => bun.String,
            .text_view => bun.TextView,
            .lchar => u8,
            .uchar => u16,
        };
    }
};

pub fn append(this: *UTF16Builder, comptime append_type: Append, value: append_type.Type()) void {
    if (this.failed) return;

    switch (comptime append_type) {
        .latin1 => this.appendLatin1(value),
        .utf16 => this.appendUTF16(value),
        .double => {
            var buffer: [124]u8 = undefined;
            this.appendLatin1(bun.fmt.FormatDouble.dtoa(&buffer, value));
        },
        .int => {
            var buffer: [16]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
            this.appendLatin1(rendered);
        },
        .usize => {
            var buffer: [32]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
            this.appendLatin1(rendered);
        },
        .string => this.appendTextView(value.textView()),
        .text_view => this.appendTextView(value),
        .lchar => this.appendCodeUnit(value),
        .uchar => this.appendCodeUnit(value),
    }
}

pub fn ensureUnusedCapacity(this: *UTF16Builder, additional: usize) void {
    if (this.failed) return;
    this.units.ensureUnusedCapacity(this.allocator, additional) catch {
        this.failed = true;
    };
}

pub fn slice(this: *const UTF16Builder) bun.OOM![]const u16 {
    if (this.failed) return error.OutOfMemory;
    return this.units.items;
}

fn appendLatin1(this: *UTF16Builder, value: []const u8) void {
    this.ensureUnusedCapacity(value.len);
    if (this.failed) return;

    const start = this.units.items.len;
    this.units.items.len += value.len;
    bun.strings.copyU8IntoU16(this.units.items[start..], value);
}

fn appendUTF16(this: *UTF16Builder, value: []const u16) void {
    this.units.appendSlice(this.allocator, value) catch {
        this.failed = true;
    };
}

fn appendCodeUnit(this: *UTF16Builder, value: u16) void {
    this.units.append(this.allocator, value) catch {
        this.failed = true;
    };
}

fn appendTextView(this: *UTF16Builder, value: bun.TextView) void {
    switch (value) {
        .latin1 => |bytes| this.appendLatin1(bytes),
        .utf16 => |units| this.appendUTF16(units),
        .utf8 => |bytes| {
            const converted = bun.strings.toUTF16Alloc(this.allocator, bytes, false, false) catch {
                this.failed = true;
                return;
            };
            if (converted) |units| {
                defer this.allocator.free(units);
                this.appendUTF16(units);
            } else {
                this.appendLatin1(bytes);
            }
        },
    }
}

const std = @import("std");
const bun = @import("bun");
