//! Request-side framing for the HTTP/3 client: build the QPACK header list
//! from `HTTPClient.buildRequest` and drain the request body (inline bytes or
//! a JS streaming sink) onto the lsquic stream. Mirrors `h2_client/encode.zig`.

/// Build pseudo-headers + user headers and send them on `qs`, then kick off
/// body transmission. The writable callback lets lsquic prioritize pending
/// TLS handshake data before application frames.
pub fn writeRequest(session: *ClientSession, stream: *Stream, qs: *quic.Stream) !void {
    bun.assert(stream.request_state == .headers);
    const client = stream.client orelse return error.Aborted;
    const request = client.buildRequest(client.state.original_request_body.len());
    if (client.verbose != .none) {
        HTTPClient.printRequest(.http3, request, client.url.href, !client.flags.reject_unauthorized, client.state.request_body, client.verbose == .curl);
    }

    var sfa_buffer: [2048]u8 = undefined;
    var sfa: std.heap.BufferFirstAllocator = .init(&sfa_buffer, bun.default_allocator);
    const alloc = sfa.allocator();
    var headers: std.ArrayList(quic.Header) = .empty;
    defer headers.deinit(alloc);
    const header_count = std.math.add(usize, request.headers.len, 4) catch return error.OutOfMemory;
    try headers.ensureTotalCapacityPrecise(alloc, header_count);

    // Names not in the QPACK static table get lowercased into one
    // pre-sized buffer so the pointers stay stable across the batch.
    var name_bytes: usize = 0;
    for (request.headers) |h| name_bytes = std.math.add(usize, name_bytes, h.name.len) catch return error.OutOfMemory;
    const lower = try alloc.alloc(u8, name_bytes);
    defer alloc.free(lower);
    var lower_len: usize = 0;

    var authority: []const u8 = client.url.host;
    headers.items.len = 4;
    for (request.headers) |h| {
        if (quic.Qpack.classify(h.name)) |class| switch (class) {
            .forbidden => {},
            .host => authority = h.value,
            .indexed => |i| headers.appendAssumeCapacity(try .init(i.name, h.value, i.index)),
        } else {
            const dst = lower[lower_len..][0..h.name.len];
            _ = strings.copyLowercase(h.name, dst);
            lower_len += h.name.len;
            headers.appendAssumeCapacity(try .init(dst, h.value, null));
        }
    }
    if (authority.len == 0) authority = session.hostname;
    headers.items[0] = try .init(":method", request.method, .method_get);
    headers.items[1] = try .init(":scheme", "https", .scheme_https);
    headers.items[2] = try .init(":authority", authority, .authority);
    headers.items[3] = try .init(":path", if (request.path.len > 0) request.path else "/", .path);

    const body = client.state.request_body;
    const has_inline_body = client.state.original_request_body == .bytes and body.len > 0;
    const is_streaming = client.state.original_request_body == .stream;

    const end_stream = !has_inline_body and !is_streaming;
    try qs.sendHeaders(headers.items, end_stream);
    stream.request_state = if (end_stream) .done else .body;

    if (has_inline_body) {
        stream.pending_body = body;
        try drainSendBody(stream, qs);
    } else if (is_streaming) {
        stream.is_streaming_body = true;
        try drainSendBody(stream, qs);
    }

    client.state.request_stage = if (stream.request_state == .done) .done else .body;
    client.state.response_stage = .headers;

    // For streaming bodies the JS sink waits for can_stream to start
    // pumping; report progress now so it begins.
    if (is_streaming) client.progressUpdateH3();
}

/// Push as much of the request body onto `qs` as flow control allows. Called
/// from `writeRequest`, `callbacks.onStreamWritable`, and
/// `ClientSession.streamBodyByHttpId` (when the JS sink delivers more bytes).
pub fn drainSendBody(stream: *Stream, qs: *quic.Stream) quic.Stream.WriteError!void {
    if (stream.request_state != .body) return;
    const client = stream.client orelse return;

    if (stream.is_streaming_body) {
        const body = &client.state.original_request_body.stream;
        const sb = body.buffer orelse return;
        const buffer = sb.acquire();
        errdefer sb.release();
        const data = buffer.slice();
        var written: usize = 0;
        while (written < data.len) {
            const w = try qs.write(data[written..]);
            if (w == 0) break;
            written += w;
        }
        buffer.cursor += written;
        const drained = buffer.isEmpty();
        if (drained) buffer.reset();
        if (drained and body.ended) {
            try qs.shutdown();
            stream.request_state = .done;
            client.state.request_stage = .done;
        } else if (!drained) {
            qs.wantWrite(true);
        } else if (data.len > 0) {
            sb.reportDrain();
        }
        sb.release();
        if (stream.request_state == .done) body.detach();
        return;
    }

    while (stream.pending_body.len > 0) {
        const w = try qs.write(stream.pending_body);
        if (w == 0) break;
        stream.pending_body = stream.pending_body[w..];
    }
    if (stream.pending_body.len == 0) {
        try qs.shutdown();
        stream.request_state = .done;
        client.state.request_stage = .done;
    } else {
        qs.wantWrite(true);
    }
}

const ClientSession = @import("./ClientSession.zig");
const Stream = @import("./Stream.zig");
const std = @import("std");

const bun = @import("bun");
const HTTPClient = bun.http;
const strings = bun.strings;
const quic = bun.uws.quic;
