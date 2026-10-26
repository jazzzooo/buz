const Self = @This();

const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

// TODO: Remove optional. StaticRoute requires a server object or else it will
// not ensure it is alive while sending a large blob.
ref_count: RefCount,
server: ?AnyServer = null,
status_code: u16,
blob: AnyBlob,
has_content_disposition: bool = false,
headers: Headers = .{
    .allocator = bun.default_allocator,
},

pub const InitOptions = struct {
    server: ?AnyServer,
    mime_type: ?*const bun.http.MimeType = null,
    status_code: u16 = 200,
    headers: Headers = .{ .allocator = bun.default_allocator },
    has_content_disposition: bool = false,
    generate_etag: bool = true,
};

/// Consumes headers on every outcome; takes the blob only on success.
pub fn initFromAnyBlob(blob: *AnyBlob, options: InitOptions) bun.OOM!*Self {
    var headers = options.headers;
    errdefer headers.deinit();
    if (headers.getContentType() == null) {
        if (options.mime_type) |mime_type| {
            try headers.append("Content-Type", mime_type.value);
        } else if (blob.hasContentTypeFromUser()) {
            try headers.append("Content-Type", blob.contentType());
        }
    }

    if (options.generate_etag and headers.get("etag") == null) {
        if (blob.slice().len > 0) {
            try ETag.appendToHeaders(blob.slice(), &headers);
        }
    }

    const route = try bun.default_allocator.create(Self);
    route.* = .{
        .ref_count = .init(),
        .blob = blob.take(),
        .has_content_disposition = options.has_content_disposition,
        .headers = headers,
        .server = options.server,
        .status_code = options.status_code,
    };
    return route;
}

fn deinit(this: *Self) void {
    this.blob.detach();
    this.headers.deinit();

    bun.destroy(this);
}

pub fn clone(this: *Self) !*Self {
    this.blob = .{ .Blob = try this.blob.intoBlob() };
    var blob = try this.blob.Blob.dupe();
    defer blob.deinit();
    var headers = try this.headers.clone();
    errdefer headers.deinit();
    const result = try bun.default_allocator.create(Self);
    result.* = .{
        .ref_count = .init(),
        .blob = .{ .Blob = blob.take() },
        .has_content_disposition = this.has_content_disposition,
        .headers = headers,
        .server = this.server,
        .status_code = this.status_code,
    };
    return result;
}

pub fn memoryCost(this: *const Self) usize {
    return @sizeOf(Self) + this.blob.memoryCost() + this.headers.memoryCost();
}

// HEAD requests have no body.
pub fn onHEADRequest(this: *Self, req: uws.AnyRequest, resp: AnyResponse) void {
    // Check If-None-Match for HEAD requests with 200 status
    if (this.status_code == 200) {
        if (this.render304NotModifiedIfNoneMatch(req, resp)) {
            return;
        }
    }

    // Continue with normal HEAD request handling
    req.setYield(false);
    this.onHEAD(resp);
}

pub fn onHEAD(this: *Self, resp: AnyResponse) void {
    bun.debugAssert(this.server != null);
    this.ref();
    if (this.server) |server| {
        server.onPendingRequest();
        resp.timeout(server.config().idleTimeout);
    }
    defer this.onResponseComplete();
    var result: uws.ResponseWriteError!void = {};
    resp.corked(renderMetadataAndEnd, .{ this, resp, &result }) catch |err| return closeAfterFailure(resp, err);
    result catch |err| closeAfterFailure(resp, err);
}

fn renderMetadataAndEnd(this: *Self, resp: AnyResponse, result: *uws.ResponseWriteError!void) void {
    result.* = this.renderHEAD(resp);
}

fn renderHEAD(this: *Self, resp: AnyResponse) uws.ResponseWriteError!void {
    try this.renderMetadata(resp);
    try resp.writeHeaderInt("Content-Length", this.blob.size());
    try resp.endWithoutBody(resp.shouldCloseConnection());
}

pub fn onRequest(this: *Self, req: uws.AnyRequest, resp: AnyResponse) void {
    const method = bun.http.Method.find(req.method()) orelse .GET;
    if (method == .GET) {
        this.onGET(req, resp);
    } else if (method == .HEAD) {
        this.onHEADRequest(req, resp);
    } else {
        // For other methods, use the original behavior
        req.setYield(false);
        this.on(resp);
    }
}

