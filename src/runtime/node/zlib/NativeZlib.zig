stream: Context = .{},
dictionary: bun.bindgen.OwnedBytes = .empty(),

pub fn create(mode: i32) @This() {
    var backend: @This() = .{};
    backend.stream.mode = @fromBackingInt(@intCast(mode));
    return backend;
}

pub fn estimatedSize(_: *const @This()) usize {
    return 3309;
}

pub fn initFromBindgen(this: *@This(), args: anytype) bun.OOM!?Error {
    if (args.dictionary) |view| {
        if (view.length() > std.math.maxInt(u32))
            return Error.init("Dictionary exceeds the maximum supported length of 4294967295 bytes", -2, "Z_STREAM_ERROR");
    }
    var dictionary = if (args.dictionary) |view|
        try view.copy()
    else
        bun.bindgen.OwnedBytes.empty();
    errdefer dictionary.deinit();

    this.stream.deinitState();
    this.dictionary.deinit();
    this.dictionary = dictionary.take();
    const err = this.stream.init(
        args.level,
        args.windowBits,
        args.memLevel,
        args.strategy,
        if (args.dictionary != null) this.dictionary.slice() else null,
    );
    return if (err.isError()) err else null;
}

pub fn paramsFromBindgen(this: *@This(), args: anytype) ?Error {
    const err = this.stream.setParams(args.level, args.strategy);
    return if (err.isError()) err else null;
}

pub fn reset(this: *@This()) Error {
    return this.stream.reset();
}

pub fn close(this: *@This()) void {
    this.stream.close();
}

pub fn deinit(this: *@This()) void {
    this.close();
    this.dictionary.deinit();
}

pub fn destroy(this: *@This()) void {
    this.deinit();
    bun.destroy(this);
}

