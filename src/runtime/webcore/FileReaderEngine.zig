const Core = @import("./FileReader.zig");

pub fn create(global: *bun.jsc.JSGlobalObject, core: Core) bun.OOM!*Source {
    const source = try Source.create(global, .{ .core = core });
    source.context.core.attachSource(source.context.sourceControl());
    return source;
}

pub const Context = struct {
    core: Core,
    pending: streams.Result.Pending = .{},

    fn source(this: *Context) *Source {
        return @fieldParentPtr("context", this);
    }

    fn sourceControl(this: *Context) Core.BorrowedSourceControl {
        return .{
            .context = .init(this),
            .increment_fn = increment,
            .decrement_fn = decrement,
            .close_fn = close,
            .cancel_fn = cancel,
            .complete_pull_fn = completePull,
        };
    }

    fn increment(context: Core.BorrowedSourceControl.Context) void {
        context.get(*Context).source().incrementCount();
    }

    fn decrement(context: Core.BorrowedSourceControl.Context) void {
        _ = context.get(*Context).source().decrementCount();
    }

    fn close(context: Core.BorrowedSourceControl.Context) void {
        context.get(*Context).source().onClose();
    }

    fn cancel(context: Core.BorrowedSourceControl.Context) void {
        context.get(*Context).source().cancel();
    }

    fn completePull(context: Core.BorrowedSourceControl.Context, result: Core.Result) void {
        const this = context.get(*Context);
        bun.assert(result != .pending);
        this.pending.result = toEngineResult(this, result);
        this.pending.run();
    }

    fn onStart(this: *Context) streams.ReadableStart {
        return switch (this.core.onStart()) {
            .err => |err| .{ .err = err },
            .out_of_memory => .out_of_memory,
            .ready => .{ .ready = {} },
            .owned_and_done => |bytes| .{ .owned_and_done = bytes },
        };
    }

    fn onPull(this: *Context, buffer: []u8) streams.Result {
        return toEngineResult(this, this.core.onPull(buffer));
    }

    fn toEngineResult(this: *Context, result: Core.Result) streams.Result {
        return switch (result) {
            .pending => .{ .pending = &this.pending },
            .err => |err| .{ .err = .fromSysError(err) },
            .done => .{ .done = {} },
            .owned => |bytes| .{ .owned = bytes },
            .owned_and_done => |bytes| .{ .owned_and_done = bytes },
            .temporary_and_done => |bytes| .{ .temporary_and_done = bytes },
            .temporary => |bytes| .{ .temporary = bytes },
            .into_array => |value| .{ .into_array = .{ .len = value.len } },
            .into_array_and_done => |value| .{ .into_array_and_done = .{ .len = value.len } },
        };
    }

    fn onCancel(this: *Context) void {
        this.core.onCancel();
    }

    fn deinit(this: *Context) void {
        this.pending.deinit();
        this.core.deinit();
    }

    fn setRefOrUnref(this: *Context, enable: bool) void {
        this.core.setRefOrUnref(enable);
    }

    pub fn setRawMode(this: *Context, enabled: bool) bun.sys.Maybe(void) {
        return this.core.setRawMode(enabled);
    }

    pub fn setFlowing(this: *Context, enabled: bool) void {
        this.core.setFlowing(enabled);
    }

    fn drain(this: *Context) bun.OOM!bun.bindgen.OwnedBytes {
        return .fromDefaultAllocatedSlice(try this.core.drainOwned());
    }

    fn memoryCost(this: *const Context) usize {
        return this.core.memoryCost();
    }
};

pub const Source = ReadableStream.NewSource(
    Context,
    "File",
    Context.onStart,
    Context.onPull,
    Context.onCancel,
    Context.deinit,
    Context.setRefOrUnref,
    Context.drain,
    Context.memoryCost,
    null,
);

const bun = @import("bun");
const ReadableStream = @import("./ReadableStream.zig");
const streams = @import("./streams.zig");
