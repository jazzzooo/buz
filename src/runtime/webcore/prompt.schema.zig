const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

fn optionalDOMString(comptime name: []const u8) b.Argument {
    return b.argument(name, b.dom_string, .{ .presence = .optional, .missing = .omitted });
}

const functions = .{
    b.function(
        "alert",
        .{optionalDOMString("message")},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .webidl },
    ),
    b.function(
        "confirm",
        .{optionalDOMString("message")},
        b.boolean,
        .{ .backend = .zig, .length = 1, .profile = .webidl },
    ),
    b.function(
        "prompt",
        .{
            optionalDOMString("message"),
            optionalDOMString("default_value"),
        },
        archetypes.nullable_dom_string,
        .{ .backend = .zig, .length = 1, .profile = .webidl },
    ),
};

pub const schema = b.module("Prompt", functions);
