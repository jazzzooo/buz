pub const Frame = struct {
    line: i32,
    column: i32,
    function_name: []u8,
    file_name: []u8,
};

pub const Payload = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    message: []u8,
    browser_url: []u8,
    frames: []Frame,

    pub fn parse(body: []const u8, allocator: std.mem.Allocator) !Payload {
        var reader_state = std.Io.Reader.fixed(body);
        const reader = &reader_state;
        const name = try readString(reader, allocator);
        errdefer allocator.free(name);
        const message = try readString(reader, allocator);
        errdefer allocator.free(message);
        const browser_url = try readString(reader, allocator);
        errdefer allocator.free(browser_url);
        const frame_count = @min(try reader.takeInt(u32, .little), 255);
        const frames = try allocator.alloc(Frame, frame_count);
        var initialized: usize = 0;
        errdefer {
            for (frames[0..initialized]) |frame| {
                allocator.free(frame.function_name);
                allocator.free(frame.file_name);
            }
            allocator.free(frames);
        }
        while (initialized < frames.len) : (initialized += 1) {
            const line = try reader.takeInt(i32, .little);
            const column = try reader.takeInt(i32, .little);
            const function_name = try readString(reader, allocator);
            errdefer allocator.free(function_name);
            const file_name = try readString(reader, allocator);
            frames[initialized] = .{
                .line = line,
                .column = column,
                .function_name = function_name,
                .file_name = file_name,
            };
        }
        return .{
            .allocator = allocator,
            .name = name,
            .message = message,
            .browser_url = browser_url,
            .frames = frames,
        };
    }

    pub fn deinit(payload: *Payload) void {
        payload.allocator.free(payload.name);
        payload.allocator.free(payload.message);
        payload.allocator.free(payload.browser_url);
        for (payload.frames) |frame| {
            payload.allocator.free(frame.function_name);
            payload.allocator.free(frame.file_name);
        }
        payload.allocator.free(payload.frames);
        payload.* = undefined;
    }
};

fn readString(reader: *std.Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    const length = try reader.takeInt(u32, .little);
    const value = try allocator.alloc(u8, length);
    errdefer allocator.free(value);
    try reader.readSliceAll(value);
    return value;
}

const std = @import("std");

test Payload {
    var bytes: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    for ([_][]const u8{ "Error", "message", "http://localhost" }) |value| {
        try writer.writeInt(u32, @intCast(value.len), .little);
        try writer.writeAll(value);
    }
    try writer.writeInt(u32, 1, .little);
    try writer.writeInt(i32, 2, .little);
    try writer.writeInt(i32, 3, .little);
    for ([_][]const u8{ "function", "file.js" }) |value| {
        try writer.writeInt(u32, @intCast(value.len), .little);
        try writer.writeAll(value);
    }
    var payload = try Payload.parse(writer.buffered(), std.testing.allocator);
    defer payload.deinit();
    try std.testing.expectEqualStrings("Error", payload.name);
    try std.testing.expectEqual(@as(i32, 2), payload.frames[0].line);
    try std.testing.expectEqualStrings("file.js", payload.frames[0].file_name);
}
