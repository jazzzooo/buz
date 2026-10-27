pub const SubscriptionCtx = struct {
    const Self = @This();

    is_subscriber: bool,
    original_enable_offline_queue: bool,
    original_enable_auto_pipelining: bool,
    callbacks: bindgen.StringCallbackRegistry(RedisSubscriptionListenerType) = .{},

    pub fn init(valkey_parent: *JSValkeyClient) Self {
        return .{
            .original_enable_offline_queue = valkey_parent.client.flags.enable_offline_queue,
            .original_enable_auto_pipelining = valkey_parent.client.flags.enable_auto_pipelining,
            .is_subscriber = false,
        };
    }

    pub fn deinit(this: *Self) void {
        this.callbacks.deinit();
    }

    fn parent(this: *Self) *JSValkeyClient {
        return @alignCast(@fieldParentPtr("_subscription_ctx", this));
    }

    pub fn channelsSubscribedToCount(this: *const Self) u32 {
        return @intCast(this.callbacks.count());
    }

    pub fn hasSubscriptions(this: *const Self) bool {
        return this.channelsSubscribedToCount() > 0;
    }

    pub fn invokeCallbacks(
        this: *Self,
        channel_name: []const u8,
        args: bindgen.Args(RedisSubscriptionListenerType),
    ) bun.OOM!void {
        defer this.parent().updatePollRef();
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.parent().globalObject);
        defer scope.deinit();
        _ = try this.callbacks.dispatch(&scope, channel_name, args);
    }
};

