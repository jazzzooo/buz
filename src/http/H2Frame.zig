pub const max_window_size = std.math.maxInt(i32);
pub const max_header_table_size = std.math.maxInt(u32);
pub const max_stream_id = std.math.maxInt(i32);
pub const max_frame_size = std.math.maxInt(u24);
pub const default_window_size = std.math.maxInt(u16);
pub const default_header_table_size: u32 = 4096;
pub const default_max_frame_size: u24 = 16384;
pub const max_window_size_f64: f64 = @floatFromInt(max_window_size);
pub const max_header_table_size_f64: f64 = @floatFromInt(max_header_table_size);
pub const max_frame_size_f64: f64 = @floatFromInt(max_frame_size);
pub const max_custom_settings = 10;

pub const client_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const valid_response_pseudo_headers = std.StaticStringMap(void).initComptime(.{
    .{":status"},
});

pub const valid_request_pseudo_headers = std.StaticStringMap(void).initComptime(.{
    .{":method"},
    .{":authority"},
    .{":scheme"},
    .{":path"},
    .{":protocol"},
});

pub const single_value_headers = std.StaticStringMap(void).initComptime(.{
    .{":status"},
    .{":method"},
    .{":authority"},
    .{":scheme"},
    .{":path"},
    .{":protocol"},
    .{"access-control-allow-credentials"},
    .{"access-control-max-age"},
    .{"access-control-request-method"},
    .{"age"},
    .{"authorization"},
    .{"content-encoding"},
    .{"content-language"},
    .{"content-length"},
    .{"content-location"},
    .{"content-md5"},
    .{"content-range"},
    .{"content-type"},
    .{"date"},
    .{"dnt"},
    .{"etag"},
    .{"expires"},
    .{"from"},
    .{"host"},
    .{"if-match"},
    .{"if-modified-since"},
    .{"if-none-match"},
    .{"if-range"},
    .{"if-unmodified-since"},
    .{"last-modified"},
    .{"location"},
    .{"max-forwards"},
    .{"proxy-authorization"},
    .{"range"},
    .{"referer"},
    .{"retry-after"},
    .{"tk"},
    .{"upgrade-insecure-requests"},
    .{"user-agent"},
    .{"x-content-type-options"},
});

pub fn normalizeHeaderName(input: []const u8, output: []u8) error{InvalidHeaderName}![]const u8 {
    if (input.len > 4096) return error.InvalidHeaderName;
    std.debug.assert(output.len >= input.len);

    var remaining_input = input;
    var remaining_output = output;
    var copied = false;
    scan: while (true) {
        for (remaining_input, 0..) |byte, index| {
            switch (byte) {
                'A'...'Z' => {
                    @memcpy(remaining_output[0..index], remaining_input[0..index]);
                    remaining_output[index] = std.ascii.toLower(byte);
                    remaining_input = remaining_input[index + 1 ..];
                    remaining_output = remaining_output[index + 1 ..];
                    copied = true;
                    continue :scan;
                },
                'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
                ':' => if (index != 0 or copied) return error.InvalidHeaderName,
                else => return error.InvalidHeaderName,
            }
        }
        if (copied) @memcpy(remaining_output[0..remaining_input.len], remaining_input);
        return if (copied) output[0..input.len] else input;
    }
}

pub const PaddingStrategy = enum {
    none,
    aligned,
    max,
};

pub const FrameType = enum(u8) {
    HTTP_FRAME_DATA = 0x00,
    HTTP_FRAME_HEADERS = 0x01,
    HTTP_FRAME_PRIORITY = 0x02,
    HTTP_FRAME_RST_STREAM = 0x03,
    HTTP_FRAME_SETTINGS = 0x04,
    HTTP_FRAME_PUSH_PROMISE = 0x05,
    HTTP_FRAME_PING = 0x06,
    HTTP_FRAME_GOAWAY = 0x07,
    HTTP_FRAME_WINDOW_UPDATE = 0x08,
    HTTP_FRAME_CONTINUATION = 0x09,
    HTTP_FRAME_ALTSVC = 0x0A,
    HTTP_FRAME_ORIGIN = 0x0C,
    _,
};

pub const PingFrameFlags = enum(u8) {
    ACK = 0x1,
};

