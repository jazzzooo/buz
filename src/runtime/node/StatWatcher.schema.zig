const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const node_fs_stat = @import("binding_schema_NodeFSStat");

pub const listener_callback = b.callback(
    "NodeFSWatchFileListener",
    .{
        b.argument("current", node_fs_stat.stat_value, .{}),
        b.argument("previous", node_fs_stat.stat_value, .{}),
    },
    b.none,
    .{
        .receiver = null,
        .profile = .exact,
        .retains_async_context = true,
    },
);

const interval_range = b.IntegerRange{ .min = 0, .max = 4294967295 };
const options = b.dictionaryWithOptions("NodeFSWatchFileOptions", .{
    b.dictionaryField("persistent", b.boolean, .{ .default_value = .{ .boolean = true } }),
    b.dictionaryField("bigint", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("interval", b.uint32, .{
        .default_value = .{ .unsigned = 5007 },
        .integer_conversion = .{ .node_validate = interval_range },
    }),
}, .{
    .node_allow_array = true,
    .node_allow_callable = true,
});

const stat_watcher_class = b.class(
    "StatWatcher",
    b.constructor(.{
        archetypes.path("path"),
        b.argument("options", b.optional(options), .{}),
        b.argument("listener", listener_callback, .{}),
    }, .{
        .length = 3,
        .profile = .node,
    }),
    .{
        b.method("close", .{}, b.none, .{ .implementation = "doClose", .length = 0 }),
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
        .memory_usage = .vm,
        .lifecycle = .{ .wrapper_created = true },
    },
);

pub const schema = b.moduleWithClasses("StatWatcher", .{}, .{stat_watcher_class});
pub const stat_watcher = schema.class("StatWatcher");