/// Valkey client wrapper for JavaScript
pub const JSValkeyClient = struct {
    pub const Ref = bindgen.ClassRef(RedisClientClassSchema);
    pub const Core = valkey.ValkeyClient(Integration);

    const Integration = struct {
        pub const Error = bun.JSError;

        fn parent(client: *Core) *JSValkeyClient {
            return @fieldParentPtr("client", client);
        }

        fn constParent(client: *const Core) *const JSValkeyClient {
            return @fieldParentPtr("client", client);
        }

        pub fn registerAutoFlusher(client: *Core, state: *AutoFlusher) void {
            AutoFlusherEngine.register(Core, client, state, parent(client).virtualMachine());
        }

        pub fn unregisterAutoFlusher(client: *Core, state: *AutoFlusher) void {
            AutoFlusherEngine.unregister(Core, client, state, parent(client).virtualMachine());
        }

        pub fn ref(client: *Core) void {
            parent(client).ref();
        }

        pub fn deref(client: *Core) void {
            parent(client).deref();
        }

        pub fn subscriptionCount(client: *Core) u32 {
            return parent(client)._subscription_ctx.channelsSubscribedToCount();
        }

        pub fn addSubscription(client: *Core) void {
            parent(client).addSubscription();
        }

        pub fn removeSubscription(client: *Core) void {
            parent(client).removeSubscription();
        }

        pub fn isSubscriber(client: *const Core) bool {
            return constParent(client).isSubscriber();
        }

        pub fn onValkeyConnect(client: *Core, value: *protocol.RESPValue) void {
            parent(client).onValkeyConnect(value);
        }

        pub fn onValkeySubscribe(client: *Core, value: *protocol.RESPValue) void {
            parent(client).onValkeySubscribe(value);
        }

        pub fn onValkeyUnsubscribe(client: *Core) void {
            parent(client).onValkeyUnsubscribe();
        }

        pub fn onValkeyMessage(client: *Core, value: []protocol.RESPValue) void {
            parent(client).onValkeyMessage(value);
        }

        pub fn onValkeyReconnect(client: *Core) void {
            parent(client).onValkeyReconnect();
        }

        pub fn onValkeyClose(client: *Core) Error!void {
            return parent(client).onValkeyClose();
        }
    };

    pub fn default(context: anytype) bindgen.CallError(@TypeOf(context))!Ref {
        const client = try JSValkeyClient.createDefaultNoJsNoPubsub(context.viewToken().globalObject(), context);
        return client.toResultRef(context);
    }

    client: Core,
    globalObject: *jsc.JSGlobalObject,
    wrapper: ?RedisClientClass.ActivityWrapper = null,
    connect_completions: std.ArrayList(bindgen.OwnedCompletion(RedisClientConnectSchema)) = .empty,
    duplicate_operation: ?*DuplicateOperation = null,
    poll_ref: bun.Async.KeepAlive = .{},
    close_task: jsc.AnyTaskWithExtraContext = .{},
    close_task_pending: bool = false,

    _subscription_ctx: SubscriptionCtx,
    /// `us_ssl_ctx_t` for `tls: { …custom CA… }`. `tls: true` borrows
    /// `RareData.defaultClientSslCtx()` instead; `tls: false` leaves this null.
    _secure: ?*uws.SslCtx = null,

    timer: Timer.EventLoopTimer = .{
        .tag = .ValkeyConnectionTimeout,
        .next = .epoch,
    },
    reconnect_timer: Timer.EventLoopTimer = .{
        .tag = .ValkeyConnectionReconnect,
        .next = .epoch,
    },
    ref_count: RefCount,

    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;
    pub const new = bun.TrivialNew(@This());

    fn virtualMachine(this: *const JSValkeyClient) *jsc.VirtualMachine {
        return this.globalObject.bunVM();
    }

    fn defaultOptions() valkey.Options {
        return .{
            .enable_auto_pipelining = !bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_REDIS_AUTO_PIPELINING.get(),
        };
    }

    fn optionsFromBinding(context: anytype, argument: anytype) bindgen.CallError(@TypeOf(context))!valkey.Options {
        var result = defaultOptions();
        const options_argument = argument orelse return result;
        const converted_options = try options_argument.convert(context);
        switch (converted_options.value) {
            .ignored => {},
            .options => |*generated| {
                if (generated.idle_timeout) |value| result.idle_timeout_ms = value;
                if (generated.connection_timeout) |value| result.connection_timeout_ms = value;
                if (generated.auto_reconnect) |value| result.enable_auto_reconnect = value;
                if (generated.max_retries) |value| result.max_retries = value;
                if (generated.enable_offline_queue) |value| result.enable_offline_queue = value;
                if (generated.enable_auto_pipelining) |value| result.enable_auto_pipelining = value;
                if (generated.tls) |*tls| switch (tls.*) {
                    .enabled => |enabled| result.tls = if (enabled) .enabled else .none,
                    .config => |*config| {
                        if (try jsc.API.ServerConfig.SSLConfigEngine.parse(context, config)) |ssl_config| {
                            result.tls = .{ .custom = ssl_config };
                        } else {
                            return context.fail(.tls_options_required, {});
                        }
                    },
                };
            },
        }
        return result;
    }

    fn defaultURL(globalObject: *jsc.JSGlobalObject) bun.OOM!bun.String {
        const env = globalObject.bunVM().transpiler.env;
        if (env.get("REDIS_URL") orelse env.get("VALKEY_URL")) |url| {
            var owned = try bindgen.ThreadSafeDOMString.fromUTF8(url);
            return owned.takeBunString();
        }
        return bun.String.static("valkey://localhost:6379");
    }

    pub fn createNoJsNoPubsub(
        globalObject: *jsc.JSGlobalObject,
        context: anytype,
        arguments: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!*JSValkeyClient {
        const url = if (arguments.url) |value| provided: {
            var owned = value.toOwned();
            break :provided owned.takeBunString();
        } else try defaultURL(globalObject);
        defer url.deref();
        var config = try ConnectionConfig.parse(context, url);
        errdefer config.deinit();
        var options = try optionsFromBinding(context, arguments.options);
        errdefer options.tls.deinit();
        const result = try createConfigured(globalObject, config, options);
        bun.analytics.Features.valkey += 1;
        return result;
    }

    fn createDefaultNoJsNoPubsub(globalObject: *jsc.JSGlobalObject, context: anytype) bindgen.CallError(@TypeOf(context))!*JSValkeyClient {
        const url = try defaultURL(globalObject);
        defer url.deref();
        var config = try ConnectionConfig.parse(context, url);
        errdefer config.deinit();
        const result = try createConfigured(globalObject, config, defaultOptions());
        bun.analytics.Features.valkey += 1;
        return result;
    }

    fn createConfigured(
        globalObject: *jsc.JSGlobalObject,
        config: ConnectionConfig,
        options: valkey.Options,
    ) bun.OOM!*JSValkeyClient {
        const this_allocator = bun.default_allocator;
        const result = try this_allocator.create(JSValkeyClient);
        result.* = .{
            .ref_count = .init(),
            ._subscription_ctx = undefined,
            .client = .{
                .address = config.address,
                .protocol = config.protocol,
                .username = config.username,
                .password = config.password,
                .in_flight = .init(this_allocator),
                .queue = .init(this_allocator),
                .status = .disconnected,
                .connection_strings = config.connection_strings,
                .socket = .{
                    .SocketTCP = .{
                        .socket = .{
                            .detached = {},
                        },
                    },
                },
                .tls = if (options.tls != .none) options.tls else if (config.protocol.isTLS()) .enabled else .none,
                .database = config.database,
                .allocator = this_allocator,
                .flags = .{
                    .enable_auto_reconnect = options.enable_auto_reconnect,
                    .enable_offline_queue = options.enable_offline_queue,
                    .enable_auto_pipelining = options.enable_auto_pipelining,
                },
                .max_retries = options.max_retries,
                .connection_timeout_ms = options.connection_timeout_ms,
                .idle_timeout_interval_ms = options.idle_timeout_ms,
            },
            .globalObject = globalObject,
        };
        result._subscription_ctx = SubscriptionCtx.init(result);
        return result;
    }

    pub fn cloneWithoutConnecting(
        this: *const JSValkeyClient,
        globalObject: *jsc.JSGlobalObject,
    ) bun.OOM!*JSValkeyClient {
        const connection_strings_copy = try this.client.allocator.dupe(u8, this.client.connection_strings);
        errdefer this.client.allocator.free(connection_strings_copy);
        const base_ptr = this.client.connection_strings.ptr;
        const new_base = connection_strings_copy.ptr;
        const username = bun.memory.rebaseSlice(this.client.username, base_ptr, new_base);
        const password = bun.memory.rebaseSlice(this.client.password, base_ptr, new_base);
        const hostname = bun.memory.rebaseSlice(this.client.address.hostname(), base_ptr, new_base);
        var tls = try this.client.tls.clone();
        errdefer tls.deinit();
        const result = try createConfigured(globalObject, .{
            .address = switch (this.client.address) {
                .unix => .{ .unix = hostname },
                .host => |host| .{ .host = .{ .host = hostname, .port = host.port } },
            },
            .protocol = this.client.protocol,
            .username = username,
            .password = password,
            .connection_strings = connection_strings_copy,
            .database = this.client.database,
        }, .{
            .tls = tls,
            .enable_offline_queue = if (this._subscription_ctx.is_subscriber)
                this._subscription_ctx.original_enable_offline_queue
            else
                this.client.flags.enable_offline_queue,
            .enable_auto_reconnect = this.client.flags.enable_auto_reconnect,
            .enable_auto_pipelining = if (this._subscription_ctx.is_subscriber)
                this._subscription_ctx.original_enable_auto_pipelining
            else
                this.client.flags.enable_auto_pipelining,
            .max_retries = this.client.max_retries,
            .connection_timeout_ms = this.client.connection_timeout_ms,
            .idle_timeout_ms = this.client.idle_timeout_interval_ms,
        });
        result.client.flags.is_manually_closed = this.client.flags.is_manually_closed;
        result.client.flags.finalized = this.client.flags.finalized;
        return result;
    }

    fn attachWrapper(
        this: *JSValkeyClient,
        wrapper_view: bindgen.ClassRefView(RedisClientClassSchema),
    ) bun.JSError!void {
        if (this.wrapper) |*wrapper| {
            const matches = try wrapper.matchesView(wrapper_view);
            bun.assert(matches);
            return;
        }

        this.wrapper = try RedisClientClass.ActivityWrapper.initView(wrapper_view);
    }

    fn wrapperRef(this: *const JSValkeyClient) bun.JSError!?bindgen.ClassRef(RedisClientClassSchema) {
        if (this.wrapper) |*wrapper| return wrapper.toOwned();
        return null;
    }

    pub fn toResultRef(this: *JSValkeyClient, context: anytype) bun.JSError!Ref {
        const binding = try RedisClientBinding.create(this);
        var reference = try RedisClientClass.adoptResult(binding, context);
        errdefer reference.deinit();
        this.wrapper = try RedisClientClass.ActivityWrapper.initRef(&reference);
        return reference;
    }

    fn hasPendingActivity(this: *const JSValkeyClient) bool {
        return this.client.status == .connecting or
            this.client.status == .connected or
            this.client.hasAnyPendingCommands() or
            this._subscription_ctx.callbacks.count() > 0 or
            this.client.flags.is_reconnecting;
    }

    pub fn addSubscription(this: *JSValkeyClient) void {
        debug("addSubscription: entering, current subscriber state: {}", .{this._subscription_ctx.is_subscriber});
        bun.debugAssert(this.client.status == .connected);
        this.ref();
        defer this.deref();

        if (!this._subscription_ctx.is_subscriber) {
            this._subscription_ctx.original_enable_offline_queue = this.client.flags.enable_offline_queue;
            this._subscription_ctx.original_enable_auto_pipelining = this.client.flags.enable_auto_pipelining;
            debug("addSubscription: calling updatePollRef", .{});
            this.updatePollRef();
        }

        this._subscription_ctx.is_subscriber = true;
        debug("addSubscription: exiting, new subscriber state: {}", .{this._subscription_ctx.is_subscriber});
    }

    pub fn removeSubscription(this: *JSValkeyClient) void {
        debug("removeSubscription: entering, has subscriptions: {}", .{this._subscription_ctx.hasSubscriptions()});
        this.ref();
        defer this.deref();

        // This is the last subscription, restore original flags
        if (!this._subscription_ctx.hasSubscriptions()) {
            this.client.flags.enable_offline_queue = this._subscription_ctx.original_enable_offline_queue;
            this.client.flags.enable_auto_pipelining = this._subscription_ctx.original_enable_auto_pipelining;
            this._subscription_ctx.is_subscriber = false;
            debug("removeSubscription: calling updatePollRef", .{});
            this.updatePollRef();
        }
        debug("removeSubscription: exiting", .{});
    }

    pub fn isSubscriber(this: *const JSValkeyClient) bool {
        return this._subscription_ctx.is_subscriber;
    }

    pub fn getConnected(this: *JSValkeyClient) bool {
        return this.client.status == .connected;
    }

    pub fn getBufferedAmount(this: *JSValkeyClient) u64 {
        const len =
            this.client.write_buffer.len() +
            this.client.read_buffer.len();
        return @intCast(len);
    }

    fn beginConnection(this: *JSValkeyClient) !void {
        this.ref();
        defer this.deref();

        this.client.flags.is_manually_closed = false;
        this.client.flags.failed = false;
        defer this.updatePollRef();

        if (this.client.flags.needs_to_open_socket) {
            this.poll_ref.ref(this.virtualMachine());

            this.connect() catch |err| {
                this.poll_ref.unref(this.virtualMachine());
                this.client.flags.needs_to_open_socket = true;
                return err;
            };

            this.resetConnectionTimeout();
            return;
        }

        switch (this.client.status) {
            .disconnected => {
                this.client.flags.is_reconnecting = true;
                this.client.retry_attempts = 0;
                this.reconnect();
            },
            else => {},
        }
    }

    fn failConnectionCompletions(this: *JSValkeyClient, allocation_failed: bool) void {
        for (this.connect_completions.items) |*completion| {
            if (allocation_failed) completion.outOfMemory() else completion.fail(.connection_closed, {});
        }
        this.connect_completions.clearRetainingCapacity();
        if (this.duplicate_operation) |operation| {
            this.duplicate_operation = null;
            if (allocation_failed) operation.completion.outOfMemory() else operation.completion.fail(.connection_closed, {});
            bun.destroy(operation);
        }
    }

    fn cancelDuplicateOperation(this: *JSValkeyClient) void {
        const operation = this.duplicate_operation orelse return;
        this.duplicate_operation = null;
        operation.completion.release();
        bun.destroy(operation);
    }

    fn resolveConnectionCompletions(this: *JSValkeyClient) void {
        for (this.connect_completions.items) |*completion| completion.resolve({});
        this.connect_completions.clearRetainingCapacity();
        if (this.duplicate_operation) |operation| {
            this.duplicate_operation = null;
            operation.completion.complete(operation);
        }
    }

    fn connectWithCompletion(
        this: *JSValkeyClient,
        completion: *bindgen.CompletionView(RedisClientConnectSchema),
    ) bun.OOM!void {
        if (this.client.status == .connected) {
            completion.resolve({});
            return;
        }

        try this.connect_completions.ensureUnusedCapacity(bun.default_allocator, 1);
        this.connect_completions.appendAssumeCapacity(completion.take());
        this.preconnect();
    }

    pub fn preconnect(this: *JSValkeyClient) void {
        if (this.connect_completions.items.len > 1 or this.client.status == .connecting or this.client.status == .connected) return;
        this.beginConnection() catch |err| this.failConnectionCompletions(err == error.OutOfMemory);
    }

    fn duplicateWithCompletion(
        this: *JSValkeyClient,
        globalObject: *jsc.JSGlobalObject,
        completion: *bindgen.CompletionView(RedisClientDuplicateSchema),
    ) bun.OOM!void {
        const operation = bun.default_allocator.create(DuplicateOperation) catch return error.OutOfMemory;
        errdefer bun.default_allocator.destroy(operation);

        const new_client = try this.cloneWithoutConnecting(globalObject);
        const owned_completion = try DuplicateCompletion.take(completion, .{ .client = new_client });
        operation.* = .{ .completion = owned_completion };
        new_client.duplicate_operation = operation;

        if (this.client.status != .connected or this.client.flags.is_manually_closed) {
            new_client.resolveConnectionCompletions();
            return;
        }

        new_client.beginConnection() catch |err| new_client.failConnectionCompletions(err == error.OutOfMemory);
    }

    fn disconnect(this: *JSValkeyClient) void {
        if (this.client.status == .disconnected) {
            return;
        }
        this.client.disconnect();
    }

    /// Safely add a timer with proper reference counting and event loop keepalive
    fn addTimer(this: *JSValkeyClient, timer: *Timer.EventLoopTimer, next_timeout_ms: u32) void {
        this.ref();
        defer this.deref();

        // If the timer is already active, we need to remove it first
        if (timer.state == .ACTIVE) {
            this.removeTimer(timer);
        }

        // Skip if timeout is zero
        if (next_timeout_ms == 0) {
            return;
        }

        // Store VM reference to use later
        const vm = this.virtualMachine();

        // Set up timer and add to event loop
        timer.next = bun.timespec.msFromNow(.allow_mocked_time, @intCast(next_timeout_ms));
        vm.timer.insert(timer);
        this.ref();
    }

    /// Safely remove a timer with proper reference counting and event loop keepalive
    fn removeTimer(this: *JSValkeyClient, timer: *Timer.EventLoopTimer) void {
        if (timer.state == .ACTIVE) {
            // Store VM reference to use later
            const vm = this.virtualMachine();

            // Remove the timer from the event loop
            vm.timer.remove(timer);

            // this.addTimer() adds a reference to 'this' when the timer is
            // alive which is balanced here.
            this.deref();
        }
    }

    fn resetConnectionTimeout(this: *JSValkeyClient) void {
        const interval = this.client.getTimeoutInterval();

        // First remove existing timer if active
        if (this.timer.state == .ACTIVE) {
            this.removeTimer(&this.timer);
        }

        // Add new timer if interval is non-zero
        if (interval > 0) {
            this.addTimer(&this.timer, interval);
        }
    }

    pub fn disableConnectionTimeout(this: *JSValkeyClient) void {
        if (this.timer.state == .ACTIVE) {
            this.removeTimer(&this.timer);
        }
        this.timer.state = .CANCELLED;
    }

    pub fn onConnectionTimeout(this: *JSValkeyClient) void {
        debug("onConnectionTimeout", .{});

        // Mark timer as fired
        this.timer.state = .FIRED;

        defer this.deref();
        if (this.client.flags.failed) {
            return;
        }

        if (this.client.getTimeoutInterval() == 0) {
            this.resetConnectionTimeout();
            return;
        }

        var buf: [128]u8 = undefined;
        switch (this.client.status) {
            .connected => {
                const msg = std.mem.printSentinel(&buf, "Idle timeout reached after {d}ms", .{this.client.idle_timeout_interval_ms}, 0) catch unreachable;
                this.clientFail(msg, protocol.RedisError.IdleTimeout);
            },
            .disconnected, .connecting => {
                const msg = std.mem.printSentinel(&buf, "Connection timeout reached after {d}ms", .{this.client.connection_timeout_ms}, 0) catch unreachable;
                this.clientFail(msg, protocol.RedisError.ConnectionTimeout);
            },
        }
    }

    pub fn onReconnectTimer(this: *JSValkeyClient) void {
        debug("Reconnect timer fired, attempting to reconnect", .{});

        // Mark timer as fired and store important values before doing any derefs
        this.reconnect_timer.state = .FIRED;

        defer this.deref();

        // Execute reconnection logic
        this.reconnect();
    }

    pub fn reconnect(this: *JSValkeyClient) void {
        if (!this.client.flags.is_reconnecting) {
            return;
        }

        const vm = this.virtualMachine();

        if (vm.isShuttingDown()) {
            @branchHint(.unlikely);
            return;
        }

        // Ref to keep this alive during the reconnection
        this.ref();
        defer this.deref();

        // Ref the poll to keep event loop alive during connection
        this.poll_ref.disable();
        this.poll_ref = .{};
        this.poll_ref.ref(vm);

        this.connect() catch |err| {
            this.poll_ref.disable();
            this.failConnectionCompletions(err == error.OutOfMemory);
            this.clientFail("Failed to reconnect", if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectionClosed);
            if (err == error.OutOfMemory) {
                this.globalObject.reportActiveExceptionAsUnhandled(error.OutOfMemory);
                return;
            }
            const message = std.fmt.allocPrint(
                bun.default_allocator,
                "{s} reconnecting",
                .{@errorName(err)},
            ) catch {
                this.globalObject.reportActiveExceptionAsUnhandled(error.OutOfMemory);
                return;
            };
            defer bun.default_allocator.free(message);
            var error_root = this.createErrorRoot(.socket_closed_before_connection, message) catch |engine_err| {
                this.globalObject.reportActiveExceptionAsUnhandled(engine_err);
                return;
            };
            defer error_root.deinit();
            this.notifyCloseWithRoot(&error_root);
            return;
        };

        // Reset the socket timeout
        this.resetConnectionTimeout();
    }

    // Callback for when Valkey client connects
    pub fn onValkeyConnect(this: *JSValkeyClient, value: *protocol.RESPValue) void {
        _ = value;
        bun.debugAssert(this.client.status == .connected);
        defer {
            this.client.onWritable();
            this.updatePollRef();
        }
        const globalObject = this.globalObject;
        const event_loop = this.virtualMachine().eventLoop();
        event_loop.enter();
        defer event_loop.exit();

        defer this.resolveConnectionCompletions();
        var receiver = this.wrapperRef() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err);
        defer if (receiver) |*reference| reference.deinit();
        if (receiver) |*reference| {
            if (RedisClientOnConnectSlot.ownedCallback(reference) catch |err|
                return globalObject.reportActiveExceptionAsUnhandled(err)) |callback|
            {
                const Holder = struct {
                    task: jsc.NativeMicrotask = undefined,
                    callback: bindgen.Callback(RedisConnectListenerType),
                    receiver: bindgen.ClassRef(RedisClientClassSchema),

                    pub fn run(holder: *@This()) bun.JSError!void {
                        var invocation: @TypeOf(holder.callback).Invocation = undefined;
                        holder.callback.beginInvocation(&invocation);
                        defer invocation.deinit();
                        try invocation.call(.{ .bindingThis = holder.receiver.operand(&invocation) });
                    }

                    pub fn deinit(holder: *@This()) void {
                        holder.callback.deinit();
                        holder.receiver.deinit();
                    }
                };
                const holder = jsc.NativeMicrotask.create(Holder, .{
                    .callback = callback,
                    .receiver = reference.clone(),
                }) catch |err| {
                    globalObject.reportActiveExceptionAsUnhandled(err);
                    return;
                };
                globalObject.queueMicrotaskTask(&holder.task) catch |err|
                    globalObject.reportActiveExceptionAsUnhandled(err);
            }
        }
    }

    pub fn onValkeySubscribe(this: *JSValkeyClient, value: *protocol.RESPValue) void {
        bun.debugAssert(this.isSubscriber());
        bun.debugAssert(this.wrapper != null);

        this.ref();
        defer this.deref();

        _ = value;

        this.client.onWritable();
        this.updatePollRef();
    }

    pub fn onValkeyUnsubscribe(this: *JSValkeyClient) void {
        bun.debugAssert(this.isSubscriber());
        bun.debugAssert(this.wrapper != null);

        this.client.onWritable();
        this.updatePollRef();
    }

    pub fn onValkeyMessage(this: *JSValkeyClient, value: []protocol.RESPValue) void {
        if (!this.isSubscriber()) {
            debug("onMessage called but client is not in subscriber mode", .{});
            return;
        }

        const event_loop = this.virtualMachine().eventLoop();
        event_loop.enter();
        defer event_loop.exit();

        if (value.len < 2) {
            debug("Message array has insufficient elements: {}", .{value.len});
            return;
        }

        const channel_bytes = subscriptionStringBytes(&value[0]) orelse {
            debug("Subscription channel was not a string", .{});
            return;
        };
        const message_bytes = subscriptionStringBytes(&value[1]) orelse {
            debug("Subscription message was not a string", .{});
            return;
        };
        var channel = bindgen.DOMString.fromUTF8(channel_bytes) catch return;
        defer channel.deinit();
        var message = bindgen.DOMString.fromUTF8(message_bytes) catch return;
        defer message.deinit();

        this._subscription_ctx.invokeCallbacks(
            channel_bytes,
            .{ .message = message.operand(), .channel = channel.operand() },
        ) catch return;

        this.client.onWritable();
        this.updatePollRef();
    }

    fn subscriptionStringBytes(value: *const protocol.RESPValue) ?[]const u8 {
        return switch (value.*) {
            .SimpleString, .Error, .BlobError, .BigNumber => |bytes| bytes,
            .BulkString => |bytes| bytes,
            .VerbatimString => |verbatim| verbatim.content,
            else => null,
        };
    }

    // Callback for when Valkey client needs to reconnect
    pub fn onValkeyReconnect(this: *JSValkeyClient) void {
        // Schedule reconnection using our safe timer methods
        if (this.reconnect_timer.state == .ACTIVE) {
            this.removeTimer(&this.reconnect_timer);
        }

        const delay_ms = this.client.getReconnectDelay();
        if (delay_ms > 0) {
            this.addTimer(&this.reconnect_timer, delay_ms);
        }
    }

    // Callback for when Valkey client closes
    pub fn onValkeyClose(this: *JSValkeyClient) bun.JSError!void {
        this.failConnectionCompletions(false);
        if (this.client.flags.finalized) return;
        var error_root = try this.createErrorRoot(.connection_closed, "Connection closed");
        defer error_root.deinit();
        this.notifyCloseWithRoot(&error_root);
    }

    fn createErrorRoot(
        this: *JSValkeyClient,
        kind: ValkeyCompletion.Failure,
        message: []const u8,
    ) bun.JSError!RedisErrorValue {
        var scope: bindgen.FocusedEngineScope = undefined;
        scope.init(this.globalObject);
        defer scope.deinit();
        const result = try scope.engine(ValkeyCompletion.CreateErrorSchema).call(.{
            .kind = kind,
            .message = bindgen.BytesOperand.fromSlice(message),
        });
        return result.toOwned();
    }

    fn notifyCloseWithRoot(this: *JSValkeyClient, error_root: *const RedisErrorValue) void {
        const globalObject = this.globalObject;
        const loop = this.virtualMachine().eventLoop();
        loop.enter();
        defer loop.exit();

        var receiver = (this.wrapperRef() catch |err| return globalObject.reportActiveExceptionAsUnhandled(err)) orelse return;
        defer receiver.deinit();
        if (RedisClientOnCloseSlot.ownedCallback(&receiver) catch |err|
            return globalObject.reportActiveExceptionAsUnhandled(err)) |callback_|
        {
            var callback = callback_;
            defer callback.deinit();
            var invocation: bindgen.Callback(RedisCloseListenerType).Invocation = undefined;
            callback.beginInvocation(&invocation);
            defer invocation.deinit();
            invocation.call(
                .{ .bindingThis = receiver.operand(&invocation), .@"error" = error_root.operand(&invocation) },
            ) catch |err| globalObject.reportActiveExceptionAsUnhandled(err);
        }
    }

    pub fn clientFail(this: *JSValkeyClient, message: []const u8, err: protocol.RedisError) void {
        this.client.fail(message, err);
    }

    fn closeSocketNextTick(this: *JSValkeyClient) void {
        if (this.client.socket.isClosed() or this.close_task_pending) return;

        this.ref();
        this.close_task_pending = true;
        const Adapter = struct {
            fn run(client: *JSValkeyClient, _: *void) void {
                client.finishScheduledClose();
            }

            fn cancel(context: jsc.AnyTaskWithExtraContext.Context) void {
                const client = context.get(*JSValkeyClient);
                client.finishScheduledClose();
            }
        };
        this.close_task = jsc.AnyTaskWithExtraContext.New(JSValkeyClient, void, Adapter.run).init(this);
        this.close_task.on_cancel = Adapter.cancel;
        const vm = this.virtualMachine();
        if (vm.has_terminated) {
            this.finishScheduledClose();
            return;
        }
        vm.eventLoop().enqueueNativeTask(&this.close_task);
    }

    fn finishScheduledClose(this: *JSValkeyClient) void {
        this.close_task_pending = false;
        defer this.deref();
        this.client.close();
    }

    fn wrapperFinalized(this: *JSValkeyClient) void {
        this.stopTimers();
        if (this.wrapper) |*wrapper| wrapper.deinit();
        this.wrapper = null;
        this.client.flags.finalized = true;
        this.client.flags.is_manually_closed = true;
        this.closeSocketNextTick();
    }

    pub fn stopTimers(this: *JSValkeyClient) void {
        // Use safe timer removal methods to ensure proper reference counting
        if (this.timer.state == .ACTIVE) {
            this.removeTimer(&this.timer);
        }
        if (this.reconnect_timer.state == .ACTIVE) {
            this.removeTimer(&this.reconnect_timer);
        }
    }

    fn connect(this: *JSValkeyClient) !void {
        this.client.flags.needs_to_open_socket = false;
        errdefer this.client.flags.needs_to_open_socket = true;
        const vm = this.virtualMachine();

        this.ref();
        defer this.deref();
        if (this.reconnect_timer.state == .ACTIVE) this.removeTimer(&this.reconnect_timer);

        const is_tls = this.client.tls != .none;
        const group = if (is_tls) vm.rareData().valkeyGroup(vm, true) else vm.rareData().valkeyGroup(vm, false);
        const ssl_ctx: ?*uws.SslCtx = switch (this.client.tls) {
            .none => null,
            .enabled => brk: {
                var failure: uws.TLSContextFailure = .{};
                break :brk vm.rareData().defaultClientSslCtx(&failure) orelse
                    return if (failure.kind == .out_of_memory) error.OutOfMemory else error.TLSContextCreationFailed;
            },
            .custom => |*custom| brk: {
                if (this._secure == null) {
                    var err: uws.TLSContextFailure = .{};
                    this._secure = vm.rareData().sslCtxCache().getOrCreate(custom, &err) orelse {
                        if (err.kind == .out_of_memory) return error.OutOfMemory;
                        this.client.flags.enable_auto_reconnect = false;
                        return error.TLSContextCreationFailed;
                    };
                }
                break :brk this._secure.?;
            },
        };

        this.ref();
        // Balance the ref above if connect() throws — the caller (e.g. send())
        // only knows to clean up its own state, not the keep-alive ref.
        errdefer this.deref();
        this.client.status = .connecting;
        this.updatePollRef();
        errdefer {
            this.client.status = .disconnected;
            this.updatePollRef();
        }
        this.client.socket = try this.client.connectSocket(group, ssl_ctx, is_tls);
    }

    fn submit(this: *JSValkeyClient, context: anytype, command: *const Command) bool {
        var completion_view = context.completion();
        var completion = ValkeyCompletion.ResponseCompletions.takeForContext(
            context,
            &completion_view,
        );
        if (this.client.flags.needs_to_open_socket) {
            @branchHint(.unlikely);

            this.connect() catch |err| {
                this.client.flags.needs_to_open_socket = true;
                if (err == error.OutOfMemory) {
                    completion.outOfMemory();
                    return false;
                }
                const message = std.fmt.allocPrint(
                    bun.default_allocator,
                    " {s} connecting to Valkey",
                    .{@errorName(err)},
                ) catch {
                    completion.outOfMemory();
                    return false;
                };
                defer bun.default_allocator.free(message);
                ValkeyCompletion.failSocketClosedBeforeConnection(&completion, message);
                return false;
            };
            this.resetConnectionTimeout();
        }

        defer this.updatePollRef();
        return this.client.send(command, completion);
    }

    pub fn send(this: *JSValkeyClient, context: anytype, command: *const Command) void {
        _ = this.submit(context, command);
    }

    pub fn sendWithStatus(this: *JSValkeyClient, context: anytype, command: *const Command) bool {
        return this.submit(context, command);
    }

    // Getter for memory cost - useful for diagnostics
    pub fn memoryCost(this: *JSValkeyClient) usize {
        // TODO(markovejnovic): This is most-likely wrong because I didn't know better.
        var memory_cost: usize = @sizeOf(JSValkeyClient);

        // Add size of all internal buffers
        memory_cost += this.client.write_buffer.byte_list.cap;
        memory_cost += this.client.read_buffer.byte_list.cap;

        // Add queue sizes
        memory_cost += this.client.in_flight.count * @sizeOf(valkey.Command.InFlight);
        for (this.client.queue.readableSlice(0)) |*command| {
            memory_cost += command.serialized_data.len;
        }
        memory_cost += this.client.queue.count * @sizeOf(valkey.Command.Entry);
        return memory_cost;
    }

    fn deinit(this: *JSValkeyClient) void {
        bun.debugAssert(this.client.socket.isClosed());
        if (this.wrapper) |*wrapper| wrapper.deinit();
        for (this.connect_completions.items) |*completion| completion.release();
        this.connect_completions.deinit(bun.default_allocator);
        this.cancelDuplicateOperation();
        this._subscription_ctx.deinit();
        if (this._secure) |s| bun.BoringSSL.c.SSL_CTX_free(s);
        this.client.deinit();
        this.poll_ref.disable();
        this.stopTimers();
        this.ref_count.assertNoRefs();

        bun.destroy(this);
    }

    /// Keep the event loop alive, or don't keep it alive.
    pub fn updatePollRef(this: *JSValkeyClient) void {
        const has_pending_commands = this.client.hasAnyPendingCommands();
        const has_subscriptions = !this.client.flags.finalized and this._subscription_ctx.callbacks.count() > 0;
        const has_activity = has_pending_commands or has_subscriptions or this.client.flags.is_reconnecting;

        // There's a couple cases to handle here:
        if (has_activity or this.client.status == .connecting) {
            // If we currently have pending activity or we are connecting, we need to keep the event
            // loop alive.
            this.poll_ref.ref(this.virtualMachine());
        } else {
            // There is no pending activity so it is safe to remove the event
            // loop.
            this.poll_ref.unref(this.virtualMachine());
        }
    }
};

