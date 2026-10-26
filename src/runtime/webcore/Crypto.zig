const Crypto = @This();

bindgen_state: bindgen.ClassState = .{},

pub fn destroy(this: *Crypto) void {
    bun.destroy(this);
}

pub fn getSubtle(_: *Crypto, _: bindgen.CallContext(GetSubtle), _: bindgen.Args(GetSubtle)) bun.JSError!bindgen.Return(GetSubtle) {
    return .{ .brand = true };
}

pub fn setSubtle(_: *Crypto, _: bindgen.CallContext(SetSubtle), _: bindgen.Args(SetSubtle)) bun.JSError!void {}

pub fn timingSafeEqual(
    _: *Crypto,
    context: bindgen.CallContext(CryptoTimingSafeEqualSchema),
    args: bindgen.Args(CryptoTimingSafeEqualSchema),
) bindgen.CallError(CryptoTimingSafeEqualSchema)!bool {
    const left = args.buf1.unsafePtr("the generated entry frame owns the left buffer lease until BoringSSL finishes comparing bytes");
    const right = args.buf2.unsafePtr("the generated entry frame owns the right buffer lease until BoringSSL finishes comparing bytes");

    if (left.len != right.len) {
        return context.fail(.length_mismatch, {});
    }

    return bun.BoringSSL.c.CRYPTO_memcmp(left.ptr, right.ptr, left.len) == 0;
}

pub fn getRandomValues(
    _: *Crypto,
    _: bindgen.CallContext(CryptoGetRandomValuesSchema),
    args: bindgen.Args(CryptoGetRandomValuesSchema),
) bun.JSError!bindgen.Return(CryptoGetRandomValuesSchema) {
    const data = args.data;
    const slice = data.unsafeMutPtr("the generated entry frame owns the destination lease until the random fill finishes writing");
    bun.current_runtime.fillEntropy(slice);

    return data.source();
}

pub fn randomUUID(
    _: *Crypto,
    _: bindgen.CallContext(CryptoRandomUUIDSchema),
    _: bindgen.Args(CryptoRandomUUIDSchema),
) bun.JSError!bindgen.DOMString {
    const str, var bytes = bun.String.createUninitialized(.latin1, 36);

    const uuid = bun.current_runtime.nextUUID();

    uuid.print(bytes[0..36]);
    return bindgen.DOMString.fromBunString(str);
}

pub fn randomUUIDv7(
    context: bindgen.CallContext(RandomUUIDV7Schema),
    args: bindgen.Args(RandomUUIDV7Schema),
) bindgen.CallError(RandomUUIDV7Schema)!bindgen.Return(RandomUUIDV7Schema) {
    var entropy: [8]u8 = undefined;
    bun.current_runtime.fillEntropy(&entropy);
    return generateUUIDv7(context, args, bun.current_runtime.io(), &entropy);
}

pub fn generateUUIDv7(
    context: bindgen.CallContext(RandomUUIDV7Schema),
    args: bindgen.Args(RandomUUIDV7Schema),
    io: std.Io,
    entropy: *[8]u8,
) bindgen.CallError(RandomUUIDV7Schema)!bindgen.Return(RandomUUIDV7Schema) {
    var encoding: UUIDEncoding = .hex;
    var timestamp: ?f64 = null;
    switch (args) {
        .defaults => {},
        .one => |values| switch (values.value) {
            .encoding => |value| encoding = uuidEncoding(value),
            .timestamp => |value| timestamp = value,
            .defaults => {},
        },
        .encoding_and_timestamp => |values| {
            encoding = uuidEncodingOrDefault(values.encoding);
            timestamp = values.timestamp;
        },
    }

    const value = timestamp orelse @as(f64, @floatFromInt(@max(0, bun.timespec.realNow().ms())));
    if (!std.math.isFinite(value) or value < 0 or value != @trunc(value) or value > std.math.maxInt(UUID7.Timestamp))
        return context.fail(.invalid_timestamp, {});
    const timestamp_ms: UUID7.Timestamp = @intFromFloat(value);

    return encodeUUID(RandomUUIDV7Schema, encoding, UUID7.init(io, timestamp_ms, entropy));
}

