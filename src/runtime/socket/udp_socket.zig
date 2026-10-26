const log = Output.scoped(.UdpSocket, .visible);

fn onClose(socket: *uws.udp.Socket) callconv(.c) void {
    const this: *UDPSocket = bun.cast(*UDPSocket, socket.user().?);
    defer this.releaseSocketActivity();
    this.closed = true;
    this.poll_ref.disable();
    this.socket = null;
    this.invalidateAddressCaches();
}

fn onRecvError(socket: *uws.udp.Socket, errno: c_int) callconv(.c) void {

    // Only called on Linux via IP_RECVERR — loop.c guards the recv-on-error
    // path with #if defined(__linux__) to preserve the pre-existing
    // close-on-error behavior on kqueue/Windows (where an error event is a
    // fatal socket condition, not a drainable error queue). Builds a
    // SystemError from the ICMP errno (ECONNREFUSED, EHOSTUNREACH,
    // ENETUNREACH, EMSGSIZE, ...) and dispatches through the 'error' handler.
    const this: *UDPSocket = bun.cast(*UDPSocket, socket.user().?);
    const sys_err = bun.sys.Error.fromCodeInt(errno, .recv);
    UDPSocketEngine.callSystemErrorHandler(this, sys_err);
}

fn onDrain(socket: *uws.udp.Socket) callconv(.c) void {
    const this: *UDPSocket = bun.cast(*UDPSocket, socket.user().?);
    var receiver = ((this.wrapper orelse return).toOwned() catch |err| return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();
    var callback = (UDPSocketOnDrainSlot.ownedCallback(&receiver) catch |err|
        return this.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer callback.deinit();

    const vm = jsc.VirtualMachine.get();
    const event_loop = vm.eventLoop();
    event_loop.enter();
    defer event_loop.exit();
    var invocation: @TypeOf(callback).Invocation = undefined;
    callback.beginInvocation(&invocation);
    defer invocation.deinit();
    invocation.call(.{
        .bindingThis = receiver.operand(&invocation),
        .socket = receiver.operand(&invocation),
    }) catch |err| {
        UDPSocketEngine.callErrorHandler(this, err);
    };
}

fn onData(socket: *uws.udp.Socket, buf: *uws.udp.PacketBuffer, packets: c_int) callconv(.c) void {
    if (packets <= 0) return;
    const udpSocket: *UDPSocket = bun.cast(*UDPSocket, socket.user().?);
    var receiver = ((udpSocket.wrapper orelse return).toOwned() catch |err| return udpSocket.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
    defer receiver.deinit();

    const loop = udpSocket.vm.eventLoop();
    loop.enter();
    defer loop.exit();

    // Nested event-loop turns reuse the receive buffer, including payloads
    // whose callbacks have not yet run.
    const payloads = bun.default_allocator.alloc(bindgen.OwnedBytes, @intCast(packets)) catch |err| {
        UDPSocketEngine.callErrorHandler(udpSocket, err);
        return;
    };
    defer bun.default_allocator.free(payloads);
    @memset(payloads, bindgen.OwnedBytes.empty());
    defer for (payloads) |*payload| payload.deinit();
    for (payloads, 0..) |*payload, index| {
        payload.* = bindgen.OwnedBytes.fromSlice(buf.getPayload(@intCast(index))) catch |err| {
            UDPSocketEngine.callErrorHandler(udpSocket, err);
            return;
        };
    }

    var i: c_int = 0;
    while (i < packets) : (i += 1) {
        if (udpSocket.closed or udpSocket.vm.isShuttingDown()) return;
        if (udpSocket.globalThis.hasExceptionIncludingTraps()) return;
        var callback = (UDPSocketOnDataSlot.ownedCallback(&receiver) catch |err|
            return udpSocket.globalThis.reportActiveExceptionAsUnhandled(err)) orelse return;
        defer callback.deinit();
        const peer = buf.getPeer(i);

        var addr_buf: [46]u8 = undefined;
        var port: u16 = 0;
        var scope_id: ?u32 = null;
        const hostname: []const u8 = format_address: {
            switch (peer.family) {
                std.posix.AF.INET => {
                    const peer4: *const std.posix.sockaddr.in = @ptrCast(peer);
                    const bytes: [4]u8 = @bitCast(peer4.addr);
                    port = std.mem.bigToNative(u16, peer4.port);
                    break :format_address std.fmt.bufPrint(&addr_buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch unreachable;
                },
                std.posix.AF.INET6 => {
                    const peer6: *const std.posix.sockaddr.in6 = @ptrCast(peer);
                    const address: std.Io.net.Ip6Address.Unresolved = .{ .bytes = peer6.addr, .interface_name = null };
                    port = std.mem.bigToNative(u16, peer6.port);
                    if (peer6.scope_id != 0) scope_id = peer6.scope_id;
                    break :format_address std.fmt.bufPrint(&addr_buf, "{f}", .{address}) catch unreachable;
                },
                else => continue,
            }
        };
        if (port == 0) {
            continue;
        }

        const truncated = buf.getTruncated(i);

        const scope_name_capacity: usize = if (bun.Environment.isWindows) 0 else bun.c.IF_NAMESIZE;
        const scoped_hostname_capacity = @as(usize, 47) + @as(usize, @max(scope_name_capacity, 10));
        var scoped_hostname: [scoped_hostname_capacity]u8 = undefined;
        const hostname_text = if (scope_id) |id| blk: {
            if (comptime !bun.Environment.isWindows) {
                var buffer = std.mem.zeroes([bun.c.IF_NAMESIZE:0]u8);
                if (bun.c.if_indextoname(id, &buffer) != null) {
                    break :blk std.fmt.bufPrint(&scoped_hostname, "{s}%{s}", .{ hostname, std.mem.span(@as([*:0]u8, &buffer)) }) catch unreachable;
                }
            }

            break :blk std.fmt.bufPrint(&scoped_hostname, "{s}%{d}", .{ hostname, id }) catch unreachable;
        } else hostname;
        var hostname_value = bindgen.DOMString.fromUTF8(hostname_text) catch |err| {
            UDPSocketEngine.callErrorHandler(udpSocket, err);
            return;
        };
        defer hostname_value.deinit();

        const owned_data = payloads[@intCast(i)];
        const Data = @FieldType(bindgen.Args(UDPSocketOnDataSlot.SemanticType), "data");
        const data_value: Data = switch (udpSocket.config.binary_type) {
            inline else => |kind| @unionInit(Data, @tagName(kind), owned_data.operand()),
        };
        var invocation: @TypeOf(callback).Invocation = undefined;
        callback.beginInvocation(&invocation);
        defer invocation.deinit();
        invocation.call(.{
            .bindingThis = receiver.operand(&invocation),
            .socket = receiver.operand(&invocation),
            .data = data_value,
            .port = port,
            .hostname = hostname_value.operand(),
            .flags = .{ .truncated = truncated },
        }) catch |err| {
            UDPSocketEngine.callErrorHandler(udpSocket, err);
        };
    }
}

pub const UDPSocketConfig = struct {
    const This = @This();

    const ConnectConfig = struct {
        port: u16,
        address: bun.String,
    };

    hostname: bun.String = .empty,
    connect: ?ConnectConfig = null,
    port: u16 = 0,
    flags: i32 = 0,
    binary_type: UDPSocketBinaryType = .buffer,
    on_data: ?bindgen.Callback(UDPSocketOnDataSlot.SemanticType) = null,
    on_drain: ?bindgen.Callback(UDPSocketOnDrainSlot.SemanticType) = null,
    on_error: ?bindgen.Callback(UDPSocketOnErrorSlot.SemanticType) = null,

    pub fn fromGenerated(context: anytype, generated: anytype) !This {
        var owned_hostname = generated.hostname.toOwned();
        var hostname = owned_hostname.takeBunString();
        if (hostname.isEmpty()) {
            hostname.deref();
            hostname = bun.String.static("0.0.0.0");
        }

        var config: This = .{
            .hostname = hostname,
            .port = generated.port,
            .flags = generated.flags,
            .binary_type = generated.binary_type,
        };
        errdefer config.deinit();

        if (generated.handlers) |*generated_handlers| {
            config.on_data = try ownHandlerCallback(UDPSocketOnDataSlot, generated_handlers.on_data);
            config.on_drain = try ownHandlerCallback(UDPSocketOnDrainSlot, generated_handlers.on_drain);
            config.on_error = try ownHandlerCallback(UDPSocketOnErrorSlot, generated_handlers.on_error);
        }

        if (generated.connect) |*connect| {
            var owned_address = connect.hostname.toOwned();
            const address = owned_address.takeBunString();
            if (address.isEmpty()) {
                address.deref();
                return context.fail(.invalid_connect_hostname, {});
            }
            config.connect = .{
                .port = connect.port,
                .address = address,
            };
        }

        return config;
    }

    pub fn deinit(this: *This) void {
        this.hostname.deref();
        if (this.connect) |*val| {
            val.address.deref();
        }
        if (this.on_data) |*callback| callback.deinit();
        if (this.on_drain) |*callback| callback.deinit();
        if (this.on_error) |*callback| callback.deinit();
        this.* = .{};
    }

    pub fn installHandlers(this: *This, receiver: *const bindgen.ClassRef(UDPSocketClassSchema)) void {
        installHandler(UDPSocketOnDataSlot, &this.on_data, receiver);
        installHandler(UDPSocketOnDrainSlot, &this.on_drain, receiver);
        installHandler(UDPSocketOnErrorSlot, &this.on_error, receiver);
    }

    fn ownHandlerCallback(comptime Slot: type, field: anytype) bun.JSError!?bindgen.Callback(Slot.SemanticType) {
        const optional_callback = field orelse return null;
        const callback = optional_callback orelse return null;
        return try callback.toOwned();
    }

    fn installHandler(comptime Slot: type, callback: anytype, receiver: anytype) void {
        if (callback.*) |*value| {
            Slot.setOwnedCallbackOnOwned(receiver, value);
            value.deinit();
            callback.* = null;
        } else {
            Slot.clearOwned(receiver);
        }
    }
};

pub const UDPSocket = struct {
    const This = @This();

    pub fn createForBinding(context: anytype, options: anytype) bindgen.CallError(@TypeOf(context))!bindgen.Return(@TypeOf(context)) {
        return createFromBinding(context, options);
    }

    pub const JSBinding = struct {
        bindgen_state: bindgen.ClassState = .{},
        socket: bindgen.RefNative(UDPSocket, .vm),

        pub const destroy = @This().deinit;

        fn deinit(this: *JSBinding) void {
            const socket = this.socket.get();
            if (socket.vm.isShuttingDown()) socket.closeSocket();
            this.socket.deinit();
            bun.destroy(this);
        }

        pub fn hasPendingActivity(this: *const JSBinding) bool {
            return this.socket.get().socket_ref_held;
        }

        pub fn bindDispose(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketDisposeSchema),
            _: bindgen.Args(UDPSocketDisposeSchema),
        ) bun.JSError!void {
            this.socket.get().closeSocket();
        }

        pub fn bindClose(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketCloseSchema),
            _: bindgen.Args(UDPSocketCloseSchema),
        ) bun.JSError!void {
            this.socket.get().closeSocket();
        }

        pub fn bindAddMembership(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketAddMembershipSchema),
            args: bindgen.Args(UDPSocketAddMembershipSchema),
        ) bindgen.CallError(UDPSocketAddMembershipSchema)!bool {
            return this.socket.get().setMembership(context, args.multicastAddress, args.multicastInterface, false);
        }

        pub fn bindGetAddress(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketAddressSchema),
            _: bindgen.Args(UDPSocketAddressSchema),
        ) bun.JSError!bindgen.Return(UDPSocketAddressSchema) {
            return try this.socket.get().getAddress();
        }

        pub fn bindAddSourceSpecificMembership(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketAddSourceSpecificMembershipSchema),
            args: bindgen.Args(UDPSocketAddSourceSpecificMembershipSchema),
        ) bindgen.CallError(UDPSocketAddSourceSpecificMembershipSchema)!bool {
            return this.socket.get().setSourceSpecificMembership(context, args.sourceAddress, args.groupAddress, args.multicastInterface, false);
        }

        pub fn bindGetBinaryType(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketBinaryTypeSchema),
            _: bindgen.Args(UDPSocketBinaryTypeSchema),
        ) bun.JSError!UDPSocketBinaryType {
            return this.socket.get().getBinaryType();
        }

        pub fn bindGetClosed(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketClosedSchema),
            _: bindgen.Args(UDPSocketClosedSchema),
        ) bun.JSError!bool {
            return this.socket.get().closed;
        }

        pub fn bindDropMembership(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketDropMembershipSchema),
            args: bindgen.Args(UDPSocketDropMembershipSchema),
        ) bindgen.CallError(UDPSocketDropMembershipSchema)!bool {
            return this.socket.get().setMembership(context, args.multicastAddress, args.multicastInterface, true);
        }

        pub fn bindDropSourceSpecificMembership(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketDropSourceSpecificMembershipSchema),
            args: bindgen.Args(UDPSocketDropSourceSpecificMembershipSchema),
        ) bindgen.CallError(UDPSocketDropSourceSpecificMembershipSchema)!bool {
            return this.socket.get().setSourceSpecificMembership(context, args.sourceAddress, args.groupAddress, args.multicastInterface, true);
        }

        pub fn bindGetHostname(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketHostnameSchema),
            _: bindgen.Args(UDPSocketHostnameSchema),
        ) bun.JSError!bindgen.DOMString {
            return this.socket.get().getHostname();
        }

        pub fn bindGetPort(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketPortSchema),
            _: bindgen.Args(UDPSocketPortSchema),
        ) bun.JSError!?u16 {
            return this.socket.get().getPort();
        }

        pub fn bindRef(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketRefSchema),
            _: bindgen.Args(UDPSocketRefSchema),
        ) bun.JSError!void {
            const socket = this.socket.get();
            if (!socket.closed) socket.poll_ref.ref(jsc.VirtualMachine.get());
        }

        pub fn bindReload(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketReloadSchema),
            args: bindgen.Args(UDPSocketReloadSchema),
        ) bindgen.CallError(UDPSocketReloadSchema)!void {
            try this.socket.get().reload(context, args.options);
        }

        pub fn bindGetRemoteAddress(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketRemoteAddressSchema),
            _: bindgen.Args(UDPSocketRemoteAddressSchema),
        ) bun.JSError!bindgen.Return(UDPSocketRemoteAddressSchema) {
            return try this.socket.get().getRemoteAddress();
        }

        pub fn bindSend(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSendSchema),
            args: bindgen.Args(UDPSocketSendSchema),
        ) bindgen.CallError(UDPSocketSendSchema)!bool {
            return this.socket.get().send(context, args);
        }

        pub fn bindSendMany(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSendManySchema),
            args: bindgen.Args(UDPSocketSendManySchema),
        ) bindgen.CallError(UDPSocketSendManySchema)!i32 {
            return this.socket.get().sendMany(context, args);
        }

        pub fn bindSetBroadcast(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSetBroadcastSchema),
            args: bindgen.Args(UDPSocketSetBroadcastSchema),
        ) bindgen.CallError(UDPSocketSetBroadcastSchema)!bool {
            return this.socket.get().setBroadcast(context, args.enabled);
        }

        pub fn bindSetMulticastInterface(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSetMulticastInterfaceSchema),
            args: bindgen.Args(UDPSocketSetMulticastInterfaceSchema),
        ) bindgen.CallError(UDPSocketSetMulticastInterfaceSchema)!bool {
            return this.socket.get().setMulticastInterface(context, args.multicastInterface);
        }

        pub fn bindSetMulticastLoopback(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSetMulticastLoopbackSchema),
            args: bindgen.Args(UDPSocketSetMulticastLoopbackSchema),
        ) bindgen.CallError(UDPSocketSetMulticastLoopbackSchema)!bool {
            return this.socket.get().setMulticastLoopback(context, args.enabled);
        }

        pub fn bindSetMulticastTTL(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSetMulticastTTLSchema),
            args: bindgen.Args(UDPSocketSetMulticastTTLSchema),
        ) bindgen.CallError(UDPSocketSetMulticastTTLSchema)!i32 {
            return this.socket.get().setAnyTTL(context, args.ttl, uws.udp.Socket.setMulticastTTL);
        }

        pub fn bindSetTTL(
            this: *JSBinding,
            context: bindgen.CallContext(UDPSocketSetTTLSchema),
            args: bindgen.Args(UDPSocketSetTTLSchema),
        ) bindgen.CallError(UDPSocketSetTTLSchema)!i32 {
            return this.socket.get().setAnyTTL(context, args.ttl, uws.udp.Socket.setUnicastTTL);
        }

        pub fn bindUnref(
            this: *JSBinding,
            _: bindgen.CallContext(UDPSocketUnrefSchema),
            _: bindgen.Args(UDPSocketUnrefSchema),
        ) bun.JSError!void {
            this.socket.get().poll_ref.unref(jsc.VirtualMachine.get());
        }
    };

    const RefCount = bun.ptr.RefCount(UDPSocket, "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    config: UDPSocketConfig,

    socket: ?*uws.udp.Socket = null,
    loop: *uws.Loop,

    globalThis: *JSGlobalObject,
    wrapper: ?UDPSocketClass.ActivityWrapper = null,
    ref_count: RefCount = .init(),
    socket_ref_held: bool = false,

    poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
    closed: bool = false,
    connect_info: ?ConnectInfo = null,
    vm: *jsc.VirtualMachine,

    const ConnectInfo = struct {
        port: u16,
    };

    pub const new = bun.TrivialNew(@This());

    pub fn createFromBinding(context: anytype, options: anytype) !bindgen.ClassRef(UDPSocketClassSchema) {
        const globalThis = context.viewToken().globalObject();
        log("udpSocket", .{});

        const vm = globalThis.bunVM();
        var this = This.new(.{
            .socket = null,
            .config = .{},
            .globalThis = globalThis,
            .loop = uws.Loop.get(),
            .vm = vm,
        });
        const binding = bun.new(JSBinding, .{ .socket = .adopt(this) });
        var reference = try UDPSocketClass.adoptNativeRef(binding, globalThis);
        errdefer reference.deinit();
        this.wrapper = try UDPSocketClass.ActivityWrapper.initRef(&reference);
        errdefer this.closeSocket();

        this.config = try UDPSocketConfig.fromGenerated(context, options);
        var receiver = reference.clone();
        defer receiver.deinit();
        this.config.installHandlers(&receiver);

        var failure: uws.udp.CreateFailure = .{};

        const hostname_z = try this.config.hostname.toOwnedSliceZ(bun.default_allocator);
        defer bun.default_allocator.free(hostname_z);

        this.socket = uws.udp.Socket.create(
            this.loop,
            onData,
            onDrain,
            onClose,
            onRecvError,
            hostname_z,
            this.config.port,
            this.config.flags,
            &failure,
            this,
        ) orelse {
            this.closed = true;
            if (failure.systemErrno()) |errno| {
                if (errno == .ENOMEM) return error.OutOfMemory;
                const code = @tagName(errno);
                const address = try this.config.hostname.toUTF8(bun.default_allocator);
                defer address.deinit();
                const message = try std.fmt.allocPrint(bun.default_allocator, "bind {s} {s}", .{ code, address.slice() });
                defer bun.default_allocator.free(message);
                return context.fail(.system, try bindgen.SystemError.init(.{
                    .errno = @backingInt(errno),
                    .code = code,
                    .message = message,
                    .address = address.slice(),
                }));
            }

            if (failure.address_error != 0) {
                const dns_error = bun.c_ares.Error.initEAI(failure.address_error) orelse return context.fail(.bind_failed, {});
                if (dns_error == .ENOMEM) return error.OutOfMemory;
                const address = try this.config.hostname.toUTF8(bun.default_allocator);
                defer address.deinit();
                return context.fail(.dns, try bindgen.SystemError.fromDNSError(dns_error, "getaddrinfo", address.slice()));
            }

            return context.fail(.bind_failed, {});
        };
        this.retainSocketActivity();

        if (this.config.connect) |*connect| {
            const address_z = try connect.address.toOwnedSliceZ(bun.default_allocator);
            defer bun.default_allocator.free(address_z);
            const ret = this.socket.?.connect(address_z, connect.port);
            if (ret != 0) {
                const sys_err = if (comptime bun.Environment.isWindows)
                    if (ret == -1)
                        bun.sys.Maybe(void).errno(bun.windows.getLastWinsockErrno(), .connect)
                    else
                        null
                else
                    bun.sys.Maybe(void).errnoSys(ret, .connect);
                if (sys_err) |sys_error| {
                    return failSystem(context, sys_error);
                }

                if (bun.c_ares.Error.initEAI(ret)) |eai_err| {
                    return context.fail(.dns, try bindgen.SystemError.fromDNSError(eai_err, "connect", address_z));
                }
            }
            this.connect_info = .{ .port = connect.port };
        }

        this.poll_ref.ref(vm);
        return reference;
    }

    pub fn setBroadcast(this: *This, context: anytype, enabled_value: ?bool) !bool {
        if (this.closed) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.BADF))), .setsockopt).?);
        }

        const enabled = enabled_value orelse
            return context.fail(.missing_argument, {});

        const res = this.socket.?.setBroadcast(enabled);

        if (getUSError(res, .setsockopt, true)) |err| {
            return failSystem(context, err);
        }

        return enabled;
    }

    pub fn setMulticastLoopback(this: *This, context: anytype, enabled_value: ?bool) !bool {
        if (this.closed) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.BADF))), .setsockopt).?);
        }

        const enabled = enabled_value orelse
            return context.fail(.missing_argument, {});

        const res = this.socket.?.setMulticastLoopback(enabled);

        if (getUSError(res, .setsockopt, true)) |err| {
            return failSystem(context, err);
        }

        return enabled;
    }

    fn setMembership(
        this: *This,
        context: anytype,
        address_value: anytype,
        interface_value: anytype,
        drop: bool,
    ) !bool {
        if (this.closed) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.BADF))), .setsockopt).?);
        }

        const address_value_ = address_value orelse
            return context.fail(.missing_argument, {});

        const converted_address = try address_value_.convert(context);
        var addr = std.mem.zeroes(std.posix.sockaddr.storage);
        if (!try this.parseBoundAddr(&converted_address.value, &addr)) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.INVAL))), .setsockopt).?);
        }

        var interface = std.mem.zeroes(std.posix.sockaddr.storage);

        const interface_ptr: ?*std.posix.sockaddr.storage = if (interface_value) |value| blk: {
            const converted_interface = try value.convert(context);
            if (!try this.parseBoundAddr(&converted_interface.value, &interface)) {
                break :blk null;
            }
            if (addr.family != interface.family) {
                return context.fail(.family_mismatch_interface, {});
            }
            break :blk &interface;
        } else null;

        const socket = this.socket orelse return context.fail(.socket_closed, {});
        const res = socket.setMembership(&addr, interface_ptr, drop);

        if (getUSError(res, .setsockopt, true)) |err| {
            return failSystem(context, err);
        }

        return true;
    }

    fn setSourceSpecificMembership(
        this: *This,
        context: anytype,
        source_value: anytype,
        group_value: anytype,
        interface_value: anytype,
        drop: bool,
    ) !bool {
        if (this.closed) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.BADF))), .setsockopt).?);
        }

        const source_value_ = source_value orelse
            return context.fail(.missing_two_arguments, {});
        const group_value_ = group_value orelse
            return context.fail(.missing_second_argument, {});

        const converted_source = try source_value_.convert(context);
        var source_addr: std.posix.sockaddr.storage = undefined;
        if (!try this.parseBoundAddr(&converted_source.value, &source_addr)) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.INVAL))), .setsockopt).?);
        }

        const converted_group = try group_value_.convert(context);
        var group_addr: std.posix.sockaddr.storage = undefined;
        if (!try this.parseBoundAddr(&converted_group.value, &group_addr)) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.INVAL))), .setsockopt).?);
        }

        if (source_addr.family != group_addr.family) {
            return context.fail(.family_mismatch_source_group, {});
        }

        var interface: std.posix.sockaddr.storage = undefined;

        const interface_ptr: ?*std.posix.sockaddr.storage = if (interface_value) |value| blk: {
            const converted_interface = try value.convert(context);
            if (!try this.parseBoundAddr(&converted_interface.value, &interface)) {
                break :blk null;
            }
            if (source_addr.family != interface.family) {
                return context.fail(.family_mismatch_all, {});
            }
            break :blk &interface;
        } else null;

        const socket = this.socket orelse return context.fail(.socket_closed, {});
        const res = socket.setSourceSpecificMembership(&source_addr, &group_addr, interface_ptr, drop);

        if (getUSError(res, .setsockopt, true)) |err| {
            return failSystem(context, err);
        }

        return true;
    }

    pub fn setMulticastInterface(this: *This, context: anytype, interface_value: anytype) !bool {
        if (this.closed) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.BADF))), .setsockopt).?);
        }

        const interface_value_ = interface_value orelse
            return context.fail(.missing_argument, {});

        const converted_interface = try interface_value_.convert(context);
        var addr: std.posix.sockaddr.storage = undefined;
        if (!try this.parseBoundAddr(&converted_interface.value, &addr)) {
            return false;
        }

        const socket = this.socket orelse return context.fail(.socket_closed, {});

        const res = socket.setMulticastInterface(&addr);

        if (getUSError(res, .setsockopt, true)) |err| {
            return failSystem(context, err);
        }

        return true;
    }

    fn wrongArgumentCountMessage(expected: usize, actual: usize) bun.OOM!bun.bindgen.DOMString {
        const message = try std.fmt.allocPrint(
            bun.default_allocator,
            "Expected {d} argument{s}, got {d}",
            .{ expected, if (expected == 1) "" else "s", actual },
        );
        defer bun.default_allocator.free(message);
        return bun.bindgen.DOMString.fromUTF8(message);
    }

    fn getUSError(res: c_int, tag: bun.sys.Tag, comptime use_wsa: bool) ?bun.sys.Maybe(void) {
        if (comptime bun.Environment.isWindows) {
            // setsockopt returns 0 on success, but errnoSys considers 0 to be failure on Windows.
            // This applies to some other usockets functions too.
            if (res >= 0) {
                return null;
            }

            if (comptime use_wsa) {
                const wsa = bun.windows.getLastWinsockErrno();
                if (wsa != .SUCCESS) {
                    bun.c.WSASetLastError(0);
                    return bun.sys.Maybe(void).errno(wsa, tag);
                }
            }

            return bun.sys.Maybe(void).errno(@as(bun.sys.E, @fromBackingInt(@intCast(std.c._errno().*))), tag);
        } else {
            return bun.sys.Maybe(void).errnoSys(res, tag);
        }
    }

    fn failSystem(context: anytype, result: bun.sys.Maybe(void)) bun.bindgen.CallError(@TypeOf(context)) {
        const err = switch (result) {
            .err => |err| err,
            .result => unreachable,
        };
        const system_error = bindgen.SystemError.fromSysError(err) catch |oom| return oom;
        return context.fail(.system, system_error);
    }

    fn setAnyTTL(this: *This, context: anytype, ttl_value: anytype, comptime function: fn (*uws.udp.Socket, i32) c_int) !i32 {
        if (this.closed) {
            return failSystem(context, bun.sys.Maybe(void).errnoSys(@as(i32, @intCast(@backingInt(std.posix.E.BADF))), .setsockopt).?);
        }

        const ttl_value_ = ttl_value orelse
            return context.fail(.missing_argument, {});

        const converted_ttl = try ttl_value_.convert(context);
        const ttl = converted_ttl.value;
        const socket = this.socket orelse return context.fail(.socket_closed, {});
        const res = function(socket, ttl);

        if (getUSError(res, .setsockopt, true)) |err| {
            return failSystem(context, err);
        }

        return ttl;
    }

    pub fn sendMany(this: *This, context: anytype, args: anytype) !i32 {
        if (this.closed) return context.fail(.socket_closed, {});
        const values = args.values orelse return context.fail(.missing_argument, {});
        const payloads = args.payloads.?;
        const connected = this.connect_info != null;
        if (connected) {
            const converted = try payloads.convert(context);
            return this.sendManyBatch(context, true, &converted.value, values);
        }
        const converted = try values.convert(context);
        return this.sendManyBatch(context, false, &converted.value, payloads);
    }

    const PreparedPayload = union(enum) {
        buffer: bindgen.ScopedLease(u8),
        string: bun.String.Slice,

        fn deinit(this: *PreparedPayload) void {
            if (this.* == .string) this.string.deinit();
        }

        fn slice(this: *const PreparedPayload) []const u8 {
            return switch (this.*) {
                .buffer => |*lease| lease.unsafePtr("the binding frame pins every batch payload through the synchronous socket send"),
                .string => |*string| string.slice(),
            };
        }
    };

    fn sendManyBatch(this: *This, context: anytype, comptime connected: bool, batch: anytype, unused: anytype) !i32 {
        const len = if (connected) batch.len() else batch.len() / 3;
        var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const prepared = try alloc.alloc(PreparedPayload, len);
        @memset(prepared, .{ .string = .empty });
        defer for (prepared) |*payload| payload.deinit();
        const payloads = try alloc.alloc([*]const u8, len);
        const lens = try alloc.alloc(usize, len);
        const addr_ptrs = try alloc.alloc(?*const anyopaque, len);
        const addrs: ?[]std.posix.sockaddr.storage = if (connected) null else try alloc.alloc(std.posix.sockaddr.storage, len);

        for (0..len) |index| {
            const payload = if (connected) batch.at(index).? else batch.at(index * 3).?.payload;
            if (connected) {
                addr_ptrs[index] = null;
            } else {
                const port: i32 = switch (batch.at(index * 3 + 1).?.port) {
                    inline else => |value| value,
                };
                const address = try batch.at(index * 3 + 2).?.address.toOwnedSliceZ(alloc);
                if (port < 1 or port > 65535)
                    return failSystem(context, .{ .err = bun.sys.Error.fromCode(.INVAL, .send) });
                if (!this.parseAddrSlice(@intCast(port), address, &addrs.?[index]))
                    return context.fail(.invalid_address, {});
                addr_ptrs[index] = &addrs.?[index];
            }
            prepared[index] = switch (payload) {
                .buffer => |value| .{ .buffer = (try value.convert(context)).value },
                .string => |value| .{ .string = try value.toUTF8(alloc) },
            };
        }
        try context.lease(try unused.discardLast(context));
        for (prepared, 0..) |*payload, index| {
            const bytes = payload.slice();
            const non_null = if (bytes.len == 0) "" else bytes;
            payloads[index] = non_null.ptr;
            lens[index] = non_null.len;
        }
        const socket = this.socket orelse return context.fail(.socket_closed, {});
        const res = socket.send(payloads, lens, addr_ptrs);
        if (getUSError(res, .send, true)) |err| return failSystem(context, err);
        return @intCast(res);
    }

    pub fn send(this: *This, context: anytype, args: anytype) !bool {
        if (this.closed) {
            return context.fail(.socket_closed, {});
        }
        const argument_count: usize = if (args.address != null)
            3
        else if (args.port != null)
            2
        else if (args.payload != null)
            1
        else
            0;
        const has_destination = brk: {
            if (this.connect_info != null) {
                if (argument_count == 1) {
                    break :brk false;
                }
                if (argument_count == 3) {
                    return context.fail(.destination_on_connected_socket, {});
                }
                return context.fail(.wrong_argument_count, try wrongArgumentCountMessage(1, argument_count));
            } else {
                if (argument_count != 3) {
                    return context.fail(.wrong_argument_count, try wrongArgumentCountMessage(3, argument_count));
                }
                break :brk true;
            }
        };

        // Destination coercion can re-enter JavaScript and detach the payload,
        // so acquire the payload lease only after the destination is resolved.
        var addr: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
        const addr_ptr = brk: {
            if (has_destination) {
                const converted_port = try args.port.?.convert(context);
                const converted_address = try args.address.?.convert(context);
                const address_slice = try converted_address.value.toOwnedSliceZ(default_allocator);
                defer default_allocator.free(address_slice);
                const port: i32 = switch (converted_port.value) {
                    inline else => |value| value,
                };
                if (port < 1 or port > 65535)
                    return failSystem(context, .{ .err = bun.sys.Error.fromCode(.INVAL, .send) });
                if (!this.parseAddrSlice(@intCast(port), address_slice, &addr)) {
                    return context.fail(.invalid_address, {});
                }
                break :brk &addr;
            } else {
                break :brk null;
            }
        };

        const forced_payload = try args.payload.?.convertLast(context);
        try context.lease(forced_payload.proof);
        var payload_value = try bun.api.node.StringOrBuffer.fromBindgen(forced_payload.converted.value, .utf8);
        defer payload_value.deinit();
        const converted_slice = payload_value.slice();
        const empty: []const u8 = "";
        const payload = if (converted_slice.len == 0) empty else converted_slice;

        const socket = this.socket orelse return context.fail(.socket_closed, {});
        const res = socket.send(&.{payload.ptr}, &.{payload.len}, &.{addr_ptr});
        if (getUSError(res, .send, true)) |err| {
            return failSystem(context, err);
        }
        return res > 0;
    }

    fn parseBoundAddr(this: *This, address: anytype, storage: *std.posix.sockaddr.storage) bun.OOM!bool {
        const address_slice = try address.toOwnedSliceZ(default_allocator);
        defer default_allocator.free(address_slice);
        return this.parseAddrSlice(0, address_slice, storage);
    }

    fn parseAddrSlice(this: *This, port: u16, address_slice: [:0]u8, storage: *std.posix.sockaddr.storage) bool {
        _ = this;
        if (std.mem.indexOfScalar(u8, address_slice, 0) != null) return false;
        if (std.Io.net.Ip4Address.parse(address_slice, port)) |address| {
            const destination: *std.posix.sockaddr.in = @ptrCast(storage);
            destination.* = .{ .addr = @bitCast(address.bytes), .port = std.mem.nativeToBig(u16, port) };
            return true;
        } else |_| {}

        var scope_id: u32 = 0;
        var ip_text: []const u8 = address_slice;
        if (std.mem.indexOfScalar(u8, address_slice, '%')) |percent| {
            if (percent + 1 == address_slice.len) return false;
            ip_text = address_slice[0..percent];
            const scope = address_slice[percent + 1 .. :0];
            scope_id = std.fmt.parseInt(u32, scope, 10) catch resolve_scope: {
                if (comptime bun.Environment.isWindows) break :resolve_scope 0;
                break :resolve_scope @as(u32, @bitCast(std.c.if_nametoindex(scope)));
            };
        }
        const address = std.Io.net.Ip6Address.parse(ip_text, port) catch return false;
        const destination: *std.posix.sockaddr.in6 = @ptrCast(storage);
        destination.* = .{
            .addr = address.bytes,
            .port = std.mem.nativeToBig(u16, port),
            .flowinfo = 0,
            .scope_id = scope_id,
        };
        return true;
    }

    pub fn closeSocket(this: *This) void {
        if (this.closed) return;
        const socket = this.socket orelse {
            this.closed = true;
            this.invalidateAddressCaches();
            return;
        };
        this.socket = null;
        socket.close();
    }

    fn invalidateAddressCaches(this: *This) void {
        const wrapper = if (this.wrapper) |*value| value else return;
        UDPSocketAddressSlot.clearWrapper(.activity, wrapper);
        UDPSocketRemoteAddressSlot.clearWrapper(.activity, wrapper);
    }

    pub fn reload(this: *This, context: anytype, options: anytype) !void {
        const generated = options orelse {
            return context.fail(.missing_argument, {});
        };

        var config = try UDPSocketConfig.fromGenerated(context, generated);
        errdefer config.deinit();
        var receiver = (try (this.wrapper orelse @panic("live UDPSocket has no wrapper")).toOwned()) orelse
            @panic("live UDPSocket wrapper is unavailable");
        defer receiver.deinit();
        config.installHandlers(&receiver);

        var previous_config = this.config;
        this.config = config;
        previous_config.deinit();
    }

    pub fn getHostname(this: *This) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromBunString(this.config.hostname.dupeRef());
    }

    pub fn getPort(this: *This) ?u16 {
        if (this.closed) return null;
        return std.math.cast(u16, this.socket.?.boundPort());
    }

    fn createSockAddr(address_bytes: []const u8, port: u16) bun.OOM!?UDPSocketAddressDTO {
        var sockaddr = SocketAddress.init(address_bytes, port) catch return null;
        return try sockaddr.intoDTO(UDPSocketAddressDTO);
    }

    pub fn getAddress(this: *This) bun.OOM!bindgen.Return(UDPSocketAddressSchema) {
        if (this.closed) return null;
        var buf: [64]u8 = @splat(0);
        var length: i32 = 64;
        this.socket.?.boundIp(&buf, &length);

        const address_bytes = buf[0..@as(usize, @intCast(length))];
        const port = this.socket.?.boundPort();
        return try createSockAddr(address_bytes, @intCast(port));
    }

    pub fn getRemoteAddress(this: *This) bun.OOM!bindgen.Return(UDPSocketRemoteAddressSchema) {
        if (this.closed) return null;
        const connect_info = this.connect_info orelse return null;
        var buf: [64]u8 = @splat(0);
        var length: i32 = 64;
        this.socket.?.remoteIp(&buf, &length);

        const address_bytes = buf[0..@as(usize, @intCast(length))];
        return try createSockAddr(address_bytes, connect_info.port);
    }

    pub fn getBinaryType(this: *This) UDPSocketBinaryType {
        return this.config.binary_type;
    }

    fn retainSocketActivity(this: *This) void {
        bun.assert(!this.socket_ref_held);
        this.ref();
        this.socket_ref_held = true;
    }

    fn releaseSocketActivity(this: *This) void {
        if (!this.socket_ref_held) return;
        this.socket_ref_held = false;
        this.deref();
    }

    fn deinit(this: *This) void {
        bun.assert(!this.socket_ref_held);
        bun.assert(this.socket == null);
        this.poll_ref.disable();
        this.config.deinit();
        if (this.wrapper) |*wrapper| wrapper.deinit();
        this.ref_count.assertNoRefs();
        bun.destroy(this);
    }

    pub fn jsConnect(
        context: bun.bindgen.CallContext(ConnectSchema),
        args: bun.bindgen.Args(ConnectSchema),
    ) bun.bindgen.CallError(ConnectSchema)!void {
        const this = args.bindingThis.get(UDPSocket.JSBinding).socket.get();

        if (this.connect_info != null) {
            return context.fail(.already_connected, {});
        }

        if (this.closed) {
            return context.fail(.socket_closed, {});
        }

        const hostname_value = args.hostname orelse return context.fail(.missing_arguments, {});
        const port_value = args.port orelse return context.fail(.missing_arguments, {});

        const hostname = try hostname_value.convert(context);
        const connect_host = try hostname.value.toOwnedSliceZ(default_allocator);
        defer default_allocator.free(connect_host);

        const converted_port = try port_value.convert(context);
        const port = converted_port.value;

        if (this.connect_info != null) {
            return context.fail(.already_connected, {});
        }
        const socket = this.socket orelse return context.fail(.socket_closed, {});
        if (socket.connect(connect_host, port) == -1) {
            return context.fail(.connect_failed, {});
        }
        this.connect_info = .{
            .port = port,
        };

        UDPSocketAddressSlot.clearView(args.bindingThis);
        UDPSocketRemoteAddressSlot.clearView(args.bindingThis);

        return;
    }

    pub fn jsDisconnect(
        context: bun.bindgen.CallContext(DisconnectSchema),
        args: bun.bindgen.Args(DisconnectSchema),
    ) bun.bindgen.CallError(DisconnectSchema)!void {
        const this = args.bindingThis.get(UDPSocket.JSBinding).socket.get();

        if (this.connect_info == null) {
            return context.fail(.not_connected, {});
        }

        if (this.closed) {
            return context.fail(.socket_closed, {});
        }

        if (this.socket.?.disconnect() == -1) {
            return context.fail(.disconnect_failed, {});
        }
        this.connect_info = null;

        UDPSocketAddressSlot.clearView(args.bindingThis);
        UDPSocketRemoteAddressSlot.clearView(args.bindingThis);

        return;
    }
};

