const Hpack = @This();

implementation: ?*lshpack.HPACK = null,
decode_buffer: std.ArrayList(u8) = .empty,
encoder_max_capacity: u32,
decoder_max_capacity: u32,
pending_encoder_capacity: ?HpackBlock.PendingCapacity = null,
active_encoder_transaction: ?*lshpack.EncoderTransaction = null,

pub const Header = lshpack.HPACK.Header;
pub const entry_overhead = 32;

pub fn init(encoder_capacity: u32, decoder_capacity: u32) Hpack {
    return .{
        .encoder_max_capacity = encoder_capacity,
        .decoder_max_capacity = decoder_capacity,
    };
}

pub fn deinit(this: *Hpack) void {
    if (this.active_encoder_transaction != null) @panic("cannot destroy HPACK with an active encoder block");
    if (this.implementation) |implementation| implementation.deinit();
    this.decode_buffer.deinit(bun.default_allocator);
    this.* = undefined;
}

fn ensureImplementation(this: *Hpack) bun.OOM!*lshpack.HPACK {
    if (this.implementation) |implementation| return implementation;
    const implementation = try lshpack.HPACK.init(this.encoder_max_capacity, this.decoder_max_capacity);
    this.implementation = implementation;
    return implementation;
}

fn decodeField(this: *Hpack, source: []const u8) !lshpack.HPACK.DecodeResult {
    const implementation = try this.ensureImplementation();
    var capacity = @max(this.decode_buffer.items.len, 4096);
    while (true) {
        try this.decode_buffer.resize(bun.default_allocator, capacity);
        return implementation.decode(source, this.decode_buffer.items) catch |err| switch (err) {
            error.BufferTooSmall => {
                if (capacity == lshpack.HPACK.max_header_size) return error.HpackHeaderTooLarge;
                capacity = @min(lshpack.HPACK.max_header_size, capacity * 2);
                continue;
            },
            else => return err,
        };
    }
}

pub fn decodeBlock(this: *Hpack, source: []const u8) DecoderBlock {
    return .{ .owner = this, .remaining = source };
}

pub const DecoderBlock = struct {
    owner: *Hpack,
    remaining: []const u8,
    at_start: bool = true,

    /// Header slices borrow the decoder's scratch until its next field decode or deinit.
    pub fn next(block: *DecoderBlock) !?Header {
        if (block.remaining.len == 0) return null;
        if (!block.at_start and block.remaining[0] & 0xe0 == 0x20) return error.UnableToDecode;
        const result = try block.owner.decodeField(block.remaining);
        block.at_start = false;
        block.remaining = block.remaining[result.next..];
        return result.header;
    }
};

pub fn setEncoderMaxCapacity(this: *Hpack, capacity: u32) void {
    if (capacity == this.encoder_max_capacity) return;
    if (this.active_encoder_transaction != null) @panic("cannot change HPACK encoder capacity during a header block");
    if (this.implementation) |implementation| implementation.setEncoderMaxCapacity(capacity);
    this.encoder_max_capacity = capacity;
    HpackBlock.PendingCapacity.record(&this.pending_encoder_capacity, capacity);
}

pub fn setDecoderMaxCapacity(this: *Hpack, capacity: u32) void {
    if (capacity == this.decoder_max_capacity) return;
    if (this.implementation) |implementation| implementation.setDecoderMaxCapacity(capacity);
    this.decoder_max_capacity = capacity;
}

pub fn beginEncoderBlock(
    this: *Hpack,
    encoded_headers: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) bun.OOM!EncoderBlock {
    if (encoded_headers.items.len != 0) @panic("HPACK encoder block must begin with an empty output");
    if (this.active_encoder_transaction != null) @panic("HPACK encoder block already active");
    const implementation = try this.ensureImplementation();
    const transaction = try implementation.beginEncoderTransaction();
    errdefer transaction.abort(implementation);

    if (this.pending_encoder_capacity) |pending| {
        try encoded_headers.ensureUnusedCapacity(allocator, 12);
        const smallest = HpackBlock.encodeSizeUpdate(pending.smallest);
        encoded_headers.appendSliceAssumeCapacity(smallest.slice());
        if (pending.final != pending.smallest) {
            const final = HpackBlock.encodeSizeUpdate(pending.final);
            encoded_headers.appendSliceAssumeCapacity(final.slice());
        }
    }

    this.active_encoder_transaction = transaction;
    return .{
        .owner = this,
        .transaction = transaction,
    };
}

pub const EncoderBlock = struct {
    owner: *Hpack,
    transaction: ?*lshpack.EncoderTransaction,
    failed: bool = false,

    fn activeTransaction(block: *const EncoderBlock) *lshpack.EncoderTransaction {
        const transaction = block.transaction orelse @panic("HPACK encoder block was already consumed");
        if (block.owner.active_encoder_transaction != transaction) @panic("copied or stale HPACK encoder block");
        return transaction;
    }

    pub fn encodeIntoList(
        block: *EncoderBlock,
        encoded_headers: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        never_index: bool,
    ) !usize {
        errdefer block.failed = true;
        if (block.failed) return error.HpackEncoderBlockFailed;
        const transaction = block.activeTransaction();
        if (name.len > lshpack.HPACK.max_header_size or
            value.len > lshpack.HPACK.max_header_size - name.len)
        {
            return error.HpackHeaderTooLarge;
        }
        const header_capacity = std.math.add(usize, name.len + value.len, entry_overhead) catch return error.HpackHeaderTooLarge;
        const required_capacity = std.math.add(usize, encoded_headers.items.len, header_capacity) catch return error.HpackHeaderBlockTooLarge;
        try encoded_headers.ensureTotalCapacity(allocator, required_capacity);
        const written = try transaction.encode(
            name,
            value,
            never_index,
            encoded_headers.allocatedSlice(),
            encoded_headers.items.len,
        );
        encoded_headers.items.len += written;
        return written;
    }

    pub fn commit(block: *EncoderBlock) void {
        if (block.failed) @panic("cannot commit a failed HPACK encoder block");
        const transaction = block.activeTransaction();
        transaction.commit(block.owner.implementation.?);
        block.transaction = null;
        block.owner.active_encoder_transaction = null;
        block.owner.pending_encoder_capacity = null;
    }

    pub fn deinit(block: *EncoderBlock) void {
        const transaction = block.transaction orelse return;
        if (block.owner.active_encoder_transaction != transaction) @panic("copied or stale HPACK encoder block");
        transaction.abort(block.owner.implementation.?);
        block.transaction = null;
        block.owner.active_encoder_transaction = null;
    }
};

pub fn encoderMaxCapacity(this: *const Hpack) u32 {
    return this.encoder_max_capacity;
}

pub fn decoderMaxCapacity(this: *const Hpack) u32 {
    return this.decoder_max_capacity;
}

const std = @import("std");
const bun = @import("bun");
const lshpack = @import("../lshpack_sys/lshpack.zig");
const HpackBlock = @import("./HpackBlock.zig");
