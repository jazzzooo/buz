const b = @import("bindgen_schema");

const invalid_semver_errors = b.domainErrors(.{
    b.domainError("invalid_semver", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

fn function(comptime name: []const u8, comptime result: b.Type, comptime errors: b.DomainErrors) b.Function {
    return b.function(
        name,
        .{
            b.argument("left", b.dom_string, .{}),
            b.argument("right", b.dom_string, .{}),
        },
        result,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .webidl,
            .errors = errors,
            .missing_required_arguments = .{ .failure = .{ .kind = .generic_error, .message = "Expected two arguments" } },
        },
    );
}

const functions = .{
    function("satisfies", b.boolean, b.no_domain_errors),
    function("order", b.int32, invalid_semver_errors),
};

pub const schema = b.module("SemverObject", functions);