const std = @import("std");
const uws = @import("../../uws/uws.zig");

const bun = @import("bun");
const Async = bun.Async;
const bindgen = bun.bindgen;
const Output = bun.Output;
const default_allocator = bun.default_allocator;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const SocketAddress = jsc.API.SocketAddress;
const UDPSocketEngine = @import("./UDPSocketEngine.zig");

const UDPSocketBindingModule = bindgen.Module("UDPSocket");
pub const UDPSocketClassSchema = UDPSocketBindingModule.class("UDPSocket");
const UDPSocketClass = bindgen.Class(UDPSocketClassSchema, UDPSocket.JSBinding);
const UDPSocketDisposeSchema = UDPSocketClassSchema.member("dispose");
const UDPSocketAddMembershipSchema = UDPSocketClassSchema.member("addMembership");
const UDPSocketAddressSchema = UDPSocketClassSchema.memberKind("address", .getter);
const UDPSocketAddressDTO = @typeInfo(bindgen.Return(UDPSocketAddressSchema)).optional.child;
const UDPSocketAddSourceSpecificMembershipSchema = UDPSocketClassSchema.member("addSourceSpecificMembership");
const UDPSocketBinaryTypeSchema = UDPSocketClassSchema.memberKind("binaryType", .getter);
const UDPSocketBinaryType = bindgen.Return(UDPSocketBinaryTypeSchema);
const UDPSocketCloseSchema = UDPSocketClassSchema.member("close");
const UDPSocketClosedSchema = UDPSocketClassSchema.memberKind("closed", .getter);
const UDPSocketDropMembershipSchema = UDPSocketClassSchema.member("dropMembership");
const UDPSocketDropSourceSpecificMembershipSchema = UDPSocketClassSchema.member("dropSourceSpecificMembership");
const UDPSocketHostnameSchema = UDPSocketClassSchema.memberKind("hostname", .getter);
const UDPSocketPortSchema = UDPSocketClassSchema.memberKind("port", .getter);
const UDPSocketRefSchema = UDPSocketClassSchema.member("ref");
const UDPSocketReloadSchema = UDPSocketClassSchema.member("reload");
const UDPSocketRemoteAddressSchema = UDPSocketClassSchema.memberKind("remoteAddress", .getter);
const UDPSocketSendSchema = UDPSocketClassSchema.member("send");
const UDPSocketSendManySchema = UDPSocketClassSchema.member("sendMany");
const UDPSocketSetBroadcastSchema = UDPSocketClassSchema.member("setBroadcast");
const UDPSocketSetMulticastInterfaceSchema = UDPSocketClassSchema.member("setMulticastInterface");
const UDPSocketSetMulticastLoopbackSchema = UDPSocketClassSchema.member("setMulticastLoopback");
const UDPSocketSetMulticastTTLSchema = UDPSocketClassSchema.member("setMulticastTTL");
const UDPSocketSetTTLSchema = UDPSocketClassSchema.member("setTTL");
const UDPSocketUnrefSchema = UDPSocketClassSchema.member("unref");
const UDPSocketOnDataSlot = UDPSocketClass.CachedSlot("on_data");
const UDPSocketOnDrainSlot = UDPSocketClass.CachedSlot("on_drain");
pub const UDPSocketOnErrorSlot = UDPSocketClass.CachedSlot("on_error");
const UDPSocketAddressSlot = UDPSocketClass.CachedSlotInvalidator("address");
const UDPSocketRemoteAddressSlot = UDPSocketClass.CachedSlotInvalidator("remoteAddress");

const NodeDgramBindings = bun.bindgen.Module("NodeDgram");
const ConnectSchema = NodeDgramBindings.function("connect");
const DisconnectSchema = NodeDgramBindings.function("disconnect");
const ConnectBinding = bun.bindgen.Fn(ConnectSchema, UDPSocket.jsConnect);
const DisconnectBinding = bun.bindgen.Fn(DisconnectSchema, UDPSocket.jsDisconnect);

comptime {
    _ = UDPSocketClass;
    _ = ConnectBinding;
    _ = DisconnectBinding;
}
