pub const HmrRuntime = struct {
    code: [:0]const u8,
    line_count: u32,

    pub fn init(code: [:0]const u8) HmrRuntime {
        return .{
            .code = code,
            .line_count = @intCast(std.mem.count(u8, code, "\n")),
        };
    }
};

pub fn getHmrRuntime(io: std.Io, side: Side) callconv(bun.callconv_inline) HmrRuntime {
    return if (bun.Environment.codegen_embed)
        switch (side) {
            .client => .init(@embedFile("bake-codegen/bake.client.js")),
            .server => .init(@embedFile("bake-codegen/bake.server.js")),
        }
    else
        .init(switch (side) {
            .client => bun.runtimeEmbedFile(io, .codegen_eager, "bake.client.js"),
            .server => bun.runtimeEmbedFile(io, .codegen, "bake.server.js"),
        });
}

pub const Mode = enum {
    development,
    production_dynamic,
    production_static,
};

pub const Side = enum(u1) {
    client,
    server,

    pub fn graph(side: Side) Graph {
        return switch (side) {
            .client => .client,
            .server => .server,
        };
    }
};

pub const Graph = enum(u2) {
    client,
    server,
    ssr,
};

pub const RouteBundleIndex = bun.GenericIndex(u30, opaque {});

pub const RoutePart = union(enum(u3)) {
    text: []const u8,
    param: []const u8,
    catch_all_optional: []const u8,
    catch_all: []const u8,
    group: []const u8,

    pub const SerializedHeader = packed struct(u32) {
        tag: @typeInfo(RoutePart).@"union".tag_type.?,
        len: u29,
    };

    pub fn writeAsSerialized(part: RoutePart, writer: anytype) !void {
        switch (part) {
            .text => |text| {
                bun.assert(text.len > 0);
                bun.assert(bun.strings.indexOfChar(text, '/') == null);
            },
            else => {},
        }
        const payload = switch (part) {
            inline else => |text| text,
        };
        try writer.writeInt(u32, @bitCast(SerializedHeader{
            .tag = std.meta.activeTag(part),
            .len = @intCast(payload.len),
        }), .little);
        try writer.writeAll(payload);
    }

    pub fn eql(left: RoutePart, right: RoutePart) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            inline else => |payload, tag| bun.strings.eql(payload, @field(right, @tagName(tag))),
        };
    }

    pub fn format(part: RoutePart, writer: *std.Io.Writer) !void {
        try writer.writeAll("Part \"");
        try part.toStringForInternalUse(writer);
        try writer.writeAll("\"");
    }

    pub fn toStringForInternalUse(part: RoutePart, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (part) {
            .text => |text| try writer.print("/{s}", .{text}),
            .param => |name| try writer.print("/:{s}", .{name}),
            .group => |label| try writer.print("/({s})", .{label}),
            .catch_all => |name| try writer.print("/:*{s}", .{name}),
            .catch_all_optional => |name| try writer.print("/:*?{s}", .{name}),
        }
    }
};

pub const ParsedPattern = struct {
    parts: []const RoutePart,
    kind: Kind,

    pub const Kind = enum {
        page,
        layout,
        extra,
    };
};

pub const PatternParseError = error{InvalidRoutePattern};

