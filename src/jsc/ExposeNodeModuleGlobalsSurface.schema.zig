const b = @import("bindgen_schema");
const host = @import("binding_schema_ExposeNodeModuleGlobalsHost");

const ordinary = b.SurfaceMemberOptions{ .attributes = .{} };

fn nodeModule(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunctionGetter(name, host.schema.function(name), ordinary);
}

const globals = b.objectSurface("ExposedNodeModuleGlobals", .{
    nodeModule("ffi"),
    nodeModule("assert"),
    nodeModule("async_hooks"),
    nodeModule("child_process"),
    nodeModule("cluster"),
    nodeModule("dgram"),
    nodeModule("diagnostics_channel"),
    nodeModule("dns"),
    nodeModule("domain"),
    nodeModule("events"),
    nodeModule("fs"),
    nodeModule("http"),
    nodeModule("http2"),
    nodeModule("https"),
    nodeModule("inspector"),
    nodeModule("net"),
    nodeModule("os"),
    nodeModule("path"),
    nodeModule("perf_hooks"),
    nodeModule("punycode"),
    nodeModule("querystring"),
    nodeModule("readline"),
    nodeModule("stream"),
    nodeModule("sys"),
    nodeModule("timers"),
    nodeModule("tls"),
    nodeModule("trace_events"),
    nodeModule("tty"),
    nodeModule("url"),
    nodeModule("util"),
    nodeModule("v8"),
    nodeModule("vm"),
    nodeModule("wasi"),
    nodeModule("sqlite"),
    nodeModule("worker_threads"),
    nodeModule("zlib"),
    nodeModule("constants"),
    nodeModule("string_decoder"),
    nodeModule("buffer"),
    nodeModule("jsc"),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("ExposeNodeModuleGlobalsSurface", .{globals});