pub fn onGET(this: *Self, req: uws.AnyRequest, resp: AnyResponse) void {
    // Check If-None-Match for GET requests with 200 status
    if (this.status_code == 200) {
        if (this.render304NotModifiedIfNoneMatch(req, resp)) {
            return;
        }
    }

    // Continue with normal GET request handling
    req.setYield(false);
    this.on(resp);
}

pub fn on(this: *Self, resp: AnyResponse) void {
    bun.debugAssert(this.server != null);
    this.ref();
    if (this.server) |server| {
        server.onPendingRequest();
        resp.timeout(server.config().idleTimeout);
    }
    const finished = this.doRenderBlob(resp) catch |err| {
        closeAfterFailure(resp, err);
        this.onResponseComplete();
        return;
    };
    if (finished) {
        this.onResponseComplete();
        return;
    }

    this.toAsync(resp);
}

fn toAsync(this: *Self, resp: AnyResponse) void {
    resp.onAborted(*Self, onAborted, this);
    resp.onWritable(*Self, onWritable, this);
}

fn onAborted(this: *Self, resp: AnyResponse) void {
    detachCallbacks(resp);
    this.onResponseComplete();
}

fn detachCallbacks(resp: AnyResponse) void {
    resp.clearAborted();
    resp.clearOnWritable();
    resp.clearTimeout();
}

fn closeAfterFailure(resp: AnyResponse, err: uws.ResponseWriteError) void {
    if (err != error.ConnectionClosed) resp.forceClose();
}

fn onResponseComplete(this: *Self) void {
    if (this.server) |server| {
        server.onStaticRequestComplete();
    }
    this.deref();
}

fn doRenderBlob(this: *Self, resp: AnyResponse) uws.ResponseWriteError!bool {
    if (this.blob.fastSize() < 16384 - 1024) {
        var result: uws.ResponseWriteError!bool = false;
        try resp.corked(doRenderBlobCorked, .{ this, resp, &result });
        return result;
    } else {
        try this.renderMetadata(resp);
        return this.onWritableBytes(0, resp);
    }
}

fn doRenderBlobCorked(this: *Self, resp: AnyResponse, result: *uws.ResponseWriteError!bool) void {
    this.renderMetadata(resp) catch |err| {
        result.* = err;
        return;
    };
    result.* = this.onWritableBytes(0, resp);
}

fn onWritable(this: *Self, write_offset: u64, resp: AnyResponse) bool {
    detachCallbacks(resp);
    if (this.server) |server| {
        resp.timeout(server.config().idleTimeout);
    }

    const finished = this.onWritableBytes(write_offset, resp) catch |err| {
        closeAfterFailure(resp, err);
        this.onResponseComplete();
        return false;
    };
    if (!finished) {
        this.toAsync(resp);
        return false;
    }

    this.onResponseComplete();
    return true;
}

fn onWritableBytes(this: *Self, write_offset: u64, resp: AnyResponse) uws.ResponseWriteError!bool {
    const blob = this.blob;
    const all_bytes = blob.slice();

    const bytes = all_bytes[@min(all_bytes.len, write_offset)..];

    return resp.tryEnd(bytes, all_bytes.len, resp.shouldCloseConnection());
}

fn doWriteStatus(_: *Self, status: u16, resp: AnyResponse) uws.ResponseWriteError!void {
    var buffer: [6]u8 = undefined;
    try resp.writeStatus(HTTPStatusText.format(status, &buffer));
}

fn doWriteHeaders(this: *Self, resp: AnyResponse) uws.ResponseWriteError!void {
    switch (resp) {
        inline else => |s, tag| {
            const entries = this.headers.entries.slice();
            const names = entries.items(.name);
            const values = entries.items(.value);
            const buf = this.headers.buf.items;

            for (names, values) |name, value| {
                try s.writeHeader(name.slice(buf), value.slice(buf));
            }
            if (comptime tag != .H3) if (this.server) |srv| if (srv.h3AltSvc()) |alt|
                try s.writeHeader("alt-svc", alt);
        },
    }
}

fn renderMetadata(this: *Self, resp: AnyResponse) uws.ResponseWriteError!void {
    var status = this.status_code;
    const size = this.blob.size();

    status = if (status == 200 and size == 0 and !this.blob.isDetached())
        204
    else
        status;

    try this.doWriteStatus(status, resp);
    try this.doWriteHeaders(resp);
}

pub fn onWithMethod(this: *Self, method: bun.http.Method, resp: AnyResponse) void {
    switch (method) {
        .GET => this.on(resp),
        .HEAD => this.onHEAD(resp),
        else => {
            this.doWriteStatus(405, resp) catch |err| return closeAfterFailure(resp, err);
            resp.endWithoutBody(resp.shouldCloseConnection()) catch |err| closeAfterFailure(resp, err);
        },
    }
}

