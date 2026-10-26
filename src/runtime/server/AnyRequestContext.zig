//! A generic wrapper for the HTTP(s) Server`RequestContext`s.
//! Only really exists because of `NewServer()` and `NewRequestContext()` generics.

pub fn WithTypes(
    comptime HTTPServer: type,
    comptime HTTPSServer: type,
    comptime DevServer: type,
) type {
    return struct {
        const AnyRequestContext = @This();

        const Storage = union(enum) {
            none,
            http: bun.bindgen.BorrowedNative(HTTPServer.RequestContext, .vm),
            https: bun.bindgen.BorrowedNative(HTTPSServer.RequestContext, .vm),
            h3: bun.bindgen.BorrowedNative(HTTPSServer.H3RequestContext, .vm),
        };

        storage: Storage,

        pub const Null: @This() = .{ .storage = .none };

        pub fn init(request_ctx: anytype) AnyRequestContext {
            const Context = @typeInfo(@TypeOf(request_ctx)).pointer.child;
            if (Context == HTTPServer.RequestContext) return .{ .storage = .{ .http = .init(request_ctx) } };
            if (Context == HTTPSServer.RequestContext) return .{ .storage = .{ .https = .init(request_ctx) } };
            if (Context == HTTPSServer.H3RequestContext) return .{ .storage = .{ .h3 = .init(request_ctx) } };
            @compileError("unsupported request context type " ++ @typeName(Context));
        }

        /// Dispatches while preserving the concrete RequestContext type for comptime
        /// SSL and HTTP/3 branches in the callback.
        inline fn dispatch(self: AnyRequestContext, comptime Ret: type, default: Ret, comptime cb: anytype, args: anytype) Ret {
            return switch (self.storage) {
                .none => default,
                inline else => |handle| @call(.auto, cb, .{
                    @typeInfo(@TypeOf(handle.get())).pointer.child,
                    handle.get(),
                } ++ args),
            };
        }

        pub fn setAdditionalOnAbortCallback(self: AnyRequestContext, cb: ?AdditionalOnAbortCallback) void {
            self.dispatch(void, {}, struct {
                fn f(comptime _: type, ctx: anytype, c: ?AdditionalOnAbortCallback) void {
                    bun.assert(ctx.additional_on_abort == null);
                    ctx.additional_on_abort = c;
                }
            }.f, .{cb});
        }

        pub fn memoryCost(self: AnyRequestContext) usize {
            return self.dispatch(usize, 0, struct {
                fn f(comptime _: type, ctx: anytype) usize {
                    return ctx.memoryCost();
                }
            }.f, .{});
        }

        pub fn get(self: AnyRequestContext, comptime T: type) ?*T {
            if (T == HTTPServer.RequestContext) return switch (self.storage) {
                .http => |handle| handle.get(),
                else => null,
            };
            if (T == HTTPSServer.RequestContext) return switch (self.storage) {
                .https => |handle| handle.get(),
                else => null,
            };
            if (T == HTTPSServer.H3RequestContext) return switch (self.storage) {
                .h3 => |handle| handle.get(),
                else => null,
            };
            @compileError("unsupported request context type " ++ @typeName(T));
        }

        pub fn setTimeout(self: AnyRequestContext, seconds: c_uint) bool {
            return self.dispatch(bool, false, struct {
                fn f(comptime _: type, ctx: anytype, s: c_uint) bool {
                    return ctx.setTimeout(s);
                }
            }.f, .{seconds});
        }

        pub fn setCookies(self: AnyRequestContext, cookie_map: ?*CookieMap) void {
            self.dispatch(void, {}, struct {
                fn f(comptime _: type, ctx: anytype, c: ?*CookieMap) void {
                    ctx.setCookies(c);
                }
            }.f, .{cookie_map});
        }

        pub fn getRemoteSocketInfo(self: AnyRequestContext) ?uws.SocketAddress {
            return self.dispatch(?uws.SocketAddress, null, struct {
                fn f(comptime _: type, ctx: anytype) ?uws.SocketAddress {
                    return ctx.getRemoteSocketInfo();
                }
            }.f, .{});
        }

        pub fn detachRequest(self: AnyRequestContext) void {
            self.dispatch(void, {}, struct {
                fn f(comptime _: type, ctx: anytype) void {
                    ctx.req = null;
                }
            }.f, .{});
        }

        /// Does nothing if `self` is `.none`.
        pub fn setRequest(self: AnyRequestContext, req: *uws.Request) void {
            self.dispatch(void, {}, struct {
                fn f(comptime T: type, ctx: anytype, r: *uws.Request) void {
                    if (comptime T.is_h3) return; // H3 populates url/headers eagerly
                    ctx.req = r;
                }
            }.f, .{req});
        }

        pub fn getRequest(self: AnyRequestContext) ?*uws.Request {
            return self.dispatch(?*uws.Request, null, struct {
                fn f(comptime T: type, ctx: anytype) ?*uws.Request {
                    if (comptime T.is_h3) return null; // url/headers already on the Request
                    return ctx.req;
                }
            }.f, .{});
        }

        pub fn onAbort(self: AnyRequestContext, response: uws.AnyResponse) void {
            self.dispatch(void, {}, struct {
                fn f(comptime T: type, ctx: anytype, r: uws.AnyResponse) void {
                    // The AnyResponse arm and T.Resp are created together; assert
                    // they agree so a mismatch traps in safe builds instead of being
                    // silently @ptrCast.
                    ctx.onAbort(switch (r) {
                        inline else => |p| if (comptime @TypeOf(p) == *T.Resp) p else unreachable,
                    });
                }
            }.f, .{response});
        }

        pub fn ref(self: AnyRequestContext) void {
            self.dispatch(void, {}, struct {
                fn f(comptime _: type, ctx: anytype) void {
                    ctx.ref();
                }
            }.f, .{});
        }

        pub fn setSignalAborted(self: AnyRequestContext, reason: CommonAbortReason) void {
            self.dispatch(void, {}, struct {
                fn f(comptime _: type, ctx: anytype, r: CommonAbortReason) void {
                    ctx.setSignalAborted(r);
                }
            }.f, .{reason});
        }

        pub fn devServer(self: AnyRequestContext) ?*DevServer {
            return self.dispatch(?*DevServer, null, struct {
                fn f(comptime _: type, ctx: anytype) ?*DevServer {
                    return ctx.devServer();
                }
            }.f, .{});
        }

        pub fn deref(self: AnyRequestContext) void {
            self.dispatch(void, {}, struct {
                fn f(comptime _: type, ctx: anytype) void {
                    ctx.deref();
                }
            }.f, .{});
        }
    };
}

pub const AdditionalOnAbortCallback = @import("./AdditionalOnAbortCallback.zig");

const bun = @import("bun");
const uws = bun.uws;

const CookieMap = @import("../webcore/CookieMap.zig").CookieMap;
const CommonAbortReason = @import("../../http_types/CommonAbortReason.zig").CommonAbortReason;
