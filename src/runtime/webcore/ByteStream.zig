const ByteStream = @This();

buffer: std.array_list.Managed(u8) = .init(bun.default_allocator),
has_received_last_chunk: bool = false,
pending: streams.Result.Pending = .{ .result = .{ .done = {} } },
done: bool = false,
pending_buffer: []u8 = &.{},
offset: usize = 0,
highWaterMark: Blob.SizeType = 0,
pipe: Pipe = .{},
size_hint: Blob.SizeType = 0,
buffer_action: ?BufferAction = null,
consume_callback: ?struct {
    context: bun.bindgen.NativeCallbackContext(.vm),
    run: *const fn (bun.bindgen.NativeCallbackContext(.vm), usize) void,
} = null,

fn didConsume(this: *ByteStream, count: usize) void {
    if (this.consume_callback) |callback| callback.run(callback.context, count);
}

pub const Source = webcore.ReadableStream.NewSource(
    @This(),
    "Bytes",
    onStart,
    onPull,
    onCancel,
    deinit,
    null,
    drainForBindings,
    memoryCost,
    toBufferedValue,
);

const log = Output.scoped(.ByteStream, .visible);

pub const tag = webcore.ReadableStream.Tag.Bytes;

pub fn onStart(this: *@This()) streams.ReadableStart {
    if (this.pending.result == .err) return .{ .ready = {} };
    this.compact();
    if (this.has_received_last_chunk and this.buffer.items.len == 0) {
        return .{ .empty = {} };
    }

    if (this.has_received_last_chunk) {
        var buffer = this.buffer.moveToUnmanaged();
        return .{ .owned_and_done = bun.ByteList.moveFromList(&buffer) };
    }

    if (this.highWaterMark == 0) {
        return .{ .ready = {} };
    }

    // For HTTP, the maximum streaming response body size will be 512 KB.
    // #define LIBUS_RECV_BUFFER_LENGTH 524288
    // For HTTPS, the size is probably quite a bit lower like 64 KB due to TLS transmission.
    // We add 1 extra page size so that if there's a little bit of excess buffered data, we avoid extra allocations.
    const page_size: Blob.SizeType = @intCast(std.heap.pageSize());
    return .{ .chunk_size = @min(512 * 1024 + page_size, @max(this.highWaterMark, page_size)) };
}

pub fn isCancelled(this: *const @This()) bool {
    return this.parent().cancelled;
}

pub fn unpipe(this: *@This()) void {
    this.pipe.deinit();
}

pub fn onData(
    this: *@This(),
    stream: streams.Result,
    allocator: std.mem.Allocator,
) bun.JSTerminated!void {
    var stream_ = stream;
    switch (stream_) {
        .owned, .owned_and_done, .temporary, .temporary_and_done, .err, .done => {},
        else => @panic("byte stream received a non-data result"),
    }
    defer releaseData(&stream_, allocator);
    if (this.done) return;

    bun.assert(!this.has_received_last_chunk or stream_ == .err);
    this.has_received_last_chunk = stream_.isDone();

    if (!this.pipe.isEmpty()) {
        this.didConsume(stream_.slice().len);
        this.pipe.deliver(stream_.take(), allocator);
        return;
    }

    if (stream_ == .err) {
        this.fail(&stream_.err);
        return;
    }

    if (this.buffer_action != null) {
        this.didConsume(stream_.slice().len);
        this.append(&stream_, 0, allocator) catch {
            this.outOfMemory();
            return;
        };
        if (this.has_received_last_chunk) {
            var action = this.buffer_action.?.take();
            this.buffer_action = null;
            var blob = this.toAnyBlob().?;
            action.fulfill(&blob);
        }
        return;
    }

    if (this.pending.state == .pending) {
        bun.assert(this.buffer.items.len == 0);
        const chunk = stream_.slice();
        const to_copy = this.pending_buffer[0..@min(chunk.len, this.pending_buffer.len)];
        bun.assert(to_copy.ptr != chunk.ptr);
        @memcpy(to_copy, chunk[0..to_copy.len]);
        this.didConsume(to_copy.len);
        this.pending_buffer = &.{};

        this.append(&stream_, to_copy.len, allocator) catch {
            this.outOfMemory();
            return;
        };
        const is_really_done = this.has_received_last_chunk and this.buffer.items.len == this.offset;
        if (is_really_done) {
            this.done = true;
            if (to_copy.len == 0) {
                this.pending.result = .{ .done = {} };
            } else {
                this.pending.result = .{
                    .into_array_and_done = .{
                        .len = to_copy.len,
                    },
                };
            }
        } else {
            this.pending.result = .{
                .into_array = .{
                    .len = to_copy.len,
                },
            };
        }

        this.pending.run();
        return;
    }

    this.append(&stream_, 0, allocator) catch this.outOfMemory();
}

fn releaseData(stream: *streams.Result, allocator: std.mem.Allocator) void {
    switch (stream.*) {
        .owned, .owned_and_done => |*bytes| bytes.deinit(allocator),
        .err => |*err| err.deinit(),
        else => {},
    }
}

fn outOfMemory(this: *ByteStream) void {
    var err: streams.Result.StreamError = .OutOfMemory;
    this.fail(&err);
}

fn fail(this: *ByteStream, err: *streams.Result.StreamError) void {
    this.done = true;
    this.has_received_last_chunk = true;
    this.buffer.clearAndFree();
    this.offset = 0;
    this.pending_buffer = &.{};
    this.pending.result.deinit();
    this.pending.result = .{ .err = err.take() };

    if (this.buffer_action) |*action| {
        action.reject(&this.pending.result.err);
        this.buffer_action = null;
        this.pending.result.deinit();
        this.pending.result = .{ .done = {} };
    } else {
        this.pending.run();
    }
}

