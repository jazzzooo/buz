//! This is the code for the object returned by Bun.listen().

const Listener = @This();
const StrongSelf = bindgen.ClassWrapperHandle(ListenerClassSchema, .strong);

pub fn connectForBinding(context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!void {
    return connectFromBinding(context, null, null, options);
}

pub fn listenForBinding(context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!bindgen.Return(@TypeOf(context)) {
    return listenFromBinding(context, options);
}

handlers: Handlers,
listener: ListenerType = .none,

poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
connection: UnixOrHost,
/// Embedded sweep/iteration list-head for every accepted socket on this
/// listener. `group.ext` = `*Listener`, so the dispatch handler recovers us
/// from the socket without a context-ext lookup.
group: uws.SocketGroup = .{},
/// `SSL_CTX*` for accepted sockets. One owned ref; `SSL_CTX_free` on close.
/// `SSL_new()` per-accept takes its own ref, so accepted sockets outlive a
/// stopped listener safely.
secure_ctx: ?*BoringSSL.SSL_CTX = null,
ssl: bool = false,
protos: ?[]const u8 = null,

strong_data: bindgen.Root.Optional = .empty,
strong_self: ?StrongSelf = null,

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    listener: bindgen.OwnedNative(Listener, .vm),

    pub const new = bun.TrivialNew(@This());

    pub const destroy = @This().deinit;

    fn deinit(this: *JSBinding) void {
        this.listener.deinit();
        bun.destroy(this);
    }

    pub fn bindDispose(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerDisposeSchema),
        _: bindgen.Args(ListenerDisposeSchema),
    ) bun.JSError!void {
        this.listener.get().doStop(true);
    }

    pub fn bindGetData(
        this: *JSBinding,
        context: bindgen.CallContext(ListenerDataGetterSchema),
        _: bindgen.Args(ListenerDataGetterSchema),
    ) bun.JSError!bindgen.Return(ListenerDataGetterSchema) {
        return this.listener.get().strong_data.toResult(context) orelse
            bindgen.Return(ListenerDataGetterSchema).initUndefined(context);
    }

    pub fn bindSetData(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerDataSetterSchema),
        args: bindgen.Args(ListenerDataSetterSchema),
    ) bun.JSError!void {
        var value = try args.value.toRoot();
        defer value.deinit();
        this.listener.get().setDataRoot(&value);
    }

    pub fn bindGetFD(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerFDGetterSchema),
        _: bindgen.Args(ListenerFDGetterSchema),
    ) bun.JSError!i64 {
        return this.listener.get().getFD();
    }

    pub fn bindGetSockNameNative(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerGetSockNameNativeSchema),
        _: bindgen.Args(ListenerGetSockNameNativeSchema),
    ) bun.JSError!bindgen.Return(ListenerGetSockNameNativeSchema) {
        return this.listener.get().getSockName();
    }

    pub fn bindGetHostname(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerHostnameGetterSchema),
        _: bindgen.Args(ListenerHostnameGetterSchema),
    ) bun.JSError!?bindgen.DOMString {
        return this.listener.get().getHostname();
    }

    pub fn bindGetPort(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerPortGetterSchema),
        _: bindgen.Args(ListenerPortGetterSchema),
    ) bun.JSError!?u16 {
        return this.listener.get().getPort();
    }

    pub fn bindRef(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerRefSchema),
        args: bindgen.Args(ListenerRefSchema),
    ) bun.JSError!void {
        try this.listener.get().doRef(args.bindingThis);
    }

    pub fn bindReload(
        this: *JSBinding,
        context: bindgen.CallContext(ListenerReloadSchema),
        args: bindgen.Args(ListenerReloadSchema),
    ) bindgen.CallError(ListenerReloadSchema)!void {
        const listener = this.listener.get();
        const options = args.options orelse return context.fail(.expected_options, {});
        if (listener.listener == .none and listener.handlers.active_connections == 0) {
            return context.fail(.expected_options, {});
        }
        const converted = try options.convert(context);
        try listener.doReload(context, &converted.value);
    }

    pub fn bindStop(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerStopSchema),
        args: bindgen.Args(ListenerStopSchema),
    ) bun.JSError!void {
        this.listener.get().doStop(args.force orelse false);
    }

    pub fn bindGetUnix(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerUnixGetterSchema),
        _: bindgen.Args(ListenerUnixGetterSchema),
    ) bun.JSError!?bindgen.DOMString {
        return this.listener.get().getUnix();
    }

    pub fn bindUnref(
        this: *JSBinding,
        _: bindgen.CallContext(ListenerUnrefSchema),
        _: bindgen.Args(ListenerUnrefSchema),
    ) bun.JSError!void {
        this.listener.get().doUnref();
    }
};

pub const Handle = struct {
    binding: ListenerClass.Handle,

    pub fn get(this: *const Handle) *Listener {
        return this.binding.get().listener.get();
    }

    pub fn deinit(this: *Handle) void {
        this.binding.deinit();
    }
};

pub const Ref = bindgen.ClassRef(ListenerClassSchema);

pub fn toRef(this: *Listener, globalObject: *jsc.JSGlobalObject) bun.JSError!Ref {
    const binding = JSBinding.new(.{ .listener = .init(this) });
    return ListenerClass.adoptNativeRef(binding, globalObject);
}

pub const ListenerType = union(enum) {
    uws: *uws.ListenSocket,
    namedPipe: *WindowsNamedPipeListeningContext,
    none: void,
};

pub fn setDataRoot(this: *Listener, value: *const bindgen.Root) void {
    log("setData()", .{});
    this.strong_data.setRoot(value);
}

