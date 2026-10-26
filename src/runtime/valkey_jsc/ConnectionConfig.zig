connection_strings: []u8,
protocol: valkey.Protocol,
address: valkey.Address,
username: []const u8,
password: []const u8,
database: u32,

pub fn parse(context: anytype, input: bun.String) bindgen.CallError(@TypeOf(context))!ConnectionConfig {
    const allocator = bun.default_allocator;
    const input_utf8 = try input.toUTF8WithoutRef(allocator);
    defer input_utf8.deinit();
    const bytes = input_utf8.slice();
    if (bytes.len == 0) return context.fail(.invalid_url, {});

    var url = parsed: {
        if (bun.strings.contains(bytes, "://")) {
            break :parsed (try URL.fromString(input)) orelse return context.fail(.invalid_url, {});
        }
        const with_protocol = try std.fmt.allocPrint(allocator, "valkey://{s}", .{bytes});
        defer allocator.free(with_protocol);
        break :parsed (try URL.fromUTF8(with_protocol)) orelse return context.fail(.invalid_url, {});
    };
    defer url.deinit();

    const protocol_string = try url.protocol();
    defer protocol_string.deref();
    const protocol_utf8 = try protocol_string.toUTF8WithoutRef(allocator);
    defer protocol_utf8.deinit();
    const protocol_name = std.mem.trimEnd(u8, protocol_utf8.slice(), ":");
    const protocol = valkey.Protocol.Map.get(protocol_name) orelse return context.fail(.invalid_protocol, {});

    const username_string = try url.username();
    defer username_string.deref();
    const username_utf8 = try username_string.toUTF8WithoutRef(allocator);
    defer username_utf8.deinit();

    const password_string = try url.password();
    defer password_string.deref();
    const password_utf8 = try password_string.toUTF8WithoutRef(allocator);
    defer password_utf8.deinit();

    const host_string = try url.host();
    defer host_string.deref();
    const host_utf8 = try host_string.toUTF8WithoutRef(allocator);
    defer host_utf8.deinit();

    const path_string = try url.pathname();
    defer path_string.deref();
    const path_utf8 = try path_string.toUTF8WithoutRef(allocator);
    defer path_utf8.deinit();

    const is_unix = switch (protocol) {
        .standalone_unix, .standalone_tls_unix => true,
        .standalone, .standalone_tls => false,
    };
    const host = if (is_unix) path_utf8.slice() else host_utf8.slice();
    if (is_unix and host.len == 0) return context.fail(.unix_path_required, {});
    const port = if (is_unix) 0 else url.port() orelse 6379;
    if (!is_unix and port == 0) return context.fail(.tcp_port_zero, {});
    const database = if (is_unix) 0 else try parseDatabase(context, path_utf8.slice());

    var strings = bun.StringBuilder{};
    strings.count(username_utf8.slice());
    strings.count(password_utf8.slice());
    strings.count(host);
    try strings.allocate(allocator);
    defer strings.deinit(allocator);
    const username = strings.append(username_utf8.slice());
    const password = strings.append(password_utf8.slice());
    const hostname = strings.append(host);
    var connection_strings: []u8 = &.{};
    strings.moveToSlice(&connection_strings);
    return .{
        .connection_strings = connection_strings,
        .protocol = protocol,
        .address = if (is_unix) .{ .unix = hostname } else .{ .host = .{ .host = hostname, .port = port } },
        .username = username,
        .password = password,
        .database = database,
    };
}

fn parseDatabase(context: anytype, path: []const u8) bindgen.CallError(@TypeOf(context))!u32 {
    if (path.len <= 1) return 0;
    const value = path[1..];
    const database: ?u32 = parsed: {
        for (value) |character| if (!std.ascii.isDigit(character)) break :parsed null;
        break :parsed std.fmt.parseInt(u32, value, 10) catch null;
    };
    if (database) |number| return number;

    const message = try std.fmt.allocPrint(bun.default_allocator, "Invalid database number in Redis URL: \"{s}\"", .{value});
    defer bun.default_allocator.free(message);
    return context.fail(.invalid_database, try bindgen.ThreadSafeDOMString.fromUTF8(message));
}

pub fn deinit(this: *ConnectionConfig) void {
    bun.default_allocator.free(this.connection_strings);
    this.* = undefined;
}

const ConnectionConfig = @This();
const bun = @import("bun");
const std = @import("std");
const bindgen = bun.bindgen;
const valkey = @import("valkey.zig");
const URL = @import("../../jsc/URL.zig").URL;
