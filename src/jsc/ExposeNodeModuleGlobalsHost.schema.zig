const b = @import("bindgen_schema");

fn moduleGetter(comptime name: []const u8) b.Function {
    return b.function(name, .{}, b.engine_value, .{ .backend = .cpp, .length = 0, .profile = .exact });
}

const functions = .{
    moduleGetter("ffi"),
    moduleGetter("assert"),
    moduleGetter("async_hooks"),
    moduleGetter("child_process"),
    moduleGetter("cluster"),
    moduleGetter("dgram"),
    moduleGetter("diagnostics_channel"),
    moduleGetter("dns"),
    moduleGetter("domain"),
    moduleGetter("events"),
    moduleGetter("fs"),
    moduleGetter("http"),
    moduleGetter("http2"),
    moduleGetter("https"),
    moduleGetter("inspector"),
    moduleGetter("net"),
    moduleGetter("os"),
    moduleGetter("path"),
    moduleGetter("perf_hooks"),
    moduleGetter("punycode"),
    moduleGetter("querystring"),
    moduleGetter("readline"),
    moduleGetter("stream"),
    moduleGetter("sys"),
    moduleGetter("timers"),
    moduleGetter("tls"),
    moduleGetter("trace_events"),
    moduleGetter("tty"),
    moduleGetter("url"),
    moduleGetter("util"),
    moduleGetter("v8"),
    moduleGetter("vm"),
    moduleGetter("wasi"),
    moduleGetter("sqlite"),
    moduleGetter("worker_threads"),
    moduleGetter("zlib"),
    moduleGetter("constants"),
    moduleGetter("string_decoder"),
    moduleGetter("buffer"),
    moduleGetter("jsc"),
};

const engine_shims = .{
    b.engineShim("exposeNodeModuleGlobals", .{}, b.none, .current_realm_nonthrowing),
    b.engineShim("setupGlobalRequire", .{b.argument("cwd", b.dom_string, .{})}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("ExposeNodeModuleGlobalsHost", functions, .{}, engine_shims, .{});
