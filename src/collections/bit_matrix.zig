pub const DenseBitMatrix = struct {
    words: []Word = &.{},
    row_count: usize = 0,
    bit_length: usize = 0,
    words_per_row: usize = 0,

    pub const Word = usize;
    const word_bit_length = @bitSizeOf(Word);
    const word_byte_length = @sizeOf(Word);
    const Shift = std.math.Log2Int(Word);

    pub const empty: DenseBitMatrix = .{};

    pub fn initEmpty(allocator: std.mem.Allocator, row_count: usize, bit_length: usize) !DenseBitMatrix {
        const words_per_row = std.math.divCeil(usize, bit_length, word_bit_length) catch return error.OutOfMemory;
        const total_words = std.math.mul(usize, row_count, words_per_row) catch return error.OutOfMemory;
        const words = try allocator.alloc(Word, total_words);
        @memset(words, 0);
        return .{
            .words = words,
            .row_count = row_count,
            .bit_length = bit_length,
            .words_per_row = words_per_row,
        };
    }

    pub fn deinit(self: *DenseBitMatrix, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        self.* = .empty;
    }

    pub fn row(self: DenseBitMatrix, index: usize) Row {
        std.debug.assert(index < self.row_count);
        const start = index * self.words_per_row;
        return .{
            .words = self.words[start..][0..self.words_per_row],
            .bit_length = self.bit_length,
        };
    }

    pub fn constRow(self: DenseBitMatrix, index: usize) ConstRow {
        return self.row(index).asConst();
    }

    pub fn freeze(self: *DenseBitMatrix) Frozen {
        const frozen: Frozen = .{
            .words = self.words,
            .row_count = self.row_count,
            .bit_length = self.bit_length,
            .words_per_row = self.words_per_row,
        };
        self.* = .empty;
        return frozen;
    }

    pub const Frozen = struct {
        words: []const Word = &.{},
        row_count: usize = 0,
        bit_length: usize = 0,
        words_per_row: usize = 0,

        pub const empty: Frozen = .{};

        pub fn deinit(self: *Frozen, allocator: std.mem.Allocator) void {
            allocator.free(self.words);
            self.* = .empty;
        }

        pub fn row(self: Frozen, index: usize) ConstRow {
            std.debug.assert(index < self.row_count);
            const start = index * self.words_per_row;
            return .{
                .words = self.words[start..][0..self.words_per_row],
                .bit_length = self.bit_length,
            };
        }
    };

    pub const Row = struct {
        words: []Word,
        bit_length: usize,

        pub fn asConst(self: Row) ConstRow {
            return .{
                .words = self.words,
                .bit_length = self.bit_length,
            };
        }

        pub fn isSet(self: Row, index: usize) bool {
            return self.asConst().isSet(index);
        }

        pub fn set(self: Row, index: usize) void {
            std.debug.assert(index < self.bit_length);
            self.words[wordIndex(index)] |= wordBit(index);
        }

        pub fn copyFrom(self: Row, other: ConstRow) void {
            std.debug.assert(self.bit_length == other.bit_length);
            @memcpy(self.words, other.words);
            self.maskPadding();
        }

        pub fn unionWith(self: Row, other: ConstRow) void {
            std.debug.assert(self.bit_length == other.bit_length);
            for (self.words, other.words) |*word, other_word| word.* |= other_word;
            self.maskPadding();
        }

        pub fn exclude(self: Row, other: ConstRow) void {
            std.debug.assert(self.bit_length == other.bit_length);
            for (self.words, other.words) |*word, other_word| word.* &= ~other_word;
            self.maskPadding();
        }

        pub fn eql(self: Row, other: ConstRow) bool {
            return self.asConst().eql(other);
        }

        fn maskPadding(self: Row) void {
            if (self.words.len > 0) self.words[self.words.len - 1] &= lastWordMask(self.bit_length);
        }
    };

    pub const ConstRow = struct {
        words: []const Word,
        bit_length: usize,

        pub fn isSet(self: ConstRow, index: usize) bool {
            std.debug.assert(index < self.bit_length);
            return self.words[wordIndex(index)] & wordBit(index) != 0;
        }

        pub fn count(self: ConstRow) usize {
            var total: usize = 0;
            for (self.words, 0..) |word, index| {
                total += @popCount(if (index + 1 == self.words.len)
                    word & lastWordMask(self.bit_length)
                else
                    word);
            }
            return total;
        }

        pub fn eql(self: ConstRow, other: ConstRow) bool {
            if (self.bit_length != other.bit_length or self.words.len != other.words.len) return false;
            if (self.words.len == 0) return true;
            if (!std.mem.eql(Word, self.words[0 .. self.words.len - 1], other.words[0 .. other.words.len - 1])) {
                return false;
            }
            const mask = lastWordMask(self.bit_length);
            return self.words[self.words.len - 1] & mask == other.words[other.words.len - 1] & mask;
        }

        pub fn intersects(self: ConstRow, other: ConstRow) bool {
            std.debug.assert(self.bit_length == other.bit_length);
            for (self.words, other.words, 0..) |word, other_word, index| {
                const intersection = word & other_word;
                if (index + 1 == self.words.len) {
                    if (intersection & lastWordMask(self.bit_length) != 0) return true;
                } else if (intersection != 0) {
                    return true;
                }
            }
            return false;
        }

        pub fn hash(self: ConstRow, seed: u64) u64 {
            var hasher = std.hash.Wyhash.init(seed);
            hashCanonicalWord(&hasher, self.bit_length);
            for (self.words, 0..) |word, index| {
                hashCanonicalWord(
                    &hasher,
                    if (index + 1 == self.words.len)
                        word & lastWordMask(self.bit_length)
                    else
                        word,
                );
            }
            return hasher.final();
        }

        pub fn canonicalOrder(self: ConstRow, other: ConstRow) std.math.Order {
            const common_bytes = @min(logicalByteCount(self.bit_length), logicalByteCount(other.bit_length));
            for (0..common_bytes) |byte_index| {
                const a_byte = canonicalByte(self, byte_index);
                const b_byte = canonicalByte(other, byte_index);
                if (a_byte < b_byte) return .lt;
                if (a_byte > b_byte) return .gt;
            }
            return std.math.order(self.bit_length, other.bit_length);
        }

        pub fn iterator(self: ConstRow) Iterator {
            return .{ .words = self.words, .bit_length = self.bit_length };
        }

        pub const Iterator = struct {
            words: []const Word,
            bit_length: usize,
            word_index: usize = 0,
            bits: Word = 0,

            pub fn next(self: *Iterator) ?usize {
                while (self.bits == 0) {
                    if (self.word_index == self.words.len) return null;
                    self.bits = self.words[self.word_index];
                    if (self.bits == 0) self.word_index += 1;
                }

                const bit = @ctz(self.bits);
                self.bits &= self.bits - 1;
                const index = self.word_index * word_bit_length + bit;
                if (self.bits == 0) self.word_index += 1;
                if (index >= self.bit_length) return null;
                return index;
            }
        };
    };

    fn wordIndex(index: usize) usize {
        return index / word_bit_length;
    }

    fn wordBit(index: usize) Word {
        return @as(Word, 1) << @as(Shift, @truncate(index));
    }

    fn lastWordMask(bit_length: usize) Word {
        if (bit_length == 0) return 0;
        const used = bit_length % word_bit_length;
        if (used == 0) return std.math.maxInt(Word);
        return @as(Word, std.math.maxInt(Word)) >> @as(Shift, @intCast(word_bit_length - used));
    }

    fn logicalByteCount(bit_length: usize) usize {
        return std.math.divCeil(usize, bit_length, 8) catch unreachable;
    }

    fn canonicalByte(row_: ConstRow, byte_index: usize) u8 {
        std.debug.assert(byte_index < logicalByteCount(row_.bit_length));
        const word = row_.words[byte_index / word_byte_length];
        const shift: Shift = @intCast((byte_index % word_byte_length) * 8);
        var byte: u8 = @truncate(word >> shift);
        if (byte_index + 1 == logicalByteCount(row_.bit_length)) {
            const used = row_.bit_length % 8;
            if (used != 0) byte &= @as(u8, std.math.maxInt(u8)) >> @intCast(8 - used);
        }
        return byte;
    }

    fn hashCanonicalWord(hasher: *std.hash.Wyhash, word: Word) void {
        var bytes: [word_byte_length]u8 = undefined;
        std.mem.writeInt(Word, &bytes, word, .little);
        hasher.update(&bytes);
    }
};

const std = @import("std");
