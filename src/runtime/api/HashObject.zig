pub const wyhash = hashBinding("wyhash", std.hash.Wyhash);
pub const adler32 = hashBinding("adler32", struct {
    pub fn hash(bytes: []const u8) u32 {
        return bun.libdeflate.libdeflate_adler32(1, bytes.ptr, bytes.len);
    }
});
/// Use hardware-accelerated CRC32 from zlib
pub const crc32 = hashBinding("crc32", struct {
    pub fn hash(seed: u32, bytes: []const u8) u32 {
        // zlib takes a 32-bit length, so chunk large inputs to avoid truncation.
        var crc: bun.zlib.uLong = seed;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const remaining = bytes.len - offset;
            const max_len: usize = std.math.maxInt(u32);
            const chunk_len: u32 = if (remaining > max_len) @intCast(max_len) else @intCast(remaining);
            crc = bun.zlib.crc32(crc, bytes.ptr + offset, chunk_len);
            offset += chunk_len;
        }
        return @intCast(crc);
    }
});
pub const cityHash32 = hashBinding("cityHash32", std.hash.CityHash32);
pub const cityHash64 = hashBinding("cityHash64", std.hash.CityHash64);
pub const xxHash32 = hashBinding("xxHash32", struct {
    pub fn hash(seed: u32, bytes: []const u8) u32 {
        // sidestep .hash taking in anytype breaking ArgTuple
        // downstream by forcing a type signature on the input
        return std.hash.XxHash32.hash(seed, bytes);
    }
});
pub const xxHash64 = hashBinding("xxHash64", struct {
    pub fn hash(seed: u64, bytes: []const u8) u64 {
        // sidestep .hash taking in anytype breaking ArgTuple
        // downstream by forcing a type signature on the input
        return std.hash.XxHash64.hash(seed, bytes);
    }
});
pub const xxHash3 = hashBinding("xxHash3", struct {
    pub fn hash(seed: u64, bytes: []const u8) u64 {
        return bun.highway.xxHash3(seed, bytes);
    }
});
pub const murmur32v2 = hashBinding("murmur32v2", std.hash.murmur.Murmur2_32);
pub const murmur32v3 = hashBinding("murmur32v3", std.hash.murmur.Murmur3_32);
pub const murmur64v2 = hashBinding("murmur64v2", std.hash.murmur.Murmur2_64);
pub const rapidhash = hashBinding("rapidhash", @import("../../hash/rapidhash.zig"));

comptime {
    _ = wyhash;
    _ = adler32;
    _ = crc32;
    _ = cityHash32;
    _ = cityHash64;
    _ = xxHash32;
    _ = xxHash64;
    _ = xxHash3;
    _ = murmur32v2;
    _ = murmur32v3;
    _ = murmur64v2;
    _ = rapidhash;
}

fn hashBinding(comptime name: []const u8, comptime Hasher_: anytype) type {
    const Schema = HashObjectBindings.function(name);
    return bun.bindgen.Fn(Schema, struct {
        const Hasher = Hasher_;
        pub fn hash(
            _: bun.bindgen.CallContext(Schema),
            args: bun.bindgen.Args(Schema),
        ) bun.bindgen.CallError(Schema)!bun.bindgen.Return(Schema) {
            var input: []const u8 = "";
            var input_slice = bun.String.Slice.empty;
            defer input_slice.deinit();
            if (args.input) |input_ref| {
                input = switch (input_ref) {
                    .blob => |blob| blob.get().sharedView(),
                    .buffer => |buffer| buffer.unsafePtr("The generated binding frame owns the input byte lease; the synchronous hash consumes these bytes before dispatch returns"),
                    .string => |string| string: {
                        input_slice = try string.toUTF8(bun.default_allocator);
                        break :string input_slice.slice();
                    },
                };
            }

            // std.hash has inconsistent interfaces
            //
            const Function = if (@hasDecl(Hasher, "hashWithSeed")) Hasher.hashWithSeed else Hasher.hash;
            const value = if (comptime std.meta.fieldNames(std.meta.ArgsTuple(@TypeOf(Function))).len == 1)
                Function(input)
            else value: {
                var function_args: std.meta.ArgsTuple(@TypeOf(Function)) = undefined;
                const seed: u64 = if (args.seed) |seed| switch (seed) {
                    .value => |number| number,
                    .invalid => 0,
                } else 0;
                if (comptime bun.trait.isNumber(@TypeOf(function_args[0]))) {
                    function_args[0] = @as(@TypeOf(function_args[0]), @truncate(seed));
                    function_args[1] = input;
                } else {
                    function_args[0] = input;
                    function_args[1] = @as(@TypeOf(function_args[1]), @truncate(seed));
                }

                break :value @call(.auto, Function, function_args);
            };

            return value;
        }
    }.hash);
}

const bun = @import("bun");
const std = @import("std");

const HashObjectBindings = bun.bindgen.Module("HashObject");
