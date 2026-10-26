const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const system_error = b.systemError("system");

const listener_event = b.enumeration("NodeFSWatchListenerEvent", .{
    b.enumerationValue("rename", "rename"),
    b.enumerationValue("change", "change"),
    b.enumerationValue("error", "error"),
    b.enumerationValue("abort", "abort"),
    b.enumerationValue("close", "close"),
});

const listener_value = b.unionType("NodeFSWatchListenerValue", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.node_buffer),
    b.unionMember("opaque", b.invocation_any),
    b.unionMember("undefined_value", b.undefined_literal),
}, .{ .ordered = true });

pub const listener_callback = b.callback(
    "NodeFSWatchListener",
    .{
        b.argument("eventType", listener_event, .{}),
        b.argument("value", listener_value, .{}),
    },
    b.none,
    .{
        .receiver = null,
        .profile = .exact,
        .retains_async_context = true,
    },
);

const options = b.dictionaryWithOptions("NodeFSWatchOptions", .{
    b.dictionaryField("persistent", b.boolean, .{ .default_value = .{ .boolean = true } }),
    b.dictionaryField("recursive", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("encoding", b.optionalFalsy(archetypes.node_encoding), .{ .default_value = .null }),
    b.dictionaryField("signal", b.abort_signal, .{}),
    b.dictionaryField("verbose", b.boolean, .{ .default_value = .{ .boolean = false } }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const fs_watcher_class = b.class(
    "FSWatcher",
    b.constructor(.{
        archetypes.path("path"),
        b.argument("options", options, .{}),
        b.argument("listener", listener_callback, .{}),
    }, .{
        .length = 3,
        .profile = .node,
        .errors = b.domainErrors(.{system_error}),
    }),
    .{
        b.method("close", .{}, b.none, .{ .implementation = "doClose", .length = 0 }),
        b.method("hasRef", .{}, b.boolean, .{ .length = 0 }),
        b.method("ref", .{}, b.none, .{ .implementation = "doRef", .length = 0 }),
        b.method("unref", .{}, b.none, .{ .implementation = "doUnref", .length = 0 }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("FSWatcher", .{}, .{fs_watcher_class});
pub const fs_watcher = schema.class("FSWatcher");
