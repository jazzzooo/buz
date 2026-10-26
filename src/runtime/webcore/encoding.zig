//! Native byte/string encoding operations shared by bindings and VM-free code.

pub fn encodeStringInto(value: bun.String, output: []u8, comptime encoding: Encoding) usize {
    if (value.isUTF16()) return encodeIntoFrom16(value.utf16(), output, encoding, true);
    return encodeIntoFrom8(value.latin1(), output, encoding, true);
}

pub fn encodeString(value: bun.String, encoding: Encoding) bun.OOM![]u8 {
    return encodeTextView(value.textView(), bun.default_allocator, encoding);
}

pub fn encodeTextView(view: bun.TextView, allocator: std.mem.Allocator, encoding: Encoding) bun.OOM![]u8 {
    return switch (view) {
        inline else => |representation| switch (encoding) {
            inline else => |resolved| try constructFrom(std.meta.Child(@TypeOf(representation)), representation, allocator, resolved),
        },
    };
}

pub fn transcodeOwnedStringSlice(owned_input_bytes: []u8, encoding: Encoding) bun.SliceWithUnderlyingString {
    if (owned_input_bytes.len == 0) {
        return .{
            .utf8 = bun.String.Slice.empty,
            .underlying = bun.String.empty,
        };
    }
    return .{
        .underlying = toBunStringFromOwnedSlice(owned_input_bytes, encoding),
    };
}

pub fn toBunStringFromOwnedSlice(input: []u8, encoding: Encoding) bun.String {
    if (input.len == 0)
        return bun.String.empty;

    switch (encoding) {
        .ascii => {
            if (strings.isAllASCII(input)) {
                return bun.String.createExternalGloballyAllocated(.latin1, input);
            }

            const str, const chars = bun.String.createUninitialized(.latin1, input.len);
            defer bun.default_allocator.free(input);
            if (str.tag == .Dead) {
                return str;
            }
            strings.copyLatin1IntoASCII(chars, input);
            return str;
        },
        .latin1 => {
            return bun.String.createExternalGloballyAllocated(.latin1, input);
        },
        .buffer, .utf8 => {
            const converted = strings.toUTF16Alloc(bun.default_allocator, input, false, false) catch {
                bun.default_allocator.free(input);
                return bun.String.dead;
            };

            if (converted) |utf16| {
                defer bun.default_allocator.free(input);
                return bun.String.createExternalGloballyAllocated(.utf16, utf16);
            }

            // If we get here, it means we can safely assume the string is 100% ASCII characters
            return bun.String.createExternalGloballyAllocated(.latin1, input);
        },
        .ucs2, .utf16le => {
            return bun.String.createExternalGloballyAllocatedBytes(.utf16, input, input.len / 2);
        },

        .hex => {
            defer bun.default_allocator.free(input);
            const str, const chars = bun.String.createUninitialized(.latin1, input.len * 2);

            if (str.tag == .Dead) {
                return str;
            }

            const wrote = strings.encodeBytesToHex(chars, input);

            // Return an empty string in this case, just like node.
            if (wrote < chars.len) {
                str.deref();
                return bun.String.empty;
            }

            return str;
        },

        // TODO: this is not right. There is an issue here. But it needs to
        // be addressed separately because constructFromU8's base64url also
        // appears inconsistent with Node.js.
        .base64url => {
            defer bun.default_allocator.free(input);
            const out, const chars = bun.String.createUninitialized(.latin1, bun.base64.urlSafeEncodeLen(input));
            if (out.tag != .Dead) {
                _ = bun.base64.encodeURLSafe(chars, input);
            }
            return out;
        },

        .base64 => {
            defer bun.default_allocator.free(input);
            const to_len = bun.base64.encodeLen(input);
            const to = bun.default_allocator.alloc(u8, to_len) catch return bun.String.dead;
            const wrote = bun.base64.encode(to, input);
            return bun.String.createExternalGloballyAllocatedWithLength(.latin1, to, wrote);
        },
    }
}

pub fn toBunString(input: []const u8, encoding: Encoding) bun.String {
    return switch (encoding) {
        inline else => |enc| toBunStringComptime(input, enc),
    };
}

