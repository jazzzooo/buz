const b = @import("bindgen_schema");
const build_message = @import("binding_schema_BuildMessage");
const resolve_message = @import("binding_schema_ResolveMessage");

const build = b.classRef(build_message.build_message);
const resolve = b.classRef(resolve_message.resolve_message);
const diagnostic = b.unionType("DiagnosticMessage", .{
    b.unionMember("build", build),
    b.unionMember("resolve", resolve),
}, .{ .ordered = true });

pub fn errors(comptime aggregate_message: []const u8) b.DomainErrors {
    return b.domainErrors(.{
        b.classError("build_message", build),
        b.classError("resolve_message", resolve),
        b.aggregateError("diagnostics", b.sequence(diagnostic), .{ .message = aggregate_message }),
    });
}

pub const schema = b.module("DiagnosticErrors", .{});
