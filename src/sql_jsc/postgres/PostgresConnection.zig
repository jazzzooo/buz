pub fn WithIntegration(comptime Integration: type) type {
    return struct {
        const PostgresConnection = @This();
        const IntegrationOwner = Integration.Connection;
        const Query = Integration.Query;
        const RequestQueue = Integration.RequestQueue;

        socket: Socket = .{ .SocketTCP = .{ .socket = .{ .detached = {} } } },
        status: Status = .connecting,

        write_buffer: bun.OffsetByteList = .{},
        read_buffer: bun.OffsetByteList = .{},
        last_message_start: u32 = 0,
        requests: RequestQueue,
        pipelined_requests: u32 = 0,
        nonpipelinable_requests: u32 = 0,

        statements: PreparedStatementsMap = .{},
        prepared_statement_id: u64 = 0,

        backend_parameters: bun.StringMap = bun.StringMap.init(bun.default_allocator, true),
        backend_key_data: protocol.BackendKeyData = .{},

        database: []const u8 = "",
        user: []const u8 = "",
        password: []const u8 = "",
        path: []const u8 = "",
        options: []const u8 = "",
        options_buf: []const u8 = "",

        authentication_state: AuthenticationState = .{ .pending = {} },

        secure: ?*uws.SslCtx = null,
        tls_config: SSLConfig = .{},
        tls_status: TLSStatus = .none,
        ssl_mode: SSLMode = .disable,

        flags: ConnectionFlags = .{},

        pub fn init(
            database: []const u8,
            user: []const u8,
            password: []const u8,
            path: []const u8,
            options: []const u8,
            options_buf: []const u8,
            tls_config: SSLConfig,
            secure: ?*uws.SslCtx,
            ssl_mode: SSLMode,
            use_unnamed_prepared_statements: bool,
        ) PostgresConnection {
            return .{
                .database = database,
                .user = user,
                .password = password,
                .path = path,
                .options = options,
                .options_buf = options_buf,
                .requests = RequestQueue.init(bun.default_allocator),
                .tls_config = tls_config,
                .secure = secure,
                .ssl_mode = ssl_mode,
                .tls_status = if (ssl_mode != .disable) .pending else .none,
                .flags = .{
                    .use_unnamed_prepared_statements = use_unnamed_prepared_statements,
                },
            };
        }

        fn owner(this: *PostgresConnection) *IntegrationOwner {
            return Integration.owner(this);
        }

        pub fn fail(this: *PostgresConnection, message: []const u8, err: AnyPostgresError) void {
            Integration.fail(this.owner(), message, err);
        }

        pub fn isProcessingData(this: *const PostgresConnection) bool {
            return this.flags.is_processing_data;
        }

        pub fn canFlush(this: *const PostgresConnection) bool {
            return !this.flags.has_backpressure and
                this.status == .connected and
                this.write_buffer.len() > 0;
        }

        pub fn setupTLS(this: *PostgresConnection) void {
            debug("setupTLS", .{});
            const owner_connection = this.owner();
            const new_socket = this.socket.SocketTCP.socket.connected.adoptTLS(
                Integration.postgresTLSGroup(owner_connection),
                .postgres_tls,
                this.secure.?,
                if (this.tls_config.server_name) |name| name.ptr else null,
                @sizeOf(?*IntegrationOwner),
                @sizeOf(?*IntegrationOwner),
            ) orelse {
                Integration.fail(owner_connection, "Failed to upgrade to TLS", error.TLSUpgradeFailed);
                return;
            };
            new_socket.ext(?*IntegrationOwner).* = owner_connection;
            this.socket = .{ .SocketTLS = .{ .socket = .{ .connected = new_socket } } };
            new_socket.startTLSHandshake();
            Integration.start(owner_connection);
        }

        pub fn flushData(this: *PostgresConnection) void {
            if (this.flags.has_backpressure) {
                debug("flushData: has backpressure", .{});
                return;
            }

            const chunk = this.write_buffer.remaining();
            if (chunk.len == 0) {
                debug("flushData: no data to flush", .{});
                return;
            }

            const wrote = this.socket.write(chunk);
            this.flags.has_backpressure = wrote < chunk.len;
            debug("flushData: wrote {d}/{d} bytes", .{ wrote, chunk.len });
            if (wrote > 0) {
                SocketMonitor.write(Integration.io(this.owner()), chunk[0..@intCast(wrote)]);
                this.write_buffer.consume(@intCast(wrote));
            }
        }

        pub fn sendStartupMessage(this: *PostgresConnection) void {
            if (this.status != .connecting) return;
            debug("sendStartupMessage", .{});
            this.status = .sent_startup_message;
            var msg = protocol.StartupMessage{
                .user = Data{ .temporary = this.user },
                .database = Data{ .temporary = this.database },
                .options = Data{ .temporary = this.options },
            };
            msg.writeInternal(Writer, this.writer()) catch |err| {
                Integration.fail(this.owner(), "Failed to write startup message", err);
            };
        }

        fn startTLS(this: *PostgresConnection, socket: Socket) void {
            debug("startTLS", .{});
            const offset = switch (this.tls_status) {
                .message_sent => |count| count,
                else => 0,
            };
            const ssl_request = [_]u8{
                0x00, 0x00, 0x00, 0x08,
                0x04, 0xD2, 0x16, 0x2F,
            };

            const written = socket.write(ssl_request[offset..]);
            this.tls_status = .{ .message_sent = if (written > 0)
                offset + @as(u8, @intCast(written))
            else
                offset };
        }

        pub fn open(this: *PostgresConnection, socket: Socket) void {
            this.socket = socket;
            if (this.tls_status == .message_sent or this.tls_status == .pending) {
                this.startTLS(socket);
                return;
            }
            Integration.start(this.owner());
        }

        pub fn handshakeSucceeded(this: *PostgresConnection, success: i32, ssl_error: uws.us_bun_verify_error_t) bool {
            debug("onHandshake: {d} {d}", .{ success, ssl_error.error_no });
            if (success != 1) return false;
            if (this.tls_config.reject_unauthorized == 0) return true;

            switch (this.ssl_mode) {
                .verify_ca, .verify_full => {
                    if (ssl_error.error_no != 0) return false;
                    const ssl_ptr: *BoringSSL.c.SSL = @ptrCast(this.socket.getNativeHandle());
                    if (BoringSSL.c.SSL_get_servername(ssl_ptr, 0)) |server_name| {
                        const hostname = server_name[0..bun.len(server_name)];
                        if (!BoringSSL.checkServerIdentity(ssl_ptr, hostname)) return false;
                    }
                },
                .require, .prefer, .disable => {},
            }
            return true;
        }

        pub fn drain(this: *PostgresConnection) void {
            debug("onDrain", .{});
            this.flags.has_backpressure = false;
            if (this.tls_status == .message_sent) {
                if (this.tls_status.message_sent < 8) this.startTLS(this.socket);
                return;
            }
            Integration.drain(this.owner());
        }

        pub fn readAndProcessData(this: *PostgresConnection, data: []const u8) void {
            SocketMonitor.read(Integration.io(this.owner()), data);
            this.read_buffer.head = this.last_message_start;

            if (this.read_buffer.remaining().len == 0) {
                var consumed: usize = 0;
                var offset: usize = 0;
                const reader = protocol.StackReader.init(data, &consumed, &offset);
                PostgresRequest.onData(this, protocol.StackReader, reader) catch |err| {
                    if (err == error.ShortRead) {
                        if (comptime bun.Environment.allow_assert) {
                            debug("read_buffer: empty and received short read: last_message_start: {d}, head: {d}, len: {d}", .{
                                offset,
                                consumed,
                                data.len,
                            });
                        }

                        this.read_buffer.head = 0;
                        this.last_message_start = 0;
                        this.read_buffer.byte_list.len = 0;
                        this.read_buffer.write(bun.default_allocator, data[offset..]) catch @panic("failed to write to read buffer");
                    } else {
                        bun.handleErrorReturnTrace(err, @errorReturnTrace());
                        Integration.fail(this.owner(), "Failed to read data", err);
                    }
                };
                return;
            }

            this.read_buffer.write(bun.default_allocator, data) catch @panic("failed to write to read buffer");
            PostgresRequest.onData(this, Reader, this.bufferedReader()) catch |err| {
                if (err != error.ShortRead) {
                    bun.handleErrorReturnTrace(err, @errorReturnTrace());
                    Integration.fail(this.owner(), "Failed to read data", err);
                    return;
                }

                if (comptime bun.Environment.allow_assert) {
                    debug("read_buffer: not empty and received short read: last_message_start: {d}, head: {d}, len: {d}", .{
                        this.last_message_start,
                        this.read_buffer.head,
                        this.read_buffer.byte_list.len,
                    });
                }
                return;
            };

            debug("clean read_buffer", .{});
            this.last_message_start = 0;
            this.read_buffer.head = 0;
        }

        pub fn deinit(this: *PostgresConnection) void {
            var iter = this.statements.valueIterator();
            while (iter.next()) |stmt_ptr| {
                var stmt = stmt_ptr.*;
                stmt.deref();
            }
            this.statements.deinit(bun.default_allocator);
            this.requests.deinit();
            this.write_buffer.deinit(bun.default_allocator);
            this.read_buffer.deinit(bun.default_allocator);
            this.backend_parameters.deinit();
            bun.freeSensitive(bun.default_allocator, this.options_buf);
            this.tls_config.deinit();
            if (this.secure) |ssl_context| BoringSSL.c.SSL_CTX_free(ssl_context);
        }

        pub fn current(this: *PostgresConnection) ?*Query {
            if (this.requests.readableLength() == 0) return null;
            return this.requests.peekItem(0);
        }

        pub fn hasQueryRunning(this: *PostgresConnection) bool {
            return !this.flags.is_ready_for_query or this.current() != null;
        }

        pub fn canPipeline(this: *PostgresConnection) bool {
            if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_SQL_AUTO_PIPELINING.get()) {
                @branchHint(.unlikely);
                return false;
            }

            return this.nonpipelinable_requests == 0 and
                !this.flags.use_unnamed_prepared_statements and
                !this.flags.waiting_to_prepare and
                !this.flags.has_backpressure and
                this.write_buffer.len() < MAX_PIPELINE_SIZE;
        }

        pub const Writer = struct {
            connection: *PostgresConnection,

            pub fn isConnected(this: Writer) bool {
                return this.connection.status == .connected;
            }

            pub fn truncate(this: Writer, end: usize) void {
                const buffer = &this.connection.write_buffer;
                bun.assert(end >= buffer.head and end <= buffer.byte_list.len);
                buffer.byte_list.len = @intCast(end);
            }

            pub fn write(this: Writer, data: []const u8) AnyPostgresError!void {
                try this.connection.write_buffer.write(bun.default_allocator, data);
            }

            pub fn pwrite(this: Writer, data: []const u8, index: usize) AnyPostgresError!void {
                @memcpy(this.connection.write_buffer.byte_list.slice()[index..][0..data.len], data);
            }

            pub fn offset(this: Writer) usize {
                return this.connection.write_buffer.byte_list.len;
            }
        };

        pub fn writer(this: *PostgresConnection) protocol.NewWriter(Writer) {
            return .{ .wrapped = .{ .connection = this } };
        }

        pub const Reader = struct {
            connection: *PostgresConnection,

            pub fn markMessageStart(this: Reader) void {
                this.connection.last_message_start = this.connection.read_buffer.head;
            }

            pub fn peek(this: Reader) []const u8 {
                return this.connection.read_buffer.remaining();
            }

            pub fn skip(this: Reader, count: usize) AnyPostgresError!void {
                if (count > this.connection.read_buffer.byte_list.len - this.connection.read_buffer.head) return error.ShortRead;
                this.connection.read_buffer.head += @intCast(count);
            }

            pub fn read(this: Reader, count: usize) AnyPostgresError!Data {
                const remaining = this.connection.read_buffer.remaining();
                try this.skip(count);
                return .{ .temporary = remaining[0..count] };
            }

            pub fn readZ(this: Reader) AnyPostgresError!Data {
                const remaining = this.connection.read_buffer.remaining();
                if (bun.strings.indexOfChar(remaining, 0)) |zero| {
                    try this.skip(zero + 1);
                    return .{ .temporary = remaining[0..zero] };
                }
                return error.ShortRead;
            }
        };

        pub fn bufferedReader(this: *PostgresConnection) protocol.NewReader(Reader) {
            return .{ .wrapped = .{ .connection = this } };
        }

        pub fn finishRequest(this: *PostgresConnection, item: *Query) void {
            switch (item.getStatus()) {
                .running, .binding, .partial_response => {
                    if (item.isSimple()) {
                        this.nonpipelinable_requests -= 1;
                    } else if (item.isPipelined()) {
                        this.pipelined_requests -= 1;
                    }
                },
                .success, .fail, .pending => {},
            }
        }

        pub fn canPrepareQuery(this: *const PostgresConnection) bool {
            return this.flags.is_ready_for_query and !this.flags.waiting_to_prepare and this.pipelined_requests == 0;
        }

        pub fn advanceAndFlush(this: *PostgresConnection) void {
            if (!this.flags.has_backpressure and this.flags.is_ready_for_query) {
                this.advance();
                this.flushData();
            }
        }

        fn queryWriteFailed(this: *PostgresConnection, request: *Query, err: AnyPostgresError) bool {
            return Integration.queryWriteFailed(this.owner(), request, err);
        }

        fn discardRequest(this: *PostgresConnection, request: *Query, offset: usize) void {
            if (offset >= this.requests.readableLength() or this.requests.peekItem(offset) != request) return;
            if (offset == 0) {
                request.deref();
                this.requests.discard(1);
            } else {
                request.setStatus(.fail);
            }
        }

        fn advance(this: *PostgresConnection) void {
            var offset: usize = 0;
            debug("advance", .{});
            defer {
                while (this.requests.readableLength() > 0) {
                    const result = this.requests.peekItem(0);
                    switch (result.getStatus()) {
                        .success, .fail => {
                            result.deref();
                            this.requests.discard(1);
                            continue;
                        },
                        else => break,
                    }
                }
            }
            while (this.status == .connected and this.requests.readableLength() > offset and !this.flags.has_backpressure) {
                if (Integration.isShuttingDown(this.owner())) return Integration.close(this.owner());

                const request: *Query = this.requests.peekItem(offset);
                // Parameter conversion can run JavaScript that closes the connection and drains the queue.
                request.ref();
                defer request.deref();
                switch (request.getStatus()) {
                    .pending => {
                        if (request.isSimple()) {
                            if (this.pipelined_requests > 0 or !this.flags.is_ready_for_query) return;
                            var query_string = request.queryText().toUTF8(bun.default_allocator) catch |err| {
                                _ = this.queryWriteFailed(request, err);
                                this.discardRequest(request, offset);
                                continue;
                            };
                            defer query_string.deinit();
                            PostgresRequest.executeQuery(query_string.slice(), Writer, this.writer()) catch |err| {
                                _ = this.queryWriteFailed(request, err);
                                this.discardRequest(request, offset);
                                continue;
                            };
                            this.nonpipelinable_requests += 1;
                            this.flags.is_ready_for_query = false;
                            request.setStatus(.running);
                            return;
                        }

                        const statement = request.getStatement() orelse {
                            offset += 1;
                            continue;
                        };
                        switch (statement.status) {
                            .failed => {
                                bun.assert(statement.error_response != null);
                                Integration.queryFailed(this.owner(), request, statement.error_response.?);
                                if (offset == 0) {
                                    this.discardRequest(request, offset);
                                } else {
                                    request.setStatus(.fail);
                                    offset += 1;
                                }
                            },
                            .prepared => {
                                const alive = Integration.queryIsAlive(request) catch |err| {
                                    _ = this.queryWriteFailed(request, err);
                                    this.discardRequest(request, offset);
                                    if (offset > 0) offset += 1;
                                    continue;
                                };
                                if (!alive) {
                                    bun.assertf(false, "query value was freed earlier than expected", .{});
                                    this.discardRequest(request, offset);
                                    if (offset > 0) offset += 1;
                                    continue;
                                }
                                const binding_value = request.bindingValues();
                                const columns_value = request.columnsValue();
                                request.setBinary(statement.fields.len > 0);

                                const write_result = if (this.flags.use_unnamed_prepared_statements) blk: {
                                    var query_string = request.queryText().toUTF8(bun.default_allocator) catch |err| break :blk err;
                                    defer query_string.deinit();
                                    break :blk PostgresRequest.parseAndBindAndExecute(
                                        query_string.slice(),
                                        statement,
                                        binding_value,
                                        columns_value,
                                        false,
                                        Writer,
                                        this.writer(),
                                    );
                                } else PostgresRequest.bindAndExecute(
                                    statement,
                                    binding_value,
                                    columns_value,
                                    Writer,
                                    this.writer(),
                                );
                                write_result catch |err| {
                                    _ = this.queryWriteFailed(request, err);
                                    this.discardRequest(request, offset);
                                    if (offset > 0) offset += 1;
                                    continue;
                                };

                                this.flags.is_ready_for_query = false;
                                request.setStatus(.binding);
                                request.setPipelined(true);
                                this.pipelined_requests += 1;
                                if (this.flags.use_unnamed_prepared_statements or !this.canPipeline()) return;
                                offset += 1;
                            },
                            .pending => {
                                if (!this.canPrepareQuery()) return;
                                var query_string = request.queryText().toUTF8(bun.default_allocator) catch |err| {
                                    if (this.queryWriteFailed(request, err)) {
                                        statement.status = .failed;
                                        statement.error_response = .{ .postgres_error = err };
                                    }
                                    this.discardRequest(request, offset);
                                    continue;
                                };
                                defer query_string.deinit();
                                const has_params = statement.signature.fields.len > 0;
                                if (!has_params) {
                                    const alive = Integration.queryIsAlive(request) catch |err| {
                                        _ = this.queryWriteFailed(request, err);
                                        this.discardRequest(request, offset);
                                        continue;
                                    };
                                    if (!alive) {
                                        bun.assertf(false, "query value was freed earlier than expected", .{});
                                        this.discardRequest(request, offset);
                                        continue;
                                    }
                                    PostgresRequest.prepareAndQueryWithSignature(
                                        query_string.slice(),
                                        request.bindingValues(),
                                        Writer,
                                        this.writer(),
                                        &statement.signature,
                                    ) catch |err| {
                                        if (this.queryWriteFailed(request, err)) {
                                            statement.status = .failed;
                                            statement.error_response = .{ .postgres_error = err };
                                        }
                                        this.discardRequest(request, offset);
                                        continue;
                                    };
                                    this.flags.is_ready_for_query = false;
                                    this.flags.waiting_to_prepare = true;
                                    request.setStatus(.binding);
                                    statement.status = .parsing;
                                    Integration.flushDataAndResetTimeout(this.owner());
                                    return;
                                }

                                if (this.flags.use_unnamed_prepared_statements) {
                                    const alive = Integration.queryIsAlive(request) catch |err| {
                                        _ = this.queryWriteFailed(request, err);
                                        this.discardRequest(request, offset);
                                        continue;
                                    };
                                    if (!alive) {
                                        bun.assertf(false, "query value was freed earlier than expected", .{});
                                        bun.assert(offset == 0);
                                        this.discardRequest(request, offset);
                                        continue;
                                    }
                                    PostgresRequest.parseAndBindAndExecute(
                                        query_string.slice(),
                                        statement,
                                        request.bindingValues(),
                                        request.columnsValue(),
                                        true,
                                        Writer,
                                        this.writer(),
                                    ) catch |err| {
                                        if (this.queryWriteFailed(request, err)) {
                                            statement.status = .failed;
                                            statement.error_response = .{ .postgres_error = err };
                                        }
                                        bun.assert(offset == 0);
                                        this.discardRequest(request, offset);
                                        continue;
                                    };
                                    this.flags.is_ready_for_query = false;
                                    this.flags.waiting_to_prepare = true;
                                    request.setStatus(.binding);
                                    statement.status = .parsing;
                                    request.setPipelined(true);
                                    this.pipelined_requests += 1;
                                    Integration.flushDataAndResetTimeout(this.owner());
                                    return;
                                }

                                const connection_writer = this.writer();
                                PostgresRequest.writeQuery(
                                    query_string.slice(),
                                    statement.signature.prepared_statement_name,
                                    statement.signature.fields,
                                    Writer,
                                    connection_writer,
                                ) catch |err| {
                                    if (this.queryWriteFailed(request, err)) {
                                        statement.error_response = .{ .postgres_error = err };
                                        statement.status = .failed;
                                    }
                                    bun.assert(offset == 0);
                                    this.discardRequest(request, offset);
                                    continue;
                                };
                                connection_writer.write(&protocol.Sync) catch |err| {
                                    if (this.queryWriteFailed(request, err)) {
                                        statement.error_response = .{ .postgres_error = err };
                                        statement.status = .failed;
                                    }
                                    bun.assert(offset == 0);
                                    this.discardRequest(request, offset);
                                    continue;
                                };
                                this.flags.is_ready_for_query = false;
                                this.flags.waiting_to_prepare = true;
                                statement.status = .parsing;
                                Integration.flushDataAndResetTimeout(this.owner());
                                return;
                            },
                            .parsing => {
                                offset += 1;
                            },
                        }
                    },
                    .running, .binding, .partial_response => {
                        if (this.flags.waiting_to_prepare or this.nonpipelinable_requests > 0) return;
                        const running = this.pipelined_requests;
                        offset += if (offset < running) running else 1;
                    },
                    .success => {
                        if (offset > 0) {
                            request.setStatus(.fail);
                            offset += 1;
                        } else {
                            this.discardRequest(request, offset);
                        }
                    },
                    .fail => {
                        if (offset > 0) {
                            offset += 1;
                        } else {
                            this.discardRequest(request, offset);
                        }
                    },
                }
            }
        }

        pub fn on(this: *PostgresConnection, comptime MessageType: @EnumLiteral(), reader: protocol.PayloadReader) AnyPostgresError!void {
            debug("on({s})", .{@tagName(MessageType)});
            switch (comptime MessageType) {
                .DataRow => {
                    const request = this.current() orelse return error.ExpectedRequest;
                    const statement = request.getStatement() orelse return error.ExpectedStatement;
                    try Integration.dataRow(this.owner(), request, statement, reader);
                },
                .CopyData => {
                    var copy_data: protocol.CopyData = undefined;
                    try copy_data.decode(reader);
                    copy_data.data.deinit();
                },
                .ParameterStatus => {
                    var parameter_status: protocol.ParameterStatus = undefined;
                    try parameter_status.decode(reader);
                    defer parameter_status.deinit();
                    try this.backend_parameters.insert(parameter_status.name.slice(), parameter_status.value.slice());
                },
                .ReadyForQuery => {
                    var ready_for_query: protocol.ReadyForQuery = undefined;
                    try ready_for_query.decode(reader);
                    Integration.setStatus(this.owner(), .connected);
                    this.flags.waiting_to_prepare = false;
                    this.flags.is_ready_for_query = true;
                    this.socket.setTimeout(300);
                    defer Integration.updateRef(this.owner());
                    if (this.current()) |request| {
                        if (request.getStatus() == .partial_response) {
                            this.finishRequest(request);
                            Integration.queryResult(this.owner(), request, "", true);
                        }
                    }
                    this.advance();
                    Integration.registerAutoFlusher(this.owner());
                },
                .CommandComplete => {
                    const request = this.current() orelse return error.ExpectedRequest;
                    var command: protocol.CommandComplete = undefined;
                    try command.decode(reader);
                    defer command.deinit();
                    defer Integration.updateRef(this.owner());
                    Integration.queryResult(this.owner(), request, command.command_tag.slice(), false);
                },
                .BindComplete => {
                    try reader.expectEnd();
                    const request = this.current() orelse return error.ExpectedRequest;
                    if (request.getStatus() == .binding) request.setStatus(.running);
                },
                .ParseComplete => {
                    try reader.expectEnd();
                    const request = this.current() orelse return error.ExpectedRequest;
                    if (request.getStatement()) |statement| {
                        if (statement.status == .parsing and statement.signature.fields.len == 0) {
                            statement.status = .prepared;
                            this.flags.waiting_to_prepare = false;
                        }
                    }
                },
                .ParameterDescription => {
                    var description: protocol.ParameterDescription = undefined;
                    try description.decode(reader);
                    errdefer bun.default_allocator.free(description.parameters);
                    const request = this.current() orelse return error.ExpectedRequest;
                    const statement = request.getStatement() orelse return error.ExpectedStatement;
                    if (statement.parameters.len > 0) bun.default_allocator.free(statement.parameters);
                    statement.parameters = description.parameters;
                    if (statement.status == .parsing) {
                        statement.status = .prepared;
                        this.flags.waiting_to_prepare = false;
                    }
                },
                .RowDescription => {
                    var description: protocol.RowDescription = undefined;
                    try description.decode(reader);
                    errdefer description.deinit();
                    const request = this.current() orelse return error.ExpectedRequest;
                    const statement = request.getStatement() orelse return error.ExpectedStatement;
                    if (statement.fields.len > 0) {
                        for (statement.fields) |*field| field.deinit();
                        bun.default_allocator.free(statement.fields);
                    }
                    statement.result_layout.deinit();
                    statement.fields = description.fields;
                },
                .Authentication => try this.onAuthentication(reader),
                .NoData => {
                    try reader.expectEnd();
                    const request = this.current() orelse return error.ExpectedRequest;
                    if (request.getStatus() == .binding) request.setStatus(.running);
                },
                .BackendKeyData => try this.backend_key_data.decode(reader),
                .ErrorResponse => try this.onErrorResponse(reader),
                .PortalSuspended => {
                    try reader.expectEnd();
                    debug("TODO PortalSuspended", .{});
                },
                .CloseComplete => {
                    try reader.expectEnd();
                    const request = this.current() orelse return error.ExpectedRequest;
                    defer Integration.updateRef(this.owner());
                    Integration.queryResult(this.owner(), request, "CLOSECOMPLETE", false);
                },
                .CopyInResponse => debug("TODO CopyInResponse", .{}),
                .NoticeResponse => {
                    var response: protocol.NoticeResponse = undefined;
                    try response.decode(reader);
                    response.deinit();
                },
                .EmptyQueryResponse => {
                    try reader.expectEnd();
                    const request = this.current() orelse return error.ExpectedRequest;
                    defer Integration.updateRef(this.owner());
                    Integration.queryResult(this.owner(), request, "", false);
                },
                .CopyOutResponse => debug("TODO CopyOutResponse", .{}),
                .CopyDone => {
                    try reader.expectEnd();
                    debug("TODO CopyDone", .{});
                },
                .CopyBothResponse => debug("TODO CopyBothResponse", .{}),
                else => @compileError("Unknown message type: " ++ @tagName(MessageType)),
            }
        }

        fn onAuthentication(this: *PostgresConnection, reader: protocol.PayloadReader) AnyPostgresError!void {
            var auth: protocol.Authentication = undefined;
            try auth.decode(reader);
            defer auth.deinit();

            switch (auth) {
                .SASL => {
                    if (this.authentication_state != .SASL) this.authentication_state = .{ .SASL = .{} };
                    var mechanism_buf: [128]u8 = undefined;
                    const mechanism = std.mem.printSentinel(&mechanism_buf, "n,,n=*,r={s}", .{this.authentication_state.SASL.nonce()}, 0) catch unreachable;
                    var response = protocol.SASLInitialResponse{
                        .mechanism = .{ .temporary = "SCRAM-SHA-256" },
                        .data = .{ .temporary = mechanism },
                    };
                    try response.writeInternal(Writer, this.writer());
                    this.flushData();
                },
                .SASLContinue => |*continuation| {
                    if (this.authentication_state != .SASL or this.authentication_state.SASL.status != .init) return error.UnexpectedMessage;
                    const sasl = &this.authentication_state.SASL;
                    const iteration_count = try continuation.iterationCount();
                    const decoded_salt = bun.base64.decodeAlloc(bun.z_allocator, continuation.s) catch |err| {
                        return switch (err) {
                            error.DecodingFailed => error.SASL_SIGNATURE_INVALID_BASE64,
                            else => |other| other,
                        };
                    };
                    defer bun.z_allocator.free(decoded_salt);
                    try sasl.computeSaltedPassword(decoded_salt, iteration_count, this.password);

                    const auth_string = try std.fmt.allocPrint(
                        bun.z_allocator,
                        "n=*,r={s},r={s},s={s},i={s},c=biws,r={s}",
                        .{ sasl.nonce(), continuation.r, continuation.s, continuation.i, continuation.r },
                    );
                    defer bun.z_allocator.free(auth_string);
                    try sasl.computeServerSignature(auth_string);

                    const client_key = sasl.clientKey();
                    const signature = sasl.clientKeySignature(&client_key, auth_string);
                    var proof: [32]u8 = undefined;
                    for (&proof, client_key, signature) |*out, key_byte, signature_byte| out.* = key_byte ^ signature_byte;
                    var encoded_proof = std.mem.zeroes([bun.base64.encodeLenFromSize(32)]u8);
                    const proof_len = bun.base64.encode(&encoded_proof, &proof);
                    const payload = try std.fmt.allocPrint(
                        bun.z_allocator,
                        "c=biws,r={s},p={s}",
                        .{ continuation.r, encoded_proof[0..proof_len] },
                    );
                    defer bun.z_allocator.free(payload);
                    var response = protocol.SASLResponse{ .data = .{ .temporary = payload } };
                    try response.writeInternal(Writer, this.writer());
                    sasl.status = .@"continue";
                    this.flushData();
                },
                .SASLFinal => |final| {
                    if (this.authentication_state != .SASL or this.authentication_state.SASL.status != .@"continue") return error.UnexpectedMessage;
                    const sasl = &this.authentication_state.SASL;
                    if (sasl.server_signature_len == 0) return error.UnexpectedMessage;
                    const server_signature = sasl.serverSignature();
                    const comparison = final.data.slice();
                    if (comparison.len < 2 or
                        server_signature.len != comparison.len - 2 or
                        BoringSSL.c.CRYPTO_memcmp(server_signature.ptr, comparison[2..].ptr, server_signature.len) != 0)
                    {
                        Integration.fail(this.owner(), "The server did not return the correct signature", error.SASL_SIGNATURE_MISMATCH);
                    } else {
                        this.authentication_state.zero();
                    }
                },
                .Ok => {
                    this.authentication_state.zero();
                    this.authentication_state = .{ .ok = {} };
                },
                .Unknown => Integration.fail(this.owner(), "Unknown authentication method", error.UNKNOWN_AUTHENTICATION_METHOD),
                .ClearTextPassword => {
                    var response = protocol.PasswordMessage{ .password = .{ .temporary = this.password } };
                    try response.writeInternal(Writer, this.writer());
                    this.flushData();
                },
                .MD5Password => |md5| {
                    var first_hash: bun.sha.MD5.Digest = undefined;
                    var first_hash_text: [32]u8 = undefined;
                    var final_hash: bun.sha.MD5.Digest = undefined;
                    var final_hash_text: [32]u8 = undefined;
                    var password_buffer: [36]u8 = undefined;

                    var first_hasher = bun.sha.MD5.init();
                    first_hasher.update(this.password);
                    first_hasher.update(this.user);
                    first_hasher.final(&first_hash);
                    const first = std.fmt.bufPrint(&first_hash_text, "{x}", .{&first_hash}) catch unreachable;
                    var final_hasher = bun.sha.MD5.init();
                    final_hasher.update(first);
                    final_hasher.update(&md5.salt);
                    final_hasher.final(&final_hash);
                    const final = std.fmt.bufPrint(&final_hash_text, "{x}", .{&final_hash}) catch unreachable;
                    const password = std.mem.printSentinel(&password_buffer, "md5{s}", .{final}, 0) catch unreachable;
                    var response = protocol.PasswordMessage{ .password = .{ .temporary = password } };
                    this.authentication_state = .{ .md5 = {} };
                    try response.writeInternal(Writer, this.writer());
                    this.flushData();
                },
                else => Integration.fail(this.owner(), "Unsupported authentication method", error.UNSUPPORTED_AUTHENTICATION_METHOD),
            }
        }

        fn onErrorResponse(this: *PostgresConnection, reader: protocol.PayloadReader) AnyPostgresError!void {
            var err: protocol.ErrorResponse = undefined;
            try err.decode(reader);

            if (this.status == .connecting or this.status == .sent_startup_message) {
                defer err.deinit();
                Integration.connectionError(this.owner(), &err);
                bun.assert(this.requests.count == 0);
                return;
            }

            const request = this.current() orelse {
                err.deinit();
                return error.ExpectedRequest;
            };
            var is_error_owned = true;
            defer if (is_error_owned) err.deinit();
            if (request.getStatement()) |statement| {
                if (statement.status == .parsing) {
                    statement.status = .failed;
                    statement.error_response = .{ .protocol = err };
                    is_error_owned = false;
                    if (this.statements.remove(bun.hash(statement.signature.name))) statement.deref();
                }
            }
            this.finishRequest(request);
            Integration.updateRef(this.owner());
            Integration.queryFailed(this.owner(), request, .{ .protocol = err });
        }

        const PreparedStatementsMap = std.HashMapUnmanaged(u64, *PostgresSQLStatement, bun.IdentityContext(u64), 80);
        const MAX_PIPELINE_SIZE = std.math.maxInt(u16);
        const debug = bun.Output.scoped(.Postgres, .visible);

        const PostgresRequest = @import("./PostgresRequest.zig");
        const PostgresSQLStatement = @import("./PostgresSQLStatement.zig");
        const SocketMonitor = @import("../../sql/postgres/SocketMonitor.zig");
        const protocol = @import("../../sql/postgres/PostgresProtocol.zig");
        const AuthenticationState = @import("./AuthenticationState.zig").AuthenticationState;
        const ConnectionFlags = @import("../../sql/shared/ConnectionFlags.zig").ConnectionFlags;
        const Data = @import("../../sql/shared/Data.zig").Data;
        const SSLMode = @import("../../sql/postgres/SSLMode.zig").SSLMode;
        const Status = @import("../../sql/postgres/Status.zig").Status;
        const TLSStatus = @import("../../sql/postgres/TLSStatus.zig").TLSStatus;
        const AnyPostgresError = @import("../../sql/postgres/AnyPostgresError.zig").AnyPostgresError;
        const SSLConfig = @import("../../runtime/socket/SSLConfig.zig");

        const std = @import("std");
        const bun = @import("bun");
        const BoringSSL = bun.BoringSSL;
        const uws = bun.uws;
        const Socket = uws.AnySocket;
    };
}
