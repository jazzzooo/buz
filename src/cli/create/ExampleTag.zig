pub const Tag = enum {
    unknown,
    github_repository,
    official,
    local_folder,
    jslike_file,

    const ExtensionTagMap = bun.ComptimeStringMap(Tag, .{
        .{ ".tsx", .jslike_file },
        .{ ".jsx", .jslike_file },
    });

    pub fn fromFileExtension(extension: []const u8) ?Tag {
        return ExtensionTagMap.get(extension);
    }
};

const bun = @import("bun");
