pub fn WithBlob(comptime Blob: type) type {
    return union(enum) {
        const Self = @This();

        path: PathOrFileDescriptor,
        blob: bun.bindgen.BorrowedNative(Blob, .vm),

        pub fn deinit(this: *Self) void {
            switch (this.*) {
                .path => |*path| path.deinit(),
                .blob => {},
            }
        }
    };
}

const bun = @import("bun");
const PathOrFileDescriptor = @import("./PathLike.zig").PathOrFileDescriptor;
