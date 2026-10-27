pub const c = @import("../brotli_sys/brotli_c.zig");
const BrotliDecoder = c.BrotliDecoder;

pub const BrotliAllocator = struct {
    pub fn alloc(_: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
        if (bun.heap_breakdown.enabled) {
            const zone = bun.heap_breakdown.getZone("brotli");
            return zone.malloc_zone_malloc(len);
        }

        return mimalloc.mi_malloc(len);
    }

    pub fn free(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        if (bun.heap_breakdown.enabled) {
            const zone = bun.heap_breakdown.getZone("brotli");
            zone.malloc_zone_free(data);
            return;
        }

        mimalloc.mi_free(data);
    }
};

pub fn isAllocationError(code: c_int) bool {
    return switch (code) {
        c.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES,
        c.BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS,
        c.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP,
        c.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1,
        c.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2,
        c.BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES,
        => true,
        else => false,
    };
}

pub const DecoderOptions = struct {
    pub const Params = std.enums.EnumFieldStruct(c.BrotliDecoderParameter, bool, false);

    params: Params = Params{
        .LARGE_WINDOW = true,
        .DISABLE_RING_BUFFER_REALLOCATION = false,
    },
};

pub const BrotliReaderArrayList = struct {
    pub const State = union(enum) {
        Uninitialized,
        Inflating,
        End,
        Error: error{ OutOfMemory, BrotliDecompressionError },
    };

    input: []const u8,
    list: *std.ArrayList(u8),
    list_allocator: std.mem.Allocator,
    brotli: *BrotliDecoder,
    state: State = .Uninitialized,
    total_in: usize = 0,

    pub fn newWithOptions(input: []const u8, list: *std.ArrayList(u8), allocator: std.mem.Allocator, options: DecoderOptions) !*BrotliReaderArrayList {
        if (!BrotliDecoder.initializeBrotli()) {
            return error.BrotliFailedToLoad;
        }

        const reader = try bun.default_allocator.create(BrotliReaderArrayList);
        errdefer bun.default_allocator.destroy(reader);
        const brotli = BrotliDecoder.createInstance(&BrotliAllocator.alloc, &BrotliAllocator.free, null) orelse return error.OutOfMemory;
        errdefer brotli.destroyInstance();
        if (options.params.LARGE_WINDOW and !brotli.setParameter(c.BrotliDecoderParameter.LARGE_WINDOW, 1))
            return error.BrotliInvalidParameter;
        if (options.params.DISABLE_RING_BUFFER_REALLOCATION and !brotli.setParameter(c.BrotliDecoderParameter.DISABLE_RING_BUFFER_REALLOCATION, 1))
            return error.BrotliInvalidParameter;

        bun.assert(list.items.ptr != input.ptr);

        reader.* = .{
            .input = input,
            .list = list,
            .list_allocator = allocator,
            .brotli = brotli,
        };
        return reader;
    }

    pub fn end(this: *BrotliReaderArrayList) void {
        this.state = .End;
    }

    pub fn readAll(this: *BrotliReaderArrayList, is_done: bool) !void {
        if (this.state == .End) return;
        if (this.state == .Error) return this.state.Error;

        bun.assert(this.list.items.ptr != this.input.ptr);

        while (this.state == .Uninitialized or this.state == .Inflating) {
            var unused_capacity = this.list.unusedCapacitySlice();

            if (unused_capacity.len < 4096) {
                this.list.ensureUnusedCapacity(this.list_allocator, 4096) catch |err| {
                    this.state = .{ .Error = err };
                    return err;
                };
                unused_capacity = this.list.unusedCapacitySlice();
            }

            bun.assert(unused_capacity.len > 0);

            const input = this.input[this.total_in..];
            var next_in: ?[*]const u8 = input.ptr;
            var next_out: ?[*]u8 = unused_capacity.ptr;
            var in_remaining = input.len;
            var out_remaining = unused_capacity.len;

            const result = this.brotli.decompressStream(
                &in_remaining,
                &next_in,
                &out_remaining,
                &next_out,
                null,
            );

            bun.assert(out_remaining <= unused_capacity.len and in_remaining <= input.len);
            const bytes_written = unused_capacity.len - out_remaining;
            const bytes_read = input.len - in_remaining;

            this.list.items.len += bytes_written;
            this.total_in += bytes_read;

            switch (result) {
                .success => {
                    if (comptime bun.Environment.allow_assert) {
                        bun.assert(this.brotli.isFinished());
                    }
                    this.end();
                    return;
                },
                .err => {
                    const code = this.brotli.getErrorCode();
                    const failure = if (isAllocationError(@backingInt(code))) error.OutOfMemory else error.BrotliDecompressionError;
                    this.state = .{ .Error = failure };
                    if (failure == error.OutOfMemory) return failure;
                    if (comptime bun.Environment.allow_assert) {
                        bun.Output.debugWarn("Brotli error: {s} ({d})", .{ @tagName(code), @backingInt(code) });
                    }

                    return failure;
                },

                .needs_more_input => {
                    if (in_remaining > 0) {
                        @panic("Brotli wants more data");
                    }
                    this.state = .Inflating;
                    if (is_done) {
                        // Stream is truncated - we're at EOF but decoder needs more data
                        this.state = .{ .Error = error.BrotliDecompressionError };
                        return error.BrotliDecompressionError;
                    }
                    // Not at EOF - we can retry with more data
                    return error.ShortRead;
                },
                .needs_more_output => {
                    this.list.ensureUnusedCapacity(this.list_allocator, 4096) catch |err| {
                        this.state = .{ .Error = err };
                        return err;
                    };
                    this.state = .Inflating;
                },
            }
        }
    }

    pub fn deinit(this: *BrotliReaderArrayList) void {
        this.brotli.destroyInstance();
        bun.destroy(this);
    }
};

const std = @import("std");

const bun = @import("bun");
const mimalloc = bun.mimalloc;