pub fn randomUUIDv5(
    context: bindgen.CallContext(RandomUUIDV5Schema),
    args: bindgen.Args(RandomUUIDV5Schema),
) bindgen.CallError(RandomUUIDV5Schema)!bindgen.Return(RandomUUIDV5Schema) {
    const encoding = if (args.encoding) |value| uuidEncodingOrDefault(value) else UUIDEncoding.hex;

    const name = switch (args.name) {
        .string => |value| try value.toUTF8(bun.default_allocator),
        .buffer => |value| bun.String.Slice.fromUTF8NeverFree(value.unsafePtr("the generated entry frame owns the name buffer until UUIDv5 finishes hashing it")),
    };
    defer name.deinit();

    const namespace = switch (args.namespace_value) {
        .string => |value| namespace: {
            const namespace_slice = try value.toUTF8(bun.default_allocator);
            defer namespace_slice.deinit();

            if (namespace_slice.slice().len != 36) {
                if (UUID5.namespaces.get(namespace_slice.slice())) |namespace| {
                    break :namespace namespace.*;
                }

                return context.fail(.invalid_namespace, {});
            }

            const parsed_uuid = UUID.parse(namespace_slice.slice()) catch {
                return context.fail(.invalid_namespace, {});
            };
            break :namespace parsed_uuid.bytes;
        },
        .buffer => |value| namespace: {
            const slice = value.unsafePtr("the generated entry frame owns the namespace buffer until UUIDv5 copies its bytes");
            if (slice.len != 16) {
                return context.fail(.invalid_namespace, {});
            }
            break :namespace slice[0..16].*;
        },
    };

    const uuid = UUID5.init(&namespace, name.slice());

    return encodeUUID(RandomUUIDV5Schema, encoding, uuid);
}

const UUIDEncoding = enum {
    base64,
    base64url,
    hex,
    buffer,
};

fn uuidEncodingOrDefault(value: anytype) UUIDEncoding {
    return switch (value) {
        .encoding => |encoding| uuidEncoding(encoding),
        .defaults => .hex,
    };
}

fn uuidEncoding(encoding: anytype) UUIDEncoding {
    return switch (encoding) {
        .base64 => .base64,
        .base64url => .base64url,
        .hex => .hex,
        .buffer => .buffer,
    };
}

fn encodeUUID(
    comptime Schema: type,
    encoding: UUIDEncoding,
    uuid: anytype,
) bindgen.CallError(Schema)!bindgen.Return(Schema) {
    switch (encoding) {
        .hex => {
            const string, var bytes = bun.String.createUninitialized(.latin1, 36);
            uuid.print(bytes[0..36]);
            return .{ .string = try bindgen.DOMString.fromBunString(string) };
        },
        .base64 => {
            const string, const bytes = bun.String.createUninitialized(.latin1, bun.base64.encodeLen(&uuid.bytes));
            _ = bun.base64.encode(bytes, &uuid.bytes);
            return .{ .string = try bindgen.DOMString.fromBunString(string) };
        },
        .base64url => {
            const string, const bytes = bun.String.createUninitialized(.latin1, bun.base64.urlSafeEncodeLen(&uuid.bytes));
            _ = bun.base64.encodeURLSafe(bytes, &uuid.bytes);
            return .{ .string = try bindgen.DOMString.fromBunString(string) };
        },
        .buffer => return .{ .buffer = try bindgen.OwnedBytes.fromSlice(&uuid.bytes) },
    }
}

fn bindCreateCryptoObject(
    context: bun.bindgen.CallContext(CryptoObjectCreateSchema),
    _: bun.bindgen.Args(CryptoObjectCreateSchema),
) bun.JSError!bun.bindgen.Return(CryptoObjectCreateSchema) {
    const ptr = try bun.default_allocator.create(Crypto);
    ptr.* = .{};

    return CryptoClass.adoptResult(ptr, context);
}

const UUID = bun.UUID;
const UUID5 = bun.UUID.UUID5;
const UUID7 = bun.UUID.UUID7;
const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;

const CryptoBindingModule = bindgen.Module("Crypto");
const CryptoSchema = CryptoBindingModule.class("Crypto");
const CryptoGetRandomValuesSchema = CryptoSchema.member("getRandomValues");
const CryptoRandomUUIDSchema = CryptoSchema.member("randomUUID");
const CryptoTimingSafeEqualSchema = CryptoSchema.member("timingSafeEqual");
const CryptoClass = bindgen.Class(CryptoSchema, Crypto);
const GetSubtle = CryptoSchema.memberKind("subtle", .getter);
const SetSubtle = CryptoSchema.memberKind("subtle", .setter);

const BunObjectBindings = bindgen.Module("BunObject");
pub const RandomUUIDV7Schema = BunObjectBindings.function("randomUUIDv7");
const RandomUUIDV5Schema = BunObjectBindings.function("randomUUIDv5");
const RandomUUIDV7Binding = bindgen.Fn(RandomUUIDV7Schema, randomUUIDv7);
const RandomUUIDV5Binding = bindgen.Fn(RandomUUIDV5Schema, randomUUIDv5);
const CryptoObjectCreateSchema = CryptoBindingModule.nativeExport("cryptoObjectCreate");
const CryptoObjectCreateBinding = bindgen.Fn(CryptoObjectCreateSchema, bindCreateCryptoObject);

comptime {
    _ = CryptoClass;
    _ = RandomUUIDV7Binding;
    _ = RandomUUIDV5Binding;
    _ = CryptoObjectCreateBinding;
}
