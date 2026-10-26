const JavaScriptSemantics = @This();

vtable: *const VTable,

pub const VTable = struct {
    join_url: *const fn (bun.String, bun.String) bun.OOM!bun.String,
    normalize_url: *const fn (bun.String) bun.OOM!bun.String,
    parse_url: *const fn ([]const u8) bun.OOM!?ParsedURL,
    parse_es5_date: *const fn ([]const u8) ?f64,
    string_to_number: *const fn ([]const u8) f64,
    pow: *const fn (f64, f64) f64,
    file_url_from_path: *const fn (std.mem.Allocator, []const u8) bun.OOM![]u8,
};

pub const ParsedURL = struct {
    href: bun.String,
    protocol: bun.String,
    hostname: bun.String,
    pathname: bun.String,
    fragment: bun.String,

    pub fn deinit(this: *const ParsedURL) void {
        this.href.deref();
        this.protocol.deref();
        this.hostname.deref();
        this.pathname.deref();
        this.fragment.deref();
    }
};

pub fn joinURL(this: JavaScriptSemantics, base: bun.String, relative: bun.String) bun.OOM!bun.String {
    return this.vtable.join_url(base, relative);
}

pub fn normalizeURL(this: JavaScriptSemantics, input: bun.String) bun.OOM!bun.String {
    return this.vtable.normalize_url(input);
}

pub fn parseURL(this: JavaScriptSemantics, input: []const u8) bun.OOM!?ParsedURL {
    return this.vtable.parse_url(input);
}

pub fn parseES5Date(this: JavaScriptSemantics, input: []const u8) ?f64 {
    return this.vtable.parse_es5_date(input);
}

pub fn stringToNumber(this: JavaScriptSemantics, input: []const u8) f64 {
    return this.vtable.string_to_number(input);
}

pub fn pow(this: JavaScriptSemantics, base: f64, exponent: f64) f64 {
    return this.vtable.pow(base, exponent);
}

pub fn fileURLFromPath(this: JavaScriptSemantics, allocator: std.mem.Allocator, path: []const u8) bun.OOM![]u8 {
    return this.vtable.file_url_from_path(allocator, path);
}

const bun = @import("bun");
const std = @import("std");
