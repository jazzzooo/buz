const Self = @This();

const RefCount = bun.ptr.RefCount(Self, "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

ref_count: RefCount,
server: ?AnyServer = null,
blob: Blob,
headers: Headers = .{ .allocator = bun.default_allocator },
status_code: u16,
stat_hash: bun.fs.StatHash = .{},
has_last_modified_header: bool,
has_content_length_header: bool,
has_content_range_header: bool,

pub const InitOptions = struct {
    server: ?AnyServer,
    status_code: u16 = 200,
    headers: Headers = .{ .allocator = bun.default_allocator },
};

pub fn lastModifiedDate(this: *const Self) bun.JSError!?u64 {
    if (this.has_last_modified_header) {
        if (this.headers.get("last-modified")) |last_modified| {
            if (try parseDate(this.server orelse return null, last_modified)) |date| return date;
        }
    }

    if (this.stat_hash.last_modified_u64 > 0) {
        return this.stat_hash.last_modified_u64;
    }

    return null;
}

fn dateForHeader(server: AnyServer, req: uws.AnyRequest, name: []const u8) bun.JSError!?u64 {
    const value = req.header(name) orelse return null;
    return parseDate(server, value);
}

pub fn initFromBlob(blob: *Blob, opts: InitOptions) bun.OOM!*Self {
    var headers = opts.headers;
    errdefer headers.deinit();
    const route = try bun.default_allocator.create(Self);
    route.* = .{
        .ref_count = .init(),
        .server = opts.server,
        .blob = blob.take(),
        .headers = headers,
        .has_last_modified_header = headers.get("last-modified") != null,
        .has_content_length_header = headers.get("content-length") != null,
        .has_content_range_header = headers.get("content-range") != null,
        .status_code = opts.status_code,
    };
    return route;
}

fn deinit(this: *Self) void {
    this.blob.deinit();
    this.headers.deinit();
    bun.destroy(this);
}

pub fn memoryCost(this: *const Self) usize {
    return @sizeOf(Self) + this.headers.memoryCost() + this.blob.reported_estimated_size;
}

fn writeHeaders(this: *Self, resp: AnyResponse) uws.ResponseWriteError!void {
    const entries = this.headers.entries.slice();
    const names = entries.items(.name);
    const values = entries.items(.value);
    const buf = this.headers.buf.items;

    switch (resp) {
        inline else => |s, tag| {
            for (names, values) |name, value| {
                try s.writeHeader(name.slice(buf), value.slice(buf));
            }
            if (comptime tag != .H3) if (this.server) |srv| if (srv.h3AltSvc()) |alt|
                try s.writeHeader("alt-svc", alt);
        },
    }

    if (!this.has_last_modified_header) {
        if (this.stat_hash.lastModified()) |last_modified| {
            try resp.writeHeader("last-modified", last_modified);
        }
    }

    if (this.has_content_length_header) {
        resp.markWroteContentLengthHeader();
    }
}

pub fn onHEADRequest(this: *Self, req: uws.AnyRequest, resp: AnyResponse) void {
    bun.debugAssert(this.server != null);

    this.on(req, resp, .HEAD);
}

pub fn onRequest(this: *Self, req: uws.AnyRequest, resp: AnyResponse) void {
    this.on(req, resp, bun.http.Method.find(req.method()) orelse .GET);
}

pub fn on(this: *Self, req: uws.AnyRequest, resp: AnyResponse, method: bun.http.Method) void {
    bun.debugAssert(this.server != null);
    this.ref();
    if (this.server) |server| {
        server.onPendingRequest();
        resp.timeout(server.config().idleTimeout);
    }
    const path = this.blob.storePtr().?.getPath() orelse {
        req.setYield(true);
        this.onResponseComplete();
        return;
    };

    const open_flags = bun.O.RDONLY | bun.O.CLOEXEC | bun.O.NONBLOCK;

    const fd_result = brk: {
        if (bun.Environment.isWindows) {
            var path_buffer: bun.PathBuffer = undefined;
            @memcpy(path_buffer[0..path.len], path);
            path_buffer[path.len] = 0;
            break :brk bun.sys.open(
                path_buffer[0..path.len :0],
                open_flags,
                0,
            );
        }
        break :brk bun.sys.openA(
            path,
            open_flags,
            0,
        );
    };

    if (fd_result == .err) {
        req.setYield(true);
        this.onResponseComplete();
        return;
    }

    const fd = fd_result.result;

    // `fd_owned` tracks whether this function is still responsible for
    // closing the file descriptor and releasing the route ref. Every
    // non-streaming return — bodiless status codes (304/204/205/307/308),
    // HEAD, non-streamable files, and the two JS-exception `catch return`
    // paths below — hits this defer, so neither the fd nor the route ref
    // (or the server's pending_requests counter) can leak regardless of
    // which branch runs. The streaming path clears `fd_owned` right
    // before handing ownership to `FileResponseStream`.
    var fd_owned = true;
    defer if (fd_owned) {
        bun.Async.Closer.close(fd, if (bun.Environment.isWindows) bun.windows.libuv.Loop.get());
        this.onResponseComplete();
    };

    const input_if_modified_since_date: ?u64 = dateForHeader(this.server.?, req, "if-modified-since") catch return; // TODO: properly propagate exception upwards

    const can_serve_file: bool, const size: u64, const file_type: bun.io.FileType, const pollable: bool = brk: {
        const stat = switch (bun.sys.fstat(fd)) {
            .result => |s| s,
            .err => break :brk .{ false, 0, undefined, false },
        };

        const stat_size: u64 = @intCast(@max(stat.size, 0));
        const _size: u64 = @min(stat_size -| this.blob.offset, @as(u64, this.blob.size));

        if (bun.S.ISDIR(@intCast(stat.mode))) {
            break :brk .{ false, 0, undefined, false };
        }

        this.stat_hash.hash(stat, path);

        if (bun.S.ISFIFO(@intCast(stat.mode)) or bun.S.ISCHR(@intCast(stat.mode))) {
            break :brk .{ true, _size, .pipe, true };
        }

        if (bun.S.ISSOCK(@intCast(stat.mode))) {
            break :brk .{ true, _size, .socket, true };
        }

        break :brk .{ true, _size, .file, false };
    };

    if (!can_serve_file) {
        req.setYield(true);
        return;
    }

    // Range applies to the slice the route was configured with, not the
    // underlying file: a Bun.file(p).slice(a,b) route exposes only [a,b).
    // RFC 9110 §14.2: Range is only defined for GET (HEAD mirrors GET's
    // headers). Skip if the route has a non-200 status or the user already
    // set Content-Range — they're managing partial responses themselves.
    const range: RangeRequest.Result = if ((method == .GET or method == .HEAD) and file_type == .file and this.status_code == 200 and !this.has_content_range_header)
        RangeRequest.fromRequest(req, size)
    else
        .none;

    const status_code: u16 = brk: {
        // RFC 9110 §13.2.2: conditional preconditions are evaluated before
        // Range. If-Modified-Since on an unmodified resource yields 304 even
        // when a Range header is present (without If-Range).
        // Unlike If-Unmodified-Since, If-Modified-Since can only be used with a
        // GET or HEAD. When used in combination with If-None-Match, it is
        // ignored, unless the server doesn't support If-None-Match.
        if (input_if_modified_since_date) |requested_if_modified_since| {
            if (method == .HEAD or method == .GET) {
                if (this.lastModifiedDate() catch return) |actual_last_modified_at| { // TODO: properly propagate exception upwards
                    // Compare at second precision: the Last-Modified header we
                    // emit is second-granular (HTTP-date), so a sub-second
                    // mtime would otherwise never satisfy `<=` against the
                    // client's echoed value.
                    if (actual_last_modified_at / 1000 <= requested_if_modified_since / 1000) {
                        break :brk 304;
                    }
                }
            }
        }

        if (range == .unsatisfiable) break :brk 416;
        if (range == .satisfiable) break :brk 206;

        if (size == 0 and file_type == .file and this.status_code == 200) {
            break :brk 204;
        }

        break :brk this.status_code;
    };

    req.setYield(false);

    const body = this.renderHeaders(resp, method, status_code, range, file_type, size) catch |err| {
        if (err != error.ConnectionClosed) resp.forceClose();
        return;
    } orelse return;

    // Hand ownership of the fd to FileResponseStream; disable the defer close.
    // The route ref taken at the top of on() is released in onStreamComplete.
    fd_owned = false;
    FileResponseStream.start(.{
        .fd = fd,
        .auto_close = true,
        .resp = resp,
        .runtime_loop = this.server.?.vm().runtimeLoopHandle(),
        .file_type = file_type,
        .pollable = pollable,
        .offset = body.offset,
        .length = body.length,
        .idle_timeout = this.server.?.config().idleTimeout,
        .ctx = .init(this),
        .on_complete = onStreamComplete,
        .on_error = onStreamError,
    });
}

const ResponseBody = struct { offset: u64, length: ?u64 };

fn renderHeaders(this: *Self, resp: AnyResponse, method: bun.http.Method, status: u16, range: RangeRequest.Result, file_type: bun.io.FileType, size: u64) uws.ResponseWriteError!?ResponseBody {
    var status_buffer: [6]u8 = undefined;
    try resp.writeStatus(HTTPStatusText.format(status, &status_buffer));
    try resp.writeMark();
    try this.writeHeaders(resp);

    switch (status) {
        204, 205, 304, 307, 308 => {
            try resp.endWithoutBody(resp.shouldCloseConnection());
            return null;
        },
        else => {},
    }

    const body: ResponseBody = switch (range) {
        .satisfiable => |r| body: {
            var buffer: [96]u8 = undefined;
            try resp.writeHeader("content-range", std.fmt.bufPrint(&buffer, "bytes {d}-{d}/{d}", .{ r.start, r.end, size }) catch unreachable);
            try resp.writeHeader("accept-ranges", "bytes");
            break :body .{ .offset = this.blob.offset + r.start, .length = r.end - r.start + 1 };
        },
        .unsatisfiable => {
            var buffer: [64]u8 = undefined;
            try resp.writeHeader("content-range", std.fmt.bufPrint(&buffer, "bytes */{d}", .{size}) catch unreachable);
            try resp.writeHeader("accept-ranges", "bytes");
            try resp.end("", resp.shouldCloseConnection());
            return null;
        },
        .none => .{
            .offset = if (file_type == .file) this.blob.offset else 0,
            .length = if (file_type == .file) size else null,
        },
    };

    if (file_type == .file and !resp.state().hasWrittenContentLengthHeader()) {
        try resp.writeHeaderInt("content-length", body.length.?);
        resp.markWroteContentLengthHeader();
    }
    if (method == .HEAD) {
        try resp.endWithoutBody(resp.shouldCloseConnection());
        return null;
    }
    return body;
}

fn onStreamComplete(ctx: FileResponseStream.Context) void {
    const this = ctx.get(*Self);
    this.onResponseComplete();
}

fn onStreamError(ctx: FileResponseStream.Context, _: FileResponseStream.Failure) void {
    const this = ctx.get(*Self);
    this.onResponseComplete();
}

fn onResponseComplete(this: *Self) void {
    if (this.server) |server| {
        server.onStaticRequestComplete();
    }
    this.deref();
}

const AnyServer = bun.api.AnyServer;
const Blob = bun.webcore.Blob;
const FileRoute = Self;
pub fn parseDate(server: AnyServer, value: []const u8) bun.JSError!?u64 {
    var string = bun.String.cloneUTF8(value);
    defer string.deref();
    const date = try bun.api.StringEngine.parseDate(&string, server.globalThis());
    if (std.math.isNan(date) or !std.math.isFinite(date) or date < 0) return null;
    return @intFromFloat(date);
}

pub const FromBlobOptions = struct {
    server: ?AnyServer,
    status_code: u16 = 200,
    headers: ?*bun.jsc.WebCore.FetchHeaders = null,
};

pub fn fromBlobWithHeaders(blob: *Blob, options: FromBlobOptions) bun.OOM!*FileRoute {
    const headers = try bun.api.HTTPHeadersEngine.from(
        options.headers,
        bun.default_allocator,
        .{ .body = &.{ .Blob = blob.* } },
    );
    return FileRoute.initFromBlob(blob, .{
        .server = options.server,
        .status_code = options.status_code,
        .headers = headers,
    });
}

pub fn fromResponse(
    context: anytype,
    response: *bun.jsc.WebCore.Response,
) bun.bindgen.CallError(@TypeOf(context))!?*FileRoute {
    const body_value = response.getBodyValue();
    try body_value.toBlobIfPossible();
    if (body_value.* != .Blob or !body_value.Blob.needsToReadFile()) return null;
    if (body_value.Blob.storePtr().?.data.file.pathlike == .fd) {
        return context.fail(.file_route_fd_todo, {});
    }

    var blob = try body_value.Blob.dupe();
    defer blob.deinit();
    bun.assertf(!blob.isHeapAllocated(), "expected blob not to be heap-allocated", .{});
    const headers = try bun.api.HTTPHeadersEngine.from(
        response.getInitHeaders(),
        bun.default_allocator,
        .{ .body = &.{ .Blob = blob } },
    );
    return try FileRoute.initFromBlob(&blob, .{
        .server = null,
        .headers = headers,
        .status_code = response.statusCode(),
    });
}

pub fn fromBlob(blob: *Blob) bun.OOM!?*FileRoute {
    if (!blob.needsToReadFile()) return null;
    var body = try blob.dupe();
    defer body.deinit();
    bun.assertf(!body.isHeapAllocated(), "expected blob not to be heap-allocated", .{});
    const headers = try bun.api.HTTPHeadersEngine.from(
        null,
        bun.default_allocator,
        .{ .body = &.{ .Blob = body } },
    );
    return try FileRoute.initFromBlob(&body, .{ .server = null, .headers = headers });
}

const std = @import("std");

const bun = @import("bun");
const Headers = bun.http.Headers;

const FileResponseStream = @import("./FileResponseStream.zig");
const RangeRequest = @import("./RangeRequest.zig");
const HTTPStatusText = @import("./HTTPStatusText.zig");

const uws = bun.uws;
const AnyResponse = uws.AnyResponse;
