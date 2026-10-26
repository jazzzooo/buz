const b = @import("bindgen_schema");

const done_callback_class = b.class(
    "DoneCallback",
    b.constructor(.{}, .{ .exposure = .never }),
    .{},
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const functions = .{
    b.function(
        "done",
        .{b.argument("value", b.optionalNullish(b.engine_value), .{ .presence = .optional, .missing = .omitted })},
        b.none,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
            .this_value_type = b.classRefByName("DoneCallback", "DoneCallback"),
        },
    ),
};

pub const schema = b.moduleWithClasses("DoneCallback", functions, .{done_callback_class});
pub const done_callback = schema.class("DoneCallback");
