pub fn fromBindgen(value: anytype) bun.OOM!PathOrBlob {
    return switch (value) {
        .fd => |fd| .{ .path = .{ .fd = bun.FD.fromUV(fd) } },
        .path => |path| .{ .path = .{ .path = try PathLike.fromBindingView(path) } },
        .blob => |blob| .{ .blob = .init(blob.get()) },
    };
}

const bun = @import("bun");
const PathOrBlob = @import("./PathOrBlob.zig").WithBlob(@import("../webcore/Blob.zig"));
const PathLike = @import("./PathLike.zig").PathLike;
