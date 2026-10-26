pub const ErrorCode = enum(i32) {
    cancel = 1,
    invalid_response = 2,
    expected_101_status_code = 3,
    missing_upgrade_header = 4,
    missing_connection_header = 5,
    missing_websocket_accept_header = 6,
    invalid_upgrade_header = 7,
    invalid_connection_header = 8,
    invalid_websocket_version = 9,
    mismatch_websocket_accept_header = 10,
    missing_client_protocol = 11,
    mismatch_client_protocol = 12,
    timeout = 13,
    closed = 14,
    failed_to_write = 15,
    failed_to_connect = 16,
    headers_too_large = 17,
    ended = 18,
    failed_to_allocate_memory = 19,
    control_frame_is_fragmented = 20,
    invalid_control_frame = 21,
    compression_unsupported = 22,
    invalid_compressed_data = 23,
    compression_failed = 24,
    unexpected_mask_from_server = 25,
    expected_control_frame = 26,
    unsupported_control_frame = 27,
    unexpected_opcode = 28,
    invalid_utf8 = 29,
    tls_handshake_failed = 30,
    message_too_big = 31,
    protocol_error = 32,
    proxy_connect_failed = 33,
    proxy_authentication_required = 34,
    proxy_connection_refused = 35,
    proxy_tunnel_failed = 36,
};

pub const ReceiveState = enum {
    need_header,
    need_mask,
    need_body,
    extended_payload_length_16,
    extended_payload_length_64,
    ping,
    pong,
    close,
    fail,
};

pub fn parseHeader(
    bytes: [2]u8,
    receiving_type: *Opcode,
    payload_length: *usize,
    is_fragmented: *bool,
    is_final: *bool,
    need_compression: *bool,
) ReceiveState {
    const header = WebsocketHeader.fromSlice(bytes);
    const payload = @as(usize, header.len);
    payload_length.* = payload;
    receiving_type.* = header.opcode;
    is_fragmented.* = header.opcode == .Continue or !header.final;
    is_final.* = header.final;

    if (header.opcode == .Text or header.opcode == .Binary) {
        need_compression.* = header.compressed;
    } else if (header.opcode == .Continue) {
        need_compression.* = false;
    } else {
        if (header.compressed) return .fail;
        need_compression.* = false;
    }

    if (header.mask and (header.opcode == .Text or header.opcode == .Binary)) return .need_mask;
    if (header.rsv != 0) return .fail;
    return switch (header.opcode) {
        .Text, .Continue, .Binary => if (payload <= 125)
            .need_body
        else if (payload == 126)
            .extended_payload_length_16
        else if (payload == 127)
            .extended_payload_length_64
        else
            .fail,
        .Close => .close,
        .Ping => .ping,
        .Pong => .pong,
        else => .fail,
    };
}

pub fn applyMask(mask: [4]u8, mask_buffer: *[4]u8, output: []u8, input: []const u8) void {
    mask_buffer.* = mask;
    if (input.len == 0) return;
    bun.highway.fillWithSkipMask(mask, output, input, @as(u32, @bitCast(mask)) == 0);
}

