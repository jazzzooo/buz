const bun = @import("bun");
const std = @import("std");

const invalid_character = 0xff;
const padding_character = 0xfe;

const node_decode_table = brk: {
    var table: [256]u8 = @splat(invalid_character);
    for (std.base64.standard_alphabet_chars, 0..) |character, index| {
        table[character] = @intCast(index);
    }
    table['-'] = 62;
    table['_'] = 63;
    table['='] = padding_character;
    break :brk table;
};

pub const decode = decodeNode;

pub fn decodeNode(destination: []u8, source: []const u8) bun.simdutf.SIMDUTFResult {
    return decodeNodeWithAlphabet(destination, source, false);
}

pub fn decodeNodeUrl(destination: []u8, source: []const u8) bun.simdutf.SIMDUTFResult {
    return decodeNodeWithAlphabet(destination, source, true);
}

fn decodeNodeWithAlphabet(destination: []u8, source: []const u8, is_urlsafe: bool) bun.simdutf.SIMDUTFResult {
    if (destination.len < 3) return decodeNodeScalar(destination, source);

    const fast_result = bun.simdutf.base64.decode(source, destination, is_urlsafe);
    if (fast_result.isSuccessful()) return fast_result;
    if (fast_result.status == .output_buffer_too_small) {
        return decodeNodeScalar(destination, source);
    }
    if (destination.len < decodeLen(source)) {
        return decodeNodeScalar(destination, source);
    }

    const input = source[0 .. std.mem.indexOfScalar(u8, source, '=') orelse source.len];
    const result = bun.simdutf.base64.decodeWithOptions(
        input,
        destination,
        .standard_or_url_accept_garbage,
        .loose,
        false,
    );

    return switch (result.status) {
        .success => .{
            .status = .success,
            .count = result.output_count,
        },
        .output_buffer_too_small => brk: {
            const tail = decodeNodeScalar(
                destination[result.output_count..],
                input[result.input_count..],
            );
            break :brk .{
                .status = tail.status,
                .count = result.output_count + tail.count,
            };
        },
        else => decodeNodeScalar(destination, input),
    };
}

pub fn decodeNodeUtf16(destination: []u8, source: []const u16) bun.simdutf.SIMDUTFResult {
    return decodeNodeScalar(destination, source);
}

fn decodeNodeScalar(destination: []u8, source: anytype) bun.simdutf.SIMDUTFResult {
    var accumulator: u16 = 0;
    var bit_count: u4 = 0;
    var output_count: usize = 0;

    for (source) |code_unit| {
        const value = node_decode_table[@as(u8, @truncate(code_unit))];
        if (value == invalid_character) continue;
        if (value == padding_character) {
            return .{ .status = .success, .count = output_count };
        }

        accumulator = (accumulator << 6) | value;
        bit_count += 6;
        if (bit_count < 8) continue;

        bit_count -= 8;
        if (output_count == destination.len) {
            return .{ .status = .output_buffer_too_small, .count = output_count };
        }

        destination[output_count] = @truncate(accumulator >> bit_count);
        output_count += 1;
        accumulator &= (@as(u16, 1) << bit_count) - 1;
    }

    return .{ .status = .success, .count = output_count };
}

pub fn decodeForgiving(destination: []u8, source: []const u8) bun.simdutf.SIMDUTFResult {
    return bun.simdutf.base64.decode(source, destination, false);
}

fn strictDecoder(source: []const u8) *const std.base64.Base64Decoder {
    return if (source.len > 0 and source[source.len - 1] == '=')
        &std.base64.standard.Decoder
    else
        &std.base64.standard_no_pad.Decoder;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = strictDecoder(input);
    const decoded_len = decoder.calcSizeForSlice(input) catch {
        return error.DecodingFailed;
    };
    const destination = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(destination);

    decoder.decode(destination, input) catch return error.DecodingFailed;
    return destination;
}

pub fn decodeAllocForgiving(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var destination = try allocator.alloc(u8, decodeLen(input));
    errdefer allocator.free(destination);

    const result = decodeForgiving(destination, input);
    if (!result.isSuccessful()) return error.DecodingFailed;
    if (result.count == destination.len) return destination;

    destination = try allocator.realloc(destination, result.count);
    return destination;
}

pub fn encode(destination: []u8, source: []const u8) usize {
    return bun.simdutf.base64.encode(source, destination, false);
}

pub fn encodeAlloc(allocator: std.mem.Allocator, source: []const u8) !bun.ByteList {
    const len = encodeLen(source);
    const destination = try allocator.alloc(u8, len);
    const encoded_len = encode(destination, source);
    return .{
        .ptr = destination.ptr,
        .len = @truncate(encoded_len),
        .cap = @truncate(len),
    };
}

pub fn decodeLen(source: anytype) usize {
    var result = source.len / 4 * 3 + source.len % 4 * 3 / 4;
    if (source.len % 4 == 0 and source.len > 0 and source[source.len - 1] == '=') {
        result -= 1;
        if (source.len > 1 and source[source.len - 2] == '=') {
            result -= 1;
        }
    }
    return result;
}

pub fn encodeLen(source: anytype) usize {
    return encodeLenFromSize(source.len);
}

pub fn encodeLenFromSize(source_len: usize) usize {
    return std.base64.standard.Encoder.calcSize(source_len);
}

pub fn urlSafeEncodeLen(source: anytype) usize {
    return std.base64.url_safe_no_pad.Encoder.calcSize(source.len);
}

pub fn encodeURLSafe(destination: []u8, source: []const u8) usize {
    return bun.simdutf.base64.encode(source, destination, true);
}
