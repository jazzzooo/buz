// -----------------------------------

/// ZSTD_compress() :
///  Compresses `src` content as a single zstd compressed frame into already allocated `dst`.
///  NOTE: Providing `dstCapacity >= ZSTD_compressBound(srcSize)` guarantees that zstd will have
///        enough space to successfully compress the data.
///  @return : compressed size written into `dst` (<= `dstCapacity),
///            or an error code if it fails (which can be tested using ZSTD_isError()). */
// ZSTDLIB_API size_t ZSTD_compress( void* dst, size_t dstCapacity,
//                             const void* src, size_t srcSize,
//                                   int compressionLevel);
pub fn compress(dest: []u8, src: []const u8, level: ?i32) Result {
    return resultFromCode(c.ZSTD_compress(dest.ptr, dest.len, src.ptr, src.len, level orelse c.ZSTD_defaultCLevel()));
}

pub fn compressBound(srcSize: usize) usize {
    return c.ZSTD_compressBound(srcSize);
}

/// ZSTD_decompress() :
/// `compressedSize` : must be the _exact_ size of some number of compressed and/or skippable frames.
/// `dstCapacity` is an upper bound of originalSize to regenerate.
/// If user cannot imply a maximum upper bound, it's better to use streaming mode to decompress data.
/// @return : the number of bytes decompressed into `dst` (<= `dstCapacity`),
///           or an errorCode if it fails (which can be tested using ZSTD_isError()). */
// ZSTDLIB_API size_t ZSTD_decompress( void* dst, size_t dstCapacity,
//   const void* src, size_t compressedSize);
pub fn decompress(dest: []u8, src: []const u8) Result {
    return resultFromCode(c.ZSTD_decompress(dest.ptr, dest.len, src.ptr, src.len));
}

fn resultFromCode(result: usize) Result {
    if (c.ZSTD_isError(result) == 0) return .{ .success = result };
    if (c.ZSTD_getErrorCode(result) == c.ZSTD_error_memory_allocation) return .out_of_memory;
    return .{ .err = std.mem.sliceTo(c.ZSTD_getErrorName(result), 0) };
}

/// Decompress data, automatically allocating the output buffer.
/// Returns owned slice that must be freed by the caller.
/// Handles both frames with known and unknown content sizes.
/// For safety, if the reported decompressed size exceeds 16MB, streaming decompression is used instead.
pub fn decompressAlloc(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const size = getDecompressedSize(src);

    const ZSTD_CONTENTSIZE_UNKNOWN = std.math.maxInt(c_ulonglong); // 0ULL - 1
    const ZSTD_CONTENTSIZE_ERROR = std.math.maxInt(c_ulonglong) - 1; // 0ULL - 2
    const MAX_PREALLOCATE_SIZE = 16 * 1024 * 1024; // 16MB safety limit

    if (size == ZSTD_CONTENTSIZE_ERROR) {
        return error.InvalidZstdData;
    }

    // Use streaming decompression if:
    // 1. Content size is unknown, OR
    // 2. Reported size exceeds safety limit (to prevent malicious inputs claiming huge sizes)
    if (size == ZSTD_CONTENTSIZE_UNKNOWN or size > MAX_PREALLOCATE_SIZE) {
        var list = std.ArrayListUnmanaged(u8).empty;
        // `reader.deinit()` below does not free `list`; free it ourselves on any error
        // (init failure, readAll failure, or toOwnedSlice failure).
        errdefer list.deinit(allocator);
        const reader = try ZstdReaderArrayList.init(src, &list, allocator);
        defer reader.deinit();

        try reader.readAll(true);
        return try list.toOwnedSlice(allocator);
    }

    // Fast path: size is known and within reasonable limits
    const output = try allocator.alloc(u8, size);
    errdefer allocator.free(output);

    const result = decompress(output, src);
    return switch (result) {
        .success => |actual_size| if (actual_size == output.len) output else try allocator.realloc(output, actual_size),
        .out_of_memory => error.OutOfMemory,
        // `output` is freed by the errdefer above.
        .err => error.DecompressionFailed,
    };
}

pub fn getDecompressedSize(src: []const u8) usize {
    return ZSTD_findDecompressedSize(src.ptr, src.len);
}

//ZSTD_findDecompressedSize() :
//`src` should point to the start of a series of ZSTD encoded and/or skippable frames
//`srcSize` must be the _exact_ size of this series
//     (i.e. there should be a frame boundary at `src + srcSize`)
//@return : - decompressed size of all data in all successive frames
//          - if the decompressed size cannot be determined: ZSTD_CONTENTSIZE_UNKNOWN
//          - if an error occurred: ZSTD_CONTENTSIZE_ERROR
//
// note 1 : decompressed size is an optional field, that may not be present, especially in streaming mode.
//          When `return==ZSTD_CONTENTSIZE_UNKNOWN`, data to decompress could be any size.
//          In which case, it's necessary to use streaming mode to decompress data.
// note 2 : decompressed size is always present when compression is done with ZSTD_compress()
// note 3 : decompressed size can be very large (64-bits value),
//          potentially larger than what local system can handle as a single memory segment.
//          In which case, it's necessary to use streaming mode to decompress data.
// note 4 : If source is untrusted, decompressed size could be wrong or intentionally modified.
//          Always ensure result fits within application's authorized limits.
//          Each application can set its own limits.
// note 5 : ZSTD_findDecompressedSize handles multiple frames, and so it must traverse the input to
//          read each contained frame header.  This is fast as most of the data is skipped,
//          however it does mean that all frame data must be present and valid. */
pub extern fn ZSTD_findDecompressedSize(src: ?*const anyopaque, srcSize: usize) c_ulonglong;

