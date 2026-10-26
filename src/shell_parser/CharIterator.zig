pub const StringEncoding = enum { ascii, wtf8, utf16 };

const SrcAscii = struct {
    bytes: []const u8,
    i: usize,

    const IndexValue = packed struct(u8) {
        char: u7,
        escaped: bool = false,
    };

    fn init(bytes: []const u8) SrcAscii {
        return .{
            .bytes = bytes,
            .i = 0,
        };
    }

    inline fn index(this: *const SrcAscii) ?IndexValue {
        if (this.i >= this.bytes.len) return null;
        return .{ .char = @intCast(this.bytes[this.i]) };
    }

    inline fn indexNext(this: *const SrcAscii) ?IndexValue {
        if (this.i + 1 >= this.bytes.len) return null;
        return .{ .char = @intCast(this.bytes[this.i + 1]) };
    }

    inline fn eat(this: *SrcAscii, escaped: bool) void {
        this.i += 1 + @as(u32, @intFromBool(escaped));
    }
};

const SrcUnicode = struct {
    iter: CodepointIterator,
    cursor: CodepointIterator.Cursor,
    next_cursor: CodepointIterator.Cursor,

    const IndexValue = struct {
        char: u32,
        width: u8,
    };

    fn nextCursor(iter: *const CodepointIterator, cursor: *CodepointIterator.Cursor) void {
        if (!iter.next(cursor)) {
            cursor.i = @intCast(iter.bytes.len + 1);
            cursor.width = 1;
            cursor.c = CodepointIterator.ZeroValue;
        }
    }

    fn init(bytes: []const u8) SrcUnicode {
        var iter = CodepointIterator.init(bytes);
        var cursor = CodepointIterator.Cursor{};
        nextCursor(&iter, &cursor);
        var next_cursor: CodepointIterator.Cursor = cursor;
        nextCursor(&iter, &next_cursor);
        return .{ .iter = iter, .cursor = cursor, .next_cursor = next_cursor };
    }

    inline fn index(this: *const SrcUnicode) ?IndexValue {
        if (this.cursor.width + this.cursor.i > this.iter.bytes.len) return null;
        return .{ .char = this.cursor.c, .width = this.cursor.width };
    }

    inline fn indexNext(this: *const SrcUnicode) ?IndexValue {
        if (this.next_cursor.width + this.next_cursor.i > this.iter.bytes.len) return null;
        return .{ .char = @intCast(this.next_cursor.c), .width = this.next_cursor.width };
    }

    inline fn eat(this: *SrcUnicode, escaped: bool) void {
        if (escaped) {
            nextCursor(&this.iter, &this.next_cursor);
            this.cursor = this.next_cursor;
            nextCursor(&this.iter, &this.next_cursor);
        } else {
            this.cursor = this.next_cursor;
            nextCursor(&this.iter, &this.next_cursor);
        }
    }
};

pub fn ShellCharIter(comptime encoding: StringEncoding) type {
    return struct {
        src: Src,
        state: State = .Normal,
        prev: ?InputChar = null,
        current: ?InputChar = null,

        pub const Src = switch (encoding) {
            .ascii => SrcAscii,
            .wtf8, .utf16 => SrcUnicode,
        };

        pub const CodepointType = if (encoding == .ascii) u7 else u32;

        pub const InputChar = if (encoding == .ascii) SrcAscii.IndexValue else struct {
            char: u32,
            escaped: bool = false,
        };

        pub fn isWhitespace(char: InputChar) bool {
            return switch (char.char) {
                '\t', '\r', '\n', ' ' => true,
                else => false,
            };
        }

        pub const State = enum {
            Normal,
            Single,
            Double,
        };

        pub fn init(bytes: []const u8) @This() {
            const src = if (comptime encoding == .ascii)
                SrcAscii.init(bytes)
            else
                SrcUnicode.init(bytes);

            return .{
                .src = src,
            };
        }

        pub fn srcBytes(self: *@This()) []const u8 {
            if (comptime encoding == .ascii) return self.src.bytes;
            return self.src.iter.bytes;
        }

        pub fn srcBytesAtCursor(self: *@This()) []const u8 {
            const bytes = self.srcBytes();
            if (comptime encoding == .ascii) {
                if (self.src.i >= bytes.len) return "";
                return bytes[self.src.i..];
            }

            if (self.src.cursor.i >= bytes.len) return "";
            return bytes[self.src.cursor.i..];
        }

        pub fn cursorPos(self: *@This()) usize {
            if (comptime encoding == .ascii) return self.src.i;
            return self.src.cursor.i;
        }

        pub fn setCursorAtByteIndex(self: *@This(), index: usize) void {
            if (comptime encoding == .ascii) {
                self.src.i = index;
                return;
            }
            self.src.cursor = .{
                .i = @intCast(index),
                .c = 0,
                .width = 0,
            };
            SrcUnicode.nextCursor(&self.src.iter, &self.src.cursor);
            self.src.next_cursor = self.src.cursor;
            SrcUnicode.nextCursor(&self.src.iter, &self.src.next_cursor);
        }

        pub fn eat(self: *@This()) ?InputChar {
            if (self.read_char()) |result| {
                self.prev = self.current;
                self.current = result;
                self.src.eat(result.escaped);
                return result;
            }
            return null;
        }

        pub fn peek(self: *@This()) ?InputChar {
            return self.read_char();
        }

        pub fn read_char(self: *@This()) ?InputChar {
            const indexed_value = self.src.index() orelse return null;
            var char = indexed_value.char;
            if (char != '\\' or self.state == .Single) return .{ .char = char };

            switch (self.state) {
                .Normal => {
                    const peeked = self.src.indexNext() orelse return null;
                    char = peeked.char;
                },
                .Double => {
                    const peeked = self.src.indexNext() orelse return null;
                    switch (peeked.char) {
                        '$', '`', '"', '\\', '\n', '#' => {
                            char = peeked.char;
                        },
                        else => return .{ .char = char, .escaped = false },
                    }
                },
                .Single => unreachable,
            }

            return .{ .char = char, .escaped = true };
        }
    };
}

const bun = @import("bun");
const CodepointIterator = bun.strings.UnsignedCodepointIterator;
