pub const Subset = struct {
    loader: ?bun.schema.api.LoaderMap = null,
    ignoreDCEAnnotations: ?bool = null,
    conditions: bun.StringArrayHashMap(void) = .empty,
    drop: bun.StringArrayHashMap(void) = .empty,
    env: bun.schema.api.DotEnvBehavior = ._none,
    env_prefix: ?[]const u8 = null,
    define: bun.schema.api.StringMap = .{ .keys = &.{}, .values = &.{} },
    source_map: bun.schema.api.SourceMapMode = .external,

    minify_syntax: ?bool = null,
    minify_identifiers: ?bool = null,
    minify_whitespace: ?bool = null,
};

const bun = @import("bun");
