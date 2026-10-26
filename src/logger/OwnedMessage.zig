const OwnedMessage = @This();

kind: logger.Kind,
data: Data,
metadata: logger.Msg.Metadata,
notes: OwnedNativeSlice(Data, .any),
redact_sensitive_information: bool,

pub const Bytes = OwnedNativeSlice(u8, .any);

pub const Location = struct {
    file: Bytes,
    namespace: Bytes,
    line_text: ?Bytes,
    length: usize,
    offset: usize,
    line: i32,
    column: i32,

    fn copy(value: logger.Location) bun.OOM!Location {
        var file = try copyBytes(value.file);
        errdefer file.deinit();
        var namespace = try copyBytes(value.namespace);
        errdefer namespace.deinit();
        return .{
            .file = file,
            .namespace = namespace,
            .line_text = if (value.line_text) |text| try copyBytes(text) else null,
            .length = value.length,
            .offset = value.offset,
            .line = value.line,
            .column = value.column,
        };
    }

    pub fn view(self: *const Location) logger.Location {
        return .{
            .file = self.file.slice(),
            .namespace = self.namespace.slice(),
            .line_text = if (self.line_text) |*text| text.slice() else null,
            .length = self.length,
            .offset = self.offset,
            .line = self.line,
            .column = self.column,
        };
    }

    pub fn deinit(self: *Location) void {
        self.file.deinit();
        self.namespace.deinit();
        if (self.line_text) |*text| text.deinit();
        self.line_text = null;
    }
};

pub const Data = struct {
    text: Bytes,
    location: ?Location,

    pub fn copy(value: logger.Data) bun.OOM!Data {
        var text = try copyBytes(value.text);
        errdefer text.deinit();
        return .{
            .text = text,
            .location = if (value.location) |location| try Location.copy(location) else null,
        };
    }

    pub fn view(self: *const Data) logger.Data {
        return .{
            .text = self.text.slice(),
            .location = if (self.location) |*location| location.view() else null,
        };
    }

    pub fn deinit(self: *Data) void {
        self.text.deinit();
        if (self.location) |*location| location.deinit();
        self.location = null;
    }
};

pub fn copyBytes(value: []const u8) bun.OOM!Bytes {
    return .fromOwnedSlice(try bun.default_allocator.dupe(u8, value));
}

pub fn copy(value: logger.Msg) bun.OOM!OwnedMessage {
    var data = try Data.copy(value.data);
    errdefer data.deinit();
    const notes = try bun.default_allocator.alloc(Data, value.notes.len);
    var initialized: usize = 0;
    errdefer {
        for (notes[0..initialized]) |*note| note.deinit();
        bun.default_allocator.free(notes);
    }
    for (value.notes, notes) |note, *owned| {
        owned.* = try Data.copy(note);
        initialized += 1;
    }
    return .{
        .kind = value.kind,
        .data = data,
        .metadata = value.metadata,
        .notes = .fromOwnedSlice(notes),
        .redact_sensitive_information = value.redact_sensitive_information,
    };
}

pub fn view(self: *const OwnedMessage, note_views: []logger.Data) logger.Msg {
    bun.assert(note_views.len == self.notes.slice().len);
    for (self.notes.slice(), note_views) |*note, *out| out.* = note.view();
    return .{
        .kind = self.kind,
        .data = self.data.view(),
        .metadata = self.metadata,
        .notes = note_views,
        .redact_sensitive_information = self.redact_sensitive_information,
    };
}

pub fn writeFormat(self: *const OwnedMessage, writer: *std.Io.Writer, comptime colors: bool) !void {
    try self.data.view().writeFormat(writer, self.kind, self.redact_sensitive_information, colors);
    if (self.notes.slice().len > 0) try writer.writeAll("\n");
    for (self.notes.slice()) |*note| {
        try writer.writeAll("\n");
        try note.view().writeFormat(writer, .note, self.redact_sensitive_information, colors);
    }
}

pub fn appendTo(self: *const OwnedMessage, log: *logger.Log) bun.OOM!void {
    const notes = try bun.default_allocator.alloc(logger.Data, self.notes.slice().len);
    defer bun.default_allocator.free(notes);
    try log.addMsg(self.view(notes));
}

pub fn deinit(self: *OwnedMessage) void {
    self.data.deinit();
    self.notes.deinit();
}

test "diagnostics own source text and preserve notes across log transfers" {
    var source = logger.Log.init(std.testing.allocator);
    defer source.deinit();
    var text = "original".*;
    var namespace = "plugin".*;
    var file = "entry.ts".*;
    var line = "let value".*;
    const location: logger.Location = .{
        .file = &file,
        .namespace = &namespace,
        .line_text = &line,
        .line = 2,
        .column = 3,
    };
    var notes = [_]logger.Data{.{ .text = "", .location = location }};
    try source.addMsg(.{
        .kind = .warn,
        .data = .{ .text = &text, .location = location },
        .notes = &notes,
        .redact_sensitive_information = true,
    });
    @memset(&text, 'x');
    @memset(&namespace, 'x');
    @memset(&file, 'x');
    @memset(&line, 'x');

    var cloned = logger.Log.init(std.testing.allocator);
    defer cloned.deinit();
    try source.cloneTo(&cloned);
    source.reset();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var destination = logger.Log.init(failing.allocator());
    defer destination.deinit();
    try std.testing.expectError(error.OutOfMemory, cloned.appendTo(&destination));
    try std.testing.expectEqual(@as(usize, 0), destination.msgs.items.len);
    try std.testing.expectEqual(@as(u32, 1), cloned.warnings);

    try cloned.appendTo(&source);
    try std.testing.expectEqual(@as(usize, 0), cloned.msgs.items.len);
    try std.testing.expectEqual(@as(u32, 0), cloned.warnings);
    const message = source.msgs.items[0];
    try std.testing.expectEqualStrings("original", message.data.text);
    try std.testing.expect(message.redact_sensitive_information);
    try std.testing.expectEqual(@as(usize, 1), message.notes.len);
    const note = message.notes[0];
    try std.testing.expectEqualStrings("", note.text);
    try std.testing.expectEqualStrings("entry.ts", note.location.?.file);
    try std.testing.expectEqualStrings("plugin", note.location.?.namespace);
    try std.testing.expectEqualStrings("let value", note.location.?.line_text.?);
}

const std = @import("std");
const bun = @import("bun");
const logger = @import("./logger.zig");
const OwnedNativeSlice = @import("../bindgen/owned_native_slice.zig").OwnedNativeSlice;
