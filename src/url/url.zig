// This is close to WHATWG URL, but we don't want the validation errors
pub const URL = struct {
    const log = Output.scoped(.URL, .visible);

    hash: string = "",
    /// hostname, but with a port
    /// `localhost:3000`
    host: string = "",
    /// hostname does not have a port
    /// `localhost`
    hostname: string = "",
    href: string = "",
    origin: string = "",
    password: string = "",
    pathname: string = "/",
    path: string = "/",
    port: string = "",
    protocol: string = "",
    search: string = "",
    searchParams: ?QueryStringMap = null,
    username: string = "",
    port_was_automatically_set: bool = false,

    pub fn isFile(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "file");
    }
    /// host + path without the ending slash, protocol, searchParams and hash
    pub fn hostWithPath(this: *const URL) []const u8 {
        if (this.host.len > 0) {
            if (this.path.len > 1 and bun.isSliceInBuffer(this.path, this.href) and bun.isSliceInBuffer(this.host, this.href)) {
                const end = @intFromPtr(this.path.ptr) + this.path.len;
                const start = @intFromPtr(this.host.ptr);
                const len: usize = end - start - (if (bun.strings.endsWithComptime(this.path, "/")) @as(usize, 1) else @as(usize, 0));
                const ptr: [*]u8 = @ptrFromInt(start);
                return ptr[0..len];
            }
            return this.host;
        }
        return "";
    }

    /// `"blob:".len + UUID.stringLength` — see `runtime/webcore/ObjectURLRegistry.specifier_len`.
    const blob_specifier_len = "blob:".len + 36;

    pub fn isBlob(this: *const URL) bool {
        return this.href.len == blob_specifier_len and strings.hasPrefixComptime(this.href, "blob:");
    }

    pub const fromJS = @import("../url_jsc/url_jsc.zig").urlFromJS;

    pub fn fromString(allocator: std.mem.Allocator, input: bun.String) !URL {
        var href = jsc.URL.hrefFromString(input);
        if (href.tag == .Dead) {
            return error.InvalidURL;
        }

        defer href.deref();
        return URL.parse(try href.toOwnedSlice(allocator));
    }

    pub fn fromUTF8(allocator: std.mem.Allocator, input: []const u8) !URL {
        return fromString(allocator, bun.String.borrowUTF8(input));
    }

    pub fn isLocalhost(this: *const URL) bool {
        return this.hostname.len == 0 or strings.eqlComptime(this.hostname, "localhost") or strings.eqlComptime(this.hostname, "0.0.0.0");
    }

    pub inline fn isUnix(this: *const URL) bool {
        return strings.hasPrefixComptime(this.protocol, "unix");
    }

    pub fn displayProtocol(this: *const URL) string {
        if (this.protocol.len > 0) {
            return this.protocol;
        }

        if (this.getPort()) |port| {
            if (port == 443) {
                return "https";
            }
        }

        return "http";
    }

    pub inline fn isHTTPS(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "https");
    }

    pub inline fn isS3(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "s3");
    }

    pub inline fn isHTTP(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "http");
    }

    pub fn displayHostname(this: *const URL) string {
        if (this.hostname.len > 0) {
            return this.hostname;
        }

        return "localhost";
    }

    pub fn s3Path(this: *const URL) string {
        // we need to remove protocol if exists and ignore searchParams, should be host + pathname
        const href = if (this.protocol.len > 0 and this.href.len > this.protocol.len + 2) this.href[this.protocol.len + 2 ..] else this.href;
        return href[0 .. href.len - (this.search.len + this.hash.len)];
    }

    pub fn displayHost(this: *const URL) bun.fmt.HostFormatter {
        return bun.fmt.HostFormatter{
            .host = if (this.host.len > 0) this.host else this.displayHostname(),
            .port = if (this.port.len > 0) this.getPort() else null,
            .is_https = this.isHTTPS(),
        };
    }

    pub fn hasHTTPLikeProtocol(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "http") or strings.eqlComptime(this.protocol, "https");
    }

    pub fn getPort(this: *const URL) ?u16 {
        return std.fmt.parseInt(u16, this.port, 10) catch null;
    }

    pub fn getPortAuto(this: *const URL) u16 {
        return this.getPort() orelse this.getDefaultPort();
    }

    pub fn getDefaultPort(this: *const URL) u16 {
        return if (this.isHTTPS()) @as(u16, 443) else @as(u16, 80);
    }

    pub fn isIPAddress(this: *const URL) bool {
        return bun.strings.isIPAddress(this.hostname);
    }

    pub fn hasValidPort(this: *const URL) bool {
        return (this.getPort() orelse 0) > 0;
    }

    pub fn isEmpty(this: *const URL) bool {
        return this.href.len == 0;
    }

    pub fn isAbsolute(this: *const URL) bool {
        return this.hostname.len > 0 and this.pathname.len > 0;
    }

    pub fn joinNormalize(out: []u8, prefix: string, dirname: string, basename: string, extname: string) string {
        var buf: [2048]u8 = undefined;

        var path_parts: [10]string = undefined;
        var path_end: usize = 0;

        path_parts[0] = "/";
        path_end += 1;

        if (prefix.len > 0) {
            path_parts[path_end] = prefix;
            path_end += 1;
        }

        if (dirname.len > 0) {
            path_parts[path_end] = std.mem.trim(u8, dirname, "/\\");
            path_end += 1;
        }

        if (basename.len > 0) {
            if (dirname.len > 0) {
                path_parts[path_end] = "/";
                path_end += 1;
            }

            path_parts[path_end] = std.mem.trim(u8, basename, "/\\");
            path_end += 1;
        }

        if (extname.len > 0) {
            path_parts[path_end] = extname;
            path_end += 1;
        }

        var buf_i: usize = 0;
        for (path_parts[0..path_end]) |part| {
            bun.copy(u8, buf[buf_i..], part);
            buf_i += part.len;
        }
        return resolve_path.normalizeStringBuf(buf[0..buf_i], out, false, .loose, false);
    }

    pub fn joinWrite(
        this: *const URL,
        writer: *std.Io.Writer,
        prefix: string,
        dirname: string,
        basename: string,
        extname: string,
    ) !void {
        var out: [2048]u8 = undefined;
        const normalized_path = joinNormalize(&out, prefix, dirname, basename, extname);

        try writer.print("{s}/{s}", .{ this.origin, normalized_path });
    }

    pub fn joinAlloc(this: *const URL, allocator: std.mem.Allocator, prefix: string, dirname: string, basename: string, extname: string, absolute_path: string) !string {
        const has_uplevels = std.mem.indexOf(u8, dirname, "../") != null;

        if (has_uplevels) {
            return try std.fmt.allocPrint(allocator, "{s}/abs:{s}", .{ this.origin, absolute_path });
        } else {
            var out: [2048]u8 = undefined;

            const normalized_path = joinNormalize(&out, prefix, dirname, basename, extname);
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ this.origin, normalized_path });
        }
    }

    pub fn parse(base: string) URL {
        if (base.len == 0) return URL{};
        var url = URL{};
        url.href = base;
        var offset: u31 = 0;
        switch (base[0]) {
            '@' => {
                offset += url.parsePassword(base[offset..]) orelse 0;
                offset += url.parseHost(base[offset..]) orelse 0;
            },
            '/', 'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ':' => {
                const is_protocol_relative = base.len > 1 and base[1] == '/';
                if (is_protocol_relative) {
                    offset += 1;
                } else {
                    offset += url.parseProtocol(base[offset..]) orelse 0;
                }

                const is_relative_path = !is_protocol_relative and base[0] == '/';

                if (!is_relative_path) {

                    // if there's no protocol or @, it's ambiguous whether the colon is a port or a username.
                    if (offset > 0) {
                        // see https://github.com/oven-sh/bun/issues/1390
                        const first_at = strings.indexOfChar(base[offset..], '@') orelse 0;
                        const first_colon = strings.indexOfChar(base[offset..], ':') orelse 0;

                        if (first_at > first_colon and first_at < (strings.indexOfChar(base[offset..], '/') orelse std.math.maxInt(u32))) {
                            offset += url.parseUsername(base[offset..]) orelse 0;
                            offset += url.parsePassword(base[offset..]) orelse 0;
                        }
                    }

                    offset += url.parseHost(base[offset..]) orelse 0;
                }
            },
            else => {},
        }

        url.origin = base[0..offset];
        var hash_offset: u32 = std.math.maxInt(u32);

        if (offset > base.len) {
            return url;
        }

        const path_offset = offset;

        var can_update_path = true;
        if (base.len > offset + 1 and base[offset] == '/' and base[offset..].len > 0) {
            url.path = base[offset..];
            url.pathname = url.path;
        }

        if (strings.indexOfChar(base[offset..], '?')) |q| {
            offset += @as(u31, @intCast(q));
            url.path = base[path_offset..][0..q];
            can_update_path = false;
            url.search = base[offset..];
        }

        if (strings.indexOfChar(base[offset..], '#')) |hash| {
            offset += @as(u31, @intCast(hash));
            hash_offset = offset;
            if (can_update_path) {
                url.path = base[path_offset..][0..hash];
            }
            url.hash = base[offset..];

            if (url.search.len > 0) {
                url.search = url.search[0 .. url.search.len - url.hash.len];
            }
        }

        if (base.len > path_offset and base[path_offset] == '/' and offset > 0) {
            if (url.search.len > 0) {
                url.pathname = base[path_offset..@min(
                    @min(offset + url.search.len, base.len),
                    hash_offset,
                )];
            } else if (hash_offset < std.math.maxInt(u32)) {
                url.pathname = base[path_offset..hash_offset];
            }

            url.origin = base[0..path_offset];
        }

        if (url.path.len > 1) {
            const trimmed = std.mem.trim(u8, url.path, "/");
            if (trimmed.len > 1) {
                url.path = url.path[@min(
                    @max(@intFromPtr(trimmed.ptr) - @intFromPtr(url.path.ptr), 1) - 1,
                    hash_offset,
                )..];
            } else {
                url.path = "/";
            }
        } else {
            url.path = "/";
        }

        if (url.pathname.len == 0) {
            url.pathname = "/";
        }

        while (url.pathname.len > 1 and @as(u16, @bitCast(url.pathname[0..2].*)) == comptime std.mem.readInt(u16, "//", .little)) {
            url.pathname = url.pathname[1..];
        }

        url.origin = std.mem.trim(u8, url.origin, "/ ?#");
        return url;
    }

    pub fn parseProtocol(url: *URL, str: string) ?u31 {
        if (str.len < "://".len) return null;
        for (0..str.len) |i| {
            switch (str[i]) {
                '/', '?', '%' => {
                    return null;
                },
                ':' => {
                    if (i + 3 <= str.len and str[i + 1] == '/' and str[i + 2] == '/') {
                        url.protocol = str[0..i];
                        return @intCast(i + 3);
                    }
                },
                else => {},
            }
        }

        return null;
    }

    pub fn parseUsername(url: *URL, str: string) ?u31 {
        // reset it
        url.username = "";

        if (str.len < "@".len) return null;
        for (0..str.len) |i| {
            switch (str[i]) {
                ':', '@' => {
                    // we found a username, everything before this point in the slice is a username
                    url.username = str[0..i];
                    return @intCast(i + 1);
                },
                // if we reach a slash or "?", there's no username
                '?', '/' => {
                    return null;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn parsePassword(url: *URL, str: string) ?u31 {
        // reset it
        url.password = "";

        if (str.len < "@".len) return null;
        for (0..str.len) |i| {
            switch (str[i]) {
                '@' => {
                    // we found a password, everything before this point in the slice is a password
                    url.password = str[0..i];
                    if (Environment.allow_assert) bun.assert(str[i..].len < 2 or std.mem.readInt(u16, str[i..][0..2], .little) != std.mem.readInt(u16, "//", .little));
                    return @intCast(i + 1);
                },
                // if we reach a slash or "?", there's no password
                '?', '/' => {
                    return null;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn parseHost(url: *URL, str: string) ?u31 {
        var i: u31 = 0;

        // reset it
        url.host = "";
        url.hostname = "";
        url.port = "";

        //if starts with "[" so its IPV6
        if (str.len > 0 and str[0] == '[') {
            i = 1;
            var ipv6_i: ?u31 = null;
            var colon_i: ?u31 = null;

            while (i < str.len) : (i += 1) {
                ipv6_i = if (ipv6_i == null and str[i] == ']') i else ipv6_i;
                colon_i = if (ipv6_i != null and colon_i == null and str[i] == ':') i else colon_i;
                switch (str[i]) {
                    // alright, we found the slash or "?"
                    '?', '/' => {
                        break;
                    },
                    else => {},
                }
            }

            url.host = str[0..i];
            if (ipv6_i) |ipv6| {
                //hostname includes "[" and "]"
                url.hostname = str[0 .. ipv6 + 1];
            }

            if (colon_i) |colon| {
                url.port = str[colon + 1 .. i];
            }
        } else {

            // look for the first "/" or "?"
            // if we have a slash or "?", anything before that is the host
            // anything before the colon is the hostname
            // anything after the colon but before the slash is the port
            // the origin is the scheme before the slash

            var colon_i: ?u31 = null;
            while (i < str.len) : (i += 1) {
                colon_i = if (colon_i == null and str[i] == ':') i else colon_i;

                switch (str[i]) {
                    // alright, we found the slash or "?"
                    '?', '/' => {
                        break;
                    },
                    else => {},
                }
            }

            url.host = str[0..i];
            if (colon_i) |colon| {
                url.hostname = str[0..colon];
                url.port = str[colon + 1 .. i];
            } else {
                url.hostname = str[0..i];
            }
        }

        return i;
    }
};

/// QueryString array-backed hash table that does few allocations and preserves the original order
pub const QueryStringMap = struct {
    allocator: std.mem.Allocator,
    slice: string,
    buffer: []u8,
    list: Param.List,
    groups: bun.StringArrayHashMap(Group),

    const no_param = std.math.maxInt(u32);

    pub fn getNameCount(this: *const QueryStringMap) usize {
        return this.groups.count();
    }

    pub fn iter(this: *const QueryStringMap) Iterator {
        return Iterator.init(this);
    }

    pub const ValueIterator = struct {
        map: *const QueryStringMap,
        next_index: u32,

        pub fn next(this: *ValueIterator) ?string {
            if (this.next_index == no_param) return null;

            const index: usize = @intCast(this.next_index);
            const params = this.map.list.slice();
            this.next_index = params.items(.next_same_name)[index];
            return this.map.str(params.items(.value)[index]);
        }
    };

    pub const Iterator = struct {
        i: usize = 0,
        map: *const QueryStringMap,

        const Result = struct {
            name: string,
            values: ValueIterator,
            value_count: usize,
        };

        pub fn init(map: *const QueryStringMap) Iterator {
            return .{ .map = map };
        }

        pub fn next(this: *Iterator) ?Result {
            if (this.i >= this.map.groups.count()) return null;

            const name = this.map.groups.keys()[this.i];
            const group = this.map.groups.values()[this.i];
            this.i += 1;
            return .{
                .name = name,
                .values = .{ .map = this.map, .next_index = group.first },
                .value_count = group.count,
            };
        }
    };

    pub fn str(this: *const QueryStringMap, ptr: api.StringPointer) string {
        return this.slice[ptr.offset .. ptr.offset + ptr.length];
    }

    pub fn getIndex(this: *const QueryStringMap, input: string) ?usize {
        const group = this.groups.get(input) orelse return null;
        return group.first;
    }

    pub fn get(this: *const QueryStringMap, input: string) ?string {
        const index = this.getIndex(input) orelse return null;
        return this.str(this.list.items(.value)[index]);
    }

    pub fn has(this: *const QueryStringMap, input: string) bool {
        return this.groups.contains(input);
    }

    pub fn getAll(this: *const QueryStringMap, input: string, target: []string) usize {
        const group = this.groups.get(input) orelse return 0;
        var values = ValueIterator{ .map = this, .next_index = group.first };
        var target_i: usize = 0;
        while (target_i < target.len) {
            target[target_i] = values.next() orelse break;
            target_i += 1;
        }
        return target_i;
    }

    pub const Param = struct {
        name: api.StringPointer,
        value: api.StringPointer,
        next_same_name: u32 = no_param,

        pub const List = std.MultiArrayList(Param);
    };

    const Group = struct {
        first: u32,
        last: u32,
        count: u32,
    };

    fn buildGroups(this: *QueryStringMap) bun.OOM!void {
        try this.groups.ensureTotalCapacity(this.allocator, this.list.len);
        var params = this.list.slice();
        for (params.items(.name), 0..) |name, i| {
            const index: u32 = @intCast(i);
            const result = this.groups.getOrPutAssumeCapacity(this.str(name));
            if (result.found_existing) {
                params.items(.next_same_name)[result.value_ptr.last] = index;
                result.value_ptr.last = index;
                result.value_ptr.count += 1;
            } else {
                result.value_ptr.* = .{ .first = index, .last = index, .count = 1 };
            }
        }
    }

    fn containsName(params: Param.List.Slice, backing: string, end: usize, name: string) bool {
        for (params.items(.name)[0..end]) |pointer| {
            const existing = backing[pointer.offset..][0..pointer.length];
            if (strings.eqlLong(existing, name, true)) return true;
        }
        return false;
    }

    fn finish(allocator: std.mem.Allocator, backing: string, buffer: []u8, list: *Param.List) bun.OOM!QueryStringMap {
        var map = QueryStringMap{
            .allocator = allocator,
            .slice = backing,
            .buffer = buffer,
            .list = list.*,
            .groups = .empty,
        };
        list.* = .{};
        errdefer map.deinit();
        try map.buildGroups();
        return map;
    }

    pub fn initWithScanner(
        allocator: std.mem.Allocator,
        _scanner: CombinedScanner,
    ) bun.OOM!?QueryStringMap {
        var list = Param.List{};
        errdefer list.deinit(allocator);
        var scanner = _scanner;

        var estimated_str_len: usize = 0;
        var count: usize = 0;

        while (scanner.pathname.next()) |result| {
            estimated_str_len += result.name.length + result.value.length;
            count += 1;
        }

        if (Environment.allow_assert)
            bun.assert(count > 0); // We should not call initWithScanner when there are no path params

        while (scanner.query.next()) |result| {
            estimated_str_len += result.name.length + result.value.length;
            count += 1;
        }

        if (count == 0) return null;

        try list.ensureTotalCapacity(allocator, count);
        scanner.reset();

        // this over-allocates
        // TODO: refactor this to support multiple slices instead of copying the whole thing
        var buf = try std.Io.Writer.Allocating.initCapacity(allocator, estimated_str_len);
        errdefer buf.deinit();
        const writer = &buf.writer;
        var buf_writer_pos: u32 = 0;

        while (scanner.pathname.next()) |result| {
            var name = result.name;
            var value = result.value;
            const name_slice = result.rawName(scanner.pathname.routename);

            name.length = @as(u32, @truncate(name_slice.len));
            name.offset = buf_writer_pos;
            writer.writeAll(name_slice) catch return error.OutOfMemory;
            buf_writer_pos += @as(u32, @truncate(name_slice.len));

            value.length = PercentEncoding.decode(writer, result.rawValue(scanner.pathname.pathname)) catch continue;
            value.offset = buf_writer_pos;
            buf_writer_pos += value.length;

            list.appendAssumeCapacity(.{ .name = name, .value = value });
        }

        const route_parameter_begin = list.len;

        while (scanner.query.next()) |result| {
            var name = result.name;
            var value = result.value;

            name.offset = buf_writer_pos;
            name.length = PercentEncoding.decode(writer, result.rawName(scanner.query.query_string)) catch continue;
            buf_writer_pos += name.length;
            const name_slice = buf.written()[name.offset..][0..name.length];
            if (containsName(list.slice(), buf.written(), route_parameter_begin, name_slice)) continue;

            value.offset = buf_writer_pos;
            value.length = PercentEncoding.decode(writer, result.rawValue(scanner.query.query_string)) catch continue;
            buf_writer_pos += value.length;

            list.appendAssumeCapacity(.{ .name = name, .value = value });
        }

        const owned = try buf.toOwnedSlice();
        return try finish(allocator, owned[0..buf_writer_pos], owned, &list);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        query_string: string,
    ) bun.OOM!?QueryStringMap {
        var list = Param.List{};
        errdefer list.deinit(allocator);

        var scanner = Scanner.init(query_string);
        var count: usize = 0;
        var estimated_str_len: usize = 0;

        var nothing_needs_decoding = true;
        while (scanner.next()) |result| {
            if (result.name_needs_decoding or result.value_needs_decoding) {
                nothing_needs_decoding = false;
            }
            estimated_str_len += result.name.length + result.value.length;
            count += 1;
        }

        if (count == 0) return null;

        scanner = Scanner.init(query_string);
        try list.ensureTotalCapacity(allocator, count);

        if (nothing_needs_decoding) {
            scanner = Scanner.init(query_string);
            while (scanner.next()) |result| {
                if (Environment.allow_assert) bun.assert(!result.name_needs_decoding);
                if (Environment.allow_assert) bun.assert(!result.value_needs_decoding);

                const name = result.name;
                const value = result.value;
                list.appendAssumeCapacity(.{ .name = name, .value = value });
            }

            return try finish(allocator, query_string, &[_]u8{}, &list);
        }

        var buf = try std.Io.Writer.Allocating.initCapacity(allocator, estimated_str_len);
        errdefer buf.deinit();
        const writer = &buf.writer;
        var buf_writer_pos: u32 = 0;

        while (scanner.next()) |result| {
            var name = result.name;
            var value = result.value;

            name.offset = buf_writer_pos;
            name.length = PercentEncoding.decode(writer, result.rawName(query_string)) catch continue;
            buf_writer_pos += name.length;

            value.offset = buf_writer_pos;
            value.length = PercentEncoding.decode(writer, result.rawValue(query_string)) catch continue;
            buf_writer_pos += value.length;

            list.appendAssumeCapacity(.{ .name = name, .value = value });
        }

        const owned = try buf.toOwnedSlice();
        return try finish(allocator, owned[0..buf_writer_pos], owned, &list);
    }

    pub fn deinit(this: *QueryStringMap) void {
        this.groups.deinit(this.allocator);
        this.list.deinit(this.allocator);
        if (this.buffer.len > 0) {
            this.allocator.free(this.buffer);
        }
    }
};

pub const PercentEncoding = struct {
    pub fn decode(writer: *std.Io.Writer, input: string) !u32 {
        return @call(bun.callmod_inline, decodeFaultTolerant, .{ writer, input, null, false });
    }

    /// Decode percent-encoded input into allocated memory.
    /// Caller owns the returned slice and must free it with the same allocator.
    pub fn decodeAlloc(allocator: std.mem.Allocator, input: string) ![]u8 {
        // Allocate enough space - decoded will be at most input.len bytes
        const buf = try allocator.alloc(u8, input.len);
        errdefer allocator.free(buf);

        var writer = std.Io.Writer.fixed(buf);
        const len = try decode(&writer, input);

        return buf[0..len];
    }

    pub fn decodeFaultTolerant(
        writer: *std.Io.Writer,
        input: string,
        needs_redirect: ?*bool,
        comptime fault_tolerant: bool,
    ) !u32 {
        var i: usize = 0;
        var written: u32 = 0;
        // unlike JavaScript's decodeURIComponent, we are not handling invalid surrogate pairs
        // we are assuming the input is valid ascii
        while (i < input.len) {
            switch (input[i]) {
                '%' => {
                    if (comptime fault_tolerant) {
                        if (!(i + 3 <= input.len and strings.isASCIIHexDigit(input[i + 1]) and strings.isASCIIHexDigit(input[i + 2]))) {
                            // i do not feel good about this
                            // create-react-app's public/index.html uses %PUBLIC_URL% in various tags
                            // This is an invalid %-encoded string, intended to be swapped out at build time by webpack-html-plugin
                            // We don't process HTML, so rewriting this URL path won't happen
                            // But we want to be a little more fault tolerant here than just throwing up an error for something that works in other tools
                            // So we just skip over it and issue a redirect
                            // We issue a redirect because various other tooling client-side may validate URLs
                            // We can't expect other tools to be as fault tolerant
                            if (i + "PUBLIC_URL%".len < input.len and strings.eqlComptime(input[i + 1 ..][0.."PUBLIC_URL%".len], "PUBLIC_URL%")) {
                                i += "PUBLIC_URL%".len + 1;
                                needs_redirect.?.* = true;
                                continue;
                            }
                            return error.DecodingError;
                        }
                    } else {
                        if (!(i + 3 <= input.len and strings.isASCIIHexDigit(input[i + 1]) and strings.isASCIIHexDigit(input[i + 2])))
                            return error.DecodingError;
                    }

                    try writer.writeByte((strings.toASCIIHexValue(input[i + 1]) << 4) | strings.toASCIIHexValue(input[i + 2]));
                    i += 3;
                    written += 1;
                    continue;
                },
                else => {
                    const start = i;
                    i += 1;

                    // scan ahead assuming .writeAll is faster than .writeByte one at a time
                    while (i < input.len and input[i] != '%') : (i += 1) {}
                    try writer.writeAll(input[start..i]);
                    written += @as(u32, @truncate(i - start));
                },
            }
        }

        return written;
    }
};

pub const FormData = @import("../runtime/webcore/FormData.zig").FormData;

pub const CombinedScanner = struct {
    query: Scanner,
    pathname: PathnameScanner,
    pub fn init(query_string: string, pathname: string, routename: string, url_params: *ParamsList) CombinedScanner {
        return CombinedScanner{
            .query = Scanner.init(query_string),
            .pathname = PathnameScanner.init(pathname, routename, url_params),
        };
    }

    pub fn reset(this: *CombinedScanner) void {
        this.query.reset();
        this.pathname.reset();
    }

    pub fn next(this: *CombinedScanner) ?Scanner.Result {
        return this.pathname.next() orelse this.query.next();
    }
};

fn stringPointerFromStrings(parent: string, in: string) api.StringPointer {
    if (in.len == 0 or parent.len == 0) return api.StringPointer{};

    if (bun.rangeOfSliceInBuffer(in, parent)) |range| {
        return api.StringPointer{ .offset = range[0], .length = range[1] };
    } else {
        if (strings.indexOf(parent, in)) |i| {
            if (comptime Environment.allow_assert) {
                bun.assert(strings.eqlLong(parent[i..][0..in.len], in, false));
            }

            return api.StringPointer{
                .offset = @as(u32, @truncate(i)),
                .length = @as(u32, @truncate(in.len)),
            };
        }
    }

    return api.StringPointer{};
}

pub const PathnameScanner = struct {
    params: *ParamsList,
    pathname: string,
    routename: string,
    i: usize = 0,

    pub inline fn isDone(this: *const PathnameScanner) bool {
        return this.params.len <= this.i;
    }

    pub fn reset(this: *PathnameScanner) void {
        this.i = 0;
    }

    pub fn init(pathname: string, routename: string, params: *ParamsList) PathnameScanner {
        return PathnameScanner{
            .pathname = pathname,
            .routename = routename,
            .params = params,
        };
    }

    pub fn next(this: *PathnameScanner) ?Scanner.Result {
        if (this.isDone()) {
            return null;
        }

        defer this.i += 1;
        const param = this.params.get(this.i);

        return Scanner.Result{
            // TODO: fix this technical debt
            .name = stringPointerFromStrings(this.routename, param.name),
            .name_needs_decoding = false,
            // TODO: fix this technical debt
            .value = stringPointerFromStrings(this.pathname, param.value),
            .value_needs_decoding = strings.containsChar(param.value, '%'),
        };
    }
};

pub const Scanner = struct {
    query_string: string,
    i: usize,
    start: usize = 0,

    pub fn init(query_string: string) Scanner {
        if (query_string.len > 0 and query_string[0] == '?') {
            return Scanner{ .query_string = query_string, .i = 1, .start = 1 };
        }

        return Scanner{ .query_string = query_string, .i = 0, .start = 0 };
    }

    pub inline fn reset(this: *Scanner) void {
        this.i = this.start;
    }

    pub const Result = struct {
        name_needs_decoding: bool = false,
        value_needs_decoding: bool = false,
        name: api.StringPointer,
        value: api.StringPointer,

        pub inline fn rawName(this: *const Result, query_string: string) string {
            return if (this.name.length > 0) query_string[this.name.offset..][0..this.name.length] else "";
        }

        pub inline fn rawValue(this: *const Result, query_string: string) string {
            return if (this.value.length > 0) query_string[this.value.offset..][0..this.value.length] else "";
        }
    };

    /// Get the next query string parameter without allocating memory.
    pub fn next(this: *Scanner) ?Result {
        var relative_i: usize = 0;
        defer this.i += relative_i;

        // reuse stack space
        // otherwise we'd recursively call the function
        loop: while (true) {
            if (this.i >= this.query_string.len) return null;

            const slice = this.query_string[this.i..];
            relative_i = 0;
            var name = api.StringPointer{ .offset = @as(u32, @truncate(this.i)), .length = 0 };
            var value = api.StringPointer{ .offset = 0, .length = 0 };
            var name_needs_decoding = false;

            while (relative_i < slice.len) {
                const char = slice[relative_i];
                switch (char) {
                    '=' => {
                        name.length = @as(u32, @truncate(relative_i));
                        relative_i += 1;

                        value.offset = @as(u32, @truncate(relative_i + this.i));

                        const offset = relative_i;
                        var value_needs_decoding = false;
                        while (relative_i < slice.len and slice[relative_i] != '&') : (relative_i += 1) {
                            value_needs_decoding = value_needs_decoding or switch (slice[relative_i]) {
                                '%', '+' => true,
                                else => false,
                            };
                        }
                        value.length = @as(u32, @truncate(relative_i - offset));
                        // If the name is empty and it's just a value, skip it.
                        // This is kind of an opinion. But, it's hard to see where that might be intentional.
                        if (name.length == 0) return null;
                        return Result{ .name = name, .value = value, .name_needs_decoding = name_needs_decoding, .value_needs_decoding = value_needs_decoding };
                    },
                    '%', '+' => {
                        name_needs_decoding = true;
                    },
                    '&' => {
                        // key&
                        if (relative_i > 0) {
                            name.length = @as(u32, @truncate(relative_i));
                            return Result{ .name = name, .value = value, .name_needs_decoding = name_needs_decoding, .value_needs_decoding = false };
                        }

                        // &&&&&&&&&&&&&key=value
                        while (relative_i < slice.len and slice[relative_i] == '&') : (relative_i += 1) {}
                        this.i += relative_i;

                        // reuse stack space
                        continue :loop;
                    },
                    else => {},
                }

                relative_i += 1;
            }

            if (relative_i == 0) {
                return null;
            }

            name.length = @as(u32, @truncate(relative_i));
            return Result{ .name = name, .value = value, .name_needs_decoding = name_needs_decoding };
        }
    }
};

const string = []const u8;

const resolve_path = @import("../paths/resolve_path.zig");
const std = @import("std");
const ParamsList = @import("../router/router.zig").Param.List;
const expect = std.testing.expect;

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const jsc = bun.jsc;
const strings = bun.strings;
const api = bun.schema.api;
