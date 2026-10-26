const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const shell_syntax = b.class(
    "ShellSyntax",
    b.constructor(.{}, .{ .exposure = .never }),
    .{},
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .any,
        .last_release = b.sweep("Shell syntax owns only an arena of native AST nodes, strings, and object indices; destruction only frees native allocations"),
    },
);

const parsed_shell_script_class = b.class(
    "ParsedShellScript",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method(
            "setCwd",
            .{b.argument("cwd", b.dom_string, .{})},
            b.none,
            .{ .length = 1 },
        ),
        b.method(
            "setEnv",
            .{b.argument("env", archetypes.environment_variables, .{})},
            b.none,
            .{ .length = 1 },
        ),
        b.method(
            "setQuiet",
            .{b.argument("quiet", b.boolean, .{ .presence = .optional })},
            b.none,
            .{ .length = 1 },
        ),
    },
    .{
        b.cachedSlot("syntax", b.optional(b.classRefByName("ParsedShellScript", "ShellSyntax")), .{ .writable = true, .exposed = false }),
    },
    .{
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
    },
);

pub const schema = b.moduleWithClasses("ParsedShellScript", .{}, .{ shell_syntax, parsed_shell_script_class });
pub const parsed_shell_script = schema.class("ParsedShellScript");
