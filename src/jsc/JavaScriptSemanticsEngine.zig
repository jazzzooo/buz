pub const javascript_semantics = JavaScriptSemantics{
    .vtable = &vtable,
};

const vtable = JavaScriptSemantics.VTable{
    .join_url = struct {
        fn call(base: bun.String, relative: bun.String) bun.OOM!bun.String {
            return jsc.URL.join(base, relative);
        }
    }.call,
    .normalize_url = struct {
        fn call(input: bun.String) bun.OOM!bun.String {
            return jsc.URL.hrefFromString(input);
        }
    }.call,
    .parse_url = struct {
        fn call(input: []const u8) bun.OOM!?JavaScriptSemantics.ParsedURL {
            const input_string = bun.String.cloneUTF8(input);
            defer input_string.deref();

            var url = (try jsc.URL.fromString(input_string)) orelse return null;
            defer url.deinit();

            const href = try url.href();
            errdefer href.deref();
            const protocol = try url.protocol();
            errdefer protocol.deref();
            const hostname = try url.hostname();
            errdefer hostname.deref();
            const pathname = try url.pathname();
            errdefer pathname.deref();
            return .{
                .href = href,
                .protocol = protocol,
                .hostname = hostname,
                .pathname = pathname,
                .fragment = try url.fragmentIdentifier(),
            };
        }
    }.call,
    .parse_es5_date = struct {
        fn call(input: []const u8) ?f64 {
            return jsc.wtf.parseES5Date(input) catch null;
        }
    }.call,
    .string_to_number = struct {
        fn call(input: []const u8) f64 {
            return bun.bindgen.Engine(StringToNumberSchema).call(.{ .bytes = bun.bindgen.BytesOperand.fromSlice(input) });
        }
    }.call,
    .pow = struct {
        fn call(base: f64, exponent: f64) f64 {
            return jsc.math.pow(base, exponent);
        }
    }.call,
    .file_url_from_path = struct {
        fn call(allocator: std.mem.Allocator, path: []const u8) bun.OOM![]u8 {
            const value = bun.String.cloneUTF8(path);
            defer value.deref();
            const url = try jsc.URL.fileURLFromString(value);
            defer url.deref();
            return url.toOwnedSlice(allocator);
        }
    }.call,
};

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const JavaScriptSemantics = @import("../bun_core/JavaScriptSemantics.zig");
const StringToNumberSchema = bun.bindgen.Module("js_strings").engineShim("jsStringToNumber");