fn append(
    this: *@This(),
    stream: *streams.Result,
    offset: usize,
    allocator: std.mem.Allocator,
) bun.OOM!void {
    const chunk = stream.slice()[offset..];
    if (chunk.len == 0) return;

    // drain() transfers a byte list whose owner uses the default allocator.
    if (this.buffer.items.len == 0 and
        bun.allocators.isDefault(allocator))
    {
        switch (stream.*) {
            .owned, .owned_and_done => |*owned| {
                this.buffer.clearAndFree();
                this.buffer = owned.moveToListManaged(allocator);
                this.offset = offset;
                return;
            },
            else => {},
        }
    }

    try this.buffer.appendSlice(chunk);
}

pub fn parent(this: *@This()) *Source {
    return @fieldParentPtr("context", this);
}

pub fn onPull(this: *@This(), buffer: []u8) streams.Result {
    bun.assert(buffer.len > 0);
    bun.debugAssert(this.buffer_action == null);

    if (this.pending.result == .err) return this.pending.result.take();

    if (this.buffer.items.len > 0) {
        const to_write = @min(
            this.buffer.items.len - this.offset,
            buffer.len,
        );
        @memcpy(buffer[0..to_write], this.buffer.items[this.offset..][0..to_write]);
        this.didConsume(to_write);

        if (this.offset + to_write == this.buffer.items.len) {
            this.offset = 0;
            this.buffer.items.len = 0;
        } else {
            this.offset += to_write;
        }

        if (this.has_received_last_chunk and this.buffer.items.len == 0) {
            this.buffer.clearAndFree();
            this.done = true;

            return .{
                .into_array_and_done = .{
                    .len = to_write,
                },
            };
        }

        return .{
            .into_array = .{
                .len = to_write,
            },
        };
    }

    if (this.has_received_last_chunk or this.done) {
        return .{
            .done = {},
        };
    }

    this.pending_buffer = buffer;

    return .{
        .pending = &this.pending,
    };
}

pub fn onCancel(this: *@This()) void {
    if (this.done) return;
    var pipe = this.pipe.take();
    defer pipe.deinit();
    var action = if (this.buffer_action) |*pending_action| pending_action.take() else null;
    this.buffer_action = null;
    this.buffer.clearAndFree();
    this.done = true;
    this.has_received_last_chunk = true;
    this.offset = 0;
    this.pending_buffer = &.{};
    this.pending.result.deinit();
    this.pending.result = .{ .done = {} };
    this.pending.run();

    if (action) |*pending_action| {
        var reason: streams.Result.StreamError = .{ .AbortReason = .UserAbort };
        pending_action.reject(&reason);
    }
    if (!pipe.isEmpty()) pipe.deliver(.{ .err = .{ .AbortReason = .UserAbort } }, bun.default_allocator);
}

pub fn memoryCost(this: *const @This()) usize {
    // ReadableStreamSource covers @sizeOf(ByteStream)
    return this.buffer.capacity;
}

pub fn deinit(this: *@This()) void {
    this.buffer.clearAndFree();
    if (this.pending.state == .pending) {
        this.pending_buffer = &.{};
        this.pending.result.deinit();
        this.pending.result = .{ .done = {} };
        this.pending.run();
    }
    this.pending.deinit();
    if (this.buffer_action) |*action| {
        action.deinit();
    }
    this.pipe.deinit();
}

pub fn drain(this: *@This()) bun.ByteList {
    this.compact();
    if (this.buffer.items.len > 0) {
        this.didConsume(this.buffer.items.len);
        return bun.ByteList.moveFromList(&this.buffer);
    }
    return .{};
}

fn drainForBindings(this: *ByteStream) bun.OOM!bun.bindgen.OwnedBytes {
    const bytes = try bun.bindgen.OwnedBytes.fromSlice(this.buffer.items[this.offset..]);
    this.didConsume(this.buffer.items.len - this.offset);
    this.buffer.clearAndFree();
    this.offset = 0;
    return bytes;
}

fn compact(this: *ByteStream) void {
    if (this.offset == 0) return;
    const remaining = this.buffer.items[this.offset..];
    std.mem.copyForwards(u8, this.buffer.items[0..remaining.len], remaining);
    this.buffer.items.len = remaining.len;
    this.offset = 0;
}

pub fn toAnyBlob(this: *@This()) ?Blob.Any {
    if (this.has_received_last_chunk and this.pending.result != .err) {
        this.compact();
        const buffer = this.buffer;
        this.buffer = .init(bun.default_allocator);
        this.done = true;
        this.pending.result.deinit();
        this.pending.result = .{ .done = {} };
        this.parent().is_closed = true;
        return .{ .InternalBlob = .{
            .bytes = .fromManaged(buffer),
            .was_string = false,
        } };
    }

    return null;
}

pub fn toBufferedValue(this: *@This(), action: *BufferAction) void {
    if (this.buffer_action != null) {
        action.failAlreadyBuffering();
        return;
    }

    if (this.pending.result == .err) {
        action.reject(&this.pending.result.err);
        this.pending.result.deinit();
        this.pending.result = .{ .done = {} };
        this.done = true;
        this.buffer.clearAndFree();
        this.offset = 0;
        return;
    }

    if (this.toAnyBlob()) |blob_| {
        var blob = blob_;
        action.fulfill(&blob);
        return;
    }

    this.didConsume(this.buffer.items.len - this.offset);
    this.buffer_action = action.take();
}

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;

const webcore = bun.webcore;
const Blob = webcore.Blob;
const BufferAction = webcore.ReadableStream.BufferAction;
const Pipe = webcore.Pipe;

const streams = webcore.streams;
