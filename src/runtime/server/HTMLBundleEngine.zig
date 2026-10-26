const Self = @This();

/// HTMLBundle can be owned by JavaScript as well as any number of Server instances.
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;
pub const derefDeferred = RefCount.derefDeferred;
pub const destroyAfterDeferred = RefCount.destroyAfterDeferred;

ref_count: RefCount,
bindgen_state: bindgen.ClassState = .{},
path: bindgen.OwnedBytes,

/// Initialize an HTMLBundle given a path.
pub fn init(path: []const u8) !*Self {
    const bundle = try bun.default_allocator.create(Self);
    errdefer bun.default_allocator.destroy(bundle);
    bundle.* = .{
        .ref_count = .init(),
        .path = try .fromSlice(path),
    };
    return bundle;
}

fn deinit(this: *Self) void {
    this.path.deinit();
    bun.destroy(this);
}

pub fn getIndex(
    this: *Self,
    _: bindgen.CallContext(HTMLBundleIndexSchema),
    _: bindgen.Args(HTMLBundleIndexSchema),
) bun.JSError!bindgen.DOMString {
    return bindgen.DOMString.fromUTF8(this.path.slice());
}

/// Deprecated: use Route instead.
pub const HTMLBundleRoute = Route;

/// An HTMLBundle can be used across multiple server instances, an
/// HTMLBundle.Route can only be used on one server, but is also
/// reference-counted because a server can have multiple instances of the same
/// html file on multiple endpoints.
pub const Route = struct {
    /// One HTMLBundle.Route can be specified multiple times
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", Route.deinit, .{ .debug_name = "HTMLBundleRoute" });
    pub const ref = Route.RefCount.ref;
    pub const deref = Route.RefCount.deref;

    bundle: RefPtr(Self),
    ref_count: Route.RefCount,
    // TODO: attempt to remove the null case. null is only present during server
    // initialization as only a ServerConfig object is present.
    server: ?AnyServer = null,
    /// When using DevServer, this value is never read or written to.
    state: State,
    /// Written and read by DevServer to identify if this route has been
    /// registered with the bundler.
    dev_server_id: bun.bake.DevServer.RouteBundle.Index.Optional = .none,
    /// When state == .pending, incomplete responses are stored here.
    pending_responses: std.ArrayListUnmanaged(*PendingResponse) = .empty,

    method: union(enum) {
        any: void,
        method: bun.http.Method.Set,
    } = .any,

    pub fn memoryCost(this: *const Route) usize {
        var cost: usize = 0;
        cost += @sizeOf(Route);
        cost += this.pending_responses.items.len * @sizeOf(PendingResponse);
        cost += this.state.memoryCost();
        return cost;
    }

    pub fn init(html_bundle: *Self) bun.OOM!RefPtr(Route) {
        const route = try bun.default_allocator.create(Route);
        route.* = .{
            .bundle = .initRef(html_bundle),
            .pending_responses = .empty,
            .ref_count = .init(),
            .server = null,
            .state = .pending,
        };
        return .adoptRef(route);
    }

    fn deinit(this: *Route) void {
        bun.assert(this.pending_responses.items.len == 0); // pending responses keep a ref to the route
        this.pending_responses.deinit(bun.default_allocator);
        this.bundle.deref();
        this.state.deinit();
        bun.destroy(this);
    }

    pub const State = union(enum) {
        pending,
        cancelled,
        building: ?*JSBundleCompletion.JSBundleCompletionTask,
        err: bun.logger.Log,
        html: *StaticRoute,

        pub fn deinit(this: *State) void {
            var state = this.*;
            this.* = .pending;
            switch (state) {
                .err => |*log| {
                    log.deinit();
                },
                .building => |completion| if (completion) |c| {
                    c.cancel();
                    c.deref();
                },
                .html => |route| route.deref(),
                .pending, .cancelled => {},
            }
        }

        pub fn memoryCost(this: *const State) usize {
            return switch (this.*) {
                .pending, .cancelled => 0,
                .building => 0,
                .err => |log| log.memoryCost(),
                .html => |html| html.memoryCost(),
            };
        }
    };

    pub fn onRequest(this: *Route, req: uws.AnyRequest, resp: HTTPResponse) void {
        this.onAnyRequest(req, resp, false);
    }

    pub fn onHEADRequest(this: *Route, req: uws.AnyRequest, resp: HTTPResponse) void {
        this.onAnyRequest(req, resp, true);
    }

    fn onAnyRequest(this: *Route, req: uws.AnyRequest, resp: HTTPResponse, is_head: bool) void {
        this.ref();
        defer this.deref();
        const server: AnyServer = this.server orelse {
            resp.endWithoutBody(true) catch |err| closeAfterWriteFailure(resp, err);
            return;
        };

        if (server.config().isDevelopment()) {
            if (server.devServer()) |dev| {
                // DevServer's HMR path is *uws.Request-typed; H3 isn't routed
                // there (no h3_app on plain-HTTP debug servers in practice),
                // but stay defensive.
                switch (req) {
                    .h1 => |h1| bun.handleOom(dev.respondForHTMLBundle(this, h1, resp)),
                    .h3 => {
                        resp.writeStatus("503 Service Unavailable") catch |err| return closeAfterWriteFailure(resp, err);
                        resp.end("DevServer HMR is HTTP/1.1 only", true) catch |err| closeAfterWriteFailure(resp, err);
                    },
                }
                return;
            }

            // Simpler development workflow which rebundles on every request.
            if (this.state == .html) {
                this.state.html.deref();
                this.state = .pending;
            } else if (this.state == .err) {
                this.state.err.deinit();
                this.state = .pending;
            }
        }

        state: switch (this.state) {
            .pending => {
                if (bun.Environment.enable_logs)
                    debug("onRequest: {s} - pending", .{req.url()});
                bun.handleOom(this.scheduleBundle(server));
                continue :state this.state;
            },
            .building => {
                if (bun.Environment.enable_logs)
                    debug("onRequest: {s} - building", .{req.url()});

                const method = bun.http.Method.which(req.method()) orelse {
                    resp.writeStatus("405 Method Not Allowed") catch |err| return closeAfterWriteFailure(resp, err);
                    resp.endWithoutBody(true) catch |err| closeAfterWriteFailure(resp, err);
                    return;
                };
                this.pending_responses.ensureUnusedCapacity(bun.default_allocator, 1) catch return resp.forceClose();
                const pending = bun.tryNew(PendingResponse, .{
                    .method = method,
                    .resp = resp,
                    .server = this.server,
                    .route = this,
                }) catch return resp.forceClose();

                this.ref();
                this.pending_responses.appendAssumeCapacity(pending);
                resp.onAborted(*PendingResponse, PendingResponse.onAborted, pending);
                req.setYield(false);
            },
            .err => |log| {
                if (bun.Environment.enable_logs)
                    debug("onRequest: {s} - err", .{req.url()});
                _ = log; // TODO: use the code from DevServer.zig to render the error
                resp.endWithoutBody(true) catch |err| closeAfterWriteFailure(resp, err);
            },
            .cancelled => {
                resp.writeStatus("503 Service Unavailable") catch |err| return closeAfterWriteFailure(resp, err);
                resp.endWithoutBody(true) catch |err| closeAfterWriteFailure(resp, err);
            },
            .html => |html| {
                if (bun.Environment.enable_logs)
                    debug("onRequest: {s} - html", .{req.url()});
                if (is_head) {
                    html.onHEADRequest(req, resp);
                } else {
                    html.onRequest(req, resp);
                }
            },
        }
    }

    /// Schedule a bundle to be built.
    /// If success, bumps the ref count and returns true;
    fn scheduleBundle(this: *Route, server: AnyServer) !void {
        switch (server.getOrLoadPlugins(.{ .html_bundle_route = this })) {
            .err => this.state = .{ .err = bun.logger.Log.init(bun.default_allocator) },
            .ready => |plugins| try onPluginsResolved(this, plugins),
            .pending => this.state = .{ .building = null },
        }
    }

    pub fn onPluginsResolved(this: *Route, plugins: ?*JSBundler.Plugin) !void {
        const server = this.server.?;
        const global = server.globalThis();
        const development = server.config().development;
        const vm = global.bunVM();

        var config: JSBundler.Config = .{};
        errdefer config.deinit(bun.default_allocator);
        try config.entry_points.insert(this.bundle.data.path.slice());
        if (vm.transpiler.options.transform_options.serve_public_path) |public_path| {
            if (public_path.len > 0) {
                try config.public_path.appendSlice(public_path);
            } else {
                try config.public_path.appendChar('/');
            }
        } else {
            try config.public_path.appendChar('/');
        }

        if (vm.transpiler.options.transform_options.serve_env_behavior != ._none) {
            config.env_behavior = vm.transpiler.options.transform_options.serve_env_behavior;

            if (config.env_behavior == .prefix) {
                try config.env_prefix.appendSlice(vm.transpiler.options.transform_options.serve_env_prefix orelse "");
            }
        }

        config.target = .browser;
        const is_development = development.isDevelopment();

        if (bun.cli.Command.get().args.serve_minify_identifiers) |minify_identifiers| {
            config.minify.identifiers = minify_identifiers;
        } else if (!is_development) {
            config.minify.identifiers = true;
        }

        if (bun.cli.Command.get().args.serve_minify_whitespace) |minify_whitespace| {
            config.minify.whitespace = minify_whitespace;
        } else if (!is_development) {
            config.minify.whitespace = true;
        }

        if (bun.cli.Command.get().args.serve_minify_syntax) |minify_syntax| {
            config.minify.syntax = minify_syntax;
        } else if (!is_development) {
            config.minify.syntax = true;
        }

        if (bun.cli.Command.get().args.serve_define) |define| {
            bun.assert(define.keys.len == define.values.len);
            try config.define.map.ensureUnusedCapacity(config.define.allocator, define.keys.len);
            config.define.map.entries.len = define.keys.len;
            @memcpy(config.define.map.keys(), define.keys);
            for (config.define.map.values(), define.values) |*to, from| {
                to.* = bun.handleOom(config.define.allocator.dupe(u8, from));
            }
            try config.define.map.reIndex(config.define.allocator);
        }

        if (!is_development) {
            bun.handleOom(config.define.put("process.env.NODE_ENV", "\"production\""));
            config.jsx.development = false;
        } else {
            config.force_node_env = .development;
            config.jsx.development = true;
        }
        config.source_map = .linked;

        const completion_task = try JSBundleCompletion.createCompletionTask(
            config,
            plugins,
            global,
        );
        completion_task.started_at_ns = bun.getRoughTickCount(.allow_mocked_time).ns();
        completion_task.html_build_task = this;
        completion_task.ref();
        this.state = .{ .building = completion_task };
        this.ref();
        completion_task.start();
    }

    pub fn onPluginsRejected(this: *Route) !void {
        debug("HTMLBundleRoute(0x{x}) plugins rejected", .{@intFromPtr(this)});
        this.state = .{ .err = bun.logger.Log.init(bun.default_allocator) };
        this.resumePendingResponses();
    }

    pub fn onBuildCancelled(this: *Route, completion_task: *JSBundleCompletion.JSBundleCompletionTask) void {
        const pending_task = switch (this.state) {
            .building => |task| task,
            else => null,
        };
        if (pending_task != completion_task) return;
        this.state = .cancelled;
        defer completion_task.deref();
        this.resumePendingResponses();
    }

    pub fn onComplete(this: *Route, completion_task: *JSBundleCompletion.JSBundleCompletionTask) void {
        const pending_task = switch (this.state) {
            .building => |task| task,
            else => null,
        };
        if (pending_task != completion_task) return;
        this.state = .pending;
        defer completion_task.deref();

        switch (completion_task.result) {
            .err => |err| {
                if (bun.Environment.enable_logs)
                    debug("onComplete: err - {s}", .{@errorName(err)});
                this.state = .{ .err = bun.logger.Log.init(bun.default_allocator) };
                bun.handleOom(completion_task.log.cloneTo(&this.state.err));

                if (this.server) |server| {
                    if (server.config().isDevelopment()) {
                        switch (bun.Output.enable_ansi_colors_stderr) {
                            inline else => |enable_ansi_colors| {
                                const writer = bun.Output.errorWriterBuffered();
                                this.state.err.printWithEnableAnsiColors(writer, enable_ansi_colors) catch {};
                                writer.flush() catch {};
                            },
                        }
                    }
                }
            },
            .value => |bundle| install: {
                if (bun.Environment.enable_logs)
                    debug("onComplete: success", .{});
                // Find the HTML entry point and create static routes
                const server: AnyServer = this.server orelse return;
                const output_files = bundle.output_files.items;

                if (server.config().isDevelopment()) {
                    const now = bun.getRoughTickCount(.allow_mocked_time).ns();
                    const duration = now - completion_task.started_at_ns;
                    var duration_f64: f64 = @floatFromInt(duration);
                    duration_f64 /= std.time.ns_per_s;

                    bun.Output.printElapsed(duration_f64);
                    var byte_length: u64 = 0;
                    for (output_files) |*output_file| {
                        byte_length += output_file.size_without_sourcemap;
                    }

                    bun.Output.prettyErrorln(" <green>bundle<r> {s} <d>{d:.2} KB<r>", .{ std.fs.path.basename(this.bundle.data.path.slice()), @as(f64, @floatFromInt(byte_length)) / 1000.0 });
                    bun.Output.flush();
                }

                var this_html_route: ?*StaticRoute = null;

                // Create static routes for each output file
                for (output_files) |*output_file| {
                    var blob = AnyBlob{ .Blob = bun.handleOom(OutputFileEngine.toBlob(output_file, bun.default_allocator)) };
                    var headers = bun.http.Headers{ .allocator = bun.default_allocator };
                    const content_type = blob.Blob.contentTypeOrMimeType() orelse brk: {
                        bun.debugAssert(false); // should be populated by `output_file.toBlob`
                        break :brk output_file.loader.toMimeType(&.{}).value;
                    };
                    bun.handleOom(headers.append("Content-Type", content_type));
                    // Do not apply etags to html.
                    if (output_file.loader != .html and output_file.value == .buffer) {
                        var hashbuf: [64]u8 = undefined;
                        const etag_str = std.fmt.bufPrint(
                            &hashbuf,
                            "{f}",
                            .{bun.fmt.hexIntLower(output_file.hash)},
                        ) catch |err| switch (err) {
                            error.NoSpaceLeft => unreachable,
                        };
                        bun.handleOom(headers.append("ETag", etag_str));
                        if (!server.config().isDevelopment() and (output_file.output_kind == .chunk))
                            bun.handleOom(headers.append("Cache-Control", "public, max-age=31536000"));
                    }

                    // Add a SourceMap header if we have a source map index
                    // and it's in development mode.
                    if (server.config().isDevelopment()) {
                        if (output_file.source_map_index != std.math.maxInt(u32)) {
                            var route_path = output_files[output_file.source_map_index].dest_path;
                            if (strings.hasPrefixComptime(route_path, "./") or strings.hasPrefixComptime(route_path, ".\\")) {
                                route_path = route_path[1..];
                            }
                            bun.handleOom(headers.append("SourceMap", route_path));
                        }
                    }

                    const static_route = bun.handleOom(StaticRoute.initFromAnyBlob(&blob, .{
                        .server = server,
                        .headers = headers,
                        .generate_etag = false,
                    }));

                    if (this_html_route == null and output_file.output_kind == .@"entry-point") {
                        if (output_file.loader == .html) {
                            this_html_route = static_route;
                        }
                    }

                    var route_path = output_file.dest_path;

                    // The route path gets cloned inside of appendStaticRoute.
                    if (strings.hasPrefixComptime(route_path, "./") or strings.hasPrefixComptime(route_path, ".\\")) {
                        route_path = route_path[1..];
                    }

                    bun.handleOom(server.appendStaticRoute(route_path, .{ .static = static_route }, .any));
                }

                const html_route: *StaticRoute = this_html_route orelse @panic("Internal assertion failure: HTML entry point not found in HTMLBundle.");
                const html_route_clone = bun.handleOom(html_route.clone());
                this.state = .{ .html = html_route_clone };

                if (!(server.reloadStaticRoutes() catch |err| {
                    server.globalThis().reportActiveExceptionAsUnhandled(err);
                    break :install;
                })) {
                    // Server has shutdown, so it won't receive any new requests
                    // TODO: handle this case
                }
            },
            .pending => unreachable,
        }
        this.resumePendingResponses();
    }

    pub fn resumePendingResponses(this: *Route) void {
        this.ref();
        defer this.deref();
        var pending = this.pending_responses;
        defer pending.deinit(bun.default_allocator);
        this.pending_responses = .empty;
        for (pending.items) |pending_response| {
            defer pending_response.deinit();

            const resp = pending_response.resp;
            const method = pending_response.method;
            if (!pending_response.is_response_pending) {
                // Aborted
                continue;
            }
            pending_response.is_response_pending = false;
            resp.clearAborted();

            switch (this.state) {
                .html => |html| {
                    if (method == .HEAD) {
                        html.onHEAD(resp);
                    } else {
                        html.on(resp);
                    }
                },
                .cancelled => {
                    resp.writeStatus("503 Service Unavailable") catch |err| {
                        closeAfterWriteFailure(resp, err);
                        continue;
                    };
                    resp.endWithoutBody(false) catch |err| closeAfterWriteFailure(resp, err);
                },
                .err => |log| {
                    if (this.server.?.config().isDevelopment()) {
                        _ = log; // TODO: use the code from DevServer.zig to render the error
                    } else {
                        // To protect privacy, do not show errors to end users in production.
                        // TODO: Show a generic error page.
                    }
                    resp.writeStatus("500 Build Failed") catch |err| {
                        closeAfterWriteFailure(resp, err);
                        continue;
                    };
                    resp.endWithoutBody(false) catch |err| closeAfterWriteFailure(resp, err);
                },
                else => {
                    resp.endWithoutBody(false) catch |err| closeAfterWriteFailure(resp, err);
                },
            }
        }
    }

    fn closeAfterWriteFailure(resp: HTTPResponse, failure: uws.ResponseWriteError) void {
        if (failure != error.ConnectionClosed) resp.forceClose();
    }

    /// Represents an in-flight response before the bundle has finished building.
    pub const PendingResponse = struct {
        method: bun.http.Method,
        resp: HTTPResponse,
        is_response_pending: bool = true,
        server: ?AnyServer = null,
        route: *Route,

        pub fn deinit(this: *PendingResponse) void {
            if (this.is_response_pending) {
                this.is_response_pending = false;
                this.resp.clearAborted();
                this.resp.clearOnWritable();
                this.resp.endWithoutBody(true) catch |err| closeAfterWriteFailure(this.resp, err);
            }
            this.route.deref();
            bun.destroy(this);
        }

        pub fn onAborted(this: *PendingResponse, _: HTTPResponse) void {
            bun.debugAssert(this.is_response_pending == true);
            this.is_response_pending = false;

            const route = this.route;
            route.ref();
            defer route.deref();

            if (std.mem.indexOfScalar(*PendingResponse, route.pending_responses.items, this)) |index| {
                _ = route.pending_responses.orderedRemove(index);
                this.deinit();
            }
        }
    };
};

