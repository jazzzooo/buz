pub fn NewReader(comptime Context: type) type {
    return struct {
        wrapped: Context,

        pub inline fn markMessageStart(this: @This()) void {
            this.wrapped.markMessageStart();
        }

        pub inline fn read(this: @This(), count: usize) AnyPostgresError!Data {
            return this.wrapped.read(count);
        }

        pub fn skip(this: @This(), count: usize) AnyPostgresError!void {
            try this.wrapped.skip(count);
        }

        pub fn peek(this: @This()) []const u8 {
            return this.wrapped.peek();
        }

        pub inline fn readZ(this: @This()) AnyPostgresError!Data {
            return this.wrapped.readZ();
        }

        pub inline fn expectLength(this: @This(), length: usize) AnyPostgresError!void {
            if (this.peek().len != length) return error.InvalidMessageLength;
        }

        pub inline fn expectEnd(this: @This()) AnyPostgresError!void {
            try this.expectLength(0);
        }

        pub fn int(this: @This(), comptime Int: type) !Int {
            var data = try this.read(@sizeOf((Int)));
            defer data.deinit();
            const slice = data.slice();
            if (slice.len < @sizeOf(Int)) {
                return error.ShortRead;
            }
            if (comptime Int == u8) {
                return @as(Int, slice[0]);
            }
            return @byteSwap(@as(Int, @bitCast(slice[0..@sizeOf(Int)].*)));
        }

        pub fn int4(this: @This()) !PostgresInt32 {
            return this.int(PostgresInt32);
        }

        pub fn short(this: @This()) !PostgresShort {
            return this.int(PostgresShort);
        }

        pub fn readFrame(this: @This()) AnyPostgresError!Frame {
            const encoded_length = try this.int(i32);
            if (encoded_length < 4) return error.InvalidMessageLength;
            return .{ .data = try this.read(@intCast(encoded_length - 4)) };
        }

        pub const bytes = read;

        pub fn String(this: @This()) !bun.String {
            var result = try this.readZ();
            defer result.deinit();
            return bun.String.borrowUTF8(result.slice());
        }
    };
}

pub const Frame = struct {
    data: Data,
    offset: usize = 0,

    pub fn deinit(this: *Frame) void {
        this.data.deinit();
    }

    pub fn reader(this: *Frame) PayloadReader {
        return .{ .wrapped = .{ .frame = this } };
    }
};

const Payload = struct {
    frame: *Frame,

    pub fn markMessageStart(_: Payload) void {}

    pub fn peek(this: Payload) []const u8 {
        return this.frame.data.slice()[this.frame.offset..];
    }

    pub fn skip(this: Payload, count: usize) AnyPostgresError!void {
        if (count > this.peek().len) return error.InvalidMessageLength;
        this.frame.offset += count;
    }

    pub fn read(this: Payload, count: usize) AnyPostgresError!Data {
        const remaining = this.peek();
        if (count > remaining.len) return error.InvalidMessageLength;
        this.frame.offset += count;
        return .{ .temporary = remaining[0..count] };
    }

    pub fn readZ(this: Payload) AnyPostgresError!Data {
        const remaining = this.peek();
        const zero = bun.strings.indexOfChar(remaining, 0) orelse return error.InvalidMessageLength;
        this.frame.offset += zero + 1;
        return .{ .temporary = remaining[0..zero] };
    }
};

pub const PayloadReader = NewReader(Payload);

const bun = @import("bun");
const AnyPostgresError = @import("../AnyPostgresError.zig").AnyPostgresError;
const Data = @import("../../shared/Data.zig").Data;

const int_types = @import("../types/int_types.zig");
const PostgresInt32 = int_types.PostgresInt32;
const PostgresShort = int_types.PostgresShort;
