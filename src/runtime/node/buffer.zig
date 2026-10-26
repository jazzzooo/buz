pub const BufferVectorized = struct {
    pub fn fill(
        input: bun.bindgen.UnsafeStringCodeUnits,
        output: []u8,
        encoding: NodeTypes.Encoding,
    ) bool {
        const input_length = switch (input) {
            inline else => |units| units.len,
        };
        if (input_length == 0) return true;

        var buf = output;

        const written = switch (input) {
            .utf16 => |units| switch (encoding) {
                inline else => |resolved| Encoder.writeU16(units.ptr, units.len, buf.ptr, buf.len, resolved, true),
            },
            .latin1 => |units| switch (encoding) {
                inline else => |resolved| Encoder.writeU8(units.ptr, units.len, buf.ptr, buf.len, resolved, true),
            },
        };

        if (written == 0 and input_length > 0) return false;

        switch (written) {
            0 => return true,
            1 => {
                @memset(buf, buf[0]);
                return true;
            },
            inline 4, 8, 16 => |n| if (comptime Environment.isMac) {
                const pattern = buf[0..n];
                buf = buf[pattern.len..];
                @field(bun.c, std.fmt.comptimePrint("memset_pattern{d}", .{n}))(buf.ptr, pattern.ptr, buf.len);
                return true;
            },
            else => {},
        }

        var contents = buf[0..written];
        buf = buf[written..];

        while (buf.len >= contents.len) {
            bun.copy(u8, buf, contents);
            buf = buf[contents.len..];
            contents.len *= 2;
        }

        if (buf.len > 0) {
            bun.copy(u8, buf, contents[0..buf.len]);
        }

        return true;
    }
};

fn bindBufferFill(
    args: bun.bindgen.Args(BufferFillSchema),
) bun.bindgen.Return(BufferFillSchema) {
    const input = args.input.unsafePtr("the calling C++ frame owns the string until synchronous buffer filling returns");
    const output = args.output.unsafePtr("the calling C++ frame roots the destination Buffer until synchronous filling returns");
    const encoding: NodeTypes.Encoding = switch (args.encoding) {
        inline else => |value| @field(NodeTypes.Encoding, @tagName(value)),
    };
    return BufferVectorized.fill(input, output, encoding);
}

comptime {
    _ = BufferFillBinding;
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const NodeTypes = @import("./types.zig");
const Encoder = @import("../webcore/encoding.zig");
const ArrayBufferBindings = bun.bindgen.Module("array_buffers");
const BufferFillSchema = ArrayBufferBindings.nativeExport("bufferFill");
const BufferFillBinding = bun.bindgen.Fn(BufferFillSchema, bindBufferFill);
