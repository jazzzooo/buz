pub const HPACK = opaque {
    pub const Header = struct {
        name: []const u8,
        value: []const u8,
        never_index: bool,
        well_known: u16,
    };

    pub const DecodeResult = struct {
        header: ?Header,
        next: usize,
    };

    pub const max_header_size: usize = c.BUN_HPACK_MAX_HEADER_SIZE;

    fn native(self: *HPACK) *c.BunHpack {
        return @ptrCast(self);
    }

    pub fn init(encoder_capacity: u32, decoder_capacity: u32) bun.OOM!*HPACK {
        return @ptrCast(c.bun_hpack_create(encoder_capacity, decoder_capacity) orelse return error.OutOfMemory);
    }

    pub fn decode(self: *HPACK, src: []const u8, scratch: []u8) !DecodeResult {
        var header: c.BunHpackHeader = undefined;
        switch (c.bun_hpack_decode(self.native(), src.ptr, src.len, scratch.ptr, scratch.len, &header)) {
            c.BUN_HPACK_OK => {},
            c.BUN_HPACK_END_BLOCK => {
                if (header.consumed != src.len) @panic("invalid lshpack block end");
                return .{ .header = null, .next = header.consumed };
            },
            c.BUN_HPACK_INVALID_DATA => return error.UnableToDecode,
            c.BUN_HPACK_HEADER_TOO_LARGE => return error.HpackHeaderTooLarge,
            c.BUN_HPACK_BUFFER_TOO_SMALL => return error.BufferTooSmall,
            c.BUN_HPACK_OUT_OF_MEMORY => return error.OutOfMemory,
            else => @panic("invalid lshpack decode status"),
        }
        if (header.name_length == 0) return error.EmptyHeaderName;
        if (header.consumed == 0 or header.consumed > src.len or
            header.name_offset > scratch.len or header.name_length > scratch.len - header.name_offset or
            header.value_offset > scratch.len or header.value_length > scratch.len - header.value_offset)
        {
            @panic("invalid lshpack output bounds");
        }

        return .{
            .header = .{
                .name = scratch[header.name_offset..][0..header.name_length],
                .value = scratch[header.value_offset..][0..header.value_length],
                .never_index = header.never_index != 0,
                .well_known = header.static_index,
            },
            .next = header.consumed,
        };
    }

    pub fn beginEncoderTransaction(self: *HPACK) bun.OOM!*EncoderTransaction {
        return @ptrCast(c.bun_hpack_encoder_begin(self.native()) orelse return error.OutOfMemory);
    }

    /// Adjust the encoder's dynamic-table capacity after init. Evicts entries
    /// to fit; the caller is responsible for emitting the RFC 7541 §6.3
    /// Dynamic Table Size Update opcode at the start of the next header block
    /// so the peer's decoder evicts in lockstep.
    pub fn setEncoderMaxCapacity(self: *HPACK, max_capacity: u32) void {
        c.bun_hpack_set_encoder_capacity(self.native(), max_capacity);
    }

    pub fn setDecoderMaxCapacity(self: *HPACK, max_capacity: u32) void {
        c.bun_hpack_set_decoder_capacity(self.native(), max_capacity);
    }

    pub fn deinit(self: *HPACK) void {
        c.bun_hpack_destroy(self.native());
    }
};

pub const EncoderTransaction = opaque {
    fn native(self: *EncoderTransaction) *c.BunHpackEncoderTransaction {
        return @ptrCast(self);
    }

    pub fn encode(self: *EncoderTransaction, name: []const u8, value: []const u8, never_index: bool, destination: []u8, offset: usize) !usize {
        if (offset > destination.len) return error.BufferTooSmall;
        const output = destination[offset..];
        var written: usize = undefined;
        switch (c.bun_hpack_encoder_encode(self.native(), name.ptr, name.len, value.ptr, value.len, @intFromBool(never_index), output.ptr, output.len, &written)) {
            c.BUN_HPACK_OK => {},
            c.BUN_HPACK_INVALID_DATA => return error.UnableToEncode,
            c.BUN_HPACK_HEADER_TOO_LARGE => return error.HpackHeaderTooLarge,
            c.BUN_HPACK_BUFFER_TOO_SMALL => return error.BufferTooSmall,
            c.BUN_HPACK_OUT_OF_MEMORY => return error.OutOfMemory,
            else => @panic("invalid lshpack encode status"),
        }
        if (written == 0 or written > output.len) @panic("invalid lshpack encoded length");
        return written;
    }

    pub fn commit(self: *EncoderTransaction, owner: *HPACK) void {
        c.bun_hpack_encoder_commit(owner.native(), self.native());
    }

    pub fn abort(self: *EncoderTransaction, owner: *HPACK) void {
        c.bun_hpack_encoder_abort(owner.native(), self.native());
    }
};

const c = @import("lshpack-ffi");
const bun = @import("bun");