pub fn toBunStringComptime(input: []const u8, comptime encoding: Encoding) bun.String {
    if (input.len == 0)
        return bun.String.empty;

    switch (comptime encoding) {
        .ascii => {
            const str, const chars = bun.String.createUninitialized(.latin1, input.len);
            if (str.tag == .Dead) {
                return str;
            }
            strings.copyLatin1IntoASCII(chars, input);
            return str;
        },
        .latin1 => {
            const str, const chars = bun.String.createUninitialized(.latin1, input.len);
            if (str.tag == .Dead) {
                return str;
            }
            @memcpy(chars, input);
            return str;
        },
        .buffer, .utf8 => {
            const converted = strings.toUTF16Alloc(bun.default_allocator, input, false, false) catch return bun.String.dead;
            if (converted) |utf16| {
                return bun.String.createExternalGloballyAllocated(.utf16, utf16);
            }

            // If we get here, it means we can safely assume the string is 100% ASCII characters
            // For this, we rely on WebKit to manage the memory.
            return bun.String.cloneLatin1(input);
        },
        .ucs2, .utf16le => {
            // Avoid incomplete characters
            if (input.len / 2 == 0) return bun.String.empty;

            const str, const chars = bun.String.createUninitialized(.utf16, input.len / 2);
            if (str.tag == .Dead) {
                return str;
            }
            var output_bytes = std.mem.sliceAsBytes(chars);
            output_bytes[output_bytes.len - 1] = 0;

            @memcpy(output_bytes, input[0..output_bytes.len]);
            return str;
        },

        .hex => {
            const str, const chars = bun.String.createUninitialized(.latin1, input.len * 2);
            if (str.tag == .Dead) {
                return str;
            }

            const wrote = strings.encodeBytesToHex(chars, input);
            bun.assert(wrote == chars.len);
            return str;
        },

        .base64url => {
            const to_len = bun.base64.urlSafeEncodeLen(input);
            const to = bun.default_allocator.alloc(u8, to_len) catch return bun.String.dead;
            const wrote = bun.base64.encodeURLSafe(to, input);
            return bun.String.createExternalGloballyAllocatedWithLength(.latin1, to, wrote);
        },

        .base64 => {
            const to_len = bun.base64.encodeLen(input);
            const to = bun.default_allocator.alloc(u8, to_len) catch return bun.String.dead;
            const wrote = bun.base64.encode(to, input);
            return bun.String.createExternalGloballyAllocatedWithLength(.latin1, to, wrote);
        },
    }
}

pub fn writeU8(input: [*]const u8, len: usize, to_ptr: [*]u8, to_len: usize, comptime encoding: Encoding, comptime allow_partial_write: bool) usize {
    if (len == 0 or to_len == 0)
        return 0;

    // TODO: increase temporary buffer size for larger amounts of data
    // defer {
    //     if (comptime encoding.isBinaryToText()) {}
    // }

    // if (comptime encoding.isBinaryToText()) {}

    switch (comptime encoding) {
        .buffer, .latin1 => {
            const written = @min(len, to_len);
            @memcpy(to_ptr[0..written], input[0..written]);

            return written;
        },
        .ascii => {
            const written = @min(len, to_len);

            const to = to_ptr[0..written];
            var remain = input[0..written];

            if (bun.simdutf.validate.ascii(remain)) {
                @memcpy(to_ptr[0..written], remain[0..written]);
            } else {
                strings.copyLatin1IntoASCII(to, remain);
            }

            return written;
        },
        .utf8 => {
            const encoded = strings.copyLatin1IntoUTF8(to_ptr[0..to_len], input[0..len]);
            if (allow_partial_write and encoded.written < to_len and encoded.read < len) {
                bun.assert(to_len - encoded.written == 1 and input[encoded.read] >= 0x80);
                to_ptr[encoded.written] = 0xc0 | (input[encoded.read] >> 6);
                return @as(usize, encoded.written) + 1;
            }
            return encoded.written;
        },
        // encode latin1 into UTF16
        .ucs2, .utf16le => {
            if (to_len < 2 and !allow_partial_write)
                return 0;

            const written = if (std.mem.isAligned(@intFromPtr(to_ptr), @alignOf(u16))) written: {
                const buf = input[0..len];

                const output = @as([*]u16, @ptrCast(@alignCast(to_ptr)))[0 .. to_len / 2];
                break :written strings.copyLatin1IntoUTF16([]u16, output, buf).written;
            } else written: {
                const buf = input[0..len];
                const output = @as([*]align(1) u16, @ptrCast(to_ptr))[0 .. to_len / 2];

                break :written strings.copyLatin1IntoUTF16([]align(1) u16, output, buf).written;
            };
            const byte_count = @as(usize, written) * 2;
            if (allow_partial_write and byte_count < to_len and written < len) {
                to_ptr[byte_count] = input[written];
                return byte_count + 1;
            }
            return byte_count;
        },

        .hex => {
            return strings.decodeHexToBytesTruncate(to_ptr[0..to_len], u8, input[0..len]);
        },

        .base64 => {
            return bun.base64.decodeNode(to_ptr[0..to_len], input[0..len]).count;
        },
        .base64url => return bun.base64.decodeNodeUrl(to_ptr[0..to_len], input[0..len]).count,
    }
}

