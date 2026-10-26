//! Engine bridges for `bun.http.{Headers,H2Client,H3Client}`. Keeps `src/http/`
//! free of JSC types.

pub fn toFetchHeaders(this: *Headers, global: *bun.jsc.JSGlobalObject) bun.JSError!FetchHeaders.Owner {
    if (this.entries.len == 0) {
        return FetchHeaders.createEmpty();
    }
    const entries = this.entries.slice();
    return FetchHeaders.create(
        global,
        entries.items(.name),
        entries.items(.value),
        this.buf.items,
    );
}

pub const FromOptions = struct {
    body: ?*const Blob.Any = null,
};

pub fn from(fetch_headers_ref: ?*FetchHeaders, allocator: std.mem.Allocator, options: FromOptions) !Headers {
    var headers = Headers{ .allocator = allocator };
    errdefer headers.deinit();
    if (fetch_headers_ref) |headers_ref| {
        var snapshot = try headers_ref.snapshotForHTTP();
        defer snapshot.deinit();
        if (snapshot.len() > std.math.maxInt(u32)) return error.OutOfMemory;
        try headers.entries.ensureTotalCapacity(allocator, snapshot.len());
        var iterator = snapshot.iterator();
        while (iterator.next()) |converted| {
            var entry = converted;
            defer entry.deinit();
            const name = entry.value.key.unsafePtr("entry owns the header name until append finishes copying it; entry.deinit runs afterward").latin1;
            const value = entry.value.value.unsafePtr("entry owns the header value until append finishes copying it; entry.deinit runs afterward").latin1;
            try headers.append(name, value);
        }
    }
    if (options.body) |body| {
        if (body.hasContentTypeFromUser() and headers.getContentType() == null)
            try headers.append("Content-Type", body.contentType());
    }
    return headers;
}

pub const H2TestingAPIs = struct {
    pub fn liveCounts(
        _: bun.bindgen.CallContext(H2LiveCountsSchema),
        _: bun.bindgen.Args(H2LiveCountsSchema),
    ) bun.JSError!bun.bindgen.Return(H2LiveCountsSchema) {
        return .{
            .sessions = H2Client.live_sessions.load(.monotonic),
            .streams = H2Client.live_streams.load(.monotonic),
        };
    }
};

pub const H3TestingAPIs = struct {
    pub fn quicLiveCounts(
        _: bun.bindgen.CallContext(H3LiveCountsSchema),
        _: bun.bindgen.Args(H3LiveCountsSchema),
    ) bun.JSError!bun.bindgen.Return(H3LiveCountsSchema) {
        return .{
            .sessions = @intCast(H3Client.live_sessions.load(.monotonic)),
            .streams = @intCast(H3Client.live_streams.load(.monotonic)),
        };
    }
};

const H2Client = @import("../http/H2Client.zig");
const H3Client = @import("../http/H3Client.zig");

const std = @import("std");
const bun = @import("bun");
const Blob = bun.webcore.Blob;
const FetchHeaders = bun.webcore.FetchHeaders;
const Headers = bun.http.Headers;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const H2LiveCountsSchema = InternalTestingBindings.function("h2LiveCounts");
const H3LiveCountsSchema = InternalTestingBindings.function("h3LiveCounts");
const H2LiveCountsBinding = bun.bindgen.Fn(H2LiveCountsSchema, H2TestingAPIs.liveCounts);
const H3LiveCountsBinding = bun.bindgen.Fn(H3LiveCountsSchema, H3TestingAPIs.quicLiveCounts);

comptime {
    _ = H2LiveCountsBinding;
    _ = H3LiveCountsBinding;
}
