const b = @import("bindgen_schema");

const domain = b.unionType("NodeURLDomain", .{
    b.unionMember("null_value", b.null_literal),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("string", b.dom_string),
}, .{ .ordered = true, .no_match_error = .{ .kind = .type_error, .message = "the \"domain\" argument must be a string" } });

fn domainFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{b.argument("domain", domain, .{})},
        domain,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .{ .failure = .{ .kind = .type_error, .message = name ++ " needs 1 argument" } },
        },
    );
}

pub const schema = b.moduleWithEngineShims("NodeURL", .{
    domainFunction("domainToASCII"),
    domainFunction("domainToUnicode"),
}, .{b.engineShim("convertDomain", .{
    b.argument("domain", b.dom_string, .{}),
    b.argument("toASCII", b.boolean, .{}),
}, b.optional(b.dom_string), .vm_thread_allocating)});
