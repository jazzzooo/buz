pub const Decompressor = union(enum) {
    zlib: *Zlib.ZlibReaderArrayList,
    brotli: *Brotli.BrotliReaderArrayList,
    zstd: *zstd.ZstdReaderArrayList,
    none: void,

    pub fn deinit(this: *Decompressor) void {
        switch (this.*) {
            inline .brotli, .zlib, .zstd => |that| {
                that.deinit();
                this.* = .{ .none = {} };
            },
            .none => {},
        }
    }

    pub fn updateBuffers(this: *Decompressor, encoding: Encoding, buffer: []const u8, body_out_str: *MutableString) !void {
        if (!encoding.isCompressed()) {
            return;
        }

        if (this.* == .none) {
            switch (encoding) {
                .gzip, .deflate => {
                    const reader = try Zlib.ZlibReaderArrayList.initWithOptionsAndListAllocator(
                        buffer,
                        &body_out_str.list,
                        body_out_str.allocator,
                        bun.http.default_allocator,
                        .{
                            // zlib.MAX_WBITS = 15
                            // to (de-)compress deflate format, use wbits = -zlib.MAX_WBITS
                            // to (de-)compress deflate format with headers we use wbits = 0 (we can detect the first byte using 120)
                            // to (de-)compress gzip format, use wbits = zlib.MAX_WBITS | 16
                            .windowBits = if (encoding == Encoding.gzip) Zlib.MAX_WBITS | 16 else (if (buffer.len > 1 and buffer[0] == 120) 0 else -Zlib.MAX_WBITS),
                        },
                    );
                    this.* = .{ .zlib = reader };
                    return;
                },
                .brotli => {
                    const reader = try Brotli.BrotliReaderArrayList.newWithOptions(
                        buffer,
                        &body_out_str.list,
                        body_out_str.allocator,
                        .{},
                    );
                    this.* = .{ .brotli = reader };
                    return;
                },
                .zstd => {
                    const reader = try zstd.ZstdReaderArrayList.initWithListAllocator(
                        buffer,
                        &body_out_str.list,
                        body_out_str.allocator,
                        bun.http.default_allocator,
                    );
                    this.* = .{ .zstd = reader };
                    return;
                },
                else => @panic("Invalid encoding. This code should not be reachable"),
            }
        }

        switch (this.*) {
            .zlib => |reader| {
                reader.updateBuffers(buffer, &body_out_str.list, body_out_str.allocator);
            },
            .brotli => |reader| {
                reader.input = buffer;
                reader.total_in = 0;
                reader.list = &body_out_str.list;
                reader.list_allocator = body_out_str.allocator;
            },
            .zstd => |reader| {
                reader.input = buffer;
                reader.total_in = 0;
                reader.list = &body_out_str.list;
                reader.list_allocator = body_out_str.allocator;
            },
            else => @panic("Invalid encoding. This code should not be reachable"),
        }
    }

    pub fn readAll(this: *Decompressor, is_done: bool) !void {
        switch (this.*) {
            .zlib => |zlib| try zlib.readAll(is_done),
            .brotli => |brotli| try brotli.readAll(is_done),
            .zstd => |reader| try reader.readAll(is_done),
            .none => {},
        }
    }
};

const Zlib = @import("../zlib/zlib.zig");
const Encoding = @import("../http_types/Encoding.zig").Encoding;

const bun = @import("bun");
const Brotli = bun.brotli;
const MutableString = bun.MutableString;
const zstd = bun.zstd;