pub fn byteLengthU8(input: [*]const u8, len: usize, comptime encoding: Encoding) usize {
    if (len == 0)
        return 0;

    switch (comptime encoding) {
        .utf8 => {
            return strings.elementLengthLatin1IntoUTF8(input[0..len]);
        },

        .latin1, .ascii, .buffer => {
            return len;
        },

        .ucs2, .utf16le => {
            return strings.elementLengthUTF8IntoUTF16(input[0..len]) * 2;
        },

        .hex => {
            return len / 2;
        },

        .base64, .base64url => {
            return bun.base64.decodeLen(input[0..len]);
        },
        // else => return &[_]u8{};
    }
}

pub fn encodeIntoFrom16(input: []const u16, to: []u8, comptime encoding: Encoding, comptime allow_partial_write: bool) usize {
    return writeU16(input.ptr, input.len, to.ptr, to.len, encoding, allow_partial_write);
}

pub fn encodeIntoFrom8(input: []const u8, to: []u8, comptime encoding: Encoding, comptime allow_partial_write: bool) usize {
    return writeU8(input.ptr, input.len, to.ptr, to.len, encoding, allow_partial_write);
}

pub fn writeU16(input: [*]const u16, len: usize, to: [*]u8, to_len: usize, comptime encoding: Encoding, comptime allow_partial_write: bool) usize {
    if (len == 0)
        return 0;

    switch (comptime encoding) {
        .utf8 => {
            return strings.copyUTF16IntoUTF8Impl(
                to[0..to_len],
                input[0..len],
                allow_partial_write,
            ).written;
        },
        .latin1, .ascii, .buffer => {
            const out = @min(len, to_len);
            strings.copyU16IntoU8(to[0..to_len], input[0..out]);
            return out;
        },
        // string is already encoded, just need to copy the data
        .ucs2, .utf16le => {
            if (allow_partial_write) {
                const bytes_input_len = len * 2;
                const written = @min(bytes_input_len, to_len);
                const input_u8 = @as([*]const u8, @ptrCast(input));
                bun.memmove(to[0..written], input_u8[0..written]);
                return written;
            } else {
                const bytes_input_len = len * 2;
                const written = @min(bytes_input_len, to_len);
                if (written < 2) return 0;

                const fixed_len = (written / 2) * 2;
                const input_u8 = @as([*]const u8, @ptrCast(input));
                bun.memmove(to[0..written], input_u8[0..fixed_len]);
                return fixed_len;
            }
        },

        .hex => {
            return strings.decodeHexToBytesTruncate(to[0..to_len], u16, input[0..len]);
        },

        .base64, .base64url => {
            return bun.base64.decodeNodeUtf16(to[0..to_len], input[0..len]).count;
        },
        // else => return &[_]u8{};
    }
}

