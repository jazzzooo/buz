pub const CookieMap = opaque {
    pub const Owner = bindgen.Return(RetainSchema);

    pub fn retain(this: *CookieMap) Owner {
        return bindgen.Engine(RetainSchema).call(.{ .cookieMap = this });
    }
};

const CookieMapObject = struct {
    bindgen_state: bindgen.ClassState = .{},
    map: CookieMap.Owner,

    fn create(map: CookieMap.Owner) bun.OOM!*CookieMapObject {
        var owned = map;
        errdefer owned.deinit();
        const object = try bun.default_allocator.create(CookieMapObject);
        object.* = .{ .map = owned };
        return object;
    }

    pub fn construct(context: bindgen.CallContext(ConstructorSchema), args: bindgen.Args(ConstructorSchema)) bindgen.CallError(ConstructorSchema)!*CookieMapObject {
        if (args.init) |init| {
            if (init == .sequence) {
                var pairs = init.sequence.iterator();
                while (pairs.next()) |pair| {
                    if (pair.value.len() != 2) return context.fail(.invalid_pair, {});
                }
            }
        }
        const map = if (args.init) |init| switch (init) {
            .sequence => |pairs| result: {
                const operation = context.engineIn("cookie_map", "cookieMapCreatePairs");
                break :result try operation.call(.{ .input = try operation.argument("input", pairs) });
            },
            .record => |record| result: {
                const operation = context.engineIn("cookie_map", "cookieMapCreateRecord");
                break :result try operation.call(.{ .input = try operation.argument("input", record) });
            },
            .string => |string| try context.engineIn("cookie_map", "cookieMapCreateString").call(.{ .input = string.operand() }),
        } else try context.engineIn("cookie_map", "cookieMapCreate").call(.{});
        return create(map);
    }

    pub fn destroy(this: *CookieMapObject) void {
        this.map.deinit();
        bun.default_allocator.destroy(this);
    }

    pub fn memoryUsage(this: *const CookieMapObject, _: bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(CookieMapObject) +| bindgen.Engine(MemoryCostSchema).call(.{ .cookieMap = this.map.get() });
    }

    pub fn get(this: *CookieMapObject, context: bindgen.CallContext(GetSchema), args: bindgen.Args(GetSchema)) bun.JSError!bindgen.Return(GetSchema) {
        const name = args.name orelse return null;
        return context.engineIn("cookie_map", "cookieMapGet").call(.{ .cookieMap = this.map.get(), .name = name.operand() });
    }

    pub fn has(this: *CookieMapObject, context: bindgen.CallContext(HasSchema), args: bindgen.Args(HasSchema)) bun.JSError!bool {
        const name = args.name orelse return false;
        var value = context.engineIn("cookie_map", "cookieMapGet").call(.{ .cookieMap = this.map.get(), .name = name.operand() }) orelse return false;
        value.deinit();
        return true;
    }

    pub fn getSize(this: *CookieMapObject, context: bindgen.CallContext(SizeSchema), _: bindgen.Args(SizeSchema)) bun.JSError!usize {
        return context.engineIn("cookie_map", "cookieMapSize").call(.{ .cookieMap = this.map.get() });
    }

    pub fn set(this: *CookieMapObject, context: bindgen.CallContext(SetSchema), args: bindgen.Args(SetSchema)) bun.JSError!void {
        switch (args) {
            .cookie => |input| try context.engineIn("cookie_map", "cookieMapSetCookie").call(.{
                .cookieMap = this.map.get(),
                .cookie = &input.cookie.get(Cookie).resource,
            }),
            .init => |input| try this.setWithOptions(context, input.init.name, input.init.value, @as(?@TypeOf(input.init), input.init)),
            .pair => |input| try this.setWithOptions(context, input.name, @as(?@TypeOf(input.value), input.value), input.options),
        }
    }

    fn setWithOptions(this: *CookieMapObject, context: anytype, name: anytype, value: anytype, options: anytype) bun.JSError!void {
        var cookie = try Cookie.createResource(context, name, value, options);
        defer cookie.deinit();
        try context.engineIn("cookie_map", "cookieMapSetCookie").call(.{
            .cookieMap = this.map.get(),
            .cookie = &cookie,
        });
    }

    pub fn delete(this: *CookieMapObject, context: bindgen.CallContext(DeleteSchema), args: bindgen.Args(DeleteSchema)) bindgen.CallError(DeleteSchema)!void {
        switch (args) {
            .init => |input| {
                const name = input.init.name orelse return context.fail(.name_required, {});
                try this.deleteWithOptions(context, name, @as(?@TypeOf(input.init), input.init));
            },
            .name => |input| {
                const name = input.name orelse return context.fail(.name_required, {});
                try this.deleteWithOptions(context, name, input.options);
            },
        }
    }

    fn deleteWithOptions(this: *CookieMapObject, context: anytype, name: anytype, options: anytype) bun.JSError!void {
        try context.engineIn("cookie_map", "cookieMapDelete").call(.{
            .cookieMap = this.map.get(),
            .name = name.operand(),
            .domain = if (if (options) |o| o.domain orelse null else null) |option| option.operand() else null,
            .path = if (if (options) |o| o.path orelse null else null) |option| option.operand() else null,
        });
    }

    pub fn toSetCookieHeaders(this: *CookieMapObject, context: bindgen.CallContext(HeadersSchema), _: bindgen.Args(HeadersSchema)) bun.JSError!bindgen.Return(HeadersSchema) {
        return context.engineIn("cookie_map", "cookieMapPrepareHeaders").call(.{ .cookieMap = this.map.get() });
    }

    pub fn toJSON(this: *CookieMapObject, context: bindgen.CallContext(JSONSchema), _: bindgen.Args(JSONSchema)) bun.JSError!bindgen.Return(JSONSchema) {
        return context.engineIn("cookie_map", "cookieMapJSON").call(.{ .cookieMap = this.map.get() });
    }

    pub fn inspectCustom(this: *CookieMapObject, context: bindgen.CallContext(InspectSchema), _: bindgen.Args(InspectSchema)) bun.JSError!bindgen.Return(InspectSchema) {
        return context.engineIn("cookie_map", "cookieMapJSON").call(.{ .cookieMap = this.map.get() });
    }

    pub fn entries(this: *CookieMapObject, context: bindgen.CallContext(EntriesSchema), _: bindgen.Args(EntriesSchema)) bun.JSError!bindgen.Return(EntriesSchema) {
        return Iterator.create(context, .{ .cookieMap = this.map.get() }, .entries);
    }

    pub fn keys(this: *CookieMapObject, context: bindgen.CallContext(KeysSchema), _: bindgen.Args(KeysSchema)) bun.JSError!bindgen.Return(KeysSchema) {
        return Iterator.create(context, .{ .cookieMap = this.map.get() }, .keys);
    }

    pub fn values(this: *CookieMapObject, context: bindgen.CallContext(ValuesSchema), _: bindgen.Args(ValuesSchema)) bun.JSError!bindgen.Return(ValuesSchema) {
        return Iterator.create(context, .{ .cookieMap = this.map.get() }, .values);
    }

    pub fn forEach(this: *CookieMapObject, context: bindgen.CallContext(ForEachSchema), args: bindgen.Args(ForEachSchema)) bun.JSError!void {
        return Iterator.forEach("cookieMap", context, args, .{ .cookieMap = this.map.get() });
    }
};

