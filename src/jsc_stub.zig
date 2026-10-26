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
pub const JSGlobalObject = opaque {};
pub const JSValue = enum(i64) {
    js_undefined = 0xa,
    zero = 0,
    _,
};
pub const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

const bun = @import("bun");
const std = @import("std");
