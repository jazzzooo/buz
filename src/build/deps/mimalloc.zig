//! mimalloc compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "mimalloc",
    .groups = &.{
        .{
            .flags = &.{ "-fno-c++-static-destructors", "-fPIC", "-DMI_STATIC_LIB", "-DMI_SKIP_COLLECT_ON_EXIT=1", "-DMI_NO_PROCESS_DETACH=1", "-DMI_DEFAULT_ALLOW_THP=0", "-DMI_DEBUG=3", "-fvisibility=hidden", "-Wno-deprecated", "-Wno-static-in-inline", "-DMI_CMAKE_BUILD_TYPE=debug", "-ftls-model=initial-exec", "-x", "c++" },
            .flags_release = &.{ "-fno-c++-static-destructors", "-fPIC", "-DMI_STATIC_LIB", "-DMI_SKIP_COLLECT_ON_EXIT=1", "-DMI_NO_PROCESS_DETACH=1", "-DMI_BUILD_RELEASE", "-DMI_DEFAULT_ALLOW_THP=0", "-DMI_MALLOC_OVERRIDE", "-fvisibility=hidden", "-Wno-deprecated", "-Wno-static-in-inline", "-DMI_CMAKE_BUILD_TYPE=release", "-ftls-model=initial-exec", "-fno-builtin-malloc", "-x", "c++" },
            .includes = &.{.{ .dep = .{ "mimalloc", "include" } }},
            .files = &.{
                "src/static.c",
            },
        },
    },
};