pub const UnixOrHost = union(enum) {
    unix: []const u8,
    host: struct {
        host: []const u8,
        port: u16,
    },
    fd: bun.FD,

    pub fn clone(this: UnixOrHost) UnixOrHost {
        switch (this) {
            .unix => |u| {
                return .{
                    .unix = bun.handleOom(bun.default_allocator.dupe(u8, u)),
                };
            },
            .host => |h| {
                return .{
                    .host = .{
                        .host = bun.handleOom(bun.default_allocator.dupe(u8, h.host)),
                        .port = this.host.port,
                    },
                };
            },
            .fd => |f| return .{ .fd = f },
        }
    }

    pub fn deinit(this: UnixOrHost) void {
        switch (this) {
            .unix => |u| {
                bun.default_allocator.free(u);
            },
            .host => |h| {
                bun.default_allocator.free(h.host);
            },
            .fd => {}, // this is an integer
        }
    }
};

pub fn doReload(this: *Listener, context: anytype, options: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
    if (this.listener == .none and this.handlers.active_connections == 0)
        return context.fail(.expected_options, {});
    var handlers = try Handlers.fromArgument(this.handlers.globalObject, context, &options.handlers, this.handlers.mode == .server);
    defer handlers.deinit();
    this.handlers.replaceCallbacks(&handlers);
}

pub fn listenFromBinding(
    context: anytype,
    generated: anytype,
) bun.bindgen.CallError(@TypeOf(context))!Ref {
    const globalObject = context.viewToken().globalObject();
    log("listen", .{});
    const vm = globalObject.bunVM();

    var socket_config = try SocketConfig.fromGenerated(globalObject, context, generated, true);
    defer socket_config.deinitExcludingHandlers();

    const handlers = &socket_config.handlers;
    // Only deinit handlers if there's an error; otherwise we put them in a `Listener` and
    // need them to stay alive.
    var handlers_owned = true;
    errdefer if (handlers_owned) handlers.deinit();

    const hostname_or_unix = &socket_config.hostname_or_unix;
    const port = socket_config.port;
    const ssl = if (socket_config.ssl) |*ssl| ssl else null;
    const ssl_enabled = ssl != null;
    const socket_flags = socket_config.socketFlags();

    if (Environment.isWindows and port == null) {
        // we check if the path is a named pipe otherwise we try to connect using AF_UNIX
        var buf: bun.PathBuffer = undefined;
        if (normalizePipeName(hostname_or_unix.slice(), buf[0..])) |pipe_name| {
            const connection: Listener.UnixOrHost = .{
                .unix = bun.handleOom(hostname_or_unix.intoOwnedSlice(bun.default_allocator)),
            };

            var socket: Listener = .{
                .handlers = handlers.take(),
                .connection = connection,
                .ssl = ssl_enabled,
                .listener = .none,
                .protos = if (ssl) |s| s.takeProtos() else null,
            };

            vm.eventLoop().ensureWaker();

            socket.strong_data.setRoot(&socket_config.default_data);

            const this: *Listener = bun.handleOom(handlers.vm.allocator.create(Listener));
            this.* = socket;
            // TODO: server_name is not supported on named pipes, I belive its , lets wait for
            // someone to ask for it

            var listener_owned = true;
            errdefer if (listener_owned) {
                this.handlers.deinit();
                this.strong_data.deinit();
                this.connection.deinit();
                if (this.protos) |protos| bun.default_allocator.free(protos);
                handlers.vm.allocator.destroy(this);
            };

            // we need to add support for the backlog parameter on listen here we use the
            // default value of nodejs
            const named_pipe = WindowsNamedPipeListeningContext.listen(
                globalObject,
                pipe_name,
                511,
                ssl,
                this,
            ) catch return globalObject.throwInvalidArguments(
                "Failed to listen at {s}",
                .{pipe_name},
            );
            this.listener = .{ .namedPipe = named_pipe };

            listener_owned = false;
            handlers_owned = false;
            const reference = try this.toRef(globalObject);
            this.strong_self = StrongSelf.initRef(&reference);
            this.poll_ref.ref(handlers.vm);
            return reference;
        }
    }

    vm.eventLoop().ensureWaker();

    // Allocate the Listener up front so the embedded `group` has its final
    // address before we hand it to listen() (it's linked into the loop's
    // intrusive list).
    var this: *Listener = try handlers.vm.allocator.create(Listener);
    this.* = .{
        .handlers = handlers.take(),
        .connection = undefined, // set after listen succeeds
        .ssl = ssl_enabled,
        .protos = if (ssl) |s| s.takeProtos() else null,
    };
    const socket_handlers = @import("./UwsHandlersEngine.zig");
    const callbacks = if (ssl_enabled) socket_handlers.listenerCallbacks(true) else socket_handlers.listenerCallbacks(false);
    this.group.init(uws.Loop.get(), callbacks, this);
    // `Listener` is mimalloc-allocated, so LSAN can't trace `loop->data.head →
    // this.group → head_sockets → us_socket_t` once the only pointer into the
    // group lives inside a mimalloc page. `process.exit()` from JS makes
    // global-object destruction early-return (vm.entryScope set), so
    // `finalize()`/`deinit()` never run and the accepted sockets' 88-byte
    // `us_create_poll` allocations are reported as leaked. Registering the
    // embedded group as a root region restores the same reachability the old
    // libc-malloc'd `us_socket_context_t` chain gave LSAN. Paired unregister
    // in `deinit()` (and the errdefer below).
    bun.asan.registerRootRegion(&this.group, @sizeOf(uws.SocketGroup));
    var listener_allocated = true;
    errdefer if (listener_allocated) {
        switch (this.listener) {
            .uws => |socket| {
                this.unlinkUnixSocketPath();
                socket.close();
                this.listener = .none;
                this.connection.deinit();
            },
            .none => {},
            .namedPipe => unreachable,
        }
        this.strong_data.deinit();
        this.handlers.deinit();
        if (this.secure_ctx) |c| BoringSSL.SSL_CTX_free(c);
        if (this.protos) |p| bun.default_allocator.free(p);
        bun.asan.unregisterRootRegion(&this.group, @sizeOf(uws.SocketGroup));
        this.group.deinit();
        handlers.vm.allocator.destroy(this);
    };

    if (generated.secure_context) |*secure_context| {
        this.secure_ctx = secure_context.get(SecureContext).borrow();
    } else if (ssl) |ssl_cfg| {
        var create_err: uws.TLSContextFailure = .{};
        this.secure_ctx = ssl_cfg.asUSockets().createSSLContext(&create_err) orelse {
            return TLSFailure.fromContextCreation(context, create_err);
        };
    }
    const kind: uws.SocketKind = if (ssl_enabled) .bun_listener_tls else .bun_listener_tcp;

    const hostname = try hostname_or_unix.intoOwnedSlice(bun.default_allocator);
    var hostname_owned = true;
    errdefer if (hostname_owned) bun.default_allocator.free(hostname);
    var connection: Listener.UnixOrHost = if (port) |port_| .{
        .host = .{ .host = hostname, .port = port_ },
    } else if (socket_config.fd) |fd| .{ .fd = fd } else .{ .unix = hostname };

    var listen_failure: uws.ListenFailure = .{};
    const listen_socket: *uws.ListenSocket = brk: {
        switch (connection) {
            .host => |host| {
                const hostz = try bun.default_allocator.dupeSentinel(u8, host.host, 0);
                defer bun.default_allocator.free(hostz);
                const ls = this.group.listen(kind, this.secure_ctx, hostz.ptr, host.port, socket_flags, @sizeOf(?*anyopaque), &listen_failure);
                if (ls) |s| connection.host.port = @intCast(s.getLocalPort());
                break :brk ls;
            },
            .unix => |u| {
                const pathz = try bun.default_allocator.dupeSentinel(u8, u, 0);
                defer bun.default_allocator.free(pathz);
                const socket = this.group.listenUnix(kind, this.secure_ctx, pathz.ptr, pathz.len, socket_flags, @sizeOf(?*anyopaque), &listen_failure);
                if (socket == null and listen_failure.socket_bound != 0 and pathz.len > 0 and pathz[0] != 0) {
                    _ = bun.sys.unlink(pathz);
                }
                break :brk socket;
            },
            .fd => |fd| {
                return context.fail(.listen_system, try bindgen.SystemError.init(.{
                    .errno = @backingInt(bun.sys.SystemErrno.EINVAL),
                    .code = "EINVAL",
                    .message = "Bun does not support listening on a file descriptor.",
                    .syscall = "listen",
                    .fd = fd.uv(),
                }));
            },
        }
    } orelse {
        const system_errno = listen_failure.systemErrno();
        if (system_errno) |err| if (err == .ENOMEM) return error.OutOfMemory;
        const message = try std.fmt.allocPrint(bun.default_allocator, "Failed to listen at {s}", .{hostname});
        defer bun.default_allocator.free(message);
        if (system_errno) |err| {
            return context.fail(.listen_address, try bindgen.SystemError.init(.{
                .errno = @backingInt(err),
                .code = @tagName(err),
                .message = message,
                .syscall = "listen",
                .address = hostname,
                .port = port,
            }));
        }
        return context.fail(.listen_failed, try bindgen.DOMString.fromUTF8(message));
    };

    this.connection = connection;
    hostname_owned = false;
    this.listener = .{ .uws = listen_socket };
    this.strong_data.setRoot(&socket_config.default_data);

    if (ssl) |ssl_config| {
        // `ssl_enabled` ⇒ `createSSLContext` succeeded above ⇒ `secure_ctx` set.
        const secure = this.secure_ctx orelse unreachable;
        if (ssl_config.server_name) |server_name| {
            if (server_name.len > 0) {
                // Registering the default cert under its own server_name is a
                // hint for sni_cb, not load-bearing — sni_find() miss falls
                // through to the default SSL_CTX anyway. A false here (e.g.
                // hostname already added via addContext before listen) is
                // benign, so don't fail the whole listen() for it.
                _ = try listen_socket.addServerName(server_name.ptr, secure, null);
            }
        }
    }

    listener_allocated = false; // ownership now on `this`; deinit handles cleanup
    handlers_owned = false;
    const reference = try this.toRef(globalObject);
    this.strong_self = StrongSelf.initRef(&reference);
    this.poll_ref.ref(handlers.vm);

    return reference;
}