pub const TinyLog = struct {
    const max_message_len = 512 + @min(std.fs.max_path_bytes, 4096);

    message_buffer: [max_message_len]u8 = undefined,
    message_len: u16,
    cursor_at: u32,
    cursor_len: u32,

    pub const empty: TinyLog = .{
        .message_len = 0,
        .cursor_at = std.math.maxInt(u32),
        .cursor_len = 0,
    };

    pub fn fail(log: *TinyLog, comptime fmt: []const u8, args: anytype, cursor_at: usize, cursor_len: usize) PatternParseError {
        log.write(fmt, args);
        log.cursor_at = @intCast(cursor_at);
        log.cursor_len = @intCast(cursor_len);
        return error.InvalidRoutePattern;
    }

    pub fn write(log: *TinyLog, comptime fmt: []const u8, args: anytype) void {
        log.message_len = @intCast(if (std.fmt.bufPrint(&log.message_buffer, fmt, args)) |rendered|
            rendered.len
        else |_| truncated: {
            @memcpy(log.message_buffer[log.message_buffer.len - 3 ..], "...");
            break :truncated log.message_buffer.len;
        });
    }

    pub fn message(log: *const TinyLog) []const u8 {
        return log.message_buffer[0..log.message_len];
    }

    pub fn print(log: *const TinyLog, relative_path: []const u8) void {
        const after = relative_path[@max(0, log.cursor_at)..];
        bun.Output.errGeneric("\"{s}<blue>{s}<r>{s}\" is not a valid route", .{
            relative_path[0..@max(0, log.cursor_at)],
            after[0..@min(log.cursor_len, after.len)],
            after[@min(log.cursor_len, after.len)..],
        });
        const writer = bun.Output.errorWriterBuffered();
        writer.splatByteAll(' ', "error: \"".len + log.cursor_at) catch return;
        if (bun.Output.enable_ansi_colors_stderr) {
            const symbols = bun.fmt.TableSymbols.unicode;
            bun.Output.prettyError("<blue>" ++ symbols.topColumnSep(), .{});
            if (log.cursor_len > 1) {
                writer.splatBytesAll(symbols.horizontalEdge(), log.cursor_len - 1) catch return;
            }
        } else if (log.cursor_len <= 1) {
            writer.writeAll("|") catch return;
        } else {
            writer.splatByteAll('-', log.cursor_len - 1) catch return;
        }
        writer.writeByte('\n') catch return;
        writer.splatByteAll(' ', "error: \"".len + log.cursor_at) catch return;
        writer.writeAll(log.message()) catch return;
        bun.Output.prettyError("<r>\n", .{});
        bun.Output.flush();
    }
};

pub fn parseCustomPattern(pattern: []const u8, log: *TinyLog, allocator: std.mem.Allocator) ![]RoutePart {
    if (pattern.len == 0 or pattern[0] != '/') {
        return log.fail("Route pattern must start with '/'", .{}, 0, @min(pattern.len, 1));
    }
    if (pattern.len == 1) return &.{};

    var parts: std.ArrayListUnmanaged(RoutePart) = .empty;
    var start: usize = 1;
    while (true) {
        const end = bun.strings.indexOfCharPos(pattern, '/', start) orelse pattern.len;
        const segment = pattern[start..end];
        if (segment.len == 0) {
            return log.fail("Route pattern cannot contain an empty path segment", .{}, start, 1);
        }

        const part: RoutePart = if (segment[0] == ':') parameter: {
            var name = segment[1..];
            const tag: enum { param, catch_all, catch_all_optional } = if (bun.strings.hasPrefixComptime(name, "*?")) tag: {
                name = name[2..];
                break :tag .catch_all_optional;
            } else if (bun.strings.hasPrefixComptime(name, "*")) tag: {
                name = name[1..];
                break :tag .catch_all;
            } else .param;

            if (name.len == 0) return log.fail("Parameter needs a name", .{}, start, segment.len);
            if (bun.strings.indexOfAny(name, "?*{}()=:#,")) |bad_character| {
                return log.fail("Parameter name cannot contain \"{c}\"", .{name[bad_character]}, start + 1 + bad_character, 1);
            }

            break :parameter switch (tag) {
                .param => .{ .param = name },
                .catch_all => .{ .catch_all = name },
                .catch_all_optional => .{ .catch_all_optional = name },
            };
        } else if (bun.strings.eqlComptime(segment, "*"))
            .{ .catch_all = "*" }
        else if (bun.strings.eqlComptime(segment, "*?"))
            .{ .catch_all_optional = "*" }
        else
            .{ .text = segment };

        switch (part) {
            .catch_all, .catch_all_optional => if (end != pattern.len) {
                return log.fail("Catch-all parameter must be at the end of a route", .{}, start, segment.len);
            },
            else => {},
        }
        try parts.append(allocator, part);
        if (end == pattern.len) return parts.items;
        start = end + 1;
    }
}

pub const RouteExtraction = enum { ui, routes };
const RoutingConvention = enum { app, pages };

pub fn parseNextJsPages(
    raw_path: []const u8,
    extension: []const u8,
    log: *TinyLog,
    allow_layouts: bool,
    allocator: std.mem.Allocator,
) !?ParsedPattern {
    var path = raw_path[0 .. raw_path.len - extension.len];
    var kind: ParsedPattern.Kind = .page;
    if (bun.strings.hasSuffixComptime(path, "/index")) {
        path.len -= "/index".len;
    } else if (allow_layouts and bun.strings.hasSuffixComptime(path, "/_layout")) {
        path.len -= "/_layout".len;
        kind = .layout;
    }
    if (path.len == 0) return .{ .kind = kind, .parts = &.{} };
    return .{
        .kind = kind,
        .parts = try parseNextJsRouteSegments(raw_path, path, log, allocator, .pages),
    };
}

