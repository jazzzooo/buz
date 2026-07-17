const URLPath = @This();

extname: string = "",
path: string = "",
pathname: string = "",
first_segment: string = "",
query_string: string = "",
needs_redirect: bool = false,
/// Treat URLs as non-sourcemap URLS
/// Then at the very end, we check.
is_source_map: bool = false,

pub fn isRoot(this: *const URLPath, asset_prefix: string) bool {
    const without = this.pathWithoutAssetPrefix(asset_prefix);
    if (without.len == 1 and without[0] == '.') return true;
    return strings.eqlComptime(without, "index");
}

// TODO: use a real URL parser
// this treats a URL like /_next/ identically to /
pub fn pathWithoutAssetPrefix(this: *const URLPath, asset_prefix: string) string {
    if (asset_prefix.len == 0) return this.path;
    const leading_slash_offset: usize = if (asset_prefix[0] == '/') 1 else 0;
    const base = this.path;
    const origin = asset_prefix[leading_slash_offset..];

    const out = if (base.len >= origin.len and strings.eql(base[0..origin.len], origin)) base[origin.len..] else base;
    if (this.is_source_map and strings.endsWithComptime(out, ".map")) {
        return out[0 .. out.len - 4];
    }

    return out;
}

/// A borrowed URLPath view and the optional allocation backing its slices.
pub const Parsed = struct {
    value: URLPath,
    owned: ?[]u8 = null,

    pub fn deinit(this: *Parsed, allocator: std.mem.Allocator) void {
        if (this.owned) |owned| {
            allocator.free(owned);
        }
        this.* = undefined;
    }

    pub fn takeOwned(this: *Parsed) ?[]u8 {
        const owned = this.owned;
        this.owned = null;
        return owned;
    }
};

pub fn parseAlloc(allocator: std.mem.Allocator, input: string) !Parsed {
    const query_start = std.mem.indexOfScalar(u8, input, '?') orelse input.len;
    const encoded_pathname = input[0..query_start];
    const query_string = input[query_start..];

    if (!strings.containsChar(encoded_pathname, '%'))
        return .{ .value = parseDecodedWithRedirect(encoded_pathname, query_string, false) };

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, input.len);
    defer output.deinit();

    var needs_redirect = false;
    var decoded_len: usize = try PercentEncoding.decodeFaultTolerant(&output.writer, encoded_pathname, &needs_redirect, true);
    bun.assert(decoded_len == output.written().len);

    if (decoded_len == 0) {
        try output.writer.writeByte('/');
        decoded_len = 1;
    }
    try output.writer.writeAll(query_string);

    const owned = try output.toOwnedSlice();
    return .{
        .value = parseDecodedWithRedirect(owned[0..decoded_len], owned[decoded_len..], needs_redirect),
        .owned = owned,
    };
}

/// Parse an already-decoded pathname. The returned slices borrow from `input`.
pub fn parseDecoded(input: string) URLPath {
    const query_start = std.mem.indexOfScalar(u8, input, '?') orelse input.len;
    return parseDecodedWithRedirect(input[0..query_start], input[query_start..], false);
}

fn parseDecodedWithRedirect(pathname: string, query_string: string, needs_redirect: bool) URLPath {
    const decoded_pathname = if (pathname.len == 0) "/" else pathname;

    var period_i: ?usize = null;

    var first_segment_end = decoded_pathname.len;
    var last_slash: ?usize = null;

    var i = decoded_pathname.len;
    while (i > 0) {
        i -= 1;
        const c = decoded_pathname[i];

        switch (c) {
            '.' => {
                if (period_i == null) period_i = i;
            },
            '/' => {
                if (last_slash == null) last_slash = i;

                if (i > 0) {
                    first_segment_end = @min(first_segment_end, i);
                }
            },
            else => {},
        }
    }

    if (last_slash) |slash| {
        if (period_i) |period| {
            if (slash > period) period_i = null;
        }
    }

    // .js.map
    //    ^
    const extname = brk: {
        if (period_i) |period| {
            const start = period + 1;
            break :brk decoded_pathname[start..];
        }
        break :brk &([_]u8{});
    };

    var path = decoded_pathname[@min(1, decoded_pathname.len)..];

    const first_segment = decoded_pathname[@min(1, first_segment_end)..first_segment_end];
    const is_source_map = strings.eqlComptime(extname, "map");
    var backup_extname: string = extname;
    if (is_source_map and path.len > ".map".len) {
        if (std.mem.lastIndexOfScalar(u8, path[0 .. path.len - ".map".len], '.')) |j| {
            backup_extname = path[j + 1 ..];
            backup_extname = backup_extname[0 .. backup_extname.len - ".map".len];
            path = path[0 .. j + backup_extname.len + 1];
        }
    }

    return URLPath{
        .extname = if (!is_source_map) extname else backup_extname,
        .is_source_map = is_source_map,
        .pathname = decoded_pathname,
        .first_segment = first_segment,
        .path = if (decoded_pathname.len == 1) "." else path,
        .query_string = query_string,
        .needs_redirect = needs_redirect,
    };
}

const string = []const u8;

const std = @import("std");
const PercentEncoding = @import("../url/url.zig").PercentEncoding;

const bun = @import("bun");
const strings = bun.strings;