pub const DataFrameFlags = enum(u8) {
    END_STREAM = 0x1,
    PADDED = 0x8,
};

pub const HeadersFrameFlags = enum(u8) {
    END_STREAM = 0x1,
    END_HEADERS = 0x4,
    PADDED = 0x8,
    PRIORITY = 0x20,
};

pub const SettingsFlags = enum(u8) {
    ACK = 0x1,
};

pub const ErrorCode = enum(u32) {
    NO_ERROR = 0x0,
    PROTOCOL_ERROR = 0x1,
    INTERNAL_ERROR = 0x2,
    FLOW_CONTROL_ERROR = 0x3,
    SETTINGS_TIMEOUT = 0x4,
    STREAM_CLOSED = 0x5,
    FRAME_SIZE_ERROR = 0x6,
    REFUSED_STREAM = 0x7,
    CANCEL = 0x8,
    COMPRESSION_ERROR = 0x9,
    CONNECT_ERROR = 0xa,
    ENHANCE_YOUR_CALM = 0xb,
    INADEQUATE_SECURITY = 0xc,
    HTTP_1_1_REQUIRED = 0xd,
    MAX_PENDING_SETTINGS_ACK = 0xe,
    _,
};

pub const SettingsType = enum(u16) {
    SETTINGS_HEADER_TABLE_SIZE = 0x1,
    SETTINGS_ENABLE_PUSH = 0x2,
    SETTINGS_MAX_CONCURRENT_STREAMS = 0x3,
    SETTINGS_INITIAL_WINDOW_SIZE = 0x4,
    SETTINGS_MAX_FRAME_SIZE = 0x5,
    SETTINGS_MAX_HEADER_LIST_SIZE = 0x6,
    SETTINGS_ENABLE_CONNECT_PROTOCOL = 0x8,
    SETTINGS_NO_RFC7540_PRIORITIES = 0x9,
    _,
};

pub fn decodeU32(src: []const u8) u32 {
    std.debug.assert(src.len == 4);
    return std.mem.readInt(u32, src[0..4], .big);
}

pub fn encodeU32(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    return bytes;
}

pub const UInt31WithReserved = struct {
    reserved: bool = false,
    uint31: u31 = 0,

    pub fn from(value: u32) UInt31WithReserved {
        return .{
            .uint31 = @truncate(value & 0x7fffffff),
            .reserved = value & 0x80000000 != 0,
        };
    }

    pub fn init(value: u31, reserved: bool) UInt31WithReserved {
        return .{ .uint31 = value, .reserved = reserved };
    }

    pub fn toUInt32(value: UInt31WithReserved) u32 {
        return @as(u32, value.uint31) | if (value.reserved) @as(u32, 0x80000000) else 0;
    }

    pub fn fromBytes(src: []const u8) UInt31WithReserved {
        return from(decodeU32(src));
    }

    pub fn write(this: UInt31WithReserved, comptime Writer: type, writer: Writer) bool {
        const bytes = encodeU32(this.toUInt32());
        return (writer.write(&bytes) catch 0) == bytes.len;
    }
};

pub const StreamPriority = struct {
    streamIdentifier: u32 = 0,
    weight: u8 = 0,

    pub const byteSize: usize = 5;

    pub fn encode(this: StreamPriority, dst: *[byteSize]u8) void {
        std.mem.writeInt(u32, dst[0..4], this.streamIdentifier, .big);
        dst[4] = this.weight;
    }

    pub fn write(this: *const StreamPriority, comptime Writer: type, writer: Writer) bool {
        var bytes: [byteSize]u8 = undefined;
        this.encode(&bytes);
        return (writer.write(&bytes) catch 0) == byteSize;
    }

    pub fn decode(src: []const u8) StreamPriority {
        std.debug.assert(src.len == byteSize);
        return .{
            .streamIdentifier = std.mem.readInt(u32, src[0..4], .big),
            .weight = src[4],
        };
    }
};

