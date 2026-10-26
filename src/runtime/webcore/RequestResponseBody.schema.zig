const b = @import("bindgen_schema");
const request_schema = @import("binding_schema_Request");
const response_schema = @import("binding_schema_Response");

const target = b.unionType("RequestResponseBodyTarget", .{
    b.unionMember("response", b.classRef(response_schema.response)),
    b.unionMember("request", b.classRef(request_schema.request)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const functions = .{
    b.function(
        "requestOrResponseHasBodyValue",
        .{b.argument("value", target, .{})},
        b.boolean,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "getCompleteRequestOrResponseBodyValueAsArrayBuffer",
        .{b.argument("value", target, .{})},
        b.optionalUndefined(b.array_buffer_result),
        .{ .backend = .zig, .profile = .exact },
    ),
};

pub const schema = b.module("RequestResponseBody", functions);