pub fn constructFrom(comptime T: type, input: []const T, allocator: std.mem.Allocator, comptime encoding: Encoding) bun.OOM![]u8 {
    return switch (comptime T) {
        u16 => try constructFromU16(input.ptr, input.len, allocator, encoding),
        u8 => try constructFromU8(input.ptr, input.len, allocator, encoding),
        else => @compileError("Unsupported type for constructFrom: " ++ @typeName(T)),
    };
}

pub fn constructFromU8(input: [*]const u8, len: usize, allocator: std.mem.Allocator, comptime encoding: Encoding) bun.OOM![]u8 {
    if (len == 0) return &[_]u8{};

    switch (comptime encoding) {
        .buffer => {
            const to = try allocator.alloc(u8, len);
            @memcpy(to[0..len], input[0..len]);
            return to;
        },
        .latin1, .ascii => {
            const to = try allocator.alloc(u8, len);
            @memcpy(to[0..len], input[0..len]);
            return to;
        },
        .utf8 => {
            return try strings.allocateLatin1IntoUTF8(allocator, input[0..len]);
        },
        .ucs2, .utf16le => {
            const to = try allocator.alloc(u16, len);
            _ = strings.copyLatin1IntoUTF16([]u16, to, input[0..len]);
            return std.mem.sliceAsBytes(to[0..len]);
        },

        .hex => {
            if (len < 2)
                return &[_]u8{};

            var to = try allocator.alloc(u8, len / 2);
            errdefer allocator.free(to);
            const wrote = strings.decodeHexToBytesTruncate(to, u8, input[0..len]);
            if (wrote == 0) {
                allocator.free(to);
                return &[_]u8{};
            }
            if (wrote != to.len) to = try allocator.realloc(to, wrote);
            return to;
        },

        .base64, .base64url => {
            const source = input[0..len];

            const outlen = bun.base64.decodeLen(source);
            var to = try allocator.alloc(u8, outlen);
            errdefer allocator.free(to);

            const wrote = if (comptime encoding == .base64)
                bun.base64.decodeNode(to, source).count
            else
                bun.base64.decodeNodeUrl(to, source).count;
            if (wrote == 0) {
                allocator.free(to);
                return &[_]u8{};
            }
            if (wrote != to.len) to = try allocator.realloc(to, wrote);
            return to;
        },
    }
}

pub fn constructFromU16(input: [*]const u16, len: usize, allocator: std.mem.Allocator, comptime encoding: Encoding) bun.OOM![]u8 {
    if (len == 0) return &[_]u8{};

    switch (comptime encoding) {
        .utf8 => {
            return try strings.toUTF8Alloc(allocator, input[0..len]);
        },
        .latin1, .buffer, .ascii => {
            const to = try allocator.alloc(u8, len);
            strings.copyU16IntoU8(to[0..len], input[0..len]);
            return to;
        },
        .ucs2, .utf16le => {
            const to = std.mem.sliceAsBytes(try allocator.alloc(u16, len));
            const bytes = std.mem.sliceAsBytes(input[0..len]);
            @memcpy(to[0..bytes.len], bytes);
            return to;
        },

        .hex => {
            if (len < 2)
                return &[_]u8{};

            var to = try allocator.alloc(u8, len / 2);
            errdefer allocator.free(to);
            const wrote = strings.decodeHexToBytesTruncate(to, u16, input[0..len]);
            if (wrote == 0) {
                allocator.free(to);
                return &[_]u8{};
            }
            if (wrote != to.len) to = try allocator.realloc(to, wrote);
            return to;
        },

        .base64, .base64url => {
            const source = input[0..len];
            const outlen = bun.base64.decodeLen(source);
            var to = try allocator.alloc(u8, outlen);
            errdefer allocator.free(to);

            const wrote = bun.base64.decodeNodeUtf16(to, source).count;
            if (wrote == 0) {
                allocator.free(to);
                return &[_]u8{};
            }
            if (wrote != to.len) to = try allocator.realloc(to, wrote);
            return to;
        },
    }
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const Encoding = @import("../node/types.zig").Encoding;
