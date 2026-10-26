const Headers = @This();

bindgen_state: bindgen.ClassState = .{},
resource: FetchHeaders.Owner,

pub fn create(resource: FetchHeaders.Owner) bun.OOM!*Headers {
    var owned = resource;
    errdefer owned.deinit();
    const headers = try bun.default_allocator.create(Headers);
    headers.* = .{ .resource = owned };
    return headers;
}

pub fn construct(_: bindgen.CallContext(ConstructorSchema), args: bindgen.Args(ConstructorSchema)) bun.JSError!*Headers {
    const resource = if (args.init) |init| init.get().retain() else try FetchHeaders.createEmpty();
    return create(resource);
}

pub fn destroy(this: *Headers) void {
    this.resource.deinit();
    bun.default_allocator.destroy(this);
}

pub fn memoryUsage(this: *const Headers, _: bindgen.MemoryUsageContext(.vm)) usize {
    return @sizeOf(Headers) +| bindgen.Engine(MemoryCostSchema).call(.{ .headers = this.resource.get() });
}

fn Method(comptime FunctionSchema: type, comptime operation: []const u8) type {
    return struct {
        pub fn call(this: *Headers, context: bindgen.CallContext(FunctionSchema), args: bindgen.Args(FunctionSchema)) bun.JSError!bindgen.Return(FunctionSchema) {
            return context.engineIn("fetch_headers", operation).callForwarded(args, .{ .headers = this.resource.get() });
        }
    };
}

pub const bindAppend = Method(Schema.member("append"), "fetchHeadersAppend").call;

pub const bindDelete = Method(Schema.member("delete"), "fetchHeadersRemove").call;

pub const bindGet = Method(Schema.member("get"), "fetchHeadersGetByName").call;

pub const bindHas = Method(Schema.member("has"), "fetchHeadersHas").call;

pub const bindSet = Method(Schema.member("set"), "fetchHeadersSet").call;

pub fn getAll(this: *Headers, context: bindgen.CallContext(GetAllSchema), args: bindgen.Args(GetAllSchema)) bindgen.CallError(GetAllSchema)!bindgen.Return(GetAllSchema) {
    if (!args.name.eqlIgnoringASCIICase("set-cookie")) return context.fail(.unsupported_name, {});
    return context.engineIn("fetch_headers", "fetchHeadersGetSetCookie").call(.{ .headers = this.resource.get() });
}

pub const getSetCookie = Method(Schema.member("getSetCookie"), "fetchHeadersGetSetCookie").call;

pub const toJSON = Method(Schema.member("toJSON"), "fetchHeadersJSON").call;

pub const getCount = Method(Schema.member("count"), "fetchHeadersCount").call;

pub fn entries(this: *Headers, context: bindgen.CallContext(EntriesSchema), _: bindgen.Args(EntriesSchema)) bun.JSError!bindgen.Return(EntriesSchema) {
    return Iterator.create(context, .{ .headers = this.resource.get() }, .entries);
}

pub fn keys(this: *Headers, context: bindgen.CallContext(KeysSchema), _: bindgen.Args(KeysSchema)) bun.JSError!bindgen.Return(KeysSchema) {
    return Iterator.create(context, .{ .headers = this.resource.get() }, .keys);
}

pub fn values(this: *Headers, context: bindgen.CallContext(ValuesSchema), _: bindgen.Args(ValuesSchema)) bun.JSError!bindgen.Return(ValuesSchema) {
    return Iterator.create(context, .{ .headers = this.resource.get() }, .values);
}

pub fn forEach(this: *Headers, context: bindgen.CallContext(ForEachSchema), args: bindgen.Args(ForEachSchema)) bun.JSError!void {
    return Iterator.forEach("headers", context, args, .{ .headers = this.resource.get() });
}

pub fn inspectCustom(_: *Headers, context: bindgen.CallContext(InspectSchema), args: bindgen.Args(InspectSchema)) bun.JSError!bindgen.DOMString {
    return @import("./HeadersEngine.zig").inspect(context, args);
}

fn retainFromWrapper(_: bindgen.CallContext(RetainFromWrapperSchema), args: bindgen.Args(RetainFromWrapperSchema)) bun.JSError!bindgen.Return(RetainFromWrapperSchema) {
    return args.value.get(Headers).resource.get().retain();
}

fn getRawKeys(context: bindgen.CallContext(RawKeysSchema), args: bindgen.Args(RawKeysSchema)) bun.JSError!bindgen.Return(RawKeysSchema) {
    return context.engineIn("fetch_headers", "fetchHeadersRawKeys").call(.{ .headers = args.headers.get(Headers).resource.get() });
}

const bun = @import("bun");
const bindgen = bun.bindgen;
const FetchHeaders = bun.webcore.FetchHeaders;
const Module = bindgen.Module("WebCoreHeaders");
const Schema = Module.class("Headers");
pub const Binding = bindgen.Class(Schema, Headers);
const ConstructorSchema = Schema.constructor();
const GetAllSchema = Schema.member("getAll");
const EntriesSchema = Schema.member("entries");
const KeysSchema = Schema.member("keys");
const ValuesSchema = Schema.member("values");
const ForEachSchema = Schema.member("forEach");
const InspectSchema = Schema.member("inspectCustom");
const ResourceModule = bindgen.Module("fetch_headers");
const MemoryCostSchema = ResourceModule.engineShim("fetchHeadersMemoryCost");
const RetainFromWrapperSchema = ResourceModule.nativeExport("fetchHeadersRetainFromWrapper");
const RawKeysSchema = bindgen.Module("FetchHeaders").function("getRawKeys");
const Iterator = @import("./StringPairIterator.zig").StringPairIterator(
    Module.class("HeadersIterator"),
    ResourceModule.engineShim("fetchHeadersIteratorCreate"),
    ResourceModule.engineShim("fetchHeadersIteratorNext"),
);

comptime {
    _ = Binding;
    _ = Iterator.Binding;
    _ = bindgen.Fn(RetainFromWrapperSchema, retainFromWrapper);
    _ = bindgen.Fn(RawKeysSchema, getRawKeys);
}