const DuplicateAttachment = struct {
    client: ?*JSValkeyClient,

    fn takeClient(this: *DuplicateAttachment) *JSValkeyClient {
        const client = this.client orelse @panic("duplicate completion no longer owns its client");
        this.client = null;
        return client;
    }

    fn deinit(this: *DuplicateAttachment) void {
        const client = this.client orelse return;
        this.client = null;
        client.cancelDuplicateOperation();
        client.deref();
    }
};

const DuplicateOperation = struct {
    completion: Completion.Owned,

    const Self = @This();

    const CompletionOps = struct {
        pub fn materialize(
            comptime FunctionSchema: type,
            context: bindgen.MaterializationContext(FunctionSchema),
            attachment: *DuplicateAttachment,
            _: *Self,
        ) bindgen.CallError(FunctionSchema)!bindgen.Return(FunctionSchema) {
            const client = attachment.takeClient();
            return try client.toResultRef(context);
        }

        pub fn destroyPayload(operation: *Self) void {
            bun.destroy(operation);
        }

        pub fn destroyAttachment(attachment: *DuplicateAttachment) void {
            attachment.deinit();
        }
    };

    const Completion = bindgen.MaterializedCompletion(
        RedisClientDuplicateSchema,
        Self,
        DuplicateAttachment,
        CompletionOps,
    );
};