pub fn onNamePipeCreated(comptime ssl: bool, listener: *Listener) *NewSocket(ssl) {
    const Socket = NewSocket(ssl);
    bun.assert(ssl == listener.ssl);

    var this_socket = Socket.new(.{
        .ref_count = .init(),
        .handlers = &listener.handlers,
        .core = .{ .socket = Socket.Socket.detached, .allocator = bun.default_allocator },
        .protos = listener.protos,
        .owned_protos = false,
    });
    this_socket.ref();
    const globalObject = listener.handlers.globalObject;
    var reference = this_socket.getThisRef(globalObject) catch |err| {
        globalObject.reportActiveExceptionAsUnhandled(err);
        this_socket.closeAndDetach(.failure);
        return this_socket;
    };
    defer reference.deinit();
    Socket.DataSlot.setOptionalRootOnOwned(&reference, &listener.strong_data);
    return this_socket;
}

/// Attaches the connection's native reference after wrapper creation succeeds.
pub fn onCreate(comptime ssl: bool, listener: *Listener, socket: uws.NewSocketHandler(ssl)) ?*NewSocket(ssl) {
    log("onCreate", .{});

    const Socket = NewSocket(ssl);
    bun.assert(ssl == listener.ssl);

    const globalObject = listener.handlers.globalObject;
    const this_socket = bun.default_allocator.create(Socket) catch {
        socket.close(.failure);
        globalObject.reportActiveExceptionAsUnhandled(error.OutOfMemory);
        return null;
    };
    this_socket.* = .{
        .ref_count = .init(),
        .handlers = &listener.handlers,
        .core = .{ .socket = socket, .allocator = bun.default_allocator },
        .protos = listener.protos,
        .owned_protos = false,
    };
    var reference = this_socket.getThisRef(globalObject) catch |err| {
        this_socket.closeAndDetach(.failure);
        this_socket.deref();
        globalObject.reportActiveExceptionAsUnhandled(err);
        return null;
    };
    defer reference.deinit();
    this_socket.ref();
    Socket.DataSlot.setOptionalRootOnOwned(&reference, &listener.strong_data);
    socket.socket.connected.ext(?*Socket).* = this_socket;
    socket.socket.connected.setKind(if (ssl) .bun_socket_tls else .bun_socket_tcp);
    socket.setTimeout(120);
    return this_socket;
}

