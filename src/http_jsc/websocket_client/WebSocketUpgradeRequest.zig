pub fn findValidKey(names: []const []const u8, values: []const []const u8) ?[]const u8 {
    std.debug.assert(names.len == values.len);
    const key = for (names, values) |name, value| {
        if (headerNameEquals(name, "sec-websocket-key")) break value;
    } else return null;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return null;
    if (decoded_len != 16) return null;
    var decoded: [16]u8 = undefined;
    _ = std.base64.standard.Decoder.decode(&decoded, key) catch return null;
    return key;
}

pub fn buildConnectRequest(
    allocator: std.mem.Allocator,
    target_host: []const u8,
    target_port: u16,
    proxy_authorization: ?[]const u8,
    proxy_header_names: []const []const u8,
    proxy_header_values: []const []const u8,
) std.mem.Allocator.Error![]u8 {
    std.debug.assert(proxy_header_names.len == proxy_header_values.len);
    var buffer = std.Io.Writer.Allocating.init(allocator);
    errdefer buffer.deinit();
    const writer = &buffer.writer;

    writer.print("CONNECT {s}:{d} HTTP/1.1\r\n", .{ target_host, target_port }) catch return error.OutOfMemory;
    writer.print("Host: {s}:{d}\r\n", .{ target_host, target_port }) catch return error.OutOfMemory;
    writer.writeAll("Proxy-Connection: Keep-Alive\r\n") catch return error.OutOfMemory;
    if (proxy_authorization) |authorization| {
        writer.print("Proxy-Authorization: {s}\r\n", .{authorization}) catch return error.OutOfMemory;
    }
    for (proxy_header_names, proxy_header_values) |name, value| {
        if (proxy_authorization != null and headerNameEquals(name, "proxy-authorization")) continue;
        writer.print("{s}: {s}\r\n", .{ name, value }) catch return error.OutOfMemory;
    }
    writer.writeAll("\r\n") catch return error.OutOfMemory;
    return buffer.toOwnedSlice();
}

pub const BuildRequestResult = struct {
    body: []u8,
    expected_accept: [28]u8,
};

pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    key: []const u8,
    pathname: []const u8,
    is_https: bool,
    host: []const u8,
    port: u16,
    client_protocol: []const u8,
    extra_header_names: []const []const u8,
    extra_header_values: []const []const u8,
    target_authorization: ?[]const u8,
    offer_permessage_deflate: bool,
) std.mem.Allocator.Error!BuildRequestResult {
    std.debug.assert(extra_header_names.len == extra_header_values.len);
    var user_host: ?[]const u8 = null;
    var user_protocol: ?[]const u8 = null;
    var user_authorization = false;
    for (extra_header_names, extra_header_values) |name, value| {
        if (user_host == null and headerNameEquals(name, "host")) {
            user_host = value;
        } else if (user_protocol == null and headerNameEquals(name, "sec-websocket-protocol")) {
            user_protocol = value;
        } else if (!user_authorization and headerNameEquals(name, "authorization")) {
            user_authorization = true;
        }
    }

    const protocol = user_protocol orelse client_protocol;

    var extra_headers = std.Io.Writer.Allocating.init(allocator);
    defer extra_headers.deinit();
    const writer = &extra_headers.writer;
    if (!user_authorization) {
        if (target_authorization) |authorization| {
            writer.print("Authorization: {s}\r\n", .{authorization}) catch return error.OutOfMemory;
        }
    }
    for (extra_header_names, extra_header_values) |name, value| {
        if (headerNameEquals(name, "host") or
            headerNameEquals(name, "connection") or
            headerNameEquals(name, "upgrade") or
            headerNameEquals(name, "sec-websocket-version") or
            headerNameEquals(name, "sec-websocket-extensions") or
            headerNameEquals(name, "sec-websocket-key") or
            headerNameEquals(name, "sec-websocket-protocol"))
        {
            continue;
        }
        writer.print("{s}: {s}\r\n", .{ name, value }) catch return error.OutOfMemory;
    }

    const extensions: []const u8 = if (offer_permessage_deflate)
        "Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n"
    else
        "";
    var request = std.Io.Writer.Allocating.init(allocator);
    errdefer request.deinit();
    const request_writer = &request.writer;
    request_writer.print("GET {s} HTTP/1.1\r\nHost: ", .{pathname}) catch return error.OutOfMemory;
    if (user_host) |header_host| {
        request_writer.writeAll(header_host) catch return error.OutOfMemory;
    } else {
        writeHost(request_writer, host, port, is_https) catch return error.OutOfMemory;
    }
    request_writer.writeAll(
        "\r\nConnection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Sec-WebSocket-Version: 13\r\n",
    ) catch return error.OutOfMemory;
    request_writer.writeAll(extensions) catch return error.OutOfMemory;
    request_writer.print("Sec-WebSocket-Key: {s}\r\n", .{key}) catch return error.OutOfMemory;
    if (protocol.len != 0) {
        request_writer.print("Sec-WebSocket-Protocol: {s}\r\n", .{protocol}) catch return error.OutOfMemory;
    }
    request_writer.writeAll(extra_headers.written()) catch return error.OutOfMemory;
    request_writer.writeAll("\r\n") catch return error.OutOfMemory;
    const body = try request.toOwnedSlice();
    return .{ .body = body, .expected_accept = computeAcceptValue(key) };
}

pub fn computeAcceptValue(key: []const u8) [28]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&hash);
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &hash);
    return result;
}

fn headerNameEquals(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn writeHost(writer: *std.Io.Writer, host: []const u8, port: u16, is_https: bool) !void {
    try writer.writeAll(host);
    if (std.mem.indexOfScalar(u8, host, ':') == null and
        !((is_https and port == 443) or (!is_https and port == 80)))
    {
        try writer.print(":{d}", .{port});
    }
}

const std = @import("std");

test computeAcceptValue {
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &computeAcceptValue("dGhlIHNhbXBsZSBub25jZQ=="));
}