const DuplicateCompletion = DuplicateOperation.Completion;

pub const RedisClientBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    client: bindgen.RefNative(JSValkeyClient, .vm),

    fn create(client: *JSValkeyClient) bun.OOM!*RedisClientBinding {
        const binding = bun.default_allocator.create(RedisClientBinding) catch |err| {
            client.wrapperFinalized();
            client.deref();
            return err;
        };
        binding.* = .{ .client = .adopt(client) };
        return binding;
    }

    pub fn destroy(this: *RedisClientBinding) void {
        this.client.get().wrapperFinalized();
        this.client.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const RedisClientBinding, _: bindgen.MemoryUsageContext(.vm)) usize {
        return @sizeOf(RedisClientBinding) + this.client.get().memoryCost();
    }

    pub fn hasPendingActivity(this: *const RedisClientBinding) bool {
        return this.client.get().hasPendingActivity();
    }

    pub fn construct(
        context: bindgen.CallContext(RedisClientConstructorSchema),
        args: bindgen.Args(RedisClientConstructorSchema),
    ) bindgen.CallError(RedisClientConstructorSchema)!*RedisClientBinding {
        const globalObject = context.viewToken().globalObject();
        const client = try JSValkeyClient.createNoJsNoPubsub(globalObject, context, args);
        return RedisClientBinding.create(client);
    }

    pub fn getBufferedAmount(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientBufferedAmountSchema),
        _: bindgen.Args(RedisClientBufferedAmountSchema),
    ) bun.JSError!u64 {
        return this.client.get().getBufferedAmount();
    }

    pub fn getConnected(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientConnectedSchema),
        _: bindgen.Args(RedisClientConnectedSchema),
    ) bun.JSError!bool {
        return this.client.get().getConnected();
    }

    pub fn getOnClose(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientOnCloseGetterSchema),
        args: bindgen.Args(RedisClientOnCloseGetterSchema),
    ) bun.JSError!bindgen.Return(RedisClientOnCloseGetterSchema) {
        try this.client.get().attachWrapper(args.bindingThis);
        return RedisClientOnCloseSlot.ownedCallbackFromView(args.bindingThis);
    }

    pub fn setOnClose(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientOnCloseSetterSchema),
        args: bindgen.Args(RedisClientOnCloseSetterSchema),
    ) bun.JSError!void {
        try this.client.get().attachWrapper(args.bindingThis);
        if (args.value) |callback|
            RedisClientOnCloseSlot.setView(args.bindingThis, callback)
        else
            RedisClientOnCloseSlot.clearView(args.bindingThis);
    }

    pub fn getOnConnect(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientOnConnectGetterSchema),
        args: bindgen.Args(RedisClientOnConnectGetterSchema),
    ) bun.JSError!bindgen.Return(RedisClientOnConnectGetterSchema) {
        try this.client.get().attachWrapper(args.bindingThis);
        return RedisClientOnConnectSlot.ownedCallbackFromView(args.bindingThis);
    }

    pub fn setOnConnect(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientOnConnectSetterSchema),
        args: bindgen.Args(RedisClientOnConnectSetterSchema),
    ) bun.JSError!void {
        try this.client.get().attachWrapper(args.bindingThis);
        if (args.value) |callback|
            RedisClientOnConnectSlot.setView(args.bindingThis, callback)
        else
            RedisClientOnConnectSlot.clearView(args.bindingThis);
    }

    fn BindCommand(comptime name: []const u8) type {
        const Schema = RedisClientClassSchema.member(name);
        const Implementation = struct {
            pub fn call(
                this: *RedisClientBinding,
                context: bindgen.CallContext(Schema),
                args: bindgen.Args(Schema),
            ) bindgen.CallError(Schema)!void {
                const implementation = if (comptime std.mem.eql(u8, name, "send"))
                    RedisCommandFunctions.jsSend
                else
                    @field(RedisCommandFunctions, name);
                const client = this.client.get();
                try client.attachWrapper(args.bindingThis);
                switch (comptime @typeInfo(@TypeOf(implementation)).@"fn".param_types.len) {
                    3 => return implementation(client, context, args),
                    2 => {
                        const CommandArguments = RedisCommandFunctions.Arguments(@TypeOf(args.values), @TypeOf(context));
                        var arguments: CommandArguments = .{ .rest = args.values, .context = context };
                        return implementation(client, &arguments);
                    },
                    else => @compileError("Redis commands require a typed context and arguments or a deferred-rest adapter"),
                }
            }
        };
        return Implementation;
    }

    pub const append = BindCommand("append").call;
    pub const bitcount = BindCommand("bitcount").call;
    pub const blmove = BindCommand("blmove").call;
    pub const blmpop = BindCommand("blmpop").call;
    pub const blpop = BindCommand("blpop").call;
    pub const brpop = BindCommand("brpop").call;
    pub const brpoplpush = BindCommand("brpoplpush").call;
    pub const bzmpop = BindCommand("bzmpop").call;
    pub const bzpopmax = BindCommand("bzpopmax").call;
    pub const bzpopmin = BindCommand("bzpopmin").call;
    pub fn close(
        this: *RedisClientBinding,
        _: bindgen.CallContext(RedisClientCloseSchema),
        args: bindgen.Args(RedisClientCloseSchema),
    ) bun.JSError!void {
        const client = this.client.get();
        try client.attachWrapper(args.bindingThis);
        client.disconnect();
    }
    pub fn connect(
        this: *RedisClientBinding,
        context: bindgen.CallContext(RedisClientConnectSchema),
        args: bindgen.Args(RedisClientConnectSchema),
    ) bindgen.CallError(RedisClientConnectSchema)!void {
        const client = this.client.get();
        try client.attachWrapper(args.bindingThis);
        var completion = context.completion();
        try client.connectWithCompletion(&completion);
    }
    pub const copy = BindCommand("copy").call;
    pub const decr = BindCommand("decr").call;
    pub const decrby = BindCommand("decrby").call;
    pub const del = BindCommand("del").call;
    pub const dump = BindCommand("dump").call;
    pub fn duplicate(
        this: *RedisClientBinding,
        context: bindgen.CallContext(RedisClientDuplicateSchema),
        args: bindgen.Args(RedisClientDuplicateSchema),
    ) bindgen.CallError(RedisClientDuplicateSchema)!void {
        return duplicateFromBinding(this, context, args);
    }
    pub const exists = BindCommand("exists").call;
    pub const expire = BindCommand("expire").call;
    pub const expireat = BindCommand("expireat").call;
    pub const expiretime = BindCommand("expiretime").call;
    pub const get = BindCommand("get").call;
    pub const getbit = BindCommand("getbit").call;
    pub const getBuffer = BindCommand("getBuffer").call;
    pub const getdel = BindCommand("getdel").call;
    pub const getex = BindCommand("getex").call;
    pub const getrange = BindCommand("getrange").call;
    pub const getset = BindCommand("getset").call;
    pub const hdel = BindCommand("hdel").call;
    pub const hexists = BindCommand("hexists").call;
    pub const hexpire = BindCommand("hexpire").call;
    pub const hexpireat = BindCommand("hexpireat").call;
    pub const hexpiretime = BindCommand("hexpiretime").call;
    pub const hget = BindCommand("hget").call;
    pub const hgetall = BindCommand("hgetall").call;
    pub const hgetdel = BindCommand("hgetdel").call;
    pub const hgetex = BindCommand("hgetex").call;
    pub const hincrby = BindCommand("hincrby").call;
    pub const hincrbyfloat = BindCommand("hincrbyfloat").call;
    pub const hkeys = BindCommand("hkeys").call;
    pub const hlen = BindCommand("hlen").call;
    pub const hmget = BindCommand("hmget").call;
    pub const hmset = BindCommand("hmset").call;
    pub const hpersist = BindCommand("hpersist").call;
    pub const hpexpire = BindCommand("hpexpire").call;
    pub const hpexpireat = BindCommand("hpexpireat").call;
    pub const hpexpiretime = BindCommand("hpexpiretime").call;
    pub const hpttl = BindCommand("hpttl").call;
    pub const hrandfield = BindCommand("hrandfield").call;
    pub const hscan = BindCommand("hscan").call;
    pub const hset = BindCommand("hset").call;
    pub const hsetex = BindCommand("hsetex").call;
    pub const hsetnx = BindCommand("hsetnx").call;
    pub const hstrlen = BindCommand("hstrlen").call;
    pub const httl = BindCommand("httl").call;
    pub const hvals = BindCommand("hvals").call;
    pub const incr = BindCommand("incr").call;
    pub const incrby = BindCommand("incrby").call;
    pub const incrbyfloat = BindCommand("incrbyfloat").call;
    pub const keys = BindCommand("keys").call;
    pub const lindex = BindCommand("lindex").call;
    pub const linsert = BindCommand("linsert").call;
    pub const llen = BindCommand("llen").call;
    pub const lmove = BindCommand("lmove").call;
    pub const lmpop = BindCommand("lmpop").call;
    pub const lpop = BindCommand("lpop").call;
    pub const lpos = BindCommand("lpos").call;
    pub const lpush = BindCommand("lpush").call;
    pub const lpushx = BindCommand("lpushx").call;
    pub const lrange = BindCommand("lrange").call;
    pub const lrem = BindCommand("lrem").call;
    pub const lset = BindCommand("lset").call;
    pub const ltrim = BindCommand("ltrim").call;
    pub const mget = BindCommand("mget").call;
    pub const mset = BindCommand("mset").call;
    pub const msetnx = BindCommand("msetnx").call;
    pub const persist = BindCommand("persist").call;
    pub const pexpire = BindCommand("pexpire").call;
    pub const pexpireat = BindCommand("pexpireat").call;
    pub const pexpiretime = BindCommand("pexpiretime").call;
    pub const pfadd = BindCommand("pfadd").call;
    pub const ping = BindCommand("ping").call;
    pub const psetex = BindCommand("psetex").call;
    pub const psubscribe = BindCommand("psubscribe").call;
    pub const pttl = BindCommand("pttl").call;
    pub const publish = BindCommand("publish").call;
    pub const pubsub = BindCommand("pubsub").call;
    pub const punsubscribe = BindCommand("punsubscribe").call;
    pub const randomkey = BindCommand("randomkey").call;
    pub const rename = BindCommand("rename").call;
    pub const renamenx = BindCommand("renamenx").call;
    pub const rpop = BindCommand("rpop").call;
    pub const rpoplpush = BindCommand("rpoplpush").call;
    pub const rpush = BindCommand("rpush").call;
    pub const rpushx = BindCommand("rpushx").call;
    pub const sadd = BindCommand("sadd").call;
    pub const scan = BindCommand("scan").call;
    pub const scard = BindCommand("scard").call;
    pub const script = BindCommand("script").call;
    pub const sdiff = BindCommand("sdiff").call;
    pub const sdiffstore = BindCommand("sdiffstore").call;
    pub const select = BindCommand("select").call;
    pub const send = BindCommand("send").call;
    pub const set = BindCommand("set").call;
    pub const setbit = BindCommand("setbit").call;
    pub const setex = BindCommand("setex").call;
    pub const setnx = BindCommand("setnx").call;
    pub const setrange = BindCommand("setrange").call;
    pub const sinter = BindCommand("sinter").call;
    pub const sintercard = BindCommand("sintercard").call;
    pub const sinterstore = BindCommand("sinterstore").call;
    pub const sismember = BindCommand("sismember").call;
    pub const smembers = BindCommand("smembers").call;
    pub const smismember = BindCommand("smismember").call;
    pub const smove = BindCommand("smove").call;
    pub const spop = BindCommand("spop").call;
    pub const spublish = BindCommand("spublish").call;
    pub const srandmember = BindCommand("srandmember").call;
    pub const srem = BindCommand("srem").call;
    pub const sscan = BindCommand("sscan").call;
    pub const strlen = BindCommand("strlen").call;
    pub const subscribe = BindCommand("subscribe").call;
    pub const substr = BindCommand("substr").call;
    pub const sunion = BindCommand("sunion").call;
    pub const sunionstore = BindCommand("sunionstore").call;
    pub const touch = BindCommand("touch").call;
    pub const ttl = BindCommand("ttl").call;
    pub const @"type" = BindCommand("type").call;
    pub const unlink = BindCommand("unlink").call;
    pub const unsubscribe = BindCommand("unsubscribe").call;
    pub const zadd = BindCommand("zadd").call;
    pub const zcard = BindCommand("zcard").call;
    pub const zcount = BindCommand("zcount").call;
    pub const zdiff = BindCommand("zdiff").call;
    pub const zdiffstore = BindCommand("zdiffstore").call;
    pub const zincrby = BindCommand("zincrby").call;
    pub const zinter = BindCommand("zinter").call;
    pub const zintercard = BindCommand("zintercard").call;
    pub const zinterstore = BindCommand("zinterstore").call;
    pub const zlexcount = BindCommand("zlexcount").call;
    pub const zmpop = BindCommand("zmpop").call;
    pub const zmscore = BindCommand("zmscore").call;
    pub const zpopmax = BindCommand("zpopmax").call;
    pub const zpopmin = BindCommand("zpopmin").call;
    pub const zrandmember = BindCommand("zrandmember").call;
    pub const zrange = BindCommand("zrange").call;
    pub const zrangebylex = BindCommand("zrangebylex").call;
    pub const zrangebyscore = BindCommand("zrangebyscore").call;
    pub const zrangestore = BindCommand("zrangestore").call;
    pub const zrank = BindCommand("zrank").call;
    pub const zrem = BindCommand("zrem").call;
    pub const zremrangebylex = BindCommand("zremrangebylex").call;
    pub const zremrangebyrank = BindCommand("zremrangebyrank").call;
    pub const zremrangebyscore = BindCommand("zremrangebyscore").call;
    pub const zrevrange = BindCommand("zrevrange").call;
    pub const zrevrangebylex = BindCommand("zrevrangebylex").call;
    pub const zrevrangebyscore = BindCommand("zrevrangebyscore").call;
    pub const zrevrank = BindCommand("zrevrank").call;
    pub const zscan = BindCommand("zscan").call;
    pub const zscore = BindCommand("zscore").call;
    pub const zunion = BindCommand("zunion").call;
    pub const zunionstore = BindCommand("zunionstore").call;
};