pub fn parseNextJsApp(
    raw_path: []const u8,
    extension: []const u8,
    log: *TinyLog,
    allow_layouts: bool,
    allocator: std.mem.Allocator,
    comptime extraction: RouteExtraction,
) !?ParsedPattern {
    const without_extension = raw_path[0 .. raw_path.len - extension.len];
    const basename = std.fs.path.basename(without_extension);
    const loader = bun.options.Loader.fromString(extension) orelse return null;
    if (!loader.isJavaScriptLike()) return null;

    const kind = bun.ComptimeStringMap(ParsedPattern.Kind, switch (extraction) {
        .ui => .{
            .{ "page", .page },
            .{ "layout", .layout },
            .{ "default", .extra },
            .{ "template", .extra },
            .{ "error", .extra },
            .{ "loading", .extra },
            .{ "not-found", .extra },
        },
        .routes => .{
            .{ "route", .page },
        },
    }).get(basename) orelse return null;

    if (kind == .layout and !allow_layouts) return null;

    const dirname = std.fs.path.dirnamePosix(without_extension) orelse "";
    if (dirname.len <= 1) return .{ .kind = kind, .parts = &.{} };
    return .{
        .kind = kind,
        .parts = try parseNextJsRouteSegments(raw_path, dirname, log, allocator, .app),
    };
}

fn parseNextJsRouteSegments(
    raw_input: []const u8,
    route_segment: []const u8,
    log: *TinyLog,
    allocator: std.mem.Allocator,
    comptime convention: RoutingConvention,
) ![]RoutePart {
    var index: usize = 1;
    var parts: std.ArrayListUnmanaged(RoutePart) = .empty;
    const stop_characters = switch (convention) {
        .pages => "[",
        .app => "[(@",
    };
    while (bun.strings.indexOfAnyPosComptime(route_segment, stop_characters, index)) |start| {
        if (convention == .pages or route_segment[start] == '[') {
            var end = bun.strings.indexOfCharPos(route_segment, ']', start + 1) orelse
                return log.fail("Missing \"]\" to match this route parameter", .{}, start, raw_input.len - start);
            const is_optional = route_segment[start + 1] == '[';
            const parameter_content = route_segment[start + 1 + @as(u64, @intFromBool(is_optional)) .. end];

            var has_ending_double_bracket = false;
            if (end + 1 < route_segment.len and route_segment[end + 1] == ']') {
                end += 1;
                has_ending_double_bracket = true;
            }
            const length = end - start + 1;
            const is_catch_all = bun.strings.hasPrefixComptime(parameter_content, "...");
            const parameter_name = if (is_catch_all) parameter_content[3..] else parameter_content;

            if (parameter_name.len == 0) return log.fail("Parameter needs a name", .{}, start, length);
            if (parameter_name[0] == '.') {
                return log.fail("Parameter name cannot start with \".\" (use \"...\" for catch-all)", .{}, start, length);
            }
            if (is_optional and !is_catch_all) {
                return log.fail(
                    "Optional parameters can only be catch-all (change to \"[[...{s}]]\" or remove extra brackets)",
                    .{parameter_name},
                    start,
                    length,
                );
            }
            if (bun.strings.indexOfAny(parameter_name, "?*{}()=:#,")) |bad_character| {
                return log.fail("Parameter name cannot contain \"{c}\"", .{parameter_name[bad_character]}, start + bad_character, 1);
            }
            if (has_ending_double_bracket and !is_optional) {
                return log.fail("Extra \"]\" in route parameter", .{}, end, 1);
            }
            if (!has_ending_double_bracket and is_optional) {
                return log.fail("Missing second \"]\" to close optional route parameter", .{}, end, 1);
            }
            if (route_segment[start - 1] != '/' or
                (end + 1 < route_segment.len and route_segment[end + 1] != '/'))
            {
                return log.fail("Parameters must take up the entire file name", .{}, start, length);
            }
            if (is_catch_all and route_segment.len != end + 1) {
                return log.fail("Catch-all parameter must be at the end of a route", .{}, start, length);
            }

            var text_parts = std.mem.tokenizeScalar(u8, route_segment[index..start], '/');
            while (text_parts.next()) |part| try parts.append(allocator, .{ .text = part });
            try parts.append(allocator, if (is_optional)
                .{ .catch_all_optional = parameter_name }
            else if (is_catch_all)
                .{ .catch_all = parameter_name }
            else
                .{ .param = parameter_name });
            index = end + 1;
        } else if (route_segment[start] == '(') {
            const end = bun.strings.indexOfCharPos(route_segment, ')', start + 1) orelse
                return log.fail("Missing \")\" to match this route group", .{}, start, raw_input.len - start);
            const length = end - start + 1;
            const group_name = route_segment[start + 1 .. end];
            if (bun.strings.hasPrefixComptime(group_name, ".")) {
                return log.fail("Bun Bake currently does not support named slots and intercepted routes", .{}, start, length);
            }
            if (route_segment[start - 1] != '/' or
                (end + 1 < route_segment.len and route_segment[end + 1] != '/'))
            {
                return log.fail("Route group marker must take up the entire file name", .{}, start, length);
            }

            var text_parts = std.mem.tokenizeScalar(u8, route_segment[index..start], '/');
            while (text_parts.next()) |part| try parts.append(allocator, .{ .text = part });
            try parts.append(allocator, .{ .group = group_name });
            index = end + 1;
        } else {
            const end = bun.strings.indexOfCharPos(route_segment, ')', start + 1) orelse route_segment.len;
            return log.fail(
                "Bun Bake currently does not support named slots and intercepted routes",
                .{},
                start,
                end - start + 1,
            );
        }
    }
    if (route_segment[index..].len > 0) {
        var trailing_parts = std.mem.tokenizeScalar(u8, route_segment[index..], '/');
        while (trailing_parts.next()) |part| try parts.append(allocator, .{ .text = part });
    }
    return parts.items;
}

