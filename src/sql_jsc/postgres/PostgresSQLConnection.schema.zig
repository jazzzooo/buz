const b = @import("bindgen_schema");
const sql_errors = @import("binding_schema_SQLErrors");

const postgres_connection_ref = b.classRefByName("PostgresSQLConnection", "PostgresSQLConnection");

pub const on_connect_callback = b.callback("PostgresSQLConnectionOnConnectCallback", .{
    b.argument("error", b.null_literal, .{}),
    b.argument("connection", postgres_connection_ref, .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });

pub const on_close_callback = b.callback("PostgresSQLConnectionOnCloseCallback", .{
    b.argument("original", b.invocation_any, .{}),
    b.argument("payload", b.optionalUndefined(sql_errors.postgres_error), .{}),
}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });

const optional_on_connect_callback = b.optionalUndefined(on_connect_callback);
const optional_on_close_callback = b.optionalUndefined(on_close_callback);

const postgres_connection = b.class(
    "PostgresSQLConnection",
    b.illegalConstructor(),
    .{
        b.method("close", .{}, b.none, .{ .implementation = "doClose", .length = 0 }),
        b.getter("connected", b.boolean, .{ .implementation = "getConnected" }),
        b.method("flush", .{}, b.none, .{ .implementation = "doFlush", .length = 0 }),
        b.getter("onclose", optional_on_close_callback, .{ .implementation = "getOnClose", .cache = "onclose", .writable = true }),
        b.getter("onconnect", optional_on_connect_callback, .{ .implementation = "getOnConnect", .cache = "onconnect", .writable = true }),
        b.method("ref", .{}, b.none, .{ .implementation = "doRef", .length = 0 }),
        b.method("unref", .{}, b.none, .{ .implementation = "doUnref", .length = 0 }),
    },
    .{
        b.cachedSlot("onconnect", optional_on_connect_callback, .{ .writable = true }),
        b.cachedSlot("onclose", optional_on_close_callback, .{ .writable = true }),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClasses("PostgresSQLConnection", .{}, .{postgres_connection});
pub const postgres_sql_connection = schema.class("PostgresSQLConnection");