pub const FrameHeader = struct {
    length: u24 = 0,
    type: u8 = @backingInt(FrameType.HTTP_FRAME_SETTINGS),
    flags: u8 = 0,
    streamIdentifier: u31 = 0,

    pub const byteSize: usize = 9;

    pub fn encode(this: FrameHeader, dst: *[byteSize]u8) void {
        dst[0] = @truncate(this.length >> 16);
        dst[1] = @truncate(this.length >> 8);
        dst[2] = @truncate(this.length);
        dst[3] = this.type;
        dst[4] = this.flags;
        std.mem.writeInt(u32, dst[5..9], this.streamIdentifier, .big);
    }

    pub fn write(this: *const FrameHeader, comptime Writer: type, writer: Writer) bool {
        var bytes: [byteSize]u8 = undefined;
        this.encode(&bytes);
        return (writer.write(&bytes) catch 0) == byteSize;
    }

    pub fn decode(src: []const u8) FrameHeader {
        std.debug.assert(src.len == byteSize);
        return .{
            .length = (@as(u24, src[0]) << 16) | (@as(u24, src[1]) << 8) | src[2],
            .type = src[3],
            .flags = src[4],
            .streamIdentifier = @truncate(std.mem.readInt(u32, src[5..9], .big)),
        };
    }
};

pub const SettingsPayloadUnit = struct {
    type: u16,
    value: u32,

    pub const byteSize: usize = 6;

    pub fn encode(this: SettingsPayloadUnit, dst: *[byteSize]u8) void {
        std.mem.writeInt(u16, dst[0..2], this.type, .big);
        std.mem.writeInt(u32, dst[2..6], this.value, .big);
    }

    pub fn decode(src: []const u8) SettingsPayloadUnit {
        std.debug.assert(src.len == byteSize);
        return .{
            .type = std.mem.readInt(u16, src[0..2], .big),
            .value = std.mem.readInt(u32, src[2..6], .big),
        };
    }

    pub fn write(this: SettingsPayloadUnit, comptime Writer: type, writer: Writer) bool {
        var bytes: [byteSize]u8 = undefined;
        this.encode(&bytes);
        return (writer.write(&bytes) catch 0) == byteSize;
    }
};

pub const SettingsSnapshot = struct {
    header_table_size: u32,
    enable_push: bool,
    max_concurrent_streams: u32,
    initial_window_size: u32,
    max_frame_size: u32,
    max_header_list_size: u32,
    max_header_size: u32,
    enable_connect_protocol: bool,
};

pub const FullSettingsPayload = struct {
    headerTableSize: u32 = default_header_table_size,
    enablePush: u32 = 1,
    maxConcurrentStreams: u32 = std.math.maxInt(u32),
    initialWindowSize: u32 = default_window_size,
    maxFrameSize: u32 = default_max_frame_size,
    maxHeaderListSize: u32 = 65535,
    enableConnectProtocol: u32 = 0,

    pub const byteSize: usize = 42;

    pub fn snapshot(this: *const FullSettingsPayload) SettingsSnapshot {
        return .{
            .header_table_size = this.headerTableSize,
            .enable_push = this.enablePush > 0,
            .max_concurrent_streams = this.maxConcurrentStreams,
            .initial_window_size = this.initialWindowSize,
            .max_frame_size = this.maxFrameSize,
            .max_header_list_size = this.maxHeaderListSize,
            .max_header_size = this.maxHeaderListSize,
            .enable_connect_protocol = this.enableConnectProtocol > 0,
        };
    }

    pub fn updateWith(this: *FullSettingsPayload, option: SettingsPayloadUnit) void {
        switch (@as(SettingsType, @fromBackingInt(@intCast(option.type)))) {
            .SETTINGS_HEADER_TABLE_SIZE => this.headerTableSize = option.value,
            .SETTINGS_ENABLE_PUSH => this.enablePush = option.value,
            .SETTINGS_MAX_CONCURRENT_STREAMS => this.maxConcurrentStreams = option.value,
            .SETTINGS_INITIAL_WINDOW_SIZE => this.initialWindowSize = option.value,
            .SETTINGS_MAX_FRAME_SIZE => this.maxFrameSize = option.value,
            .SETTINGS_MAX_HEADER_LIST_SIZE => this.maxHeaderListSize = option.value,
            .SETTINGS_ENABLE_CONNECT_PROTOCOL => this.enableConnectProtocol = option.value,
            else => {},
        }
    }

    pub fn write(this: *const FullSettingsPayload, comptime Writer: type, writer: Writer) bool {
        inline for (.{
            .{ SettingsType.SETTINGS_HEADER_TABLE_SIZE, this.headerTableSize },
            .{ SettingsType.SETTINGS_ENABLE_PUSH, this.enablePush },
            .{ SettingsType.SETTINGS_MAX_CONCURRENT_STREAMS, this.maxConcurrentStreams },
            .{ SettingsType.SETTINGS_INITIAL_WINDOW_SIZE, this.initialWindowSize },
            .{ SettingsType.SETTINGS_MAX_FRAME_SIZE, this.maxFrameSize },
            .{ SettingsType.SETTINGS_MAX_HEADER_LIST_SIZE, this.maxHeaderListSize },
            .{ SettingsType.SETTINGS_ENABLE_CONNECT_PROTOCOL, this.enableConnectProtocol },
        }) |setting| {
            if (!(SettingsPayloadUnit{
                .type = @backingInt(setting[0]),
                .value = setting[1],
            }).write(Writer, writer)) return false;
        }
        return true;
    }
};

