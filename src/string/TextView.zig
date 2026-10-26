//! A borrowed tri-encoding text view: a slice of code units plus their
//! declared encoding. This is the Zig-side shape of the engine's string-view
//! wire type; it owns nothing and must not outlive the viewed memory.

pub const TextView = union(Encoding) {
    latin1: []const u8,
    utf8: []const u8,
    utf16: []const u16,

    pub const Encoding = enum(u8) { latin1, utf8, utf16 };

    pub const empty: TextView = .{ .latin1 = "" };

    /// UTF-8 unless the bytes are all ASCII, in which case latin1 (which
    /// converts without inspection).
    pub fn fromBytes(bytes: []const u8) TextView {
        if (bun.strings.isAllASCII(bytes)) return .{ .latin1 = bytes };
        return .{ .utf8 = bytes };
    }

    /// Code units, not bytes and not code points.
    pub fn len(this: TextView) usize {
        return switch (this) {
            inline else => |slice| slice.len,
        };
    }

    pub fn isEmpty(this: TextView) bool {
        return this.len() == 0;
    }

    pub fn byteSlice(this: TextView) []const u8 {
        return switch (this) {
            .latin1, .utf8 => |bytes| bytes,
            .utf16 => |slice| std.mem.sliceAsBytes(slice),
        };
    }

    /// UTF-8 bytes, always allocated.
    pub fn toOwnedSlice(this: TextView, allocator: std.mem.Allocator) bun.OOM![]u8 {
        switch (this) {
            .utf8 => |bytes| return allocator.dupe(u8, bytes),
            inline .latin1, .utf16 => |input| {
                var list = std.array_list.Managed(u8).init(allocator);
                errdefer list.deinit();
                if (comptime @TypeOf(input) == []const u16)
                    try bun.strings.toUTF8AppendToList(&list, input)
                else
                    try bun.strings.allocateLatin1IntoUTF8WithList(&list, input);
                return list.toOwnedSlice();
            },
        }
    }

    /// Null-terminated UTF-8 bytes, always allocated.
    pub fn toOwnedSliceZ(this: TextView, allocator: std.mem.Allocator) bun.OOM![:0]u8 {
        switch (this) {
            .utf8 => |bytes| return allocator.dupeSentinel(u8, bytes, 0),
            inline .latin1, .utf16 => |input| {
                var list = std.array_list.Managed(u8).init(allocator);
                errdefer list.deinit();
                if (comptime @TypeOf(input) == []const u16)
                    try bun.strings.toUTF8AppendToList(&list, input)
                else
                    try bun.strings.allocateLatin1IntoUTF8WithList(&list, input);
                return list.toOwnedSliceSentinel(0);
            },
        }
    }

    /// UTF-8 view of the text: borrows when the bytes are already valid
    /// UTF-8, converts otherwise.
    pub fn toSlice(this: TextView, allocator: std.mem.Allocator) bun.OOM!bun.String.Slice {
        switch (this) {
            .utf8 => |bytes| return .fromUTF8NeverFree(bytes),
            .latin1 => |bytes| {
                if (bun.strings.isAllASCII(bytes)) return .fromUTF8NeverFree(bytes);
            },
            .utf16 => {},
        }
        const buffer = try this.toOwnedSlice(allocator);
        return .init(allocator, buffer);
    }

    /// UTF-8 bytes owned by `allocator`, always allocated.
    pub fn toSliceClone(this: TextView, allocator: std.mem.Allocator) bun.OOM!bun.String.Slice {
        return .init(allocator, try this.toOwnedSlice(allocator));
    }

    /// Clone into an owned string.
    pub fn toBunString(this: TextView) bun.String {
        return switch (this) {
            .latin1 => |bytes| bun.String.cloneLatin1(bytes),
            .utf8 => |bytes| bun.String.cloneUTF8(bytes),
            .utf16 => |units| bun.String.cloneUTF16(units),
        };
    }

    pub fn hasPrefixComptime(this: TextView, comptime prefix: []const u8) bool {
        if (this.len() < prefix.len) return false;
        return this.substringWithLen(0, prefix.len).eqlBytes(prefix);
    }

    pub fn inMapCaseInsensitive(this: TextView, comptime ComptimeStringMap: anytype) ?ComptimeStringMap.Value {
        return ComptimeStringMap.getWithEqlList(this, indexOfComptimeArrayCaseInsensitiveSameLength);
    }

    fn indexOfComptimeArrayCaseInsensitiveSameLength(this: TextView, comptime values: []const []const u8) ?usize {
        switch (this) {
            .latin1, .utf8 => |bytes| {
                inline for (0..values.len) |i| {
                    bun.assert(bytes.len == values[i].len);
                    if (bun.strings.eqlCaseInsensitiveASCIIIgnoreLength(bytes, values[i])) {
                        return i;
                    }
                }
                return null;
            },
            .utf16 => |units| {
                const buffer: [values[0].len]u8 = brk: {
                    var bytes: [values[0].len]u8 = undefined;
                    for (&bytes, units) |*byte, uchar| {
                        if (uchar > 255)
                            return null;

                        byte.* = @as(u8, @intCast(uchar));
                    }
                    break :brk bytes;
                };

                inline for (0..values.len) |i| {
                    if (bun.strings.eqlCaseInsensitiveASCIIIgnoreLength(&buffer, values[i])) {
                        return i;
                    }
                }
                return null;
            },
        }
    }

    pub fn indexOfAsciiChar(this: TextView, char: u8) ?usize {
        return switch (this) {
            .latin1, .utf8 => |bytes| std.mem.indexOfScalar(u8, bytes, char),
            .utf16 => |units| std.mem.indexOfScalar(u16, units, char),
        };
    }

    /// The code unit at `index`, truncated to its low byte.
    pub fn charAt(this: TextView, index: usize) u8 {
        return switch (this) {
            .latin1, .utf8 => |bytes| bytes[index],
            .utf16 => |slice| @truncate(slice[index]),
        };
    }

    pub fn indexOfAny(this: TextView, comptime chars: []const u8) ?bun.strings.OptionalUsize {
        return switch (this) {
            .latin1, .utf8 => |bytes| bun.strings.indexOfAny(bytes, chars),
            .utf16 => |slice| bun.strings.indexOfAny16(slice, chars),
        };
    }

    /// Subview over the code-unit range [start, end).
    pub fn substringWithLen(this: TextView, start: usize, end: usize) TextView {
        return switch (this) {
            inline else => |slice, tag| @unionInit(TextView, @tagName(tag), slice[start..end]),
        };
    }

    /// Subview from the code-unit index to the end.
    pub fn substring(this: TextView, start: usize) TextView {
        return this.substringWithLen(@min(start, this.len()), this.len());
    }

    /// Content equality across encodings.
    pub fn eqlUTF8View(this: TextView, other: TextView) bool {
        if (this.len() == 0 or other.len() == 0) {
            return this.len() == other.len();
        }
        if (std.meta.activeTag(this) == std.meta.activeTag(other)) {
            return bun.strings.eqlLong(this.byteSlice(), other.byteSlice(), true);
        }
        // Mixed encodings: an all-ASCII byte side compares directly against
        // UTF-16; anything else goes through UTF-8 conversion.
        switch (this) {
            .utf16 => |units| switch (other) {
                .latin1, .utf8 => |bytes| if (bun.strings.isAllASCII(bytes)) return bun.strings.utf16EqlString(units, bytes),
                .utf16 => unreachable,
            },
            .latin1, .utf8 => |bytes| switch (other) {
                .utf16 => |units| if (bun.strings.isAllASCII(bytes)) return bun.strings.utf16EqlString(units, bytes),
                .latin1, .utf8 => |other_bytes| {
                    if (bun.strings.isAllASCII(bytes) and bun.strings.isAllASCII(other_bytes)) {
                        return bun.strings.eqlLong(bytes, other_bytes, true);
                    }
                },
            },
        }
        var left = UTF8Chunks{ .text = this };
        var right = UTF8Chunks{ .text = other };
        var left_chunk = left.next() orelse &.{};
        var right_chunk = right.next() orelse &.{};
        while (left_chunk.len != 0 and right_chunk.len != 0) {
            const length = @min(left_chunk.len, right_chunk.len);
            if (!std.mem.eql(u8, left_chunk[0..length], right_chunk[0..length])) return false;
            left_chunk = left_chunk[length..];
            right_chunk = right_chunk[length..];
            if (left_chunk.len == 0) left_chunk = left.next() orelse &.{};
            if (right_chunk.len == 0) right_chunk = right.next() orelse &.{};
        }
        return left_chunk.len == 0 and right_chunk.len == 0;
    }

    pub const encodeWithAllocator = text_encoding.encodeTextView;

    pub fn eqlBytes(this: TextView, expected: []const u8) bool {
        return switch (this) {
            .latin1, .utf8 => |bytes| bun.strings.eqlLong(bytes, expected, true),
            .utf16 => |slice| bun.strings.utf16EqlString(slice, expected),
        };
    }

    pub fn format(this: TextView, writer: *std.Io.Writer) !void {
        switch (this) {
            .latin1 => |bytes| try bun.fmt.formatLatin1(bytes, writer),
            .utf8 => |bytes| try writer.writeAll(bytes),
            .utf16 => |slice| try bun.fmt.formatUTF16Type(slice, writer),
        }
    }

    pub fn hashUTF8(this: TextView) u64 {
        var hasher = std.hash.Wyhash.init(0);
        var chunks = UTF8Chunks{ .text = this };
        while (chunks.next()) |chunk| hasher.update(chunk);
        return hasher.final();
    }

    pub fn utf8Chunks(this: TextView) UTF8Chunks {
        return .{ .text = this };
    }

    const UTF8Chunks = struct {
        text: TextView,
        offset: usize = 0,
        encoded: [4]u8 = undefined,

        // Chunks borrow the input or scratch bytes until the next call.
        pub fn next(this: *UTF8Chunks) ?[]const u8 {
            if (this.offset == this.text.len()) return null;
            const codepoint: u32 = switch (this.text) {
                .utf8 => |bytes| {
                    this.offset = bytes.len;
                    return bytes;
                },
                .latin1 => |bytes| latin1: {
                    if (this.offset == 0 and bun.strings.isAllASCII(bytes)) {
                        this.offset = bytes.len;
                        return bytes;
                    }
                    const unit = bytes[this.offset];
                    this.offset += 1;
                    break :latin1 unit;
                },
                .utf16 => |units| utf16: {
                    const decoded = bun.strings.utf16CodepointWithFFFD(units[this.offset..]);
                    this.offset += decoded.len;
                    break :utf16 decoded.code_point;
                },
            };
            const length = bun.strings.encodeWTF8RuneT(&this.encoded, u32, codepoint);
            return this.encoded[0..length];
        }
    };
};

const std = @import("std");

const bun = @import("bun");
const text_encoding = @import("../runtime/webcore/encoding.zig");