pub fn addServerNameFromBinding(
    this: *Listener,
    context: bindgen.CallContext(AddServerNameSchema),
    hostname: bindgen.DOMStringView,
    tls: anytype,
) bindgen.CallError(AddServerNameSchema)!void {
    const global = context.viewToken().globalObject();
    if (!this.ssl) {
        return context.fail(.ssl_required, {});
    }
    const server_name = try hostname.toOwnedSliceZ(bun.default_allocator);
    defer bun.default_allocator.free(server_name);
    if (server_name.len == 0) {
        return context.fail(.empty_hostname, {});
    }

    if (this.listener != .uws) return;
    const ls = this.listener.uws;

    // node:tls passes the native SecureContext (already-built SSL_CTX*) — no
    // re-parse. Bun.listen({tls}) callers may still pass a raw options dict.
    const sni_ctx: *BoringSSL.SSL_CTX = switch (tls) {
        .secure_context => |secure| secure.get(SecureContext).borrow(),
        .options => |options| brk: {
            var cfg = (try SSLConfigEngine.parse(context, &options)) orelse return;
            defer cfg.deinit();
            var create_err: uws.TLSContextFailure = .{};
            const rare_data = try global.bunVM().tryRareData();
            break :brk rare_data.sslCtxCache().getOrCreate(&cfg, &create_err) orelse {
                return TLSFailure.fromContextCreation(context, create_err);
            };
        },
    };

    defer BoringSSL.SSL_CTX_free(sni_ctx);
    const ok = try ls.replaceServerName(server_name, sni_ctx);
    if (!ok) {
        const message = try std.fmt.allocPrint(bun.default_allocator, "Failed to register SNI for '{s}'", .{server_name});
        defer bun.default_allocator.free(message);
        return context.fail(.tls_boringssl, try bindgen.ThreadSafeDOMString.fromUTF8(message));
    }
}

fn doStop(this: *Listener, force_close: bool) void {
    log("close", .{});
    if (this.listener == .none) return;
    const listener = this.listener;

    if (listener == .uws) this.unlinkUnixSocketPath();

    defer switch (listener) {
        .uws => |socket| socket.close(),
        .namedPipe => |namedPipe| if (Environment.isWindows) namedPipe.closePipeAndDeinit(),
        .none => {},
    };
    this.listener = .none;

    if (this.handlers.active_connections == 0) {
        this.poll_ref.unref(this.handlers.vm);
        this.clearStrongSelf();
        this.strong_data.clear();
    } else if (force_close) {
        this.group.closeAll();
    }
}

pub fn finalize(this: *Listener) callconv(.c) void {
    log("finalize", .{});
    const listener = this.listener;
    this.listener = .none;
    switch (listener) {
        .uws => |socket| {
            this.unlinkUnixSocketPath();
            socket.close();
        },
        .namedPipe => |namedPipe| if (Environment.isWindows) namedPipe.closePipeAndDeinit(),
        .none => {},
    }
    this.deinit();
}

pub fn destroy(this: *Listener) void {
    this.finalize();
}

/// Match Node.js/libuv: unlink the unix socket file before closing the listening fd.
/// Unlinking after close would race with another process creating a socket at the same path.
fn unlinkUnixSocketPath(this: *const Listener) void {
    if (this.connection != .unix) return;
    const path = this.connection.unix;
    // Abstract sockets (Linux) start with a NUL byte and have no filesystem entry.
    if (path.len == 0 or path[0] == 0) return;
    const buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(buf);
    _ = bun.sys.unlink(bun.path.z(path, buf));
}

pub fn deinit(this: *Listener) void {
    log("deinit", .{});
    this.clearStrongSelf();
    this.strong_data.deinit();
    const vm = this.handlers.vm;
    this.poll_ref.unref(vm);
    bun.assert(this.listener == .none);

    // Any still-open accepted sockets hold a `&listener.handlers` pointer, so
    // we cannot free `this` while they're alive. Force-close them; their
    // onClose paths will markInactive against handlers we drop right after.
    if (this.handlers.active_connections > 0) {
        this.group.closeAll();
    }
    bun.asan.unregisterRootRegion(&this.group, @sizeOf(uws.SocketGroup));
    this.group.deinit();
    if (this.secure_ctx) |ctx| BoringSSL.SSL_CTX_free(ctx);

    this.connection.deinit();
    if (this.protos) |protos| {
        this.protos = null;
        bun.default_allocator.free(protos);
    }
    this.handlers.deinit();
    vm.allocator.destroy(this);
}

pub fn getUnix(this: *Listener) bun.OOM!?bindgen.DOMString {
    if (this.connection != .unix) {
        return null;
    }

    return try bindgen.DOMString.fromUTF8(this.connection.unix);
}

pub fn getHostname(this: *Listener) bun.OOM!?bindgen.DOMString {
    if (this.connection != .host) {
        return null;
    }
    return try bindgen.DOMString.fromUTF8(this.connection.host.host);
}

pub fn getPort(this: *Listener) ?u16 {
    if (this.connection != .host) {
        return null;
    }
    return this.connection.host.port;
}

pub fn getFD(this: *Listener) i64 {
    switch (this.listener) {
        .uws => |uws_listener| {
            return uws_listener.socket(false).fd().number();
        },
        else => return -1,
    }
}