pub const max_payload_size_without_frame = default_max_frame_size - FrameHeader.byteSize - 1;

test "frame header serialization round trips" {
    const expected: FrameHeader = .{
        .length = 0x010203,
        .type = @backingInt(FrameType.HTTP_FRAME_HEADERS),
        .flags = @backingInt(HeadersFrameFlags.END_HEADERS),
        .streamIdentifier = 0x10203040,
    };
    var bytes: [FrameHeader.byteSize]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expect(expected.write(@TypeOf(&writer), &writer));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x01, 0x04, 0x10, 0x20, 0x30, 0x40 }, &bytes);

    const actual = FrameHeader.decode(&bytes);
    try std.testing.expectEqualDeep(expected, actual);
}

test "settings payload updates known values" {
    var settings: FullSettingsPayload = .{};
    settings.updateWith(.{
        .type = @backingInt(SettingsType.SETTINGS_INITIAL_WINDOW_SIZE),
        .value = 1234,
    });
    try std.testing.expectEqual(@as(u32, 1234), settings.initialWindowSize);
    try std.testing.expectEqual(@as(u32, 1234), settings.snapshot().initial_window_size);

    var bytes: [FullSettingsPayload.byteSize]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expect(settings.write(@TypeOf(&writer), &writer));
    const unit = SettingsPayloadUnit.decode(bytes[18..24]);
    try std.testing.expectEqual(@backingInt(SettingsType.SETTINGS_INITIAL_WINDOW_SIZE), unit.type);
    try std.testing.expectEqual(@as(u32, 1234), unit.value);
}

test "stream priority uses network byte order" {
    const expected: StreamPriority = .{ .streamIdentifier = 0x10203040, .weight = 0x55 };
    var bytes: [StreamPriority.byteSize]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try std.testing.expect(expected.write(@TypeOf(&writer), &writer));
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 0x40, 0x55 }, &bytes);
    const actual = StreamPriority.decode(&bytes);
    try std.testing.expectEqualDeep(expected, actual);
}

test "reserved stream bit occupies the high wire bit" {
    const value = UInt31WithReserved.init(0x10203040, true);
    try std.testing.expectEqual(@as(u32, 0x90203040), value.toUInt32());
    try std.testing.expectEqualDeep(value, UInt31WithReserved.from(value.toUInt32()));
}

test "header rules distinguish pseudo and repeated headers" {
    try std.testing.expect(valid_response_pseudo_headers.has(":status"));
    try std.testing.expect(!valid_response_pseudo_headers.has(":method"));
    try std.testing.expect(valid_request_pseudo_headers.has(":method"));
    try std.testing.expect(single_value_headers.has("content-length"));
    try std.testing.expect(!single_value_headers.has("set-cookie"));
}

test "header names normalize without changing valid borrowed names" {
    var output: [32]u8 = undefined;
    const borrowed = "content-type";
    try std.testing.expect((try normalizeHeaderName(borrowed, &output)).ptr == borrowed.ptr);
    try std.testing.expectEqualStrings("content-type", try normalizeHeaderName("Content-Type", &output));
    try std.testing.expectEqualStrings(":authority", try normalizeHeaderName(":Authority", &output));
    try std.testing.expectError(error.InvalidHeaderName, normalizeHeaderName("content:type", &output));
    try std.testing.expectError(error.InvalidHeaderName, normalizeHeaderName("white space", &output));
}

const std = @import("std");
