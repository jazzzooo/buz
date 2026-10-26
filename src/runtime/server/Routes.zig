const std = @import("std");
const bun = @import("bun");
const uws = bun.uws;

pub fn Routes(comptime ssl: bool, comptime http3: bool) type {
    return struct {
        const Self = @This();
        pub const is_ssl = ssl;
        pub const Request = if (http3) uws.H3.Request else uws.Request;
        pub const Response = if (http3) uws.H3.Response else uws.NewApp(ssl).Response;
        const App = uws.NewApp(ssl);
        const Capture = bun.bindgen.NativeCallbackContext(.vm);
        const Upgrade = @FieldType(uws.WebSocketBehavior, "upgrade");
        const Table = @import("../../http/Router.zig");

        const Handler = union(enum) {
            http: struct {
                context: Capture,
                call: *const fn (Capture, *Request, *Response) void,
            },
            websocket: struct {
                context: Capture,
                native: *uws.WebSocketUpgradeContext,
                id: usize,
                call: Upgrade,
                invoke: *const fn (Capture, *Request, *Response, *uws.WebSocketUpgradeContext, usize, Upgrade) void,
            },
        };

        const WebSocketContext = struct {
            behavior: uws.WebSocketBehavior,
            native: *uws.WebSocketUpgradeContext,
        };

        table: Table,
        handlers: std.ArrayList(Handler) = .empty,
        app: *App,
        custom_methods: bool,
        websocket_contexts: std.ArrayList(WebSocketContext) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, app: *App, custom_methods: bool) Self {
            return .{ .table = .init(allocator), .app = app, .custom_methods = custom_methods, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.websocket_contexts.items) |context| App.releaseWebSocketContext(context.native);
            self.websocket_contexts.deinit(self.allocator);
            self.table.deinit();
            self.handlers.deinit(self.allocator);
        }

        pub fn memoryCost(self: *const Self) usize {
            return self.table.memoryCost() + self.handlers.capacity * @sizeOf(Handler) + self.websocket_contexts.capacity * @sizeOf(WebSocketContext);
        }

        fn callback(comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) Handler {
            const Adapter = struct {
                fn call(data: Capture, request: *Request, response: *Response) void {
                    handler(data.get(T), request, response);
                }
            };
            return .{ .http = .{ .context = .init(context), .call = Adapter.call } };
        }

        fn addHandler(self: *Self, handler: Handler) bun.OOM!usize {
            try self.handlers.append(self.allocator, handler);
            return self.handlers.items.len - 1;
        }

        pub fn method(self: *Self, verb: bun.http.Method, path: []const u8, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) bun.OOM!void {
            const index = try self.addHandler(callback(T, context, handler));
            try self.table.add(@tagName(verb), path, .normal, index);
        }

        pub fn get(self: *Self, path: []const u8, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) bun.OOM!void {
            try self.method(.GET, path, T, context, handler);
        }

        pub fn head(self: *Self, path: []const u8, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) bun.OOM!void {
            try self.method(.HEAD, path, T, context, handler);
        }

        pub fn post(self: *Self, path: []const u8, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) bun.OOM!void {
            try self.method(.POST, path, T, context, handler);
        }

        pub fn any(self: *Self, path: []const u8, comptime T: type, context: T, comptime handler: fn (T, *Request, *Response) void) bun.OOM!void {
            const handler_value = try self.addHandler(callback(T, context, handler));
            for (std.enums.values(bun.http.Method)) |verb| {
                try self.table.add(@tagName(verb), path, .fallback, handler_value);
            }
            if (self.custom_methods) try self.table.add("*", path, .fallback, handler_value);
        }

        pub fn ws(self: *Self, path: []const u8, context: anytype, id: usize, behavior: uws.WebSocketBehavior) bun.OOM!void {
            if (http3) @compileError("WebSocket upgrades require HTTP/1");
            const Adapter = struct {
                fn invoke(capture: Capture, request: *Request, response: *Response, native: *uws.WebSocketUpgradeContext, route_id: usize, upgrade: Upgrade) void {
                    upgrade.?(@ptrCast(capture.get(@TypeOf(context))), @ptrCast(response), request, native, route_id);
                }
            };
            const native = native: {
                for (self.websocket_contexts.items) |existing| {
                    if (std.meta.eql(existing.behavior, behavior)) break :native existing.native;
                }
                try self.websocket_contexts.ensureUnusedCapacity(self.allocator, 1);
                const prepared = try self.app.prepareWebSocketContext(&behavior);
                self.websocket_contexts.appendAssumeCapacity(.{ .behavior = behavior, .native = prepared });
                break :native prepared;
            };
            const index = try self.addHandler(.{ .websocket = .{
                .context = .init(context),
                .native = native,
                .id = id,
                .call = behavior.upgrade,
                .invoke = Adapter.invoke,
            } });
            try self.table.add("GET", path, .upgrade, index);
        }

        pub fn dispatch(self: *const Self, request: *Request, response: *Response) bun.OOM!bool {
            var buffer: [4096]u8 = undefined;
            var allocator: std.heap.BufferFirstAllocator = .init(&buffer, self.allocator);
            const target = request.url();
            const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
            var iterator = try Table.Iterator.init(&self.table, allocator.allocator(), request.rawMethod(), path);
            defer iterator.deinit();
            defer request.clearParameters();
            while (iterator.next()) |match| {
                request.setYield(false);
                request.setParameters(&match.parameters);
                switch (self.handlers.items[match.handler]) {
                    .http => |handler| handler.call(handler.context, request, response),
                    .websocket => |handler| {
                        if (comptime http3) unreachable;
                        const key = request.header("sec-websocket-key") orelse continue;
                        if (key.len != 24) continue;
                        App.prepareWebSocketDispatch(response, request);
                        handler.invoke(handler.context, request, response, handler.native, handler.id, handler.call);
                    },
                }
                if (!request.getYield()) return true;
            }
            return false;
        }
    };
}
