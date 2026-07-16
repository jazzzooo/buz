//! sqlite compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "sqlite",
    .in_tree = true,
    .groups = &.{
        .{
            .flags = &.{ "-DSQLITE_ENABLE_COLUMN_METADATA", "-DSQLITE_MAX_VARIABLE_NUMBER=250000", "-DSQLITE_ENABLE_RTREE=1", "-DSQLITE_ENABLE_FTS3=1", "-DSQLITE_ENABLE_FTS3_PARENTHESIS=1", "-DSQLITE_ENABLE_FTS5=1", "-DSQLITE_ENABLE_JSON1=1", "-DSQLITE_ENABLE_MATH_FUNCTIONS=1", "-DSQLITE_ENABLE_UPDATE_DELETE_LIMIT=1", "-DSQLITE_UDL_CAPABLE_PARSER=1", "-Wno-incompatible-pointer-types-discards-qualifiers" },
            .includes = &.{.{ .repo = "src/jsc/bindings/sqlite" }},
            .files = &.{
                "src/jsc/bindings/sqlite/sqlite3.c",
            },
        },
    },
};