fn render304NotModifiedIfNoneMatch(this: *Self, req: uws.AnyRequest, resp: AnyResponse) bool {
    const if_none_match = req.header("if-none-match") orelse return false;
    const etag = this.headers.get("etag") orelse return false;
    if (if_none_match.len == 0 or etag.len == 0) {
        return false;
    }

    if (!ETag.ifNoneMatch(etag, if_none_match)) {
        return false;
    }

    // Return 304 Not Modified
    req.setYield(false);
    this.ref();
    if (this.server) |server| {
        server.onPendingRequest();
        resp.timeout(server.config().idleTimeout);
    }
    defer this.onResponseComplete();
    this.render304(resp) catch |err| closeAfterFailure(resp, err);
    return true;
}

fn render304(this: *Self, resp: AnyResponse) uws.ResponseWriteError!void {
    try this.doWriteStatus(304, resp);
    try this.doWriteHeaders(resp);
    try resp.endWithoutBody(resp.shouldCloseConnection());
}

const AnyServer = bun.api.AnyServer;
const AnyBlob = bun.webcore.Blob.Any;
const StaticRoute = Self;
pub const InitFromBytesOptions = struct {
    server: ?AnyServer,
    mime_type: ?*const bun.http.MimeType = null,
    status_code: u16 = 200,
    headers: ?*bun.jsc.WebCore.FetchHeaders = null,
};

pub fn fromBlobWithHeaders(blob: *AnyBlob, options: InitFromBytesOptions) bun.OOM!*StaticRoute {
    const headers = try bun.api.HTTPHeadersEngine.from(
        options.headers,
        bun.default_allocator,
        .{ .body = blob },
    );
    return StaticRoute.initFromAnyBlob(blob, .{
        .server = options.server,
        .mime_type = options.mime_type,
        .status_code = options.status_code,
        .headers = headers,
    });
}

pub fn sendBlobThenDeinit(resp: bun.uws.AnyResponse, blob: *AnyBlob, options: InitFromBytesOptions) bun.OOM!void {
    const route = try fromBlobWithHeaders(blob, options);
    defer route.deref();
    route.on(resp);
}

pub fn fromResponse(
    context: anytype,
    response: *bun.jsc.WebCore.Response,
) bun.bindgen.CallError(@TypeOf(context))!*StaticRoute {
    const body_value = response.getBodyValue();
    const was_string = body_value.wasString();
    try body_value.toBlobIfPossible();

    var blob: AnyBlob = brk: {
        switch (body_value.*) {
            .Used => return context.fail(.static_route_body_used, {}),
            .Null, .Empty => break :brk .{
                .InternalBlob = .{ .bytes = .init(bun.default_allocator) },
            },
            .Blob, .InternalBlob, .WTFStringImpl => {
                if (body_value.* == .Blob and body_value.Blob.needsToReadFile()) {
                    return context.fail(.static_route_file_todo, {});
                }
                var body_blob = try body_value.use();
                errdefer body_value.* = .{ .Blob = body_blob.take() };
                bun.assertf(!body_blob.isHeapAllocated(), "expected blob not to be heap-allocated", .{});
                body_value.* = .{ .Blob = try body_blob.dupe() };
                break :brk .{ .Blob = body_blob };
            },
            else => return context.fail(.static_route_body_not_buffered, {}),
        }
    };
    errdefer blob.detach();

    var headers = if (response.getInitHeaders()) |source|
        try bun.api.HTTPHeadersEngine.from(source, bun.default_allocator, .{ .body = &blob })
    else
        bun.http.Headers{ .allocator = bun.default_allocator };
    headers.remove("transfer-encoding");
    headers.remove("content-length");
    const has_content_disposition = headers.getContentDisposition() != null;
    const string_mime_type = bun.http.MimeType.Compact.from(.@"text/plain; charset=utf-8").toMimeType();

    return StaticRoute.initFromAnyBlob(&blob, .{
        .has_content_disposition = has_content_disposition,
        .headers = headers,
        .server = null,
        .status_code = response.statusCode(),
        .mime_type = if (was_string) &string_mime_type else null,
    });
}

const std = @import("std");

const bun = @import("bun");

const ETag = bun.http.ETag;
const Headers = bun.http.Headers;
const HTTPStatusText = @import("./HTTPStatusText.zig");

const uws = bun.uws;
const AnyResponse = uws.AnyResponse;