const debug = bun.Output.scoped(.HTMLBundle, .hidden);

const AnyServer = bun.api.AnyServer;
const JSBundleCompletion = @import("../../bundler_jsc/JSBundleCompletionTaskEngine.zig");
const JSBundler = @import("../api/JSBundlerEngine.zig").JSBundler;
const OutputFileEngine = @import("../../bundler_jsc/OutputFileEngine.zig");
const StaticRoute = @import("StaticRouteEngine.zig");
const AnyBlob = bun.webcore.Blob.Any;
const HTMLBundleClass = bindgen.Class(HTMLBundleSchema, Self);

pub fn toClassRef(this: *Self, global: *bun.jsc.JSGlobalObject) bun.JSError!bindgen.ClassRef(HTMLBundleSchema) {
    return HTMLBundleClass.adoptNativeRef(this, global);
}

comptime {
    _ = HTMLBundleClass;
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const RefPtr = bun.ptr.RefPtr;

const bindgen = bun.bindgen;

const HTMLBundleBindingModule = bindgen.Module("HTMLBundle");
const HTMLBundleSchema = HTMLBundleBindingModule.class("HTMLBundle");
const HTMLBundleIndexSchema = HTMLBundleSchema.member("index");

const uws = bun.uws;
const HTTPResponse = bun.uws.AnyResponse;
