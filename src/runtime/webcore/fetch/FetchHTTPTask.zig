const FetchHTTPTask = @This();

ref_count: RefCount = .init(),
registry: *bun.jsc.NativeCompletionRegistry,
entry: bun.jsc.NativeCompletionRegistry.Entry = undefined,
progress: FetchProgress,
http: ?*bun.http.AsyncHTTP = null,
response_buffer: bun.MutableString = .{ .allocator = bun.default_allocator, .list = .empty },
request_headers: bun.http.Headers = .{ .allocator = bun.default_allocator },
url_proxy_buffer: []const u8 = "",
hostname: ?[]u8 = null,
request_bytes: []const u8 = "",
sendfile: ?bun.http.SendFile = null,
stream_buffer: ?*bun.http.ThreadSafeStreamBuffer = null,
signal_store: bun.http.Signals.Store = .{},
signals: bun.http.Signals = .{},

const RefCount = bun.ptr.ThreadSafeRefCount(FetchHTTPTask, "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub fn create(registry: *bun.jsc.NativeCompletionRegistry, io: std.Io) bun.OOM!*FetchHTTPTask {
    const this = try bun.tryNew(FetchHTTPTask, .{ .registry = registry, .progress = .{ .io = io } });
    registry.retain();
    return this;
}

pub fn start(this: *FetchHTTPTask) void {
    this.ref();
    if (this.stream_buffer) |buffer| buffer.ref();
    var batch: bun.BackgroundTaskGroup.Batch = .{};
    this.http.?.schedule(bun.default_allocator, &batch);
    bun.http.http_thread.schedule(batch);
}

pub fn abort(this: *FetchHTTPTask) void {
    this.signal_store.aborted.store(true, .release);
    if (this.http) |request| {
        if (request.state.load(.monotonic) != .pending) bun.http.http_thread.scheduleShutdown(request);
    }
}

pub fn close(this: *FetchHTTPTask) void {
    this.progress.close();
    if (this.stream_buffer) |buffer| buffer.clearDrainCallback();
}

pub fn onResult(this: *FetchHTTPTask, _: *bun.http.AsyncHTTP, result: bun.http.HTTPClientResult) void {
    defer if (!result.has_more) this.deref();
    if (result.body) |body| {
        _ = this.signal_store.response_buffered_bytes.fetchAdd(body.list.items.len, .release);
    }
    if (this.progress.publish(result)) _ = this.registry.notify(&this.entry);
}

pub fn consumeResponseBytes(this: *FetchHTTPTask, count: usize) void {
    if (count == 0) return;
    const previous = this.signal_store.response_buffered_bytes.fetchSub(count, .acq_rel);
    bun.assert(previous >= count);
    const high_water = bun.http.Signals.response_buffer_high_water;
    if (previous >= high_water and previous - count < high_water) {
        if (this.http) |request| bun.http.http_thread.scheduleResponseBodyDrain(request.async_http_id);
    }
}

pub fn onDrain(this: *FetchHTTPTask) void {
    if (this.progress.requestDrain()) _ = this.registry.notify(&this.entry);
}

fn deinit(this: *FetchHTTPTask) void {
    if (this.stream_buffer) |buffer| {
        buffer.clearDrainCallback();
        buffer.deref();
    }
    if (this.http) |request| {
        if (request.state.load(.monotonic) == .pending) {
            request.client.deinit();
            request.clearData();
        }
        bun.destroy(request);
    }
    if (this.sendfile) |body| body.fd.close();
    bun.default_allocator.free(this.request_bytes);
    this.response_buffer.deinit();
    this.progress.deinit();
    this.request_headers.deinit();
    bun.default_allocator.free(this.url_proxy_buffer);
    if (this.hostname) |hostname| bun.default_allocator.free(hostname);
    const registry = this.registry;
    bun.destroy(this);
    registry.release();
}

const bun = @import("bun");
const std = @import("std");
const FetchProgress = @import("./FetchProgress.zig");
