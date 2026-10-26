const b = @import("bindgen_schema");
const deferred_received_data = "the upgraded stream checks shutdown state before converting an optional received payload";

const buffer_or_nullish_or_invalid = b.unionType("BufferOrNullishOrInvalid", .{
    b.unionMember("buffer", b.buffer(.lease)),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });

fn callback(comptime name: []const u8, comptime arguments: anytype) b.Function {
    return b.function(
        name,
        arguments,
        b.none,
        .{
            .backend = .zig,
            .length = 0,
            .profile = .exact,
            .callback_data = b.callbackData("api.socket.UpgradedDuplex"),
        },
    );
}

const functions = .{
    callback(
        "onReceivedData",
        .{b.argument("data", b.lazy(buffer_or_nullish_or_invalid), .{ .presence = .optional, .missing = .omitted, .deferred_reason = deferred_received_data })},
    ),
    callback("onEnd", .{}),
    callback("onWritable", .{}),
    callback("onClose", .{}),
};

const engine_shims = .{
    b.engineShim("createHandlerArray", .{
        b.argument("onData", b.any, .{}),
        b.argument("onEnd", b.any, .{}),
        b.argument("onWritable", b.any, .{}),
        b.argument("onClose", b.any, .{}),
    }, b.js_array, .current_realm_throwing),
    b.engineShim("upgradedDuplexCall", .{
        b.argument("duplex", b.js_object, .{}),
        b.argument("data", b.optional(b.buffer(.copy)), .{}),
        b.argument("write", b.boolean, .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithEngineShims("UpgradedDuplex", functions, engine_shims);
