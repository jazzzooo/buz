const b = @import("bindgen_schema");

pub const nullable_int = b.optional(b.int32);

pub const schema = b.module("bindgen_shared", .{});