pub fn clearStrongSelf(this: *Listener) void {
    if (this.strong_self) |*reference| reference.deinit();
    this.strong_self = null;
}

pub fn strongRef(this: *const Listener) ?Ref {
    const reference = if (this.strong_self) |*value| value else return null;
    return reference.toOwned();
}

pub fn doRef(this: *Listener, this_value: bindgen.ClassRefView(ListenerClassSchema)) bun.JSError!void {
    if (this.listener == .none) return;
    if (this.strong_self == null) this.strong_self = try StrongSelf.initView(this_value);
    this.poll_ref.ref(this.handlers.vm);
}

pub fn doUnref(this: *Listener) void {
    this.poll_ref.unref(this.handlers.vm);
    if (this.handlers.active_connections == 0) {
        this.clearStrongSelf();
    }
}

pub fn connectFromBinding(
    context: anytype,
    prev_maybe_tcp: ?*TCPSocket,
    prev_maybe_tls: ?*TLSSocket,
    generated: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    const globalObject = context.viewToken().globalObject();
    const vm = globalObject.bunVM();

    // is_server=false: this is the client connect path. Handlers.mode must be
    // .client so markInactive() takes the allocator.destroy branch — the
    // .server branch does @fieldParentPtr("handlers", this) to reach a
    // Listener, but here handlers live in a standalone allocator.create()
    // block (see below), so that would read past the allocation.
    var socket_config = try SocketConfig.fromGenerated(globalObject, context, generated, false);
    defer socket_config.deinitExcludingHandlers();

    const handlers = &socket_config.handlers;
    // Only deinit handlers if there's an error; otherwise we put them in a `TCPSocket` or
    // `TLSSocket` and need them to stay alive.
    errdefer handlers.deinit();
    try handlers.prepareConnectCompletion();

    const hostname_or_unix = &socket_config.hostname_or_unix;
    const port = socket_config.port;
    const ssl = if (socket_config.ssl) |*ssl| ssl else null;
    const ssl_enabled = ssl != null;
    const default_data = &socket_config.default_data;

    var server_name = if (ssl) |s| s.takeServerName() else null;
    defer if (server_name) |value| bun.default_allocator.free(value);

    vm.eventLoop().ensureWaker();

    var connection: Listener.UnixOrHost = blk: {
        if (socket_config.fd) |fd| break :blk .{ .fd = fd };
        const host = bun.handleOom(hostname_or_unix.intoOwnedSlice(bun.default_allocator));
        break :blk if (port) |port_| .{
            .host = .{
                .host = host,
                .port = port_,
            },
        } else .{ .unix = host };
    };
    errdefer connection.deinit();

    // A borrowed SecureContext preserves its CA bundle and certificate state
    // across both the named-pipe and uSockets branches.
    var owned_ssl_ctx: ?*BoringSSL.SSL_CTX = null;
    if (ssl_enabled) {
        if (generated.secure_context) |*secure_context| {
            owned_ssl_ctx = secure_context.get(SecureContext).borrow();
        }
    }
    errdefer if (owned_ssl_ctx) |c| BoringSSL.SSL_CTX_free(c);

    if (Environment.isWindows) {
        var buf: bun.PathBuffer = undefined;
        var pipe_name: ?[]const u8 = null;
        const isNamedPipe = switch (connection) {
            // we check if the path is a named pipe otherwise we try to connect using AF_UNIX
            .unix => |slice| brk: {
                pipe_name = normalizePipeName(slice, buf[0..]);
                break :brk (pipe_name != null);
            },
            .fd => |fd| brk: {
                const uvfd = fd.uv();
                const fd_type = uv.uv_guess_handle(uvfd);
                if (fd_type == uv.Handle.Type.named_pipe) {
                    break :brk true;
                }
                if (fd_type == uv.Handle.Type.unknown) {
                    // is not a libuv fd, check if it's a named pipe
                    const osfd: uv.uv_os_fd_t = @ptrFromInt(@as(usize, @intCast(uvfd)));
                    if (bun.windows.GetFileType(osfd) == bun.windows.FILE_TYPE_PIPE) {
                        // yay its a named pipe lets make it a libuv fd
                        connection.fd = bun.FD.fromNative(osfd).makeLibUVOwned() catch
                            @panic("failed to allocate file descriptor");
                        break :brk true;
                    }
                }
                break :brk false;
            },
            else => false,
        };
        if (isNamedPipe) {
            const handlers_ptr = try handlers.vm.allocator.create(Handlers);
            handlers_ptr.* = handlers.take();
            handlers_ptr.mode = .client;

            if (ssl_enabled) {
                var tls = if (prev_maybe_tls) |prev| blk: {
                    if (prev.handlers) |prev_handlers| {
                        prev_handlers.deinit();
                        handlers.vm.allocator.destroy(prev_handlers);
                    }
                    bun.assert(prev.wrapper != null);
                    prev.handlers = handlers_ptr;
                    bun.assert(prev.core.socket.socket == .detached);
                    // Free old resources before reassignment to prevent memory leaks
                    // when sockets are reused for reconnection (common with MongoDB driver)
                    if (prev.connection) |old_connection| {
                        old_connection.deinit();
                    }
                    prev.connection = connection;
                    if (prev.owned_protos) {
                        if (prev.protos) |old_protos| {
                            bun.default_allocator.free(old_protos);
                        }
                    }
                    prev.protos = if (ssl) |s| s.takeProtos() else null;
                    if (prev.server_name) |old_server_name| {
                        bun.default_allocator.free(old_server_name);
                    }
                    prev.server_name = bun.take(&server_name);
                    break :blk prev;
                } else TLSSocket.new(.{
                    .ref_count = .init(),
                    .handlers = handlers_ptr,
                    .core = .{ .socket = TLSSocket.Socket.detached, .allocator = bun.default_allocator },
                    .connection = connection,
                    .protos = if (ssl) |s| s.takeProtos() else null,
                    .server_name = bun.take(&server_name),
                });

                var reference = try tls.getThisRef(globalObject);
                defer reference.deinit();
                TLSSocket.DataSlot.setRootOnOwned(&reference, default_data);
                tls.poll_ref.ref(handlers.vm);
                tls.ref();
                handlers_ptr.attachConnectCompletion(context, TLSSocket.ClassSchema, &reference);

                // Transfer the borrowed CTX into the pipe's SSLWrapper. From
                // here it owns the ref on every path (initWithCTX adopts on
                // success, initTLSWrapper frees on failure), so null our local
                // before the call so the errdefer above can't double-free.
                const ctx_for_pipe = owned_ssl_ctx;
                owned_ssl_ctx = null;
                const named_pipe = switch (connection) {
                    .unix => WindowsNamedPipeContext.connect(
                        globalObject,
                        pipe_name.?,
                        if (ssl) |s| s.* else null,
                        ctx_for_pipe,
                        .{ .tls = tls },
                    ) catch return,
                    .fd => |fd| WindowsNamedPipeContext.open(
                        globalObject,
                        fd,
                        if (ssl) |s| s.* else null,
                        ctx_for_pipe,
                        .{ .tls = tls },
                    ) catch return,
                    else => unreachable,
                };
                tls.core.socket = TLSSocket.Socket.fromNamedPipe(named_pipe);
            } else {
                var tcp = if (prev_maybe_tcp) |prev| blk: {
                    bun.assert(prev.wrapper != null);
                    if (prev.handlers) |prev_handlers| {
                        prev_handlers.deinit();
                        handlers.vm.allocator.destroy(prev_handlers);
                    }
                    prev.handlers = handlers_ptr;
                    bun.assert(prev.core.socket.socket == .detached);
                    // Adopt `connection` (heap-owned for .unix) so the socket's
                    // deinit frees it; matches the TLS arm above and the
                    // non-pipe arm below. Previously `.connection = null`
                    // dropped the duped pipe-path bytes on the floor.
                    if (prev.connection) |old_connection| {
                        old_connection.deinit();
                    }
                    prev.connection = connection;
                    bun.assert(prev.protos == null);
                    bun.assert(prev.server_name == null);
                    break :blk prev;
                } else TCPSocket.new(.{
                    .ref_count = .init(),
                    .handlers = handlers_ptr,
                    .core = .{ .socket = TCPSocket.Socket.detached, .allocator = bun.default_allocator },
                    .connection = connection,
                    .protos = null,
                    .server_name = null,
                });
                tcp.ref();
                var reference = try tcp.getThisRef(globalObject);
                defer reference.deinit();
                TCPSocket.DataSlot.setRootOnOwned(&reference, default_data);
                tcp.poll_ref.ref(handlers.vm);
                handlers_ptr.attachConnectCompletion(context, TCPSocket.ClassSchema, &reference);

                const named_pipe = switch (connection) {
                    .unix => WindowsNamedPipeContext.connect(
                        globalObject,
                        pipe_name.?,
                        null,
                        null,
                        .{ .tcp = tcp },
                    ) catch return,
                    .fd => |fd| WindowsNamedPipeContext.open(
                        globalObject,
                        fd,
                        null,
                        null,
                        .{ .tcp = tcp },
                    ) catch return,
                    else => unreachable,
                };
                tcp.core.socket = TCPSocket.Socket.fromNamedPipe(named_pipe);
            }
            return;
        }
    }

    // SecureContext was already borrowed above; build the SSL_CTX from
    // SSLConfig only if no SecureContext was passed. doConnect hands
    // `socket.owned_ssl_ctx` to the per-VM connect group.
    if (ssl_enabled and owned_ssl_ctx == null) {
        if (ssl) |ssl_cfg| {
            // Per-connection server names and ALPN values do not affect the
            // cached context's certificate and trust configuration.
            var create_err: uws.TLSContextFailure = .{};
            const rare_data = try vm.tryRareData();
            owned_ssl_ctx = rare_data.sslCtxCache().getOrCreate(ssl_cfg, &create_err) orelse {
                return TLSFailure.fromContextCreation(context, create_err);
            };
        }
    }
    // (errdefer for owned_ssl_ctx already armed at the earlier lookup site;
    // duplicating it here would double-free on error.)

    const handlers_ptr = try handlers.vm.allocator.create(Handlers);
    handlers_ptr.* = handlers.take();
    handlers_ptr.mode = .client;

    switch (ssl_enabled) {
        inline else => |is_ssl_enabled| {
            const SocketType = NewSocket(is_ssl_enabled);
            const maybe_previous: ?*SocketType = if (is_ssl_enabled)
                prev_maybe_tls
            else
                prev_maybe_tcp;

            const socket = if (maybe_previous) |prev| blk: {
                bun.assert(prev.wrapper != null);
                if (prev.handlers) |prev_handlers| {
                    prev_handlers.deinit();
                    handlers.vm.allocator.destroy(prev_handlers);
                }
                prev.handlers = handlers_ptr;
                bun.assert(prev.core.socket.socket == .detached);
                // Free old resources before reassignment to prevent memory leaks
                // when sockets are reused for reconnection (common with MongoDB driver)
                if (prev.connection) |old_connection| {
                    old_connection.deinit();
                }
                prev.connection = connection;
                if (prev.owned_protos) {
                    if (prev.protos) |old_protos| {
                        bun.default_allocator.free(old_protos);
                    }
                }
                prev.protos = if (ssl) |s| s.takeProtos() else null;
                if (prev.server_name) |old_server_name| {
                    bun.default_allocator.free(old_server_name);
                }
                prev.server_name = bun.take(&server_name);
                if (prev.owned_ssl_ctx) |old| BoringSSL.SSL_CTX_free(old);
                prev.owned_ssl_ctx = owned_ssl_ctx;
                break :blk prev;
            } else bun.new(SocketType, .{
                .ref_count = .init(),
                .handlers = handlers_ptr,
                .core = .{ .socket = SocketType.Socket.detached, .allocator = bun.default_allocator },
                .connection = connection,
                .protos = if (ssl) |s| s.takeProtos() else null,
                .server_name = bun.take(&server_name),
                .owned_ssl_ctx = owned_ssl_ctx,
            });
            // Ownership moved into `socket`; disarm the errdefer.
            owned_ssl_ctx = null;
            socket.ref();
            var reference = try socket.getThisRef(globalObject);
            defer reference.deinit();
            SocketType.DataSlot.setRootOnOwned(&reference, default_data);
            socket.core.flags.allow_half_open = socket_config.flags.allow_half_open;
            handlers_ptr.attachConnectCompletion(context, SocketType.ClassSchema, &reference);
            const connect_failure: ?SocketType.ConnectFailure = failure: {
                const native_failure = socket.doConnect(connection) catch break :failure .out_of_memory;
                break :failure if (native_failure) |value| .{ .native = value } else null;
            };
            if (connect_failure) |failure| {
                socket.handleConnectFailure(failure) catch |err| globalObject.reportActiveExceptionAsUnhandled(err);
                // No native socket owns the reference acquired before doConnect.
                socket.deref();
                return;
            }

            // if this is from node:net there's surface where the user can .ref() and .deref()
            // before the connection starts. make sure we honor that here.
            // in the Bun.connect path, this will always be true at this point in time.
            if (socket.ref_pollref_on_connect) socket.poll_ref.ref(handlers.vm);

            return;
        },
    }
}