fn requireRedisClientBinding(comptime Client: type) void {
    if (Client != *RedisClientBinding) {
        @compileError("Valkey runtime operations require the RedisClient native binding");
    }
}

fn duplicateFromBinding(
    binding: anytype,
    context: anytype,
    args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    const globalObject = context.viewToken().globalObject();
    comptime requireRedisClientBinding(@TypeOf(binding));
    const client = binding.client.get();
    try client.attachWrapper(args.bindingThis);
    var completion = context.completion();
    try client.duplicateWithCompletion(globalObject, &completion);
}

/// Callback adapter for the connection's uSockets group.
pub fn SocketHandler(comptime ssl: bool) type {
    const Handler = struct {
        const SocketType = uws.NewSocketHandler(ssl);
        fn _socket(s: SocketType) Socket {
            if (comptime ssl) {
                return Socket{ .SocketTLS = s };
            }

            return Socket{ .SocketTCP = s };
        }
        pub fn onOpen(this: *JSValkeyClient, socket: SocketType) void {
            this.client.socket = _socket(socket);
            this.client.onOpen(_socket(socket));
        }

        fn onHandshake_(this: *JSValkeyClient, _: anytype, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            debug("onHandshake: {d} error={d} reason={s} code={s}", .{
                success,
                ssl_error.error_no,
                if (ssl_error.reason != null) bun.span(ssl_error.reason[0..bun.len(ssl_error.reason) :0]) else "no reason",
                if (ssl_error.code != null) bun.span(ssl_error.code[0..bun.len(ssl_error.code) :0]) else "no code",
            });
            const handshake_success = if (success == 1) true else false;
            this.ref();
            defer this.deref();
            defer this.updatePollRef();
            const vm = this.virtualMachine();
            if (handshake_success) {
                if (this.client.tls.rejectUnauthorized(vm.getTLSRejectUnauthorized())) {
                    // only reject the connection if reject_unauthorized == true
                    if (ssl_error.error_no != 0) {
                        // Certificate chain validation failed.
                        return failHandshakeWithVerifyError(this, vm, &ssl_error);
                    }

                    // Certificate chain is valid; verify the hostname matches the
                    // certificate. Prefer the SNI servername if one was set, otherwise
                    // fall back to the host from the connection URL. Unix-domain
                    // sockets have no hostname to verify, so skip the identity check
                    // for redis+tls+unix:// / valkey+tls+unix:// connections.
                    const ssl_ptr: *BoringSSL.c.SSL = @ptrCast(this.client.socket.getNativeHandle());
                    var hostname: []const u8 = if (BoringSSL.c.SSL_get_servername(ssl_ptr, 0)) |servername|
                        servername[0..bun.len(servername)]
                    else switch (this.client.address) {
                        .host => |h| h.host,
                        .unix => "",
                    };
                    // URL.host() serialises IPv6 literals with surrounding brackets
                    // (e.g. "[::1]"). Strip them so checkServerIdentity can recognise
                    // the value as an IP and match against IP SAN entries; this
                    // mirrors what connectAnon already does before getaddrinfo.
                    if (hostname.len >= 2 and hostname[0] == '[' and hostname[hostname.len - 1] == ']') {
                        hostname = hostname[1 .. hostname.len - 1];
                    }
                    if (hostname.len > 0 and !BoringSSL.checkServerIdentity(ssl_ptr, hostname)) {
                        return failHandshake(this, vm, .{ .tls_hostname = hostname });
                    }
                }
                this.client.start();
            } else {
                // if we are here is because the server rejected us, and the error_no is the cause of this
                // no matter if reject_unauthorized is false, because we were disconnected by the server
                return failHandshakeWithVerifyError(this, vm, &ssl_error);
            }
        }

        fn failHandshakeWithVerifyError(this: *JSValkeyClient, vm: *jsc.VirtualMachine, ssl_error: *const uws.us_bun_verify_error_t) void {
            failHandshake(this, vm, .{ .tls_verification = .{
                .code = if (ssl_error.code == null) "" else ssl_error.code[0..bun.len(ssl_error.code)],
                .reason = if (ssl_error.reason == null) "" else ssl_error.reason[0..bun.len(ssl_error.reason)],
            } });
        }

        fn failHandshake(this: *JSValkeyClient, vm: *jsc.VirtualMachine, failure: ValkeyCompletion.CommandFailure) void {
            this.client.flags.is_authenticated = false;
            const loop = vm.eventLoop();
            loop.enter();
            defer loop.exit();
            this.client.flags.is_manually_closed = true;
            defer this.client.close();
            this.client.failWith(failure);
        }

        pub const onHandshake = if (ssl) onHandshake_ else null;

        pub fn onClose(this: *JSValkeyClient, _: SocketType, _: i32, _: ?*anyopaque) void {
            debug("Socket closed.", .{});
            this.client.socket = .{ .SocketTCP = .detached };
            this.client.status = .disconnected;
            defer {
                this.updatePollRef();
                this.deref();
            }

            this.client.onClose() catch |err| this.globalObject.reportActiveExceptionAsUnhandled(err);
        }

        pub fn onEnd(this: *JSValkeyClient, socket: SocketType) void {
            _ = this;
            _ = socket;

            // Half-opened sockets are not allowed.
            // usockets will always call onClose after onEnd in this case so we don't need to do anything here
        }

        pub fn onConnectError(this: *JSValkeyClient, _: SocketType, failure: uws.ConnectFailure) void {
            this.client.socket = .{ .SocketTCP = .detached };
            this.client.status = .disconnected;
            defer {
                this.updatePollRef();
                this.deref();
            }

            if (failure.isOutOfMemory()) {
                this.failConnectionCompletions(true);
                this.clientFail("Failed to allocate connection", error.OutOfMemory);
            }
            this.client.onClose() catch |err| this.globalObject.reportActiveExceptionAsUnhandled(err);
        }

        pub fn onTimeout(this: *JSValkeyClient, socket: SocketType) void {
            debug("Socket timed out.", .{});

            this.client.socket = _socket(socket);
            // Handle socket timeout
        }

        pub fn onData(this: *JSValkeyClient, socket: SocketType, data: []const u8) void {
            // Ensure the socket pointer is updated.
            this.client.socket = _socket(socket);

            this.ref();
            defer this.deref();
            this.client.onData(data);
            this.updatePollRef();
        }

        pub fn onWritable(this: *JSValkeyClient, socket: SocketType) void {
            this.client.socket = _socket(socket);
            this.ref();
            defer this.deref();
            this.client.onWritable();
            this.updatePollRef();
        }
    };
    return Handler;
}

