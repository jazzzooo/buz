const Command = @This();

command: []const u8,
args: Args,
meta: Meta = .{},

pub const Argument = union(enum) {
    bytes: []const u8,
    text: Slice,
    blob: @import("../webcore/blob/SharedBytes.zig"),

    pub fn slice(this: *const Argument) []const u8 {
        return switch (this.*) {
            .bytes => |bytes| bytes,
            inline .text, .blob => |*value| value.slice(),
        };
    }

    pub fn byteLength(this: *const Argument) usize {
        return this.slice().len;
    }

    pub fn deinit(this: *const Argument) void {
        switch (this.*) {
            .bytes => {},
            .text => |*text| text.deinit(),
            .blob => |value| {
                var owned = value;
                owned.deinit();
            },
        }
    }
};

pub const Args = union(enum) {
    slices: []const Slice,
    args: []const Argument,
    raw: []const []const u8,

    pub fn len(this: *const @This()) usize {
        return switch (this.*) {
            inline .slices, .args, .raw => |args| args.len,
        };
    }
};

pub fn write(this: *const Command, writer: anytype) !void {
    const count = std.math.add(usize, this.args.len(), 1) catch return error.WriteFailed;
    try writer.print("*{d}\r\n", .{count});
    try writer.print("${d}\r\n{s}\r\n", .{ this.command.len, this.command });

    switch (this.args) {
        inline .slices, .args => |args| {
            for (args) |*arg| {
                try writer.print("${d}\r\n{s}\r\n", .{ arg.byteLength(), arg.slice() });
            }
        },
        .raw => |args| {
            for (args) |arg| {
                try writer.print("${d}\r\n{s}\r\n", .{ arg.len, arg });
            }
        },
    }
}

pub fn format(this: Command, writer: *std.Io.Writer) !void {
    try this.write(writer);
}

fn addBulkStringLength(total: *usize, length: usize) bun.OOM!void {
    total.* = std.math.add(usize, total.*, std.fmt.count("${d}\r\n\r\n", .{length})) catch return error.OutOfMemory;
    total.* = std.math.add(usize, total.*, length) catch return error.OutOfMemory;
}

pub fn byteLength(this: *const Command) bun.OOM!usize {
    const count = std.math.add(usize, this.args.len(), 1) catch return error.OutOfMemory;
    var total = std.fmt.count("*{d}\r\n", .{count});
    try addBulkStringLength(&total, this.command.len);
    switch (this.args) {
        inline .slices, .args => |args| {
            for (args) |*arg| try addBulkStringLength(&total, arg.byteLength());
        },
        .raw => |args| {
            for (args) |arg| try addBulkStringLength(&total, arg.len);
        },
    }
    return total;
}

pub fn serialize(this: *const Command, allocator: std.mem.Allocator) bun.OOM![]u8 {
    const buffer = try allocator.alloc(u8, try this.byteLength());
    var writer: std.Io.Writer = .fixed(buffer);
    this.write(&writer) catch @panic("Valkey command exceeded its serialized size");
    bun.assert(writer.end == buffer.len);
    return buffer;
}

/// Command stored in offline queue when disconnected
pub const Entry = struct {
    serialized_data: []u8, // Pre-serialized RESP protocol bytes
    meta: Meta = .{},
    completion: Completion.ResponseCompletions.Owned,

    pub const Queue = bun.LinearFifo(Entry, .Dynamic);

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.serialized_data);
    }

    // Create an Offline by serializing the Valkey command directly
    pub fn create(
        allocator: std.mem.Allocator,
        command: *const Command,
        completion: Completion.ResponseCompletions.Owned,
    ) !Entry {
        return Entry{
            .serialized_data = try command.serialize(allocator),
            .meta = command.meta,
            .completion = completion,
        };
    }
};

pub const Meta = packed struct(u8) {
    return_as_bool: bool = false,
    supports_auto_pipelining: bool = true,
    return_as_buffer: bool = false,
    subscription_request: bool = false,
    _padding: u4 = 0,

    const not_allowed_autopipeline_commands = bun.ComptimeStringMap(void, .{
        .{"AUTH"},
        .{"INFO"},
        .{"QUIT"},
        .{"EXEC"},
        .{"MULTI"},
        .{"WATCH"},
        .{"SCRIPT"},
        .{"SELECT"},
        .{"CLUSTER"},
        .{"DISCARD"},
        .{"UNWATCH"},
        .{"PIPELINE"},
        .{"SUBSCRIBE"},
        .{"PSUBSCRIBE"},
        .{"UNSUBSCRIBE"},
        .{"UNPSUBSCRIBE"},
    });

    pub fn check(self: @This(), command: *const Command) @This() {
        var new = self;
        new.supports_auto_pipelining = !not_allowed_autopipeline_commands.has(command.command);
        return new;
    }
};

pub const InFlight = struct {
    meta: Meta,
    completion: Completion.ResponseCompletions.Owned,

    pub const Queue = bun.LinearFifo(InFlight, .Dynamic);
};

const Completion = @import("./ValkeyCompletion.zig");
const std = @import("std");

const bun = @import("bun");
const Slice = bun.String.Slice;