pub fn getSockName(this: *Listener) bun.OOM!bindgen.Return(ListenerGetSockNameNativeSchema) {
    if (this.listener != .uws) {
        return null;
    }

    const socket = this.listener.uws;

    var buf: [64]u8 = @splat(0);
    var text_buf: [512]u8 = undefined;
    const address_bytes: []const u8 = socket.getLocalAddress(&buf) catch return null;
    const address_zig: SocketAddress = switch (address_bytes.len) {
        4 => .initIp4(address_bytes[0..4].*, 0),
        16 => .initIp6(address_bytes[0..16].*, 0, 0, 0),
        else => return null,
    };
    const family = switch (address_bytes.len) {
        4 => "IPv4",
        16 => "IPv6",
        else => return null,
    };
    return .{
        .family = try bindgen.DOMString.fromUTF8(family),
        .address = try bindgen.DOMString.fromUTF8(address_zig.formatIp(&text_buf)),
        .port = std.math.cast(u16, socket.getLocalPort()) orelse return null,
    };
}

pub fn jsAddServerName(
    context: bun.bindgen.CallContext(AddServerNameSchema),
    args: bun.bindgen.Args(AddServerNameSchema),
) bun.bindgen.CallError(AddServerNameSchema)!void {
    const listener = args.listener.get(JSBinding).listener.get();
    return listener.addServerNameFromBinding(
        context,
        args.hostname,
        args.tls,
    );
}
pub const log = Output.scoped(.Listener, .visible);

