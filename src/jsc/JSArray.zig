pub const JSArray = opaque {
    extern fn JSC__JSArray__create(*JSGlobalObject, [*]const JSValue, usize) ?*JSArray;

    pub fn create(global: *JSGlobalObject, items: []const JSValue) bun.JSError!*JSArray {
        return (try bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSArray__create, .{ global, items.ptr, items.len })) orelse unreachable;
    }

    extern fn JSC__JSArray__createEmpty(*JSGlobalObject, usize) ?*JSArray;

    pub fn createEmpty(global: *JSGlobalObject, len: usize) bun.JSError!*JSArray {
        return (try bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSArray__createEmpty, .{ global, len })) orelse unreachable;
    }

    extern fn JSC__JSArray__putDirectIndex(*JSArray, *JSGlobalObject, u32, JSValue) void;

    pub fn putDirectIndex(array: *JSArray, global: *JSGlobalObject, index: u32, value: JSValue) bun.JSError!void {
        return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSArray__putDirectIndex, .{ array, global, index, value });
    }

    extern fn JSC__JSArray__push(*JSArray, *JSGlobalObject, JSValue) void;

    pub fn push(array: *JSArray, global: *JSGlobalObject, value: JSValue) bun.JSError!void {
        return bun.jsc.fromJSHostCallGeneric(global, @src(), JSC__JSArray__push, .{ array, global, value });
    }

    pub fn toObject(array: *JSArray) *jsc.JSObject {
        return @ptrCast(array);
    }

    pub fn toJS(array: *JSArray) JSValue {
        return JSValue.fromCell(array);
    }

    pub fn getLength(array: *JSArray, global: *JSGlobalObject) bun.JSError!usize {
        return array.toJS().getLength(global);
    }

    pub fn getIndex(array: *JSArray, global: *JSGlobalObject, index: u32) bun.JSError!JSValue {
        return array.toObject().getIndex(global, index);
    }

    pub fn getDirectIndex(array: *JSArray, global: *JSGlobalObject, index: u32) JSValue {
        return array.toObject().getDirectIndex(global, index);
    }

    pub fn toFmt(array: *JSArray, formatter: *jsc.ConsoleObject.Formatter) jsc.ConsoleObject.Formatter.ZigFormatter {
        return array.toJS().toFmt(formatter);
    }

    pub fn protect(array: *JSArray) void {
        array.toJS().protect();
    }

    pub fn unprotect(array: *JSArray) void {
        array.toJS().unprotect();
    }

    pub fn ensureStillAlive(array: *JSArray) void {
        std.mem.doNotOptimizeAway(array);
    }

    pub fn iterator(array: *JSArray, global: *JSGlobalObject) bun.JSError!JSArrayIterator {
        return JSValue.fromCell(array).arrayIterator(global);
    }
};

const bun = @import("bun");
const std = @import("std");
const JSArrayIterator = @import("./JSArrayIterator.zig").JSArrayIterator;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
