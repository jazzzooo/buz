/// Mixin to read an entire request body into memory and run a callback.
/// The owner stays alive until `finalize`, which runs once after delivery or abort.
pub fn BodyReaderMixin(
    Wrap: type,
    field: []const u8,
    // The callback borrows its owner and body until it returns.
    onBody: fn (*Wrap, body: []const u8, resp: uws.AnyResponse) anyerror!void,
    finalize: fn (*Wrap) void,
) type {
    return struct {
        body: std.array_list.Managed(u8),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .body = .init(allocator) };
        }

        /// Memory is freed after the callback returns, or automatically on failure.
        pub fn readBody(ctx: *@This(), resp: anytype) void {
            const Mixin = @This();
            const Response = @TypeOf(resp);
            const handlers = struct {
                fn onDataGeneric(mixin: *Mixin, r: Response, chunk: []const u8, last: bool) void {
                    const any = uws.AnyResponse.init(r);
                    onData(mixin, any, chunk, last);
                }
                fn onAborted(mixin: *Mixin, r: Response) void {
                    detach(uws.AnyResponse.init(r));
                    mixin.body.clearAndFree();
                    finalize(@fieldParentPtr(field, mixin));
                }
            };
            resp.onData(*@This(), handlers.onDataGeneric, ctx);
            resp.onAborted(*@This(), handlers.onAborted, ctx);
        }

        fn onData(ctx: *@This(), resp: uws.AnyResponse, chunk: []const u8, last: bool) void {
            if (last) {
                detach(resp);
                defer finalize(@fieldParentPtr(field, ctx));
                var body = ctx.body;
                defer body.deinit();
                ctx.body = .init(ctx.body.allocator);
                if (body.items.len > 0) {
                    body.appendSlice(chunk) catch |err| return respondToFailure(resp, err);
                    onBody(@fieldParentPtr(field, ctx), body.items, resp) catch |err| respondToFailure(resp, err);
                } else {
                    onBody(@fieldParentPtr(field, ctx), chunk, resp) catch |err| respondToFailure(resp, err);
                }
            } else {
                ctx.body.appendSlice(chunk) catch |err| {
                    detach(resp);
                    ctx.body.clearAndFree();
                    defer finalize(@fieldParentPtr(field, ctx));
                    respondToFailure(resp, err);
                };
            }
        }

        fn detach(r: uws.AnyResponse) void {
            r.clearAborted();
            r.clearOnData();
        }

        fn respondToFailure(r: uws.AnyResponse, failure: anyerror) void {
            switch (failure) {
                error.ConnectionClosed => return,
                error.WriteFailed => return r.forceClose(),
                else => {},
            }
            if (r.state().isHttpStatusCalled()) return r.forceClose();
            r.writeStatus(if (failure == error.OutOfMemory) "500 Internal Server Error" else "400 Bad Request") catch |err| {
                if (err != error.ConnectionClosed) r.forceClose();
                return;
            };
            r.endWithoutBody(false) catch |err| {
                if (err != error.ConnectionClosed) r.forceClose();
            };
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const uws = bun.uws;