fn isValidPipeName(pipe_name: []const u8) bool {
    if (!Environment.isWindows) {
        return false;
    }
    const windows_path = std.fs.path.PathType.windows;
    // check for valid pipe names
    // at minimum we need to have \\.\pipe\ or \\?\pipe\ + 1 char that is not a separator
    return pipe_name.len > 9 and
        windows_path.isSep(u8, pipe_name[0]) and
        windows_path.isSep(u8, pipe_name[1]) and
        (pipe_name[2] == '.' or pipe_name[2] == '?') and
        windows_path.isSep(u8, pipe_name[3]) and
        strings.eql(pipe_name[4..8], "pipe") and
        windows_path.isSep(u8, pipe_name[8]) and
        !windows_path.isSep(u8, pipe_name[9]);
}

fn normalizePipeName(pipe_name: []const u8, buffer: []u8) ?[]const u8 {
    if (Environment.isWindows) {
        bun.assert(pipe_name.len < buffer.len);
        if (!isValidPipeName(pipe_name)) {
            return null;
        }
        // normalize pipe name with can have mixed slashes
        // pipes are simple and this will be faster than using node:path.resolve()
        // we dont wanna to normalize the pipe name it self only the pipe identifier (//./pipe/, //?/pipe/, etc)
        @memcpy(buffer[0..9], "\\\\.\\pipe\\");
        @memcpy(buffer[9..pipe_name.len], pipe_name[9..]);
        return buffer[0..pipe_name.len];
    } else {
        return null;
    }
}

