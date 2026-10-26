const b = @import("bindgen_schema");
const blob_types = @import("binding_schema_BlobTypes");
const hash_types = @import("binding_schema_HashTypes");

fn hashFunction(comptime name: []const u8, comptime result: b.Type, comptime seeded: bool) b.Function {
    return b.function(
        name,
        .{
            b.argument("input", blob_types.or_string_or_buffer, .{ .presence = .optional, .missing = .omitted }),
        } ++ if (seeded) .{
            hash_types.seed("seed", .{
                .presence = .optional,
                .missing = .omitted,
            }),
        } else .{
            b.rest("ignored", b.discarded),
        },
        result,
        .{ .backend = .zig, .length = 1, .profile = .webidl },
    );
}

const bigint_hash = b.integerRepresentation(b.uint64, .bigint);

const functions = .{
    hashFunction("wyhash", bigint_hash, true),
    hashFunction("adler32", b.uint32, false),
    hashFunction("crc32", b.uint32, true),
    hashFunction("cityHash32", b.uint32, false),
    hashFunction("cityHash64", bigint_hash, true),
    hashFunction("xxHash32", b.uint32, true),
    hashFunction("xxHash64", bigint_hash, true),
    hashFunction("xxHash3", bigint_hash, true),
    hashFunction("murmur32v2", b.uint32, true),
    hashFunction("murmur32v3", b.uint32, true),
    hashFunction("murmur64v2", bigint_hash, true),
    hashFunction("rapidhash", bigint_hash, true),
};

pub const schema = b.module("HashObject", functions);
