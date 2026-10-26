const b = @import("bindgen_schema");

const output = b.dictionary("ShellInterpreterOutput", .{
    b.dictionaryField("exitCode", b.uint16, .{ .required = true }),
    b.dictionaryField("stdout", b.node_buffer, .{ .required = true }),
    b.dictionaryField("stderr", b.node_buffer, .{ .required = true }),
});

const shell_interpreter_class = b.class(
    "ShellInterpreter",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("isRunning", .{}, b.boolean, .{ .length = 0 }),
        b.method("run", .{}, output, .{
            .errors = b.domainErrors(.{
                b.systemError("system"),
                b.domainError("already_started", b.none, .{
                    .class = .generic_error,
                    .message = .{ .literal = "Shell interpreter has already started" },
                }),
            }),
            .completion = .{
                .retention = .strong,
                .sender_drop = .{ .reject = "Shell interpreter stopped before completion" },
            },
            .length = 0,
        }),
        b.method("started", .{}, b.boolean, .{ .implementation = "getStarted", .length = 0 }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .any,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("ShellInterpreter", .{}, .{shell_interpreter_class});
pub const shell_interpreter = schema.class("ShellInterpreter");