const debug = bun.Output.scoped(.RedisJS, .visible);

const Command = @import("./ValkeyCommand.zig");
const ValkeyCompletion = @import("./ValkeyCompletion.zig");
const std = @import("std");
const valkey = @import("./valkey.zig");
const ConnectionConfig = @import("ConnectionConfig.zig");
const AutoFlusher = @import("../../event_loop/AutoFlusher.zig");
const AutoFlusherEngine = @import("../../event_loop/AutoFlusherEngine.zig");

const protocol = @import("../../valkey/valkey_protocol.zig");
const RedisError = protocol.RedisError;

const bun = @import("bun");
const BoringSSL = bun.BoringSSL;
const String = bun.String;
const Timer = bun.api.Timer;

const jsc = bun.jsc;
const bindgen = bun.bindgen;

const RedisClientBindings = bindgen.Module("RedisClient");
const RedisClientClassSchema = RedisClientBindings.class("RedisClient");
const RedisClientClass = bindgen.Class(RedisClientClassSchema, RedisClientBinding);
const RedisClientConstructorSchema = RedisClientClassSchema.constructor();
const RedisClientBufferedAmountSchema = RedisClientClassSchema.memberKind("bufferedAmount", .getter);
const RedisClientConnectedSchema = RedisClientClassSchema.memberKind("connected", .getter);
const RedisClientCloseSchema = RedisClientClassSchema.member("close");
const RedisClientConnectSchema = RedisClientClassSchema.member("connect");
const RedisClientDuplicateSchema = RedisClientClassSchema.member("duplicate");
const RedisClientOnCloseGetterSchema = RedisClientClassSchema.memberKind("onclose", .getter);
const RedisClientOnCloseSetterSchema = RedisClientClassSchema.memberKind("onclose", .setter);
const RedisClientOnConnectGetterSchema = RedisClientClassSchema.memberKind("onconnect", .getter);
const RedisClientOnConnectSetterSchema = RedisClientClassSchema.memberKind("onconnect", .setter);
const RedisClientSubscribeSchema = RedisClientClassSchema.member("subscribe");
const RedisSubscriptionListenerType = @FieldType(bindgen.Args(RedisClientSubscribeSchema), "listener").SemanticType;
const RedisCloseListenerType = @typeInfo(@FieldType(bindgen.Args(RedisClientOnCloseSetterSchema), "value")).optional.child.SemanticType;
const RedisConnectListenerType = @typeInfo(@FieldType(bindgen.Args(RedisClientOnConnectSetterSchema), "value")).optional.child.SemanticType;
const RedisErrorValue = bindgen.OwnedBrandedValue(ValkeyCompletion.CreateErrorSchema.ReturnType);
const RedisClientOnConnectSlot = RedisClientClass.CachedSlot("onconnect");
const RedisClientOnCloseSlot = RedisClientClass.CachedSlot("onclose");
const RedisCommandFunctions = @import("./ValkeyFunctions.zig");

comptime {
    _ = RedisClientClass;
}

const uws = bun.uws;
const Socket = uws.AnySocket;