const Context = struct {
    const c = bun.zlib;
    const GZIP_HEADER_ID1: u8 = 0x1f;
    const GZIP_HEADER_ID2: u8 = 0x8b;

    mode: c.NodeMode = .NONE,
    state: c.z_stream = std.mem.zeroes(c.z_stream),
    err: c.ReturnCode = .Ok,
    flush: c.FlushValue = .NoFlush,
    dictionary: []const u8 = "",
    gzip_id_bytes_read: u8 = 0,
    pending_params: ?struct { level: c_int, strategy: c_int } = null,
    allocated: bool = false,

    pub fn init(this: *Context, level: c_int, windowBits: c_int, memLevel: c_int, strategy: c_int, dictionary: ?[]const u8) Error {
        this.flush = .NoFlush;
        this.err = .Ok;

        const windowBitsActual = switch (this.mode) {
            .NONE => unreachable,
            .DEFLATE, .INFLATE => windowBits,
            .GZIP, .GUNZIP => windowBits + 16,
            .UNZIP => windowBits + 32,
            .DEFLATERAW, .INFLATERAW => windowBits * -1,
            .BROTLI_DECODE, .BROTLI_ENCODE => unreachable,
            .ZSTD_COMPRESS, .ZSTD_DECOMPRESS => unreachable,
        };

        this.dictionary = dictionary orelse "";

        switch (this.mode) {
            .NONE => unreachable,
            .DEFLATE, .GZIP, .DEFLATERAW => this.err = c.deflateInit2_(&this.state, level, 8, windowBitsActual, memLevel, strategy, c.zlibVersion(), @sizeOf(c.z_stream)),
            .INFLATE, .GUNZIP, .UNZIP, .INFLATERAW => this.err = c.inflateInit2_(&this.state, windowBitsActual, c.zlibVersion(), @sizeOf(c.z_stream)),
            .BROTLI_DECODE, .BROTLI_ENCODE => unreachable,
            .ZSTD_COMPRESS, .ZSTD_DECOMPRESS => unreachable,
        }
        if (this.err != .Ok) {
            return this.error_for_message("Failed to initialize compression stream");
        }
        this.allocated = true;

        return this.setDictionary();
    }

    pub fn setDictionary(this: *Context) Error {
        const dict = this.dictionary;
        if (dict.len == 0) return Error.ok;
        this.err = .Ok;
        switch (this.mode) {
            .DEFLATE, .DEFLATERAW => {
                this.err = c.deflateSetDictionary(&this.state, dict.ptr, @intCast(dict.len));
            },
            .INFLATERAW => {
                this.err = c.inflateSetDictionary(&this.state, dict.ptr, @intCast(dict.len));
            },
            else => {},
        }
        if (this.err != .Ok) {
            return this.error_for_message("Failed to set dictionary");
        }
        return Error.ok;
    }

    pub fn setParams(this: *Context, level: c_int, strategy: c_int) Error {
        switch (this.mode) {
            .DEFLATE, .DEFLATERAW, .GZIP => {
                this.pending_params = .{ .level = level, .strategy = strategy };
            },
            else => {},
        }
        return Error.ok;
    }

    fn error_for_message(this: *Context, default: [*:0]const u8) Error {
        var message = default;
        if (this.state.err_msg) |msg| message = msg;
        return .{
            .msg = message,
            .err = @backingInt(this.err),
            .allocation_failed = this.err == .MemError,
            .code = switch (this.err) {
                .Ok => "Z_OK",
                .StreamEnd => "Z_STREAM_END",
                .NeedDict => "Z_NEED_DICT",
                .ErrNo => "Z_ERRNO",
                .StreamError => "Z_STREAM_ERROR",
                .DataError => "Z_DATA_ERROR",
                .MemError => "Z_MEM_ERROR",
                .BufError => "Z_BUF_ERROR",
                .VersionError => "Z_VERSION_ERROR",
            },
        };
    }

    pub fn reset(this: *Context) Error {
        this.err = .Ok;
        switch (this.mode) {
            .DEFLATE, .DEFLATERAW, .GZIP => {
                this.err = c.deflateReset(&this.state);
            },
            .INFLATE, .INFLATERAW, .GUNZIP => {
                this.err = c.inflateReset(&this.state);
            },
            else => {},
        }
        if (this.err != .Ok) {
            return this.error_for_message("Failed to reset stream");
        }
        return this.setDictionary();
    }

    pub fn process(this: *Context, in: ?[]const u8, out: ?[]u8, flush: c_int) void {
        this.state.avail_in = if (in) |p| @intCast(p.len) else 0;
        this.state.next_in = if (in) |p| p.ptr else null;
        this.state.avail_out = if (out) |p| @intCast(p.len) else 0;
        this.state.next_out = if (out) |p| p.ptr else null;
        defer {
            this.state.next_in = null;
            this.state.next_out = null;
        }
        this.flush = @fromBackingInt(@intCast(flush));
        this.doWork();
    }

    fn doWork(this: *Context) void {
        var next_expected_header_byte: ?[*]const u8 = null;

        // If the avail_out is left at 0, then it means that it ran out
        // of room.  If there was avail_out left over, then it means
        // that all of the input was consumed.
        switch (this.mode) {
            .DEFLATE, .GZIP, .DEFLATERAW => {
                return this.doWorkDeflate();
            },
            .UNZIP => {
                if (this.state.avail_in > 0) {
                    next_expected_header_byte = this.state.next_in;
                }
                if (this.gzip_id_bytes_read == 0) {
                    if (next_expected_header_byte == null) {
                        return this.doWorkInflate();
                    }
                    if (next_expected_header_byte.?[0] == GZIP_HEADER_ID1) {
                        this.gzip_id_bytes_read = 1;
                        next_expected_header_byte.? += 1;
                        if (this.state.avail_in == 1) { // The only available byte was already read.
                            return this.doWorkInflate();
                        }
                    } else {
                        this.mode = .INFLATE;
                        return this.doWorkInflate();
                    }
                }
                if (this.gzip_id_bytes_read == 1) {
                    if (next_expected_header_byte == null) {
                        return this.doWorkInflate();
                    }
                    if (next_expected_header_byte.?[0] == GZIP_HEADER_ID2) {
                        this.gzip_id_bytes_read = 2;
                        this.mode = .GUNZIP;
                    } else {
                        this.mode = .INFLATE;
                    }
                    return this.doWorkInflate();
                }
                bun.assert(false); // invalid number of gzip magic number bytes read
            },
            .INFLATE, .GUNZIP, .INFLATERAW => {
                return this.doWorkInflate();
            },
            .NONE => {},
            .BROTLI_ENCODE, .BROTLI_DECODE => {},
            .ZSTD_COMPRESS, .ZSTD_DECOMPRESS => {},
        }
    }

    fn doWorkDeflate(this: *Context) void {
        if (this.pending_params) |params| {
            // Parameter changes may flush a block and must use the current write's
            // output buffer without consuming input under the old parameters.
            const available_input = this.state.avail_in;
            this.state.avail_in = 0;
            this.err = c.deflateParams(&this.state, params.level, params.strategy);
            this.state.avail_in = available_input;
            if (this.err != .Ok) return;
            this.pending_params = null;
        }
        this.err = c.deflate(&this.state, this.flush);
    }

    fn doWorkInflate(this: *Context) void {
        this.err = c.inflate(&this.state, this.flush);

        if (this.mode != .INFLATERAW and this.err == .NeedDict and this.dictionary.len > 0) {
            this.err = c.inflateSetDictionary(&this.state, this.dictionary.ptr, @intCast(this.dictionary.len));

            if (this.err == .Ok) {
                this.err = c.inflate(&this.state, this.flush);
            } else if (this.err == .DataError) {
                this.err = .NeedDict;
            }
        }
        while (this.state.avail_in > 0 and this.mode == .GUNZIP and this.err == .StreamEnd and @as(?[*]const u8, this.state.next_in).?[0] != 0) {
            // Bytes remain in input buffer. Perhaps this is another compressed member in the same archive, or just trailing garbage.
            // Trailing zero bytes are okay, though, since they are frequently used for padding.
            if (this.reset().isError()) return;
            this.err = c.inflate(&this.state, this.flush);
        }
    }

    pub fn updateWriteResult(this: *Context, avail_in: *u32, avail_out: *u32) void {
        avail_in.* = this.state.avail_in;
        avail_out.* = this.state.avail_out;
    }

    pub fn getErrorInfo(this: *Context) Error {
        switch (this.err) {
            .Ok, .BufError => {
                if (this.state.avail_out != 0 and this.flush == .Finish) {
                    return this.error_for_message("unexpected end of file");
                }
            },
            .StreamEnd => {},
            .NeedDict => {
                if (this.dictionary.len == 0) {
                    return this.error_for_message("Missing dictionary");
                } else {
                    return this.error_for_message("Bad dictionary");
                }
            },
            else => {
                return this.error_for_message("Zlib error");
            },
        }
        return Error.ok;
    }

    fn deinitState(this: *Context) void {
        if (!this.allocated) return;
        var status = c.ReturnCode.Ok;
        switch (this.mode) {
            .DEFLATE, .DEFLATERAW, .GZIP => {
                status = c.deflateEnd(&this.state);
            },
            .INFLATE, .INFLATERAW, .GUNZIP, .UNZIP => {
                status = c.inflateEnd(&this.state);
            },
            .NONE => {},
            .BROTLI_ENCODE, .BROTLI_DECODE => {},
            .ZSTD_COMPRESS, .ZSTD_DECOMPRESS => {},
        }
        bun.assert(status == .Ok or status == .DataError);
        this.allocated = false;
        this.state = std.mem.zeroes(c.z_stream);
    }

    pub fn close(this: *Context) void {
        this.deinitState();
        this.pending_params = null;
        this.mode = .NONE;
    }
};

const std = @import("std");
const CompressionJSBinding = @import("../node_zlib_binding.zig").CompressionJSBinding;
const Error = @import("../node_zlib_binding.zig").Error;

const bun = @import("bun");
const bindgen = bun.bindgen;

const NativeCompressionModule = bindgen.Module("NativeCompression");
const ClassSchema = NativeCompressionModule.class("NativeZlib");
pub const JSBinding = CompressionJSBinding(@This(), ClassSchema);
pub const JSClass = bindgen.Class(ClassSchema, JSBinding);

comptime {
    _ = JSClass;
}