pub const WindowsNamedPipeListeningContext = if (Environment.isWindows) struct {
    uvPipe: uv.Pipe = std.mem.zeroes(uv.Pipe),
    listener: ?*Listener,
    globalThis: *jsc.JSGlobalObject,
    vm: *jsc.VirtualMachine,
    ctx: ?*BoringSSL.SSL_CTX = null, // server reuses the same ctx
    pub const new = bun.TrivialNew(WindowsNamedPipeListeningContext);

    fn onClientConnect(this: *WindowsNamedPipeListeningContext, status: uv.ReturnCode) void {
        if (status != uv.ReturnCode.zero or this.vm.isShuttingDown() or this.listener == null) {
            // connection dropped or vm is shutting down or we are deiniting/closing
            return;
        }
        const listener = this.listener.?;
        const socket: WindowsNamedPipeContext.SocketType = brk: {
            if (this.ctx) |_| {
                break :brk .{ .tls = Listener.onNamePipeCreated(true, listener) };
            } else {
                break :brk .{ .tcp = Listener.onNamePipeCreated(false, listener) };
            }
        };

        const client = WindowsNamedPipeContext.create(this.globalThis, socket);

        const result = client.named_pipe.getAcceptedBy(&this.uvPipe, this.ctx);
        if (result == .err) {
            // connection dropped
            client.deinit();
        }
    }

    fn onPipeClosed(pipe: *uv.Pipe) callconv(.c) void {
        const this: *WindowsNamedPipeListeningContext = @ptrCast(@alignCast(pipe.data));
        this.deinit();
    }

    pub fn closePipeAndDeinit(this: *WindowsNamedPipeListeningContext) void {
        this.listener = null;
        this.uvPipe.data = this;
        this.uvPipe.close(onPipeClosed);
    }

    pub fn listen(
        globalThis: *jsc.JSGlobalObject,
        path: []const u8,
        backlog: i32,
        ssl_config: ?*const SSLConfig,
        listener: *Listener,
    ) !*WindowsNamedPipeListeningContext {
        const this = WindowsNamedPipeListeningContext.new(.{
            .globalThis = globalThis,
            .vm = globalThis.bunVM(),
            .listener = listener,
        });
        var pipe_initialized = false;
        errdefer {
            // Once the uv pipe handle is registered with the loop it must be closed via
            // uv_close; before that point we can free the struct directly. `deinit()` also
            // frees the SSL context if one was created.
            if (pipe_initialized) this.closePipeAndDeinit() else this.deinit();
        }

        if (ssl_config) |ssl_options| {
            bun.BoringSSL.load();

            const ctx_opts: uws.SocketContext.BunSocketContextOptions = ssl_options.asUSockets();
            var err: uws.TLSContextFailure = .{};
            // Create SSL context using uSockets to match behavior of node.js
            this.ctx = ctx_opts.createSSLContext(&err) orelse return switch (err.kind) {
                .out_of_memory => error.OutOfMemory,
                else => error.InvalidOptions,
            };
        }

        const initResult = this.uvPipe.init(this.vm.uvLoop(), false);
        if (initResult == .err) {
            return error.FailedToInitPipe;
        }
        pipe_initialized = true;
        if (path[path.len - 1] == 0) {
            // is already null terminated
            const slice_z = path[0 .. path.len - 1 :0];
            this.uvPipe.listenNamedPipe(slice_z, backlog, this, onClientConnect).unwrap() catch return error.FailedToBindPipe;
        } else {
            var path_buf: bun.PathBuffer = undefined;
            // we need to null terminate the path
            const len = @min(path.len, path_buf.len - 1);

            @memcpy(path_buf[0..len], path[0..len]);
            path_buf[len] = 0;
            const slice_z = path_buf[0..len :0];
            this.uvPipe.listenNamedPipe(slice_z, backlog, this, onClientConnect).unwrap() catch return error.FailedToBindPipe;
        }
        //TODO: add readableAll and writableAll support if someone needs it
        // if(uv.uv_pipe_chmod(&this.uvPipe, uv.UV_WRITABLE | uv.UV_READABLE) != 0) {
        // this.closePipeAndDeinit();
        // return error.FailedChmodPipe;
        //}

        return this;
    }

    fn runEvent(this: *WindowsNamedPipeListeningContext) void {
        switch (this.task_event) {
            .deinit => {
                this.deinit();
            },
            .none => @panic("Invalid event state"),
        }
    }

    fn deinitInNextTick(this: *WindowsNamedPipeListeningContext) void {
        bun.assert(this.task_event != .deinit);
        this.task_event = .deinit;
        this.vm.enqueueTask(jsc.Task.init(&this.task));
    }

    fn deinit(this: *WindowsNamedPipeListeningContext) void {
        this.listener = null;
        if (this.ctx) |ctx| {
            this.ctx = null;
            BoringSSL.SSL_CTX_free(ctx);
        }
        bun.destroy(this);
    }
} else void;

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;
const Async = bun.Async;
const Environment = bun.Environment;
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const uws = bun.uws;
const TLSFailure = @import("./TLSFailure.zig");
const BoringSSL = bun.BoringSSL.c;
const uv = bun.windows.libuv;

const api = bun.api;
const Handlers = bun.api.SocketHandlers;
const SecureContext = bun.api.SecureContext;
const TCPSocket = bun.api.TCPSocket;
const TLSSocket = bun.api.TLSSocket;
const SSLConfig = bun.api.ServerConfig.SSLConfig;
const SSLConfigEngine = bun.api.ServerConfig.SSLConfigEngine;

const NewSocket = api.socket.NewSocket;
const SocketConfig = api.socket.SocketConfig;
const SocketAddress = api.socket.SocketAddress;
const WindowsNamedPipeContext = api.socket.WindowsNamedPipeContext;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;

const NodeSocketBindings = bun.bindgen.Module("NodeSocket");
const AddServerNameSchema = NodeSocketBindings.function("addServerName");
const AddServerNameBinding = bun.bindgen.Fn(AddServerNameSchema, jsAddServerName);
const ListenerBindingModule = bindgen.Module("Listener");
pub const ListenerClassSchema = ListenerBindingModule.class("Listener");
pub const ListenerClass = bindgen.Class(ListenerClassSchema, JSBinding);
const ListenerDisposeSchema = ListenerClassSchema.member("dispose");
const ListenerDataGetterSchema = ListenerClassSchema.memberKind("data", .getter);
const ListenerDataSetterSchema = ListenerClassSchema.memberKind("data", .setter);
const ListenerFDGetterSchema = ListenerClassSchema.memberKind("fd", .getter);
const ListenerGetSockNameNativeSchema = ListenerClassSchema.member("getSockNameNative");
const ListenerHostnameGetterSchema = ListenerClassSchema.memberKind("hostname", .getter);
const ListenerPortGetterSchema = ListenerClassSchema.memberKind("port", .getter);
const ListenerRefSchema = ListenerClassSchema.member("ref");
const ListenerReloadSchema = ListenerClassSchema.member("reload");
const ListenerStopSchema = ListenerClassSchema.member("stop");
const ListenerUnixGetterSchema = ListenerClassSchema.memberKind("unix", .getter);
const ListenerUnrefSchema = ListenerClassSchema.member("unref");

comptime {
    _ = AddServerNameBinding;
    _ = ListenerClass;
}
