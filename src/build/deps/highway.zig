//! highway compile recipe. Hand-maintained; update when bumping the dep.

const m = @import("deps.zig");

pub const dep: m.Dep = .{
    .name = "highway",
    .groups = &.{
        .{
            .cxx = true,
            .flags = &.{ "-fno-c++-static-destructors", "-fPIC", "-DHWY_STATIC_DEFINE", "-fno-exceptions", "-fmath-errno" },
            // assets/include: sanitizer ABI headers zig does not ship
            // (abort.cc includes one unconditionally; the declared call is
            // only made under sanitizer builds).
            .includes = &.{ .{ .dep = .{ "highway", "" } }, .{ .repo = "src/build/assets/include" } },
            .files = &.{
                "hwy/abort.cc",
                "hwy/aligned_allocator.cc",
                "hwy/nanobenchmark.cc",
                "hwy/per_target.cc",
                "hwy/perf_counters.cc",
                "hwy/print.cc",
                "hwy/profiler.cc",
                "hwy/targets.cc",
                "hwy/timer.cc",
            },
        },
    },
};
