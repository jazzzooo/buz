pub const URLSearchParams = opaque {
    pub const Owner = bun.bindgen.Return(RetainSchema);

    pub fn retain(this: *URLSearchParams) Owner {
        return bun.bindgen.Engine(RetainSchema).call(.{ .params = this });
    }

    pub fn toString(self: *URLSearchParams) bun.OOM!bun.bindgen.ThreadSafeDOMString {
        return bun.bindgen.Engine(URLSearchParamsToStringSchema).call(.{ .params = self });
    }
};

pub const URLSearchParamsObject = struct {
    pub const Binding = bun.bindgen.Class(ParamsSchema, URLSearchParamsObject);

    bindgen_state: bun.bindgen.ClassState = .{},
    resource: URLSearchParams.Owner,

    pub fn create(resource: URLSearchParams.Owner) bun.OOM!*URLSearchParamsObject {
        var owned = resource;
        errdefer owned.deinit();
        const object = try bun.default_allocator.create(URLSearchParamsObject);
        object.* = .{ .resource = owned };
        return object;
    }

    pub fn construct(context: bun.bindgen.CallContext(ConstructorSchema), args: bun.bindgen.Args(ConstructorSchema)) bun.bindgen.CallError(ConstructorSchema)!*URLSearchParamsObject {
        if (args.init) |init| {
            if (init == .sequence) {
                var pairs = init.sequence.iterator();
                while (pairs.next()) |pair| {
                    if (pair.value.len() != 2) return context.fail(.invalid_pair, {});
                }
            }
        }
        const operation = context.engineIn("WebCoreURL", "urlSearchParamsCreate");
        return create(try operation.call(.{ .init = try operation.argument("init", args.init) }));
    }

    pub fn destroy(this: *URLSearchParamsObject) void {
        this.resource.deinit();
        bun.default_allocator.destroy(this);
    }

    pub fn memoryUsage(this: *const URLSearchParamsObject, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(URLSearchParamsObject) +| bun.bindgen.Engine(MemoryCostSchema).call(.{ .params = this.resource.get() });
    }

    fn Method(comptime FunctionSchema: type, comptime operation: []const u8) type {
        return struct {
            pub fn call(this: *URLSearchParamsObject, context: bun.bindgen.CallContext(FunctionSchema), args: bun.bindgen.Args(FunctionSchema)) bun.JSError!bun.bindgen.Return(FunctionSchema) {
                return context.engineIn("WebCoreURL", operation).callForwarded(args, .{ .params = this.resource.get() });
            }
        };
    }

    pub const append = Method(ParamsSchema.member("append"), "urlSearchParamsAppend").call;

    pub const delete = Method(ParamsSchema.member("delete"), "urlSearchParamsDelete").call;

    pub const get = Method(ParamsSchema.member("get"), "urlSearchParamsGet").call;

    pub const getAll = Method(ParamsSchema.member("getAll"), "urlSearchParamsGetAll").call;

    pub const has = Method(ParamsSchema.member("has"), "urlSearchParamsHas").call;

    pub const set = Method(ParamsSchema.member("set"), "urlSearchParamsSet").call;

    pub const sort = Method(ParamsSchema.member("sort"), "urlSearchParamsSort").call;

    pub fn toString(this: *URLSearchParamsObject, _: bun.bindgen.CallContext(StringSchema), _: bun.bindgen.Args(StringSchema)) bun.JSError!bun.bindgen.DOMString {
        var string = try this.resource.get().toString();
        return bun.bindgen.DOMString.fromBunString(string.takeBunString());
    }

    pub const toJSON = Method(ParamsSchema.member("toJSON"), "urlSearchParamsJSON").call;

    pub fn inspectCustom(_: *URLSearchParamsObject, context: bun.bindgen.CallContext(InspectSchema), args: bun.bindgen.Args(InspectSchema)) bun.JSError!bun.bindgen.DOMString {
        return bun.jsc.ConsoleObject.formatClassRefForBinding(context, args);
    }

    pub const getLength = Method(ParamsSchema.member("length"), "urlSearchParamsSize").call;

    pub const getSize = Method(ParamsSchema.member("size"), "urlSearchParamsSize").call;

    pub fn entries(this: *URLSearchParamsObject, context: bun.bindgen.CallContext(EntriesSchema), _: bun.bindgen.Args(EntriesSchema)) bun.JSError!bun.bindgen.Return(EntriesSchema) {
        return Iterator.create(context, .{ .params = this.resource.get() }, .entries);
    }

    pub fn keys(this: *URLSearchParamsObject, context: bun.bindgen.CallContext(KeysSchema), _: bun.bindgen.Args(KeysSchema)) bun.JSError!bun.bindgen.Return(KeysSchema) {
        return Iterator.create(context, .{ .params = this.resource.get() }, .keys);
    }

    pub fn values(this: *URLSearchParamsObject, context: bun.bindgen.CallContext(ValuesSchema), _: bun.bindgen.Args(ValuesSchema)) bun.JSError!bun.bindgen.Return(ValuesSchema) {
        return Iterator.create(context, .{ .params = this.resource.get() }, .values);
    }

    pub fn forEach(this: *URLSearchParamsObject, context: bun.bindgen.CallContext(ForEachSchema), args: bun.bindgen.Args(ForEachSchema)) bun.bindgen.CallError(ForEachSchema)!void {
        const callback = switch (args.callback) {
            .callback => |value| value,
            .invalid => return context.fail(.invalid_callback, {}),
        };
        return Iterator.forEach("searchParams", context, .{
            .bindingThis = args.bindingThis,
            .callback = callback,
            .thisArg = args.thisArg,
        }, .{ .params = this.resource.get() });
    }
};

const Iterator = @import("../runtime/webcore/StringPairIterator.zig").StringPairIterator(IteratorSchema, IteratorCreateSchema, IteratorNextSchema);

const bun = @import("bun");

const URLBindings = bun.bindgen.Module("urls");
const RetainSchema = URLBindings.engineShim("urlSearchParamsRetain");
const MemoryCostSchema = URLBindings.engineShim("urlSearchParamsMemoryCost");
const RetainFromWrapperSchema = URLBindings.nativeExport("urlSearchParamsRetainFromWrapper");
const URLSearchParamsToStringSchema = URLBindings.engineShim("urlSearchParamsToString");
const IteratorCreateSchema = URLBindings.engineShim("urlSearchParamsIteratorCreate");
const IteratorNextSchema = URLBindings.engineShim("urlSearchParamsIteratorNext");
const WebCoreBindings = bun.bindgen.Module("WebCoreURL");
const ParamsSchema = WebCoreBindings.class("URLSearchParams");
const ConstructorSchema = ParamsSchema.constructor();
const StringSchema = ParamsSchema.member("toString");
const InspectSchema = ParamsSchema.member("inspectCustom");
const EntriesSchema = ParamsSchema.member("entries");
const KeysSchema = ParamsSchema.member("keys");
const ValuesSchema = ParamsSchema.member("values");
const ForEachSchema = ParamsSchema.member("forEach");
const IteratorSchema = WebCoreBindings.class("URLSearchParamsIterator");

fn retainFromWrapper(_: bun.bindgen.CallContext(RetainFromWrapperSchema), args: bun.bindgen.Args(RetainFromWrapperSchema)) bun.JSError!bun.bindgen.Return(RetainFromWrapperSchema) {
    return args.value.get(URLSearchParamsObject).resource.get().retain();
}

comptime {
    _ = URLSearchParamsObject.Binding;
    _ = Iterator.Binding;
    _ = bun.bindgen.Fn(RetainFromWrapperSchema, retainFromWrapper);
}
