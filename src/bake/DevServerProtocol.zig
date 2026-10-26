pub const internal_prefix = "/_bun";
pub const asset_prefix = internal_prefix ++ "/asset";
pub const client_prefix = internal_prefix ++ "/client";

/// Every message uses binary transport. The first byte is a message ID and all
/// integers are little-endian.
pub const MessageId = enum(u8) {
    /// Version payload. Sent on connection startup. The client should issue a
    /// hard reload when it differs from its configured version.
    version = 'V',
    /// Successful bundle payload:
    /// - repeated changed server route IDs, terminated by `-1`
    /// - repeated route/CSS attachment records, terminated by `-1`
    /// - repeated CSS mutation records
    /// - the remaining bytes as JavaScript source
    hot_update = 'u',
    /// Error removals followed by serialized failures.
    errors = 'e',
    /// Browser tab ID followed by opaque browser-error bytes.
    browser_message = 'b',
    /// Browser tab IDs whose browser errors should be cleared.
    browser_message_clear = 'B',
    /// Removed request error IDs, a route pattern, and one serialized failure.
    request_handler_error = 'h',
    /// Incremental graph nodes and edges for the development visualizer.
    visualizer = 'v',
    /// DevServer and process memory counters for the memory visualizer.
    memory_visualizer = 'M',
    /// The route bundle ID selected for a client URL.
    set_url_response = 'n',
    /// Watcher synchronization state used by DevServer tests.
    testing_watch_synchronization = 'r',

    pub inline fn char(id: MessageId) u8 {
        return @backingInt(id);
    }
};

pub const IncomingMessageId = enum(u8) {
    /// Initialization packet containing the hexadecimal source-map ID.
    init = 'i',
    /// A sequence of `HmrTopic` bytes to subscribe to.
    subscribe = 's',
    /// A client-side navigation pathname.
    set_url = 'n',
    /// Enables watcher-event batching in DevServer tests.
    testing_batch_events = 'H',
    /// A browser console message.
    console_log = 'l',
    /// A little-endian `u64` source-map key to release.
    unref_source_map = 'u',
    _,
};

pub const ConsoleLogKind = enum(u8) {
    log = 'l',
    err = 'e',
};

pub const HmrTopic = enum(u8) {
    hot_update = 'h',
    errors = 'e',
    browser_error = 'E',
    incremental_visualizer = 'v',
    memory_visualizer = 'M',
    testing_watch_synchronization = 'r',
    _,

    const field_names = @typeInfo(HmrTopic).@"enum".field_names;
    const default_bit = false;

    pub const max_count = field_names.len;
    pub const Bits = @Struct(
        .@"packed",
        @Int(.unsigned, max_count),
        field_names,
        &@splat(bool),
        &@splat(.{ .default_value_ptr = &default_bit }),
    );
};

pub fn parseHexToInt(comptime T: type, slice: []const u8) ?T {
    if (slice.len != @sizeOf(T) * 2) return null;
    var out: [@sizeOf(T)]u8 = undefined;
    const written = std.fmt.hexToBytes(&out, slice) catch return null;
    if (written.len != out.len) return null;
    return @bitCast(out);
}

pub fn extractPathnameFromUrl(url: []const u8) []const u8 {
    var pathname = url;
    if (std.mem.indexOf(u8, url, "://")) |protocol_end| {
        const authority = url[protocol_end + 3 ..];
        const path_start = std.mem.indexOfScalar(u8, authority, '/') orelse return "/";
        const query_start = std.mem.indexOfScalar(u8, authority, '?') orelse authority.len;
        const fragment_start = std.mem.indexOfScalar(u8, authority, '#') orelse authority.len;
        if (path_start > @min(query_start, fragment_start)) return "/";
        pathname = authority[path_start..];
    }

    const query_index = std.mem.indexOfScalar(u8, pathname, '?') orelse pathname.len;
    const hash_index = std.mem.indexOfScalar(u8, pathname, '#') orelse pathname.len;
    pathname = pathname[0..@min(query_index, hash_index)];

    return pathname;
}

test "hex integers require the complete fixed-width representation" {
    try std.testing.expectEqual(@as(?u16, @bitCast([2]u8{ 0x12, 0x34 })), parseHexToInt(u16, "1234"));
    try std.testing.expectEqual(@as(?u16, null), parseHexToInt(u16, "12"));
    try std.testing.expectEqual(@as(?u16, null), parseHexToInt(u16, "zzzz"));
}

test "URL pathname extraction strips the authority query and fragment" {
    try std.testing.expectEqualStrings("/route", extractPathnameFromUrl("https://example.com/route?query#fragment"));
    try std.testing.expectEqualStrings("/route", extractPathnameFromUrl("/route#fragment"));
    try std.testing.expectEqualStrings("/", extractPathnameFromUrl("https://example.com?query"));
    try std.testing.expectEqualStrings("relative", extractPathnameFromUrl("relative?query"));
}

const std = @import("std");