pub const Result = union(enum) {
    success: usize,
    err: [:0]const u8,
    out_of_memory,
};

pub const ZstdReaderArrayList = struct {
    const Failure = error{ OutOfMemory, ZstdDecompressionError };
    const State = union(enum) {
        Uninitialized,
        Inflating,
        End,
        Error: Failure,
    };

    input: []const u8,
    list: *std.ArrayListUnmanaged(u8),
    list_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    zstd: *c.ZSTD_DStream,
    state: State = .Uninitialized,
    total_in: usize = 0,

    pub fn init(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    ) !*ZstdReaderArrayList {
        return initWithListAllocator(input, list, allocator, allocator);
    }

    pub fn initWithListAllocator(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        list_allocator: std.mem.Allocator,
        allocator: std.mem.Allocator,
    ) !*ZstdReaderArrayList {
        const reader = try allocator.create(ZstdReaderArrayList);
        errdefer allocator.destroy(reader);
        const stream = c.ZSTD_createDStream() orelse return error.OutOfMemory;
        errdefer _ = c.ZSTD_freeDStream(stream);
        const result = c.ZSTD_initDStream(stream);
        if (c.ZSTD_isError(result) != 0) return failureFromCode(result);
        reader.* = .{
            .input = input,
            .list = list,
            .list_allocator = list_allocator,
            .allocator = allocator,
            .zstd = stream,
        };
        return reader;
    }

    pub fn end(this: *ZstdReaderArrayList) void {
        if (this.state != .End) {
            _ = c.ZSTD_freeDStream(this.zstd);
            this.state = .End;
        }
    }

    pub fn deinit(this: *ZstdReaderArrayList) void {
        const alloc = this.allocator;
        this.end();
        alloc.destroy(this);
    }

    pub fn readAll(this: *ZstdReaderArrayList, is_done: bool) !void {
        if (this.state == .End) return;
        if (this.state == .Error) return this.state.Error;

        var can_flush_without_input = false;
        while (this.state == .Uninitialized or this.state == .Inflating) {
            const next_in = this.input[this.total_in..];

            if (next_in.len == 0 and !can_flush_without_input) {
                if (this.state == .Uninitialized) {
                    if (is_done) this.end();
                    return;
                }
                if (!is_done) return error.ShortRead;
                this.state = .{ .Error = error.ZstdDecompressionError };
                return error.ZstdDecompressionError;
            }

            var unused = this.list.unusedCapacitySlice();
            if (unused.len < 4096) {
                this.list.ensureUnusedCapacity(this.list_allocator, 4096) catch |err| {
                    this.state = .{ .Error = err };
                    return err;
                };
                unused = this.list.unusedCapacitySlice();
            }
            var in_buf: c.ZSTD_inBuffer = .{
                .src = if (next_in.len > 0) next_in.ptr else null,
                .size = next_in.len,
                .pos = 0,
            };
            var out_buf: c.ZSTD_outBuffer = .{
                .dst = if (unused.len > 0) unused.ptr else null,
                .size = unused.len,
                .pos = 0,
            };

            const rc = c.ZSTD_decompressStream(this.zstd, &out_buf, &in_buf);
            if (c.ZSTD_isError(rc) != 0) {
                const failure = failureFromCode(rc);
                this.state = .{ .Error = failure };
                return failure;
            }

            bun.assert(out_buf.pos <= unused.len and in_buf.pos <= next_in.len);
            const bytes_written = out_buf.pos;
            const bytes_read = in_buf.pos;
            this.list.items.len += bytes_written;
            this.total_in += bytes_read;
            can_flush_without_input = rc != 0 and out_buf.pos == out_buf.size;

            if (rc == 0) {
                this.state = .Uninitialized;
                continue;
            }

            this.state = .Inflating;
            if (bytes_read == 0 and bytes_written == 0) {
                if (next_in.len == 0 and !is_done) return error.ShortRead;
                this.state = .{ .Error = error.ZstdDecompressionError };
                return error.ZstdDecompressionError;
            }
        }
    }

    fn failureFromCode(result: usize) Failure {
        return if (c.ZSTD_getErrorCode(result) == c.ZSTD_error_memory_allocation)
            error.OutOfMemory
        else
            error.ZstdDecompressionError;
    }
};

const std = @import("std");

const bun = @import("bun");
const c = bun.c;
