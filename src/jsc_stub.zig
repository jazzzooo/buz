// For WASM builds
pub const C = struct {};
pub const WebCore = struct {};
pub const Jest = struct {};
pub const API = struct {
    pub const Transpiler = struct {};
};
pub const Node = struct {
    pub const Encoding = enum(u8) {
        utf8,
        ucs2,
        utf16le,
        latin1,
        ascii,
        base64,
        base64url,
        hex,
        buffer,
    };
};

pub const VirtualMachine = struct {};
pub const RuntimeTranspilerCache = struct {
    input_hash: ?u64 = null,
    exports_kind: bun.ast.ExportsKind = .none,

    pub fn put(_: *@This(), _: []const u8, _: []const u8, _: []const u8) void {}
};
pub const JSGlobalObject = opaque {};
pub const JSValue = enum(i64) {
    js_undefined = 0xa,
    zero = 0,
    _,
};
pub const ZigString = @import("./jsc/ZigString.zig").ZigString;
pub const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;
pub const MIN_SAFE_INTEGER: i64 = -MAX_SAFE_INTEGER;

pub fn markBinding(_: std.builtin.SourceLocation) void {}

pub fn fromJSHostCall(
    _: *JSGlobalObject,
    _: std.builtin.SourceLocation,
    comptime function: anytype,
    _: anytype,
) bun.JSError!@typeInfo(@TypeOf(function)).@"fn".return_type.? {
    return error.JSError;
}

const bun = @import("bun");
const std = @import("std");
