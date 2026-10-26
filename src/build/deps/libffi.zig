const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "libffi",
    .groups = &.{.{
        .flags = &.{ "-D_GNU_SOURCE", "-DFFI_BUILDING", "-fno-strict-aliasing" },
        .includes = &.{
            .{ .gen = .{ "libffi", "" } },
            .{ .dep = .{ "libffi", "include" } },
            .{ .dep = .{ "libffi", "src/x86" } },
        },
        .files = &.{
            "src/prep_cif.c",
            "src/types.c",
            "src/raw_api.c",
            "src/java_raw_api.c",
            "src/closures.c",
            "src/tramp.c",
            "src/x86/ffi64.c",
            "src/x86/unix64.S",
            "src/x86/ffiw64.c",
            "src/x86/win64.S",
        },
    }},
};
