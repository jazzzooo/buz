stream: Context = .{},
active: bool = false,

pub fn create(mode: i32) @This() {
    var backend: @This() = .{};
    backend.stream.mode = @fromBackingInt(@intCast(mode));
    return backend;
}

pub fn estimatedSize(this: *const @This()) usize {
    return @as(usize, switch (this.stream.mode) {
        .ZSTD_COMPRESS => 5272,
        .ZSTD_DECOMPRESS => 95968,
        else => 0,
    });
}

pub fn initFromBindgen(this: *@This(), args: anytype) bun.OOM!?Error {
    const pledged_src_size: u64 = switch (args.pledgedSourceSize) {
        .value => |value| value,
        .ignored => std.math.maxInt(u64),
    };

    var err = this.stream.init(pledged_src_size);
    if (err.isError()) return err;
    this.active = true;

    for (0..args.params.length() / @sizeOf(u32)) |i| {
        var x: u32 = undefined;
        if (!args.params.read(i * @sizeOf(u32), std.mem.asBytes(&x))) unreachable;
        if (x == std.math.maxInt(u32)) continue;
        const err_ = this.stream.setParams(@intCast(i), x);
        if (err_.isError()) {
            this.stream.deinitState();
            this.active = false;
            return err_;
        }
    }

    return null;
}

pub fn paramsFromBindgen(this: *@This(), _: anytype) ?Error {
    _ = this;
    return null;
}

pub fn reset(this: *@This()) Error {
    const err = this.stream.reset();
    this.active = !err.isError();
    return err;
}

pub fn close(this: *@This()) void {
    if (this.active) this.stream.close();
    this.active = false;
}

pub fn deinit(this: *@This()) void {
    this.close();
}

pub fn destroy(this: *@This()) void {
    this.deinit();
    bun.destroy(this);
}

