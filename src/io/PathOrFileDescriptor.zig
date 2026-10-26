pub const PathOrFileDescriptor = union(enum) {
    path: bun.String.Slice,
    fd: bun.FD,

    pub fn deinit(this: *const PathOrFileDescriptor) void {
        if (this.* == .path) this.path.deinit();
    }
};

const bun = @import("bun");