pub const Copy = union(enum) {
    utf16: []const u16,
    latin1: []const u8,
    bytes: []const u8,
    raw: []const u8,

    pub fn len(copy: @This(), byte_len: *usize) usize {
        switch (copy) {
            .utf16 => {
                byte_len.* = strings.elementLengthUTF16IntoUTF8(copy.utf16);
                return WebsocketHeader.frameSizeIncludingMask(byte_len.*);
            },
            .latin1 => {
                byte_len.* = strings.elementLengthLatin1IntoUTF8(copy.latin1);
                return WebsocketHeader.frameSizeIncludingMask(byte_len.*);
            },
            .bytes => {
                byte_len.* = copy.bytes.len;
                return WebsocketHeader.frameSizeIncludingMask(byte_len.*);
            },
            .raw => {
                byte_len.* = copy.raw.len;
                return copy.raw.len;
            },
        }
    }

    pub fn writeFrame(copy: @This(), mask: [4]u8, buffer: []u8, content_byte_len: usize, opcode: Opcode) void {
        if (copy == .raw) {
            bun.assert(buffer.len >= copy.raw.len);
            bun.assert(buffer.ptr != copy.raw.ptr);
            @memcpy(buffer[0..copy.raw.len], copy.raw);
            return;
        }

        const length_bytes = WebsocketHeader.lengthByteCount(content_byte_len);
        const mask_offset = 2 + length_bytes;
        const content_offset = mask_offset + 4;
        const output = buffer[content_offset..];
        switch (length_bytes) {
            0 => {},
            2 => std.mem.writeInt(u16, buffer[2..][0..2], @truncate(content_byte_len), .big),
            8 => std.mem.writeInt(u64, buffer[2..][0..8], @truncate(content_byte_len), .big),
            else => unreachable,
        }

        var header: WebsocketHeader = @bitCast(@as(u16, 0));
        header.mask = true;
        header.compressed = false;
        header.final = true;
        header.opcode = opcode;
        bun.assert(WebsocketHeader.frameSizeIncludingMask(content_byte_len) == buffer.len);

        switch (copy) {
            .utf16 => |utf16| {
                const encoded = strings.copyUTF16IntoUTF8Impl(output, utf16, true);
                bun.assert(@as(usize, encoded.written) == content_byte_len);
                bun.assert(@as(usize, encoded.read) == utf16.len);
                header.len = WebsocketHeader.packLength(encoded.written);
                var writer = std.Io.Writer.fixed(buffer);
                header.writeHeader(&writer, encoded.written) catch unreachable;
                applyMask(mask, buffer[mask_offset..][0..4], output[0..content_byte_len], output[0..content_byte_len]);
            },
            .latin1 => |latin1| {
                const encoded = strings.copyLatin1IntoUTF8(output, latin1);
                bun.assert(@as(usize, encoded.written) == content_byte_len);
                bun.assert(@as(usize, encoded.read) == latin1.len);
                header.len = WebsocketHeader.packLength(encoded.written);
                var writer = std.Io.Writer.fixed(buffer);
                header.writeHeader(&writer, encoded.written) catch unreachable;
                applyMask(mask, buffer[mask_offset..][0..4], output[0..content_byte_len], output[0..content_byte_len]);
            },
            .bytes => |bytes| {
                header.len = WebsocketHeader.packLength(bytes.len);
                var writer = std.Io.Writer.fixed(buffer);
                header.writeHeader(&writer, bytes.len) catch unreachable;
                applyMask(mask, buffer[mask_offset..][0..4], output[0..content_byte_len], bytes);
            },
            .raw => unreachable,
        }
    }

    pub fn writeCompressedFrame(
        mask: [4]u8,
        buffer: []u8,
        compressed_data: []const u8,
        opcode: Opcode,
        is_first_fragment: bool,
    ) void {
        const content_byte_len = compressed_data.len;
        const length_bytes = WebsocketHeader.lengthByteCount(content_byte_len);
        const mask_offset = 2 + length_bytes;
        const content_offset = mask_offset + 4;
        const output = buffer[content_offset..];
        switch (length_bytes) {
            0 => {},
            2 => std.mem.writeInt(u16, buffer[2..][0..2], @truncate(content_byte_len), .big),
            8 => std.mem.writeInt(u64, buffer[2..][0..8], @truncate(content_byte_len), .big),
            else => unreachable,
        }

        var header: WebsocketHeader = @bitCast(@as(u16, 0));
        header.mask = true;
        header.compressed = is_first_fragment;
        header.final = true;
        header.opcode = opcode;
        header.len = WebsocketHeader.packLength(content_byte_len);
        bun.assert(WebsocketHeader.frameSizeIncludingMask(content_byte_len) == buffer.len);
        var writer = std.Io.Writer.fixed(buffer);
        header.writeHeader(&writer, content_byte_len) catch unreachable;
        applyMask(mask, buffer[mask_offset..][0..4], output[0..content_byte_len], compressed_data);
    }
};

const std = @import("std");
const bun = @import("bun");
const strings = bun.strings;
const Opcode = @import("../http/websocket.zig").Opcode;
const WebsocketHeader = @import("../http/websocket.zig").WebsocketHeader;