const Context = struct {
    const c = bun.c;

    mode: bun.zlib.NodeMode = .NONE,
    state: union(enum) {
        none,
        encoder: bindgen.OwnedNativeWithDestructor(c.ZSTD_CCtx, destroyEncoder, .any),
        decoder: bindgen.OwnedNativeWithDestructor(c.ZSTD_DCtx, destroyDecoder, .any),
    } = .none,
    avail_in: usize = 0,
    avail_out: usize = 0,
    pledged_src_size: u64 = std.math.maxInt(u64),
    remaining: u64 = 0,

    fn destroyEncoder(state: *c.ZSTD_CCtx) void {
        _ = c.ZSTD_freeCCtx(state);
    }

    fn destroyDecoder(state: *c.ZSTD_DCtx) void {
        _ = c.ZSTD_freeDCtx(state);
    }

    pub fn init(this: *Context, pledged_src_size: u64) Error {
        this.deinitState();
        switch (this.mode) {
            .ZSTD_COMPRESS => {
                this.pledged_src_size = pledged_src_size;
                const state = c.ZSTD_createCCtx();
                if (state == null) return Error.out_of_memory;
                this.state = .{ .encoder = .init(state.?) };
                const result = c.ZSTD_CCtx_setPledgedSrcSize(state, pledged_src_size);
                if (c.ZSTD_isError(result) > 0) {
                    this.deinitState();
                    if (c.ZSTD_getErrorCode(result) == c.ZSTD_error_memory_allocation) return Error.out_of_memory;
                    return .init("Could not set pledged src size", -1, "ERR_ZLIB_INITIALIZATION_FAILED");
                }
                return .ok;
            },
            .ZSTD_DECOMPRESS => {
                const state = c.ZSTD_createDCtx();
                if (state == null) return Error.out_of_memory;
                this.state = .{ .decoder = .init(state.?) };
                return .ok;
            },
            else => @panic("unreachable"),
        }
    }

    pub fn setParams(this: *Context, key: c_uint, value: u32) Error {
        switch (this.mode) {
            .ZSTD_COMPRESS => {
                const result = c.ZSTD_CCtx_setParameter(this.state.encoder.get(), key, @bitCast(value));
                if (c.ZSTD_getErrorCode(result) == c.ZSTD_error_memory_allocation) return Error.out_of_memory;
                if (c.ZSTD_isError(result) > 0) return .init("Setting parameter failed", -1, "ERR_ZSTD_PARAM_SET_FAILED");
                return .ok;
            },
            .ZSTD_DECOMPRESS => {
                const result = c.ZSTD_DCtx_setParameter(this.state.decoder.get(), key, @bitCast(value));
                if (c.ZSTD_getErrorCode(result) == c.ZSTD_error_memory_allocation) return Error.out_of_memory;
                if (c.ZSTD_isError(result) > 0) return .init("Setting parameter failed", -1, "ERR_ZSTD_PARAM_SET_FAILED");
                return .ok;
            },
            else => @panic("unreachable"),
        }
    }

    pub fn reset(this: *Context) Error {
        return this.init(this.pledged_src_size);
    }

    /// Frees the Zstd encoder/decoder state without changing mode.
    /// Use close() for full cleanup that also sets mode to NONE.
    fn deinitState(this: *Context) void {
        switch (this.state) {
            .none => {},
            inline else => |*state| state.deinit(),
        }
        this.state = .none;
    }

    pub fn process(this: *Context, in: ?[]const u8, out: ?[]u8, flush: c_int) void {
        var input: c.ZSTD_inBuffer = .{
            .src = if (in) |p| p.ptr else null,
            .size = if (in) |p| p.len else 0,
            .pos = 0,
        };
        var output: c.ZSTD_outBuffer = .{
            .dst = if (out) |p| p.ptr else null,
            .size = if (out) |p| p.len else 0,
            .pos = 0,
        };
        this.remaining = switch (this.mode) {
            .ZSTD_COMPRESS => c.ZSTD_compressStream2(this.state.encoder.get(), &output, &input, @intCast(flush)),
            .ZSTD_DECOMPRESS => c.ZSTD_decompressStream(this.state.decoder.get(), &output, &input),
            else => @panic("unreachable"),
        };
        this.avail_in = input.size - input.pos;
        this.avail_out = output.size - output.pos;
    }

    pub fn updateWriteResult(this: *Context, avail_in: *u32, avail_out: *u32) void {
        avail_in.* = @intCast(this.avail_in);
        avail_out.* = @intCast(this.avail_out);
    }

    pub fn getErrorInfo(this: *Context) Error {
        defer this.remaining = 0;
        const err = c.ZSTD_getErrorCode(this.remaining);
        if (err == 0) {
            return .ok;
        }
        return Error{
            .err = @intCast(err),
            .allocation_failed = err == c.ZSTD_error_memory_allocation,
            .msg = c.ZSTD_getErrorString(err),
            .code = switch (err) {
                c.ZSTD_error_no_error => "ZSTD_error_no_error",
                c.ZSTD_error_GENERIC => "ZSTD_error_GENERIC",
                c.ZSTD_error_prefix_unknown => "ZSTD_error_prefix_unknown",
                c.ZSTD_error_version_unsupported => "ZSTD_error_version_unsupported",
                c.ZSTD_error_frameParameter_unsupported => "ZSTD_error_frameParameter_unsupported",
                c.ZSTD_error_frameParameter_windowTooLarge => "ZSTD_error_frameParameter_windowTooLarge",
                c.ZSTD_error_corruption_detected => "ZSTD_error_corruption_detected",
                c.ZSTD_error_checksum_wrong => "ZSTD_error_checksum_wrong",
                c.ZSTD_error_literals_headerWrong => "ZSTD_error_literals_headerWrong",
                c.ZSTD_error_dictionary_corrupted => "ZSTD_error_dictionary_corrupted",
                c.ZSTD_error_dictionary_wrong => "ZSTD_error_dictionary_wrong",
                c.ZSTD_error_dictionaryCreation_failed => "ZSTD_error_dictionaryCreation_failed",
                c.ZSTD_error_parameter_unsupported => "ZSTD_error_parameter_unsupported",
                c.ZSTD_error_parameter_combination_unsupported => "ZSTD_error_parameter_combination_unsupported",
                c.ZSTD_error_parameter_outOfBound => "ZSTD_error_parameter_outOfBound",
                c.ZSTD_error_tableLog_tooLarge => "ZSTD_error_tableLog_tooLarge",
                c.ZSTD_error_maxSymbolValue_tooLarge => "ZSTD_error_maxSymbolValue_tooLarge",
                c.ZSTD_error_maxSymbolValue_tooSmall => "ZSTD_error_maxSymbolValue_tooSmall",
                c.ZSTD_error_stabilityCondition_notRespected => "ZSTD_error_stabilityCondition_notRespected",
                c.ZSTD_error_stage_wrong => "ZSTD_error_stage_wrong",
                c.ZSTD_error_init_missing => "ZSTD_error_init_missing",
                c.ZSTD_error_memory_allocation => "ZSTD_error_memory_allocation",
                c.ZSTD_error_workSpace_tooSmall => "ZSTD_error_workSpace_tooSmall",
                c.ZSTD_error_dstSize_tooSmall => "ZSTD_error_dstSize_tooSmall",
                c.ZSTD_error_srcSize_wrong => "ZSTD_error_srcSize_wrong",
                c.ZSTD_error_dstBuffer_null => "ZSTD_error_dstBuffer_null",
                c.ZSTD_error_noForwardProgress_destFull => "ZSTD_error_noForwardProgress_destFull",
                c.ZSTD_error_noForwardProgress_inputEmpty => "ZSTD_error_noForwardProgress_inputEmpty",
                else => "ZSTD_error_GENERIC",
            },
        };
    }

    pub fn close(this: *Context) void {
        this.deinitState();
        this.mode = .NONE;
    }
};

const std = @import("std");
const CompressionJSBinding = @import("../node_zlib_binding.zig").CompressionJSBinding;
const Error = @import("../node_zlib_binding.zig").Error;

const bun = @import("bun");
const bindgen = bun.bindgen;

const NativeCompressionModule = bindgen.Module("NativeCompression");
const ClassSchema = NativeCompressionModule.class("NativeZstd");
pub const JSBinding = CompressionJSBinding(@This(), ClassSchema);
pub const JSClass = bindgen.Class(ClassSchema, JSBinding);

comptime {
    _ = JSClass;
}
