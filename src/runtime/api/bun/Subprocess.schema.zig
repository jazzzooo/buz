const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const resource_usage = @import("binding_schema_ResourceUsage");
const terminal = @import("binding_schema_Terminal");
const node_ipc = @import("binding_schema_NodeIPC");

const nullable_dom_string_or_int32 = b.optionalNullish(b.unionType("DOMStringOrInt32", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("integer", b.int32),
}, .{ .ordered = true }));
const nullable_doubles = b.sequence(b.optionalNullish(b.double));

const optional_terminal_ref = b.optionalUndefined(b.classRef(terminal.terminal));
const subprocess_ref = b.classRefByName("Subprocess", "Subprocess");
const subprocess_errors = b.domainErrors(.{b.systemError("system")});
const subprocess_exited_promise = b.promise(b.int32);

const subprocess_readable_output = b.unionType("SubprocessReadableOutput", .{
    b.unionMember("stream", b.readable_stream),
    b.unionMember("node_buffer", b.node_buffer),
    b.unionMember("fd", b.int32),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

const subprocess_writable_output = b.unionType("SubprocessWritableOutput", .{
    b.unionMember("sink", b.classRefByName("JSSink", "FileSink")),
    b.unionMember("readable_stream", b.readable_stream),
    b.unionMember("fd", b.int32),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
}, .{ .ordered = true });

pub const ipc_callback = b.callback("SubprocessIPCCallback", .{
    b.argument("message", b.invocation_any, .{}),
    b.argument("subprocess", subprocess_ref, .{}),
    b.argument("handle", b.undefined_literal, .{}),
}, b.none, .{ .receiver = subprocess_ref, .profile = .exact, .retains_async_context = true });

pub const on_disconnect_callback = b.callback("SubprocessOnDisconnectCallback", .{
    b.argument("firstTime", b.boolean, .{}),
}, b.none, .{ .receiver = subprocess_ref, .profile = .exact, .retains_async_context = true });

pub const on_exit_callback = b.callback("SubprocessOnExitCallback", .{
    b.argument("subprocess", subprocess_ref, .{}),
    b.argument("exitCode", archetypes.nullable_int32, .{}),
    b.argument("signalCode", nullable_dom_string_or_int32, .{}),
    b.argument("error", b.optionalUndefined(b.js_error_instance), .{}),
}, b.none, .{
    .receiver = subprocess_ref,
    .profile = .exact,
    .retains_async_context = true,
});

const subprocess_class = b.class(
    "Subprocess",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("__asyncDispose", .{}, b.none, .{
            .errors = subprocess_errors,
            .implementation = "bindAsyncDisposeNative",
            .length = 0,
            .private_symbol = "asyncDisposeNative",
        }),
        b.method("asyncDispose", .{}, b.promise(b.none), .{
            .backend = .builtin,
            .builtin = "subprocessAsyncDisposeCodeGenerator",
            .length = 0,
            .symbol = .async_dispose,
        }),
        b.getter("connected", b.boolean, .{ .implementation = "bindGetConnected" }),
        b.method("disconnect", .{}, b.none, .{ .implementation = "bindDisconnect", .length = 0 }),
        b.getter("exitCode", archetypes.nullable_int32, .{ .implementation = "bindGetExitCode" }),
        b.getter("exited", b.int32, .{
            .cache = "exited",
            .completion = .{
                .retention = .strong,
                .sender_drop = .cancel,
            },
            .errors = subprocess_errors,
            .implementation = "bindGetExited",
        }),
        b.method(
            "kill",
            .{b.argument("signal", archetypes.subprocess_signal, .{ .presence = .optional, .missing = .omitted })},
            b.none,
            .{ .errors = subprocess_errors, .implementation = "bindKill", .length = 1 },
        ),
        b.getter("killed", b.boolean, .{ .implementation = "bindGetKilled" }),
        b.getter("pid", b.int32, .{ .implementation = "bindGetPid" }),
        b.getter("readable", subprocess_readable_output, .{
            .errors = subprocess_errors,
            .implementation = "bindGetReadable",
            .cache = "stdout",
        }),
        b.method("ref", .{}, b.none, .{ .implementation = "bindRef", .length = 0 }),
        b.method("resourceUsage", .{}, b.optionalUndefined(b.classRef(resource_usage.resource_usage)), .{ .implementation = "bindResourceUsage", .length = 0 }),
        b.method(
            "send",
            node_ipc.send_arguments,
            b.boolean,
            .{
                .implementation = "bindSend",
                .length = 1,
                .profile = .node,
                .errors = node_ipc.send_errors,
                .missing_required_arguments = .convert_undefined,
            },
        ),
        b.getter("signalCode", nullable_dom_string_or_int32, .{ .implementation = "bindGetSignalCode" }),
        b.getter("stderr", subprocess_readable_output, .{
            .errors = subprocess_errors,
            .implementation = "bindGetStderr",
            .cache = "stderr",
        }),
        b.getter("stdin", subprocess_writable_output, .{
            .errors = subprocess_errors,
            .implementation = "bindGetStdin",
            .cache = "stdin",
        }),
        b.getter("stdio", nullable_doubles, .{ .implementation = "bindGetStdio" }),
        b.getter("stdout", subprocess_readable_output, .{
            .errors = subprocess_errors,
            .implementation = "bindGetStdout",
            .cache = "stdout",
        }),
        b.getter("terminal", optional_terminal_ref, .{ .implementation = "bindGetTerminal", .cache = "terminal" }),
        b.method("unref", .{}, b.none, .{ .implementation = "bindUnref", .length = 0 }),
        b.getter("writable", subprocess_writable_output, .{
            .errors = subprocess_errors,
            .implementation = "bindGetWritable",
            .cache = "stdin",
        }),
    },
    .{
        b.cachedSlot("onExitCallback", on_exit_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("onDisconnectCallback", on_disconnect_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("ipcCallback", ipc_callback, .{ .writable = true, .exposed = false }),
        b.cachedSlot("stdout", subprocess_readable_output, .{ .writable = true }),
        b.cachedSlot("stderr", subprocess_readable_output, .{ .writable = true }),
        b.cachedSlot("stdin", subprocess_writable_output, .{ .writable = true }),
        b.cachedSlot("terminal", optional_terminal_ref, .{ .writable = true }),
        b.cachedSlot("exited", subprocess_exited_promise, .{}),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("Subprocess", .{}, .{subprocess_class});
pub const subprocess = schema.class("Subprocess");
