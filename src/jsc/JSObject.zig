extern const JSC__JSObject__maxInlineCapacity: c_uint;

pub const JSObject = opaque {
    pub inline fn maxInlineCapacity() c_uint {
        return JSC__JSObject__maxInlineCapacity;
    }

    extern fn JSC__JSObject__createEmpty(global: *JSGlobalObject, capacity: usize) *JSObject;
    extern fn JSC__JSObject__createEmptyWithNullPrototype(global: *JSGlobalObject) *JSObject;
    extern fn JSC__JSObject__createObject2(global: *JSGlobalObject, key1: *const ZigString, key2: *const ZigString, value1: JSValue, value2: JSValue) ?*JSObject;
    extern fn JSC__JSObject__getDirectIndex(this: *JSObject, globalThis: *JSGlobalObject, i: u32) JSValue;
    extern fn JSC__JSObject__getIndex(this: *JSObject, globalThis: *JSGlobalObject, i: u32) JSValue;
    extern fn JSC__JSObject__putDirect(this: *JSObject, global: *JSGlobalObject, key: *const ZigString, value: JSValue) void;
    extern fn JSC__JSObject__putDirectBunString(this: *JSObject, global: *JSGlobalObject, key: *const bun.String, value: JSValue) void;
    extern fn JSC__JSObject__putDirectMayBeIndex(this: *JSObject, global: *JSGlobalObject, key: *const bun.String, value: JSValue) void;
    extern fn JSC__JSObject__putDirectToPropertyKey(this: *JSObject, global: *JSGlobalObject, key: JSValue, value: JSValue) void;
    extern fn JSC__JSObject__upsertBunStringArray(this: *JSObject, global: *JSGlobalObject, key: *const bun.String, value: JSValue) JSValue;
    extern fn JSC__JSObject__deleteProperty(this: *JSObject, global: *JSGlobalObject, key: *const ZigString) bool;
    extern fn Bun__JSObject__getCodePropertyVMInquiry(global: *JSGlobalObject, obj: *JSObject) JSValue;
    extern fn JSC__createStructure(global: *jsc.JSGlobalObject, owner: ?*jsc.JSCell, length: u32, slots: [*]const ExternColumnSlot) jsc.JSValue;
    extern fn JSC__JSObject__create(global_object: *JSGlobalObject, length: usize, ctx: *anyopaque, initializer: InitializeCallback) *JSObject;

    pub fn toJS(obj: *JSObject) JSValue {
        return JSValue.fromCell(obj);
    }

    pub fn protect(obj: *JSObject) void {
        obj.toJS().protect();
    }

    pub fn unprotect(obj: *JSObject) void {
        obj.toJS().unprotect();
    }

    pub fn createEmpty(global: *JSGlobalObject, capacity: usize) *JSObject {
        return JSC__JSObject__createEmpty(global, capacity);
    }

    pub fn createEmptyWithNullPrototype(global: *JSGlobalObject) *JSObject {
        return JSC__JSObject__createEmptyWithNullPrototype(global);
    }

    pub fn createObject2(global: *JSGlobalObject, key1: *const ZigString, key2: *const ZigString, value1: JSValue, value2: JSValue) bun.JSError!*JSObject {
        return (try bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSObject__createObject2, .{ global, key1, key2, value1, value2 })) orelse unreachable;
    }

    /// Marshall a struct instance into a JSObject, copying its properties.
    ///
    /// Each field will be encoded with `jsc.toJS`. Fields whose types have a
    /// `toJS` method will have it called to encode.
    ///
    /// This method is equivalent to `Object.create(...)` + setting properties,
    /// and is only intended for creating POJOs.
    pub fn create(pojo: anytype, global: *JSGlobalObject) bun.JSError!*JSObject {
        return createFromStructWithPrototype(@TypeOf(pojo), pojo, global, false);
    }
    /// Marshall a struct into a JSObject, copying its properties. It's
    /// `__proto__` will be `null`.
    ///
    /// Each field will be encoded with `jsc.toJS`. Fields whose types have a
    /// `toJS` method will have it called to encode.
    ///
    /// This is roughly equivalent to creating an object with
    /// `Object.create(null)` and adding properties to it.
    pub fn createNullProto(pojo: anytype, global: *JSGlobalObject) bun.JSError!*JSObject {
        return createFromStructWithPrototype(@TypeOf(pojo), pojo, global, true);
    }

    /// Marshall a struct instance into a JSObject. `pojo` is borrowed.
    ///
    /// Each field will be encoded with `jsc.toJS`. Fields whose types have a
    /// `toJS` method will have it called to encode.
    ///
    /// This method is equivalent to `Object.create(...)` + setting properties,
    /// and is only intended for creating POJOs.
    ///
    /// The object's prototype with either be `null` or `ObjectPrototype`
    /// depending on whether `null_prototype` is set. Prefer using the object
    /// prototype (`null_prototype = false`) unless you have a good reason not
    /// to.
    fn createFromStructWithPrototype(comptime T: type, pojo: T, global: *JSGlobalObject, comptime null_prototype: bool) bun.JSError!*JSObject {
        const info: std.builtin.Type.Struct = @typeInfo(T).@"struct";

        const obj = if (comptime null_prototype)
            createEmptyWithNullPrototype(global)
        else
            createEmpty(global, comptime info.field_names.len);

        inline for (info.field_names) |field_name| {
            const property = @field(pojo, field_name);
            obj.putDirect(
                global,
                field_name,
                try .fromAny(global, @TypeOf(property), property),
            );
        }

        return obj;
    }

    pub fn get(obj: *JSObject, global: *JSGlobalObject, prop: anytype) JSError!?JSValue {
        return obj.toJS().get(global, prop);
    }

    pub fn getOwn(obj: *JSObject, global: *JSGlobalObject, prop: anytype) JSError!?JSValue {
        return obj.toJS().getOwn(global, prop);
    }

    pub fn putDirect(obj: *JSObject, global: *JSGlobalObject, key: anytype, value: JSValue) void {
        const Key = @TypeOf(key);
        if (comptime @typeInfo(Key) == .pointer) {
            const Elem = @typeInfo(Key).pointer.child;
            if (Elem == ZigString) {
                JSC__JSObject__putDirect(obj, global, key, value);
            } else if (Elem == bun.String) {
                if (comptime bun.Environment.isDebug) jsc.markBinding(@src());
                JSC__JSObject__putDirectBunString(obj, global, key, value);
            } else if (std.meta.Elem(Key) == u8) {
                JSC__JSObject__putDirect(obj, global, &ZigString.init(key), value);
            } else {
                @compileError("Unsupported key type in putDirect(). Expected ZigString or bun.String, got " ++ @typeName(Elem));
            }
        } else if (comptime Key == ZigString) {
            JSC__JSObject__putDirect(obj, global, &key, value);
        } else if (comptime Key == bun.String) {
            if (comptime bun.Environment.isDebug) jsc.markBinding(@src());
            JSC__JSObject__putDirectBunString(obj, global, &key, value);
        } else {
            @compileError("Unsupported key type in putDirect(). Expected ZigString or bun.String, got " ++ @typeName(Key));
        }
    }

    pub fn putDirectMayBeIndex(obj: *JSObject, global: *JSGlobalObject, key: *const bun.String, value: JSValue) bun.JSError!void {
        return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSObject__putDirectMayBeIndex, .{ obj, global, key, value });
    }

    pub fn putDirectToPropertyKey(obj: *JSObject, global: *JSGlobalObject, key: JSValue, value: JSValue) bun.JSError!void {
        return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSObject__putDirectToPropertyKey, .{ obj, global, key, value });
    }

    pub fn putBunStringOneOrArray(obj: *JSObject, global: *JSGlobalObject, key: *const bun.String, value: JSValue) bun.JSError!JSValue {
        return bun.jsc.fromJSHostCall(global, @src(), JSC__JSObject__upsertBunStringArray, .{ obj, global, key, value });
    }

    pub fn deleteProperty(obj: *JSObject, global: *JSGlobalObject, key: anytype) bun.JSError!bool {
        const Key = @TypeOf(key);
        if (comptime @typeInfo(Key) == .pointer and std.meta.Elem(Key) == u8) {
            return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSObject__deleteProperty, .{ obj, global, &ZigString.init(key) });
        } else if (comptime Key == ZigString) {
            return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSObject__deleteProperty, .{ obj, global, &key });
        } else if (comptime @typeInfo(Key) == .pointer and @typeInfo(Key).pointer.child == ZigString) {
            return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSObject__deleteProperty, .{ obj, global, key });
        } else {
            @compileError("Unsupported key type in deleteProperty(). Expected ZigString or string literal, got " ++ @typeName(Key));
        }
    }

    /// When the GC sees a JSValue referenced in the stack, it knows not to free it
    /// This mimics the implementation in JavaScriptCore's C++
    pub inline fn ensureStillAlive(this: *JSObject) void {
        std.mem.doNotOptimizeAway(this);
    }

    pub const ExternColumnSlot = extern struct {
        tag: Tag = .duplicate,
        value: extern union {
            index: u32,
            name: bun.String,
        },

        pub const Tag = enum(u8) {
            duplicate,
            indexed,
            named,
            named_offset,
        };

        pub fn string(this: *ExternColumnSlot) ?*bun.String {
            return switch (this.tag) {
                .named => &this.value.name,
                else => null,
            };
        }

        pub fn deinit(this: *ExternColumnSlot) void {
            if (this.string()) |str| {
                str.deref();
            }
        }
    };

    pub fn createStructure(global: *JSGlobalObject, owner: ?jsc.JSValue, slots: []const ExternColumnSlot) JSValue {
        jsc.markBinding(@src());
        return JSC__createStructure(global, if (owner) |value| value.asCell() else null, @intCast(slots.len), slots.ptr);
    }

    const InitializeCallback = *const fn (ctx: *anyopaque, obj: *JSObject, global: *JSGlobalObject) callconv(.c) void;

    pub fn Initializer(comptime Ctx: type, comptime func: fn (*Ctx, obj: *JSObject, global: *JSGlobalObject) bun.JSError!void) type {
        return struct {
            pub fn call(this: *anyopaque, obj: *JSObject, global: *JSGlobalObject) callconv(.c) void {
                func(@ptrCast(@alignCast(this)), obj, global) catch |err| bun.jsc.host_fn.voidFromJSError(err, global);
            }
        };
    }

    pub fn createWithInitializer(comptime Ctx: type, creator: *Ctx, global: *JSGlobalObject, length: usize) *JSObject {
        const Type = Initializer(Ctx, Ctx.create);
        return JSC__JSObject__create(global, length, creator, Type.call);
    }

    pub fn getIndex(this: *JSObject, globalThis: *JSGlobalObject, i: u32) JSError!JSValue {
        // we don't use fromJSHostCall, because it will assert that if there is an exception
        // then the JSValue is zero. the function this ends up calling can return undefined
        // with an exception:
        // https://github.com/oven-sh/WebKit/blob/397dafc9721b8f8046f9448abb6dbc14efe096d3/Source/JavaScriptCore/runtime/JSObjectInlines.h#L112
        var scope: jsc.TopExceptionScope = undefined;
        scope.init(globalThis, @src());
        defer scope.deinit();
        const value = JSC__JSObject__getIndex(this, globalThis, i);
        try scope.returnIfException();
        bun.assert(value != .zero);
        return value;
    }

    pub fn getDirectIndex(this: *JSObject, globalThis: *JSGlobalObject, i: u32) JSValue {
        return JSC__JSObject__getDirectIndex(this, globalThis, i);
    }

    pub fn putDirectStringOrStringArray(this: *JSObject, global: *JSGlobalObject, key: *const ZigString, values: []const ZigString) bun.JSError!void {
        return bun.cpp.JSC__JSObject__putDirectStringOrStringArray(this, global, key, values.ptr, values.len);
    }

    /// This will not call getters or be observable from JavaScript.
    pub fn getCodePropertyVMInquiry(obj: *JSObject, global: *JSGlobalObject) ?JSValue {
        const v = Bun__JSObject__getCodePropertyVMInquiry(global, obj);
        if (v == .zero) return null;
        return v;
    }
};

const std = @import("std");

const bun = @import("bun");
const JSError = bun.JSError;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;