pub const PatternBuffer = struct {
    bytes: bun.PathBuffer,
    index: std.math.IntFittingRange(0, @sizeOf(bun.PathBuffer)),

    pub const empty: PatternBuffer = .{
        .bytes = undefined,
        .index = @sizeOf(bun.PathBuffer),
    };

    pub fn prepend(buffer: *PatternBuffer, chunk: []const u8) void {
        bun.assert(buffer.index >= chunk.len);
        buffer.index -= @intCast(chunk.len);
        @memcpy(buffer.slice()[0..chunk.len], chunk);
    }

    pub fn prependPart(buffer: *PatternBuffer, part: RoutePart) void {
        switch (part) {
            .text => |text| {
                bun.assert(text.len == 0 or text[0] != '/');
                buffer.prepend(text);
                buffer.prepend("/");
            },
            .param, .catch_all, .catch_all_optional => |name| {
                buffer.prepend(name);
                buffer.prepend("/:");
            },
            .group => {},
        }
    }

    pub fn slice(buffer: *PatternBuffer) []u8 {
        return buffer.bytes[buffer.index..];
    }
};

pub fn addImportMetaDefines(
    define: *bun.options.Define,
    mode: Mode,
    side: Side,
) !void {
    const Define = bun.options.Define;
    try define.insert(
        "import.meta.env.DEV",
        Define.Data.initBoolean(mode == .development),
    );
    try define.insert(
        "import.meta.env.PROD",
        Define.Data.initBoolean(mode != .development),
    );
    try define.insert(
        "import.meta.env.MODE",
        Define.Data.initStaticString(switch (mode) {
            .development => &.{ .data = "development" },
            .production_dynamic, .production_static => &.{ .data = "production" },
        }),
    );
    try define.insert(
        "import.meta.env.SSR",
        Define.Data.initBoolean(side == .server),
    );
    try define.insert(
        "import.meta.env.STATIC",
        Define.Data.initBoolean(mode == .production_static),
    );
}

pub const server_virtual_source: bun.logger.Source = .{
    .path = bun.fs.Path.initWithNamespaceVirtual("_bun/bake/server", "bun", "bake/server"),
    .contents = "",
    .index = bun.ast.Index.bake_server_data,
};

pub const client_virtual_source: bun.logger.Source = .{
    .path = bun.fs.Path.initWithNamespaceVirtual("_bun/bake/client", "bun", "bake/client"),
    .contents = "",
    .index = bun.ast.Index.bake_client_data,
};

pub fn printWarning() void {
    if (bun.env_var.BUN_DEV_SERVER_TEST_RUNNER.get() != null) return;
    bun.Output.warn(
        \\Be advised that Bun Bake is highly experimental, and its API
        \\will have breaking changes. Join the <magenta>#bake<r> Discord
        \\channel to help us find bugs: <blue>https://bun.com/discord<r>
        \\
        \\
    , .{});
    bun.Output.flush();
}

const std = @import("std");
const bun = @import("bun");