fn wrap(context: bindgen.CallContext(WrapSchema), args: bindgen.Args(WrapSchema)) bun.JSError!bindgen.Return(WrapSchema) {
    return MapBinding.adoptResult(try CookieMapObject.create(args.cookieMap.retain()), context);
}

fn cloneWrapper(context: bindgen.CallContext(CloneWrapperSchema), args: bindgen.Args(CloneWrapperSchema)) bun.JSError!bindgen.Return(CloneWrapperSchema) {
    const map = try context.engineIn("cookie_map", "cookieMapClone").call(.{ .cookieMap = args.value.get(CookieMapObject).map.get() });
    return MapBinding.adoptResult(try CookieMapObject.create(map), context);
}

fn retainFromWrapper(_: bindgen.CallContext(RetainFromWrapperSchema), args: bindgen.Args(RetainFromWrapperSchema)) bun.JSError!bindgen.Return(RetainFromWrapperSchema) {
    return args.value.get(CookieMapObject).map.get().retain();
}

const bun = @import("bun");
const Cookie = @import("./Cookie.zig");
const bindgen = bun.bindgen;
const CookieMapModule = bindgen.Module("cookie_map");
const RetainSchema = CookieMapModule.engineShim("cookieMapRetain");
const MemoryCostSchema = CookieMapModule.engineShim("cookieMapMemoryCost");
const WrapSchema = CookieMapModule.nativeExport("cookieMapWrap");
const CloneWrapperSchema = CookieMapModule.nativeExport("cookieMapCloneWrapper");
const RetainFromWrapperSchema = CookieMapModule.nativeExport("cookieMapRetainFromWrapper");
const MapSchema = bindgen.Module("WebCoreCookies").class("CookieMap");
const MapBinding = bindgen.Class(MapSchema, CookieMapObject);
const ConstructorSchema = MapSchema.constructor();
const GetSchema = MapSchema.member("get");
const HasSchema = MapSchema.member("has");
const SizeSchema = MapSchema.member("size");
const SetSchema = MapSchema.member("set");
const DeleteSchema = MapSchema.member("delete");
const HeadersSchema = MapSchema.member("toSetCookieHeaders");
const JSONSchema = MapSchema.member("toJSON");
const InspectSchema = MapSchema.member("inspectCustom");
const EntriesSchema = MapSchema.member("entries");
const KeysSchema = MapSchema.member("keys");
const ValuesSchema = MapSchema.member("values");
const ForEachSchema = MapSchema.member("forEach");
const Iterator = @import("./StringPairIterator.zig").StringPairIterator(
    bun.bindgen.Module("WebCoreCookies").class("CookieMapIterator"),
    bun.bindgen.Module("cookie_map").engineShim("cookieMapIteratorCreate"),
    bun.bindgen.Module("cookie_map").engineShim("cookieMapIteratorNext"),
);

comptime {
    _ = MapBinding;
    _ = Iterator.Binding;
    _ = bindgen.Fn(WrapSchema, wrap);
    _ = bindgen.Fn(CloneWrapperSchema, cloneWrapper);
    _ = bindgen.Fn(RetainFromWrapperSchema, retainFromWrapper);
}
