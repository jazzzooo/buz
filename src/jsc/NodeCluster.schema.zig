const b = @import("bindgen_schema");
const subprocess = @import("binding_schema_Subprocess");

const internal_message_callback = b.callback(
    "ClusterInternalMessageCallback",
    .{
        b.argument("message", b.invocation_any, .{}),
        b.argument("handle", b.null_literal, .{}),
    },
    b.none,
    .{ .receiver = null, .profile = .exact },
);

const internal_send_result = b.enumeration("ClusterInternalSendResult", .{
    b.enumerationValue("success", "success"),
    b.enumerationValue("backoff", "backoff"),
    b.enumerationValue("failure", "failure"),
    b.enumerationValue("unavailable", "unavailable"),
});

const functions = .{
    b.function("channelIgnoreOneDisconnectEventListener", .{}, b.boolean, .{
        .backend = .zig,
        .length = 0,
        .profile = .exact,
    }),
    b.function(
        "onInternalMessageChild",
        .{b.argument("callback", internal_message_callback, .{})},
        b.none,
        .{ .backend = .zig, .length = 1, .profile = .node },
    ),
    b.function(
        "onInternalMessagePrimary",
        .{
            b.argument("subprocess", b.classRef(subprocess.subprocess), .{}),
            b.argument("callback", internal_message_callback, .{}),
        },
        b.none,
        .{ .backend = .zig, .length = 2, .profile = .node },
    ),
    b.function(
        "sendHelperChild",
        .{b.argument("message", b.engine_value, .{})},
        internal_send_result,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .node,
        },
    ),
    b.function(
        "sendHelperPrimary",
        .{
            b.argument("subprocess", b.classRef(subprocess.subprocess), .{}),
            b.argument("message", b.engine_value, .{}),
        },
        internal_send_result,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .node,
        },
    ),
    b.function(
        "setRef",
        .{b.argument("enabled", b.boolean, .{})},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .node,
        },
    ),
    b.function(
        "emitProcessErrorEvent",
        .{b.argument("error_value", b.engine_value, .{})},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .missing_required_arguments = .convert_undefined,
            .profile = .exact,
        },
    ),
};

fn nativeExport(comptime name: [:0]const u8, comptime result: b.Type) b.NativeExport {
    return b.nativeExportWithOptions(name, .{}, result, .current_realm_nonthrowing);
}

const native_exports = .{
    nativeExport("refChannelUnlessOverridden", b.none),
    nativeExport("unrefChannelUnlessOverridden", b.none),
    nativeExport("shouldIgnoreOneDisconnectEventListener", b.boolean),
};

const engine_shims = .{
    b.engineShim("processEmitErrorEvent", .{b.argument("value", b.engine_value, .{})}, b.none, .current_realm_throwing),
    b.engineShim("scheduleProcessErrorEvent", .{b.argument("errorValue", b.brandCast(b.js_error_instance, .{ .failure = .assert, .input = .engine_value }), .{})}, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("NodeCluster", functions, .{}, engine_shims, native_exports);
