const ArrayBufferSink = @This();
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

pub const JSSink = webcore.Sink.JSSink(@This(), "ArrayBufferSink", 0);

ref_count: RefCount = .init(),
bytes: bun.bindgen.OwnedByteList,
done: bool = false,
signal: Signal = .{},
streaming: bool = false,
as_uint8array: bool = false,

pub fn connect(this: *ArrayBufferSink, signal: Signal) void {
    this.signal = signal;
}

pub fn start(this: *ArrayBufferSink, stream_start: streams.Start) bun.OOM!bun.sys.Maybe(void) {
    this.bytes.clearRetainingCapacity();

    switch (stream_start) {
        .ArrayBufferSink => |config| {
            if (config.chunk_size > 0) {
                try this.bytes.ensureTotalCapacityPrecise(config.chunk_size);
            }

            this.as_uint8array = config.as_uint8array;
            this.streaming = config.stream;
        },
        else => {},
    }

    this.done = false;

    this.signal.start();
    return .success;
}

pub fn flush(_: *ArrayBufferSink) bun.sys.Maybe(void) {
    return .success;
}

pub fn flushFromBinding(this: *ArrayBufferSink, wait: bool) bun.OOM!bun.sys.Maybe(Sink.BindingOperation) {
    _ = wait;
    if (this.streaming) {
        const bytes = try bun.bindgen.OwnedBytes.fromSlice(this.bytes.slice());
        this.bytes.clearRetainingCapacity();
        return .{ .result = .{ .buffer = .{
            .bytes = bytes,
            .as_uint8_array = this.as_uint8array,
        } } };
    }

    return .{ .result = .{ .count = 0 } };
}

pub fn finalize(this: *ArrayBufferSink) void {
    this.destroy();
}
pub const releaseBindingRef = finalize;

pub fn construct(
    this: *ArrayBufferSink,
    _: std.mem.Allocator,
) void {
    this.* = ArrayBufferSink{
        .bytes = .init(bun.default_allocator),
    };
}

pub fn write(this: *@This(), data: streams.Result) streams.Result.Writable {
    const len = this.bytes.write(data.slice()) catch {
        return .out_of_memory;
    };
    this.signal.ready(null, null);
    return .{ .owned = len };
}
pub const writeBytes = write;
pub fn writeLatin1(this: *@This(), data: streams.Result) streams.Result.Writable {
    const len = this.bytes.writeLatin1(data.slice()) catch {
        return .out_of_memory;
    };
    this.signal.ready(null, null);
    return .{ .owned = len };
}
pub fn writeUTF16(this: *@This(), data: streams.Result) streams.Result.Writable {
    const len = this.bytes.writeUTF16(@as([*]const u16, @ptrCast(@alignCast(data.slice().ptr)))[0..std.mem.bytesAsSlice(u16, data.slice()).len]) catch {
        return .out_of_memory;
    };
    this.signal.ready(null, null);
    return .{ .owned = len };
}

pub fn end(this: *ArrayBufferSink, err: ?Syscall.Error) bun.sys.Maybe(void) {
    this.signal.close(err);
    return .success;
}
pub fn destroy(this: *ArrayBufferSink) void {
    this.deref();
}

fn deinit(this: *ArrayBufferSink) void {
    this.bytes.deinit();
    bun.destroy(this);
}
pub fn endFromBinding(this: *ArrayBufferSink) bun.OOM!bun.sys.Maybe(Sink.BindingOperation) {
    if (this.done) {
        return .{ .result = .{ .buffer = .{
            .bytes = bun.bindgen.OwnedBytes.empty(),
            .as_uint8_array = false,
        } } };
    }

    const bytes = bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(try this.bytes.tryToDefaultOwnedSlice());
    this.done = true;
    const as_uint8_array = this.as_uint8array;
    this.signal.close(null);
    return .{ .result = .{ .buffer = .{
        .bytes = bytes,
        .as_uint8_array = as_uint8_array,
    } } };
}

pub fn sink(this: *ArrayBufferSink) Sink {
    return Sink.init(this);
}

pub fn memoryCost(this: *const ArrayBufferSink) usize {
    // Since this is a JSSink, the NewJSSink function does @sizeOf(JSSink) which includes @sizeOf(ArrayBufferSink).
    return this.bytes.capacity();
}

const std = @import("std");

const bun = @import("bun");
const Syscall = bun.sys;

const webcore = bun.webcore;
const Sink = webcore.Sink;

const streams = webcore.streams;
const Signal = webcore.streams.Signal;
