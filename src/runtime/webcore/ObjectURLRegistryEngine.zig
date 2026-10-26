const ObjectURLRegistry = @import("ObjectURLRegistry.zig");

const Registry = ObjectURLRegistry.Registry(Blob);

pub const singleton = Registry.singleton;
pub const specifier_len = ObjectURLRegistry.specifier_len;
pub const isBlobURL = ObjectURLRegistry.isBlobURL;

pub fn urlCreateObjectURL(
    context: bun.bindgen.CallContext(CreateObjectURLSchema),
    args: bun.bindgen.Args(CreateObjectURLSchema),
) bun.JSError!bun.bindgen.DOMString {
    _ = context;
    return createObjectURL(bun.current_runtime.io(), bun.current_runtime.nextUUID(), args);
}

fn createObjectURL(io: std.Io, uuid: UUID, args: bun.bindgen.Args(CreateObjectURLSchema)) bun.JSError!bun.bindgen.DOMString {
    var result = try bun.bindgen.DOMString.fromBunString(try bun.String.createFormat("blob:{f}", .{uuid}));
    errdefer result.deinit();
    const blob = switch (args.blob) {
        .blob => |view| view.get(),
        .artifact => |view| &view.get(bun.jsc.API.BuildArtifact).blob,
    };
    try singleton().register(io, uuid, blob);
    return result;
}

pub fn urlRevokeObjectURL(
    context: bun.bindgen.CallContext(RevokeObjectURLSchema),
    args: bun.bindgen.Args(RevokeObjectURLSchema),
) bun.JSError!void {
    _ = context;
    return revokeObjectURL(bun.current_runtime.io(), args);
}

fn revokeObjectURL(io: std.Io, args: bun.bindgen.Args(RevokeObjectURLSchema)) bun.JSError!void {
    const uuid = uuidFromURL(args.url) orelse return;
    singleton().revokeUUID(io, uuid);
}

fn uuidFromURL(url: bun.bindgen.DOMStringView) ?UUID {
    if (url.length() != specifier_len) return null;
    const prefix = "blob:";
    inline for (prefix, 0..) |unit, index| {
        if (url.codeUnitAt(index).? != unit) return null;
    }
    var encoded: [UUID.stringLength]u8 = undefined;
    for (&encoded, prefix.len..) |*byte, index| {
        const unit = url.codeUnitAt(index).?;
        if (unit > 0x7f) return null;
        byte.* = @intCast(unit);
    }
    return UUID.parse(&encoded) catch null;
}

fn resolveObjectURL(
    context: bun.bindgen.CallContext(ResolveObjectURLSchema),
    args: bun.bindgen.Args(ResolveObjectURLSchema),
) bun.JSError!bun.bindgen.Return(ResolveObjectURLSchema) {
    return resolveObjectURLWithIo(bun.current_runtime.io(), context, args);
}

fn resolveObjectURLWithIo(io: std.Io, context: bun.bindgen.CallContext(ResolveObjectURLSchema), args: bun.bindgen.Args(ResolveObjectURLSchema)) bun.JSError!bun.bindgen.Return(ResolveObjectURLSchema) {
    const str = args.url orelse return null;
    const uuid = uuidFromURL(str) orelse return null;
    var blob = (try singleton().resolveUUIDAndDupe(io, uuid)) orelse return null;
    defer blob.deinit();
    return try (try Blob.new(&blob)).toBindingRef(context);
}

const std = @import("std");

const bun = @import("bun");
const Blob = @import("Blob.zig");
const UUID = bun.UUID;

const ObjectURLRegistryBindings = bun.bindgen.Module("ObjectURLRegistry");
const ResolveObjectURLSchema = ObjectURLRegistryBindings.function("resolve");
const WebCoreBindings = bun.bindgen.Module("WebCoreURL");
const URLSchema = WebCoreBindings.class("URL");
const CreateObjectURLSchema = URLSchema.member("createObjectURL");
const RevokeObjectURLSchema = URLSchema.member("revokeObjectURL");
const ResolveObjectURLBinding = bun.bindgen.Fn(ResolveObjectURLSchema, resolveObjectURL);

comptime {
    _ = ResolveObjectURLBinding;
}
