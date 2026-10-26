stream: Context = .{},
active: bool = false,

pub fn create(mode: i32) @This() {
    var backend: @This() = .{};
    backend.stream.mode = @fromBackingInt(@intCast(mode));
    return backend;
}

pub fn estimatedSize(this: *const @This()) usize {
    const encoder_state_size: usize = 5143; // @sizeOf(@cImport(@cInclude("brotli/encode.h")).BrotliEncoderStateStruct)
    const decoder_state_size: usize = 855; // @sizeOf(@cImport(@cInclude("brotli/decode.h")).BrotliDecoderStateStruct)
    return switch (this.stream.mode) {
        .BROTLI_ENCODE => encoder_state_size,
        .BROTLI_DECODE => decoder_state_size,
        else => 0,
    };
}

pub fn initFromBindgen(this: *@This(), args: anytype) bun.OOM!?Error {
    var err = this.stream.init();
    if (err.isError()) return err;
    this.active = true;

    for (0..args.params.length() / @sizeOf(u32)) |i| {
        var d: u32 = undefined;
        if (!args.params.read(i * @sizeOf(u32), std.mem.asBytes(&d))) unreachable;
        if (d == std.math.maxInt(u32)) {
            continue;
        }
        err = this.stream.setParams(@intCast(i), d);
        if (err.isError()) {
            this.stream.deinitState();
            this.active = false;
            return err;
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
    const c = bun.brotli.c;
    const Op = bun.brotli.c.BrotliEncoder.Operation;

    mode: bun.zlib.NodeMode = .NONE,
    state: union(enum) {
        none,
        encoder: bindgen.OwnedNativeWithDestructor(c.BrotliEncoder, destroyEncoder, .any),
        decoder: bindgen.OwnedNativeWithDestructor(c.BrotliDecoder, destroyDecoder, .any),
    } = .none,
    avail_in: usize = 0,
    avail_out: usize = 0,

    flush: Op = .process,

    last_result: extern union { e: c_int, d: c.BrotliDecoderResult } = .{ .e = 0 },
    error_: c.BrotliDecoderErrorCode2 = .NO_ERROR,
    allocation_failed: bool = false,

    fn destroyEncoder(state: *c.BrotliEncoder) void {
        c.BrotliEncoderDestroyInstance(state);
    }

    fn destroyDecoder(state: *c.BrotliDecoder) void {
        c.BrotliDecoderDestroyInstance(state);
    }

    fn allocate(opaque_context: ?*anyopaque, len: usize) callconv(.c) ?*anyopaque {
        const this: *Context = @ptrCast(@alignCast(opaque_context.?));
        const result = bun.brotli.BrotliAllocator.alloc(null, len);
        if (result == null) this.allocation_failed = true;
        return result;
    }

    pub fn init(this: *Context) Error {
        this.deinitState();
        this.allocation_failed = false;
        this.error_ = .NO_ERROR;
        this.last_result = .{ .e = 0 };
        switch (this.mode) {
            .BROTLI_ENCODE => {
                const alloc = &allocate;
                const free = &bun.brotli.BrotliAllocator.free;
                const state = c.BrotliEncoderCreateInstance(alloc, free, this);
                if (state == null) {
                    return Error.out_of_memory;
                }
                this.state = .{ .encoder = .init(state.?) };
                return Error.ok;
            },
            .BROTLI_DECODE => {
                const alloc = &allocate;
                const free = &bun.brotli.BrotliAllocator.free;
                const state = c.BrotliDecoderCreateInstance(alloc, free, this);
                if (state == null) {
                    return Error.out_of_memory;
                }
                this.state = .{ .decoder = .init(state.?) };
                return Error.ok;
            },
            else => unreachable,
        }
    }

    pub fn setParams(this: *Context, key: c_uint, value: u32) Error {
        this.allocation_failed = false;
        switch (this.mode) {
            .BROTLI_ENCODE => {
                if (c.BrotliEncoderSetParameter(this.state.encoder.get(), key, value) == 0) {
                    if (this.allocation_failed) return Error.out_of_memory;
                    return Error.init("Setting parameter failed", -1, "ERR_BROTLI_PARAM_SET_FAILED");
                }
                return Error.ok;
            },
            .BROTLI_DECODE => {
                if (c.BrotliDecoderSetParameter(this.state.decoder.get(), key, value) == 0) {
                    if (this.allocation_failed) return Error.out_of_memory;
                    return Error.init("Setting parameter failed", -1, "ERR_BROTLI_PARAM_SET_FAILED");
                }
                return Error.ok;
            },
            else => unreachable,
        }
    }

    pub fn reset(this: *Context) Error {
        return this.init();
    }

    /// Frees the Brotli encoder/decoder state without changing mode.
    /// Use close() for full cleanup that also sets mode to NONE.
    fn deinitState(this: *Context) void {
        switch (this.state) {
            .none => {},
            inline else => |*state| state.deinit(),
        }
        this.state = .none;
    }

    pub fn process(this: *Context, in: ?[]const u8, out: ?[]u8, flush: c_int) void {
        var next_in: ?[*]const u8 = if (in) |p| p.ptr else null;
        var next_out: ?[*]u8 = if (out) |p| p.ptr else null;
        this.avail_in = if (in) |p| p.len else 0;
        this.avail_out = if (out) |p| p.len else 0;
        this.flush = @fromBackingInt(@intCast(flush));
        this.allocation_failed = false;
        switch (this.mode) {
            .BROTLI_ENCODE => {
                this.last_result.e = c.BrotliEncoderCompressStream(this.state.encoder.get(), this.flush, &this.avail_in, &next_in, &this.avail_out, &next_out, null);
            },
            .BROTLI_DECODE => {
                this.last_result.d = c.BrotliDecoderDecompressStream(this.state.decoder.get(), &this.avail_in, &next_in, &this.avail_out, &next_out, null);
                if (this.last_result.d == .err) {
                    this.error_ = c.BrotliDecoderGetErrorCode(this.state.decoder.get());
                }
            },
            else => unreachable,
        }
    }

    pub fn updateWriteResult(this: *Context, avail_in: *u32, avail_out: *u32) void {
        avail_in.* = @intCast(this.avail_in);
        avail_out.* = @intCast(this.avail_out);
    }

    pub fn getErrorInfo(this: *Context) Error {
        switch (this.mode) {
            .BROTLI_ENCODE => {
                if (this.last_result.e == 0) {
                    if (this.allocation_failed) return Error.out_of_memory;
                    return Error.init("Compression failed", -1, "ERR_BROTLI_COMPRESSION_FAILED");
                }
                return Error.ok;
            },
            .BROTLI_DECODE => {
                if (this.error_ != .NO_ERROR) {
                    if (this.allocation_failed) return Error.out_of_memory;
                    if (bun.brotli.isAllocationError(@backingInt(this.error_))) return Error.out_of_memory;
                    return Error.init("Decompression failed", @backingInt(this.error_), code_for_error(this.error_));
                } else if (this.flush == .finish and this.last_result.d == .needs_more_input) {
                    return Error.init("unexpected end of file", @backingInt(bun.zlib.ReturnCode.BufError), "Z_BUF_ERROR");
                }
                return Error.ok;
            },
            else => unreachable,
        }
    }

    pub fn close(this: *Context) void {
        this.deinitState();
        this.mode = .NONE;
    }

    fn code_for_error(err: c.BrotliDecoderErrorCode2) [:0]const u8 {
        const E = c.BrotliDecoderErrorCode2;
        const names = comptime std.meta.fieldNames(E);
        const values = comptime std.enums.values(E);
        inline for (names, values) |n, v| {
            if (err == v) {
                return "ERR_BROTLI_DECODER_" ++ n;
            }
        }
        unreachable;
    }
};

const std = @import("std");
const CompressionJSBinding = @import("../node_zlib_binding.zig").CompressionJSBinding;
const Error = @import("../node_zlib_binding.zig").Error;

const bun = @import("bun");
const bindgen = bun.bindgen;

const NativeCompressionModule = bindgen.Module("NativeCompression");
const ClassSchema = NativeCompressionModule.class("NativeBrotli");
pub const JSBinding = CompressionJSBinding(@This(), ClassSchema);
pub const JSClass = bindgen.Class(ClassSchema, JSBinding);

comptime {
    _ = JSClass;
}
