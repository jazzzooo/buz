const b = @import("bindgen_schema");

pub const message = b.brandedValueWithBrand(b.cppBrand("NodeIPCMessageValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isNodeIPCMessage",
    .header = "BindgenTypePredicates.h",
}, "string | object | number | boolean | null"), .{
    .error_kind = .type,
    .node_expected_types = &.{ "string", "object", "number", "boolean" },
});

pub const send_errors = b.domainErrors(.{
    b.domainError("missing_message", b.none, .{
        .class = .type_error,
        .code = "ERR_MISSING_ARGS",
        .message = .{ .literal = "The \"message\" argument must be specified" },
    }),
});

const send_callback = b.callback(
    "NodeIPCSendCallback",
    .{b.argument("error", b.optional(b.js_error_instance), .{})},
    b.none,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true, .schedule_next_tick = true },
);
const optional_callback = b.unionType("NodeIPCOptionalSendCallback", .{
    b.unionMember("callback", send_callback),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });

const deferred_message = b.lazy(b.optionalUndefined(message));
const message_order = "IPC options are validated before the message, and callbacks are retained after message validation";
const handle = b.optionalNullish(b.discardAny(.ignored));
const options = b.optionalUndefined(b.js_object);

pub const send_arguments = b.overloads(.{
    b.overloadCaseWithOptions("message_callback", .{
        b.argument("message", deferred_message, .{ .deferred_reason = message_order }),
        b.argument("callback", send_callback, .{}),
    }, .{ .discriminants = &.{1} }),
    b.overloadCaseWithOptions("message_handle_callback", .{
        b.argument("message", deferred_message, .{ .deferred_reason = message_order }),
        b.argument("handle", handle, .{}),
        b.argument("callback", send_callback, .{}),
    }, .{ .discriminants = &.{2} }),
    b.overloadCase("message_handle_options_callback", .{
        b.argument("message", deferred_message, .{ .deferred_reason = message_order }),
        b.argument("handle", handle, .{ .presence = .optional, .missing = .undefined }),
        b.argument("options", options, .{ .presence = .optional, .missing = .undefined }),
        b.argument("callback", optional_callback, .{ .presence = .optional, .missing = .undefined }),
    }),
}, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "message_handle_options_callback" });

pub const schema = b.module("NodeIPC", .{});
