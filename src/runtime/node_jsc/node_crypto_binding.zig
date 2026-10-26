fn scheduleWithDiagnostic(comptime operation: []const u8, job: anytype, background_tasks: *bun.BackgroundTaskGroup) void {
    bun.BackgroundWork.schedule(background_tasks, &job.task) catch |err| {
        defer job.deinit();
        var buffer: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Failed to start {s}: {s}", .{ operation, @errorName(err) }) catch unreachable;
        const message = bun.bindgen.ThreadSafeDOMString.fromUTF8(text) catch {
            job.completion.outOfMemory();
            return;
        };
        job.completion.fail(.schedule_failed, message);
    };
}

const random = struct {
    const max_range = 0xffff_ffff_ffff;

    const Region = struct {
        offset: usize,
        length: usize,
    };

    const RandomFillAttachment = struct {
        lease: bun.bindgen.OwnedMutableLease(u8),
        offset: usize,

        pub fn deinit(attachment: *@This()) void {
            attachment.lease.deinit();
        }
    };

    const RandomBytesJob = struct {
        const Self = @This();

        output: bun.bindgen.OwnedBytes,
        completion: bun.bindgen.OwnedCompletion(RandomBytesAsyncSchema),
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
            scheduleWithDiagnostic("random byte generation", job, background_tasks);
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *Self = @fieldParentPtr("task", task);
            bun.csprng(job.output.mutableSlice());
            job.completion.resolve(job.output.take());
            job.deinit();
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *Self = @fieldParentPtr("task", task);
            job.completion.release();
            job.deinit();
        }

        fn deinit(job: *Self) void {
            job.output.deinit();
            bun.destroy(job);
        }
    };

    const RandomFillJob = struct {
        const Self = @This();

        output: []u8,
        completion: Completion.Owned,
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        const CompletionOps = struct {
            pub fn materialize(
                comptime FunctionSchema: type,
                _: bun.bindgen.MaterializationContext(FunctionSchema),
                attachment: *RandomFillAttachment,
                job: *Self,
            ) void {
                if (!attachment.lease.write(attachment.offset, job.output)) unreachable;
            }

            pub const destroyPayload = Self.deinit;

            pub fn destroyAttachment(attachment: *RandomFillAttachment) void {
                attachment.deinit();
            }
        };

        const Completion = bun.bindgen.MaterializedCompletion(
            RandomFillSchema,
            Self,
            RandomFillAttachment,
            CompletionOps,
        );

        pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
            scheduleWithDiagnostic("random buffer fill", job, background_tasks);
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *Self = @fieldParentPtr("task", task);
            bun.csprng(job.output);
            job.completion.complete(job);
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *Self = @fieldParentPtr("task", task);
            job.completion.release();
            job.deinit();
        }

        fn deinit(job: *Self) void {
            bun.default_allocator.free(job.output);
            bun.destroy(job);
        }
    };

    fn randomInt(
        context: bun.bindgen.CallContext(RandomIntSchema),
        args: bun.bindgen.Args(RandomIntSchema),
    ) bun.bindgen.CallError(RandomIntSchema)!i64 {
        _ = args.callback;

        if (args.max <= args.min) {
            const message = try std.fmt.allocPrint(
                bun.default_allocator,
                "The value of max must be greater than min ({d}). Received {d}",
                .{ args.min, args.max },
            );
            defer bun.default_allocator.free(message);
            return context.fail(.out_of_range, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
        }

        const difference = args.max - args.min;
        if (difference > max_range) {
            const message = try std.fmt.allocPrint(
                bun.default_allocator,
                "The value of max - min must be no greater than {d}. Received {d}",
                .{ max_range, difference },
            );
            defer bun.default_allocator.free(message);
            return context.fail(.out_of_range, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
        }

        const range: u64 = @intCast(difference);
        const rejection_limit = std.math.maxInt(u64) - (std.math.maxInt(u64) % range);
        var random_value: u64 = undefined;
        while (true) {
            bun.csprng(std.mem.asBytes(&random_value));
            if (random_value < rejection_limit) break;
        }
        return args.min + @as(i64, @intCast(random_value % range));
    }

    fn randomUUID(
        _: bun.bindgen.CallContext(RandomUUIDSchema),
        args: bun.bindgen.Args(RandomUUIDSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        const disable_entropy_cache = if (args.options) |options|
            options.disable_entropy_cache orelse false
        else
            false;

        const str, var bytes = String.createUninitialized(.latin1, 36);

        const uuid = if (disable_entropy_cache)
            UUID.init()
        else
            bun.current_runtime.nextUUID();

        uuid.print(bytes[0..36]);
        return bun.bindgen.DOMString.fromBunString(str);
    }

    fn region(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        offset_value: ?i64,
        size_value: ?i64,
        element_size: usize,
        byte_length: usize,
    ) bun.bindgen.CallError(Schema)!Region {
        const max_offset = byte_length / element_size;
        const offset_units: usize = @intCast(offset_value orelse 0);
        if (offset_units > max_offset) {
            const message = try std.fmt.allocPrint(
                bun.default_allocator,
                "The value of offset must be no greater than {d}. Received {d}",
                .{ max_offset, offset_units },
            );
            defer bun.default_allocator.free(message);
            return context.fail(.out_of_range, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
        }

        const offset = offset_units * element_size;
        const remaining = byte_length - offset;
        if (size_value) |raw_size| {
            const size_units: usize = @intCast(raw_size);
            const max_size = remaining / element_size;
            if (size_units > max_size) {
                const message = try std.fmt.allocPrint(
                    bun.default_allocator,
                    "The value of size must be no greater than {d}. Received {d}",
                    .{ max_size, size_units },
                );
                defer bun.default_allocator.free(message);
                return context.fail(.out_of_range, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
            }
            return .{ .offset = offset, .length = size_units * element_size };
        }

        return .{ .offset = offset, .length = remaining };
    }

    fn randomBytes(
        _: bun.bindgen.CallContext(RandomBytesSchema),
        args: bun.bindgen.Args(RandomBytesSchema),
    ) bun.bindgen.CallError(RandomBytesSchema)!bun.bindgen.OwnedBytes {
        var output = try bun.bindgen.OwnedBytes.initUninitialized(@intCast(args.size));
        bun.csprng(output.mutableSlice());
        return output;
    }

    fn randomBytesAsync(
        context: bun.bindgen.CallContext(RandomBytesAsyncSchema),
        args: bun.bindgen.Args(RandomBytesAsyncSchema),
    ) bun.bindgen.CallError(RandomBytesAsyncSchema)!void {
        const job = bun.default_allocator.create(RandomBytesJob) catch return error.OutOfMemory;
        errdefer bun.default_allocator.destroy(job);

        var output = try bun.bindgen.OwnedBytes.initUninitialized(@intCast(args.size));
        errdefer output.deinit();
        var completion = context.completion();
        const owned_completion = completion.take();

        job.* = .{
            .output = output.take(),
            .completion = owned_completion,
        };
        job.schedule(bun.current_runtime.backgroundTasks());
    }

    fn randomFillSync(
        context: bun.bindgen.CallContext(RandomFillSyncSchema),
        args: bun.bindgen.Args(RandomFillSyncSchema),
    ) bun.bindgen.CallError(RandomFillSyncSchema)!bun.bindgen.Return(RandomFillSyncSchema) {
        const bytes = args.buf.unsafeMutPtr("the generated entry frame owns the destination lease until randomFillSync finishes writing");
        const fill_region = try region(
            RandomFillSyncSchema,
            context,
            args.offset,
            args.size,
            args.buf.elementSize(),
            bytes.len,
        );
        bun.csprng(bytes[fill_region.offset..][0..fill_region.length]);
        return args.buf.source();
    }

    fn randomFill(
        context: bun.bindgen.CallContext(RandomFillSchema),
        args: bun.bindgen.Args(RandomFillSchema),
    ) bun.bindgen.CallError(RandomFillSchema)!void {
        const fill_region = try region(
            RandomFillSchema,
            context,
            args.offset,
            args.size,
            args.buf.elementSize(),
            args.buf.length(),
        );

        const job = bun.default_allocator.create(RandomFillJob) catch return error.OutOfMemory;
        errdefer bun.default_allocator.destroy(job);
        const output = try bun.default_allocator.alloc(u8, fill_region.length);
        errdefer bun.default_allocator.free(output);

        const lease = try args.buf.toOwned();
        var completion = context.completion();
        const owned_completion = RandomFillJob.Completion.take(&completion, .{
            .lease = lease,
            .offset = fill_region.offset,
        }) catch return error.OutOfMemory;

        job.* = .{
            .output = output,
            .completion = owned_completion,
        };
        job.schedule(bun.current_runtime.backgroundTasks());
    }
};

const NodeCryptoInput = union(enum) {
    buffer: []const u8,
    string: bun.String.Slice,
    owned: bun.bindgen.OwnedBytes,

    fn init(value: anytype) bun.OOM!NodeCryptoInput {
        return switch (value.*) {
            .buffer => |*bytes| .{
                .buffer = if (comptime @hasDecl(@TypeOf(bytes.*), "unsafePtr"))
                    bytes.unsafePtr("the generated entry frame owns the converted buffer until the synchronous crypto operation consumes or copies its bytes")
                else
                    bytes.slice(),
            },
            .string => |*text| .{ .string = try text.toUTF8(bun.default_allocator) },
        };
    }

    fn slice(input: *const NodeCryptoInput) []const u8 {
        return switch (input.*) {
            .buffer => |bytes| bytes,
            .string => |*text| text.slice(),
            .owned => |*bytes| bytes.slice(),
        };
    }

    fn deinit(input: *NodeCryptoInput) void {
        switch (input.*) {
            .buffer => {},
            .string => |*text| text.deinit(),
            .owned => |*bytes| bytes.deinit(),
        }
    }

    fn initSecret(context: anytype, value: anytype) bun.JSError!NodeCryptoInput {
        return switch (value.*) {
            .buffer => |*bytes| .{ .buffer = bytes.unsafePtr("the generated binding frame owns the copied key until HKDF copies it") },
            .string => |*text| .{ .string = try text.toUTF8(bun.default_allocator) },
            .key_object => |key| result: {
                const operation = context.engineIn("node_crypto_engine", "nodeCryptoExportSecretKey");
                break :result .{ .owned = try operation.call(.{ .key = operation.argument("key", key) }) };
            },
        };
    }
};

fn createHkdfContext(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    backend: NodeCryptoBackend.Backend,
    args: bun.bindgen.Args(Schema),
) bun.bindgen.CallError(Schema)!HkdfOwnedContext {
    var key = try NodeCryptoInput.initSecret(context, &args.ikm);
    defer key.deinit();
    const converted_salt = try args.salt.convert(context);
    const converted_info = try args.info.convert(context);
    const length = if (comptime @hasField(@TypeOf(args), "callback")) length: {
        const converted_length = try args.length.convert(context);
        const callback = try args.callback.convertLast(context);
        try context.lease(callback.proof);
        break :length converted_length.value;
    } else length: {
        const converted_length = try args.length.convertLast(context);
        try context.lease(converted_length.proof);
        break :length converted_length.converted.value;
    };

    var info = try NodeCryptoInput.init(&converted_info.value);
    defer info.deinit();
    if (info.slice().len > 1024) {
        const message = try std.fmt.allocPrint(
            bun.default_allocator,
            "The value of \"info\" is out of range. It must not contain more than 1024 bytes. Received {d}",
            .{info.slice().len},
        );
        defer bun.default_allocator.free(message);
        return context.fail(.info_too_long, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
    }

    const digest = try context.engineIn("node_crypto_engine", "nodeCryptoResolveDigest").call(.{ .name = args.digest.operand() });
    const digest_size = backend.digestSize(digest);
    if (length > digest_size * 255)
        return context.fail(.invalid_key_length, {});

    var salt = try NodeCryptoInput.init(&converted_salt.value);
    defer salt.deinit();
    return backend.createHkdf(
        digest,
        key.slice(),
        salt.slice(),
        info.slice(),
        length,
    );
}

fn ContextJob(comptime Schema: type, comptime Context: type, comptime run_context: anytype, comptime take_result: anytype) type {
    const Result = bun.bindgen.Return(Schema);
    if (Result != bool and Result != bun.bindgen.OwnedBytes) @compileError("context jobs require a boolean or owned byte result");
    return struct {
        const Self = @This();

        backend: NodeCryptoBackend.Backend,
        context: Context,
        completion: bun.bindgen.OwnedCompletion(Schema),
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        pub fn start(context: bun.bindgen.CallContext(Schema), backend: NodeCryptoBackend.Backend, engine_context: *Context) bun.OOM!void {
            const job = try bun.default_allocator.create(Self);
            var completion = context.completion();
            job.* = .{
                .backend = backend,
                .context = engine_context.take(),
                .completion = completion.take(),
            };
            bun.BackgroundWork.schedule(bun.current_runtime.backgroundTasks(), &job.task) catch {
                job.completion.fail(.operation_failed, {});
                job.deinit();
            };
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *Self = @fieldParentPtr("task", task);
            defer job.deinit();
            run_context(job.backend, &job.context);
            const result = (take_result(job.backend, &job.context) catch {
                job.completion.outOfMemory();
                return;
            }) orelse {
                job.completion.fail(.operation_failed, {});
                return;
            };
            job.completion.resolve(result);
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *Self = @fieldParentPtr("task", task);
            job.completion.release();
            job.deinit();
        }

        fn deinit(job: *Self) void {
            job.context.deinit();
            bun.default_allocator.destroy(job);
        }
    };
}

const HkdfJob = ContextJob(HkdfSchema, HkdfOwnedContext, NodeCryptoBackend.Backend.runHkdf, NodeCryptoBackend.Backend.takeHkdfResult);

fn hkdf(
    context: bun.bindgen.CallContext(HkdfSchema),
    args: bun.bindgen.Args(HkdfSchema),
) bun.bindgen.CallError(HkdfSchema)!void {
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createHkdfContext(HkdfSchema, context, backend, args);
    errdefer engine_context.deinit();

    try HkdfJob.start(context, backend, &engine_context);
}

fn hkdfSync(
    context: bun.bindgen.CallContext(HkdfSyncSchema),
    args: bun.bindgen.Args(HkdfSyncSchema),
) bun.bindgen.CallError(HkdfSyncSchema)!bun.bindgen.OwnedBytes {
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createHkdfContext(HkdfSyncSchema, context, backend, args);
    defer engine_context.deinit();

    backend.runHkdf(&engine_context);
    return (try backend.takeHkdfResult(&engine_context)) orelse
        return context.fail(.operation_failed, {});
}

fn createCheckPrimeContext(backend: NodeCryptoBackend.Backend, args: anytype) bun.OOM!CheckPrimeOwnedContext {
    return backend.createCheckPrime(
        args.candidate.unsafePtr("the generated entry frame owns the candidate bytes until the check-prime context copies them"),
        if (args.options) |options| options.checks orelse 0 else 0,
    );
}

const CheckPrimeJob = ContextJob(CheckPrimeSchema, CheckPrimeOwnedContext, NodeCryptoBackend.Backend.runCheckPrime, NodeCryptoBackend.Backend.takeCheckPrimeResult);

fn checkPrime(
    context: bun.bindgen.CallContext(CheckPrimeSchema),
    args: bun.bindgen.Args(CheckPrimeSchema),
) bun.bindgen.CallError(CheckPrimeSchema)!void {
    _ = args.callback;
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createCheckPrimeContext(backend, args);
    errdefer engine_context.deinit();

    try CheckPrimeJob.start(context, backend, &engine_context);
}

fn checkPrimeSync(
    context: bun.bindgen.CallContext(CheckPrimeSyncSchema),
    args: bun.bindgen.Args(CheckPrimeSyncSchema),
) bun.bindgen.CallError(CheckPrimeSyncSchema)!bool {
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createCheckPrimeContext(backend, args);
    defer engine_context.deinit();

    backend.runCheckPrime(&engine_context);
    return (try backend.takeCheckPrimeResult(&engine_context)) orelse
        return context.fail(.operation_failed, {});
}

const PreparedGeneratePrime = struct {
    backend: NodeCryptoBackend.Backend,
    context: GeneratePrimeOwnedContext,
    bigint: bool,
};

fn createGeneratePrimeContext(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    args: bun.bindgen.Args(Schema),
) bun.bindgen.CallError(Schema)!PreparedGeneratePrime {
    const backend = bun.current_runtime.nodeCryptoBackend();
    const safe = if (args.options) |options| options.safe else false;
    const bigint = if (args.options) |options| options.bigint else false;
    const add = if (args.options) |options|
        if (options.add) |value| value.unsafePtr("the generated entry frame owns options.add until the generate-prime context copies it") else null
    else
        null;
    const rem = if (args.options) |options|
        if (options.rem) |value| value.unsafePtr("the generated entry frame owns options.rem until the generate-prime context copies it") else null
    else
        null;

    var engine_context = try backend.createGeneratePrime(args.size, safe, add, rem);
    errdefer engine_context.deinit();

    switch (backend.generatePrimeStatus(&engine_context)) {
        .success => {},
        .invalid_add => return context.fail(.invalid_add, {}),
        .invalid_rem => return context.fail(.invalid_rem, {}),
        .operation_failed => return context.fail(.operation_failed, {}),
    }

    return .{
        .backend = backend,
        .context = engine_context.take(),
        .bigint = bigint,
    };
}

const GeneratePrimeJob = struct {
    const Self = @This();

    backend: NodeCryptoBackend.Backend,
    context: GeneratePrimeOwnedContext,
    bigint: bool,
    completion: bun.bindgen.OwnedCompletion(GeneratePrimeSchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &job.task) catch {
            job.completion.fail(.operation_failed, {});
            job.deinit();
        };
    }

    fn run(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        defer job.deinit();

        job.backend.runGeneratePrime(&job.context);
        var result = (job.backend.takeGeneratePrimeResult(&job.context) catch {
            job.completion.outOfMemory();
            return;
        }) orelse {
            job.completion.fail(.operation_failed, {});
            return;
        };
        defer result.deinit();
        job.completion.resolve(.{
            .bytes = result.take(),
            .bigint = job.bigint,
        });
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        job.completion.release();
        job.deinit();
    }

    fn deinit(job: *Self) void {
        job.context.deinit();
        bun.default_allocator.destroy(job);
    }
};

fn generatePrime(
    context: bun.bindgen.CallContext(GeneratePrimeSchema),
    args: bun.bindgen.Args(GeneratePrimeSchema),
) bun.bindgen.CallError(GeneratePrimeSchema)!void {
    _ = args.callback;
    var prepared = try createGeneratePrimeContext(GeneratePrimeSchema, context, args);
    errdefer prepared.context.deinit();

    const job = bun.default_allocator.create(GeneratePrimeJob) catch return error.OutOfMemory;
    var completion = context.completion();
    job.* = .{
        .backend = prepared.backend,
        .context = prepared.context.take(),
        .bigint = prepared.bigint,
        .completion = completion.take(),
    };
    job.schedule(bun.current_runtime.backgroundTasks());
}

fn generatePrimeSync(
    context: bun.bindgen.CallContext(GeneratePrimeSyncSchema),
    args: bun.bindgen.Args(GeneratePrimeSyncSchema),
) bun.bindgen.CallError(GeneratePrimeSyncSchema)!bun.bindgen.Return(GeneratePrimeSyncSchema) {
    var prepared = try createGeneratePrimeContext(GeneratePrimeSyncSchema, context, args);
    defer prepared.context.deinit();

    prepared.backend.runGeneratePrime(&prepared.context);
    const result = (try prepared.backend.takeGeneratePrimeResult(&prepared.context)) orelse
        return context.fail(.operation_failed, {});
    return .{
        .bytes = result,
        .bigint = prepared.bigint,
    };
}

fn generateKeyLength(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    args: bun.bindgen.Args(Schema),
) bun.bindgen.CallError(Schema)!usize {
    return switch (args.type) {
        .hmac => @intCast(@divFloor(args.options.length, 8)),
        .aes => switch (args.options.length) {
            128, 192, 256 => @intCast(@divExact(args.options.length, 8)),
            else => context.fail(.invalid_aes_length, {}),
        },
    };
}

const GenerateKeyJob = struct {
    const Self = @This();

    output: []u8,
    completion: bun.bindgen.OwnedCompletion(GenerateKeySchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &job.task) catch {
            job.completion.fail(.operation_failed, {});
            job.deinit();
        };
    }

    fn run(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        defer job.deinit();

        if (BoringSSL.RAND_bytes(job.output.ptr, job.output.len) != 1) {
            BoringSSL.ERR_clear_error();
            job.completion.fail(.operation_failed, {});
            return;
        }

        const output = bun.bindgen.OwnedBytes.fromSlice(job.output) catch {
            job.completion.outOfMemory();
            return;
        };
        job.completion.resolve(output);
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        job.completion.release();
        job.deinit();
    }

    fn deinit(job: *Self) void {
        if (job.output.len > 0)
            bun.freeSensitive(bun.default_allocator, job.output);
        bun.default_allocator.destroy(job);
    }
};

fn generateKey(
    context: bun.bindgen.CallContext(GenerateKeySchema),
    args: bun.bindgen.Args(GenerateKeySchema),
) bun.bindgen.CallError(GenerateKeySchema)!void {
    _ = args.callback;
    const length = try generateKeyLength(GenerateKeySchema, context, args);
    const output = bun.default_allocator.alloc(u8, length) catch return error.OutOfMemory;
    errdefer bun.freeSensitive(bun.default_allocator, output);

    const job = bun.default_allocator.create(GenerateKeyJob) catch return error.OutOfMemory;
    var completion = context.completion();
    job.* = .{
        .output = output,
        .completion = completion.take(),
    };
    job.schedule(bun.current_runtime.backgroundTasks());
}

fn generateKeySync(
    context: bun.bindgen.CallContext(GenerateKeySyncSchema),
    args: bun.bindgen.Args(GenerateKeySyncSchema),
) bun.bindgen.CallError(GenerateKeySyncSchema)!bun.bindgen.OwnedBytes {
    const length = try generateKeyLength(GenerateKeySyncSchema, context, args);
    const output = bun.default_allocator.alloc(u8, length) catch return error.OutOfMemory;
    defer bun.freeSensitive(bun.default_allocator, output);

    if (BoringSSL.RAND_bytes(output.ptr, output.len) != 1) {
        BoringSSL.ERR_clear_error();
        return context.fail(.operation_failed, {});
    }
    return bun.bindgen.OwnedBytes.fromSlice(output);
}

fn createDiffieHellmanContext(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    args: bun.bindgen.Args(Schema),
) bun.bindgen.CallError(Schema)!DiffieHellmanOwnedContext {
    return (try context.engineIn("node_crypto_engine", "nodeCryptoDiffieHellmanCreate").call(.{
        .private_key = args.options.private_key.operand(context),
        .public_key = args.options.public_key.operand(context),
    })) orelse context.fail(.key_type_mismatch, {});
}

const DiffieHellmanJob = ContextJob(DiffieHellmanSchema, DiffieHellmanOwnedContext, NodeCryptoBackend.Backend.runDiffieHellman, NodeCryptoBackend.Backend.takeDiffieHellmanResult);

fn diffieHellman(
    context: bun.bindgen.CallContext(DiffieHellmanSchema),
    args: bun.bindgen.Args(DiffieHellmanSchema),
) bun.bindgen.CallError(DiffieHellmanSchema)!void {
    _ = args.callback;
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createDiffieHellmanContext(DiffieHellmanSchema, context, args);
    errdefer engine_context.deinit();

    try DiffieHellmanJob.start(context, backend, &engine_context);
}

fn diffieHellmanSync(
    context: bun.bindgen.CallContext(DiffieHellmanSyncSchema),
    args: bun.bindgen.Args(DiffieHellmanSyncSchema),
) bun.bindgen.CallError(DiffieHellmanSyncSchema)!bun.bindgen.OwnedBytes {
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createDiffieHellmanContext(DiffieHellmanSyncSchema, context, args);
    defer engine_context.deinit();

    backend.runDiffieHellman(&engine_context);
    return (try backend.takeDiffieHellmanResult(&engine_context)) orelse
        context.fail(.operation_failed, {});
}

const signOneShot = SignatureOperation(false).call;
const signOneShotSync = SignatureOperation(false).callSync;
const verifyOneShot = SignatureOperation(true).call;
const verifyOneShotSync = SignatureOperation(true).callSync;

fn SignatureOperation(comptime verify: bool) type {
    return struct {
        const AsyncSchema = if (verify) VerifyOneShotSchema else SignOneShotSchema;
        const SyncSchema = if (verify) VerifyOneShotSyncSchema else SignOneShotSyncSchema;
        const Result = bun.bindgen.Return(SyncSchema);

        fn createContext(comptime Schema: type, context: bun.bindgen.CallContext(Schema), args: bun.bindgen.Args(Schema)) bun.JSError!SignOwnedContext {
            var data = try NodeCryptoInput.init(&args.data);
            defer data.deinit();
            const digest = if (args.algorithm) |name|
                try context.engineIn("node_crypto_engine", "nodeCryptoResolveDigest").call(.{ .name = name.operand() })
            else
                null;
            const key = try args.key.convert(context);
            const operation = context.engineIn("node_crypto_engine", if (verify) "nodeCryptoVerifyCreate" else "nodeCryptoSignCreate");
            const source = if (verify) .{ .key = key.value, .signature = args.signature } else .{ .key = key.value };
            return operation.callForwarded(source, .{
                .digest = digest,
                .data = bun.bindgen.BytesOperand.fromSlice(data.slice()),
            });
        }

        fn takeResult(backend: NodeCryptoBackend.Backend, context: *SignOwnedContext) bun.OOM!?Result {
            return if (verify) backend.takeVerifyResult(context) else backend.takeSignResult(context);
        }

        const Job = ContextJob(AsyncSchema, SignOwnedContext, NodeCryptoBackend.Backend.runSign, takeResult);

        fn call(context: bun.bindgen.CallContext(AsyncSchema), args: bun.bindgen.Args(AsyncSchema)) bun.bindgen.CallError(AsyncSchema)!void {
            const backend = bun.current_runtime.nodeCryptoBackend();
            var engine_context = try createContext(AsyncSchema, context, args);
            errdefer engine_context.deinit();
            try Job.start(context, backend, &engine_context);
        }

        fn callSync(context: bun.bindgen.CallContext(SyncSchema), args: bun.bindgen.Args(SyncSchema)) bun.bindgen.CallError(SyncSchema)!Result {
            const backend = bun.current_runtime.nodeCryptoBackend();
            var engine_context = try createContext(SyncSchema, context, args);
            defer engine_context.deinit();
            backend.runSign(&engine_context);
            return (try takeResult(backend, &engine_context)) orelse context.fail(.operation_failed, {});
        }
    };
}

const KeyPairJob = struct {
    const Self = @This();

    backend: NodeCryptoBackend.Backend,
    context: KeyPairOwnedContext,
    completion: Completion.Owned,
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    const CompletionOps = struct {
        pub fn materialize(
            comptime FunctionSchema: type,
            context: bun.bindgen.MaterializationContext(FunctionSchema),
            job: *Self,
        ) bun.bindgen.CallError(FunctionSchema)!bun.bindgen.Return(FunctionSchema) {
            return try context.engineIn("node_crypto_engine", "nodeCryptoKeyPairResult").call(.{
                .job = &job.context,
            });
        }

        pub const destroyPayload = Self.deinit;

    };

    const Completion = bun.bindgen.MaterializedCompletion(
        GenerateKeyPairSchema,
        Self,
        void,
        CompletionOps,
    );

    pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
        bun.BackgroundWork.schedule(background_tasks, &job.task) catch {
            job.completion.fail(.operation_failed, {});
            job.deinit();
        };
    }

    fn run(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        job.backend.runKeyPair(&job.context) catch {
            job.completion.outOfMemory();
            job.deinit();
            return;
        };
        job.completion.complete(job);
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        job.completion.release();
        job.deinit();
    }

    fn deinit(job: *Self) void {
        job.context.deinit();
        bun.default_allocator.destroy(job);
    }
};

fn createKeyPairContext(comptime Schema: type, context: bun.bindgen.CallContext(Schema), args: bun.bindgen.Args(Schema)) bun.JSError!KeyPairOwnedContext {
    const request = if (Schema == GenerateKeyPairSchema)
        (try args.request.convert(context)).value
    else
        args.request;
    const operation = context.engineIn("node_crypto_engine", "nodeCryptoKeyPairCreate");
    return operation.call(.{ .request = operation.argument("request", request) });
}

fn generateKeyPair(
    context: bun.bindgen.CallContext(GenerateKeyPairSchema),
    args: bun.bindgen.Args(GenerateKeyPairSchema),
) bun.bindgen.CallError(GenerateKeyPairSchema)!void {
    _ = args.callback;
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createKeyPairContext(GenerateKeyPairSchema, context, args);
    errdefer engine_context.deinit();

    const job = bun.default_allocator.create(KeyPairJob) catch return error.OutOfMemory;
    errdefer bun.default_allocator.destroy(job);
    var completion = context.completion();
    const owned_completion = KeyPairJob.Completion.take(&completion, {}) catch return error.OutOfMemory;
    job.* = .{
        .backend = backend,
        .context = engine_context.take(),
        .completion = owned_completion,
    };
    job.schedule(bun.current_runtime.backgroundTasks());
}

fn generateKeyPairSync(
    context: bun.bindgen.CallContext(GenerateKeyPairSyncSchema),
    args: bun.bindgen.Args(GenerateKeyPairSyncSchema),
) bun.bindgen.CallError(GenerateKeyPairSyncSchema)!bun.bindgen.Return(GenerateKeyPairSyncSchema) {
    const backend = bun.current_runtime.nodeCryptoBackend();
    var engine_context = try createKeyPairContext(GenerateKeyPairSyncSchema, context, args);
    defer engine_context.deinit();

    try backend.runKeyPair(&engine_context);
    return context.engineIn("node_crypto_engine", "nodeCryptoKeyPairResult").call(.{
        .job = &engine_context,
    });
}

fn pbkdf2Digest(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    argument: anytype,
) bun.bindgen.CallError(Schema)!*const BoringSSL.EVP_MD {
    const converted = try argument.convert(context);
    var digest_name = try converted.value.toUTF8(bun.default_allocator);
    defer digest_name.deinit();
    const name = digest_name.slice();

    if (EVP.Algorithm.map.getWithEql(name, bun.strings.eqlCaseInsensitiveASCIIIgnoreLength)) |algorithm| {
        if (PBKDF2.resolveDigest(algorithm)) |digest| return digest;
    }

    const message = try std.fmt.allocPrint(bun.default_allocator, "Invalid digest: {s}", .{name});
    defer bun.default_allocator.free(message);
    return context.fail(.invalid_digest, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
}

fn pbkdf2OwnedInput(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    argument: anytype,
    comptime too_long: anytype,
) bun.bindgen.CallError(Schema)![]u8 {
    const converted = try argument.convert(context);
    var input = try NodeCryptoInput.init(&converted.value);
    defer input.deinit();
    if (input.slice().len > std.math.maxInt(i32)) return context.fail(too_long, {});
    return bun.default_allocator.dupe(u8, input.slice());
}

fn boringSSLErrorMessage(comptime StringType: type, error_code: u32) bun.OOM!StringType {
    var openssl_buffer: [129]u8 = @splat(0);
    _ = BoringSSL.ERR_error_string_n(error_code, &openssl_buffer, openssl_buffer.len);
    const openssl_message = std.mem.sliceTo(&openssl_buffer, 0);

    var message_buffer: [192]u8 = undefined;
    const message = if (openssl_message.len == 0)
        std.fmt.bufPrint(&message_buffer, "An unknown BoringSSL error occurred: {d}", .{error_code}) catch unreachable
    else
        std.fmt.bufPrint(&message_buffer, "BoringSSL {s}", .{openssl_message}) catch unreachable;
    return StringType.fromUTF8(message);
}

const PBKDF2Job = struct {
    const Self = @This();

    password: []u8,
    salt: []u8,
    iteration_count: u32,
    length: u32,
    digest: *const BoringSSL.EVP_MD,
    completion: bun.bindgen.OwnedCompletion(PBKDF2Schema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
        scheduleWithDiagnostic("PBKDF2 operation", job, background_tasks);
    }

    fn run(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        defer job.deinit();
        const output = bun.default_allocator.alloc(u8, job.length) catch {
            job.completion.outOfMemory();
            return;
        };
        if (!PBKDF2.run(output, job.password, job.salt, job.iteration_count, job.digest)) {
            defer bun.freeSensitive(bun.default_allocator, output);
            const error_code = BoringSSL.ERR_get_error();
            BoringSSL.ERR_clear_error();
            if (error_code == 0) {
                job.completion.fail(.derivation_failed, {});
            } else {
                const message = boringSSLErrorMessage(bun.bindgen.ThreadSafeDOMString, error_code) catch {
                    job.completion.outOfMemory();
                    return;
                };
                job.completion.fail(.boring_ssl_error, message);
            }
            return;
        }
        job.completion.resolve(bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(output));
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        job.completion.release();
        job.deinit();
    }

    fn deinit(job: *Self) void {
        bun.freeSensitive(bun.default_allocator, job.password);
        bun.freeSensitive(bun.default_allocator, job.salt);
        bun.destroy(job);
    }
};

fn pbkdf2(
    context: bun.bindgen.CallContext(PBKDF2Schema),
    args: bun.bindgen.Args(PBKDF2Schema),
) bun.bindgen.CallError(PBKDF2Schema)!void {
    const keylen: u32 = @intCast(args.keylen);

    const converted_iterations = try args.iterations.convert(context);
    const iteration_count: u32 = @intCast(converted_iterations.value);

    const digest = try pbkdf2Digest(PBKDF2Schema, context, args.digest);
    const salt = try pbkdf2OwnedInput(PBKDF2Schema, context, args.salt, .salt_too_long);
    errdefer bun.freeSensitive(bun.default_allocator, salt);
    const password = try pbkdf2OwnedInput(PBKDF2Schema, context, args.password, .password_too_long);
    errdefer bun.freeSensitive(bun.default_allocator, password);

    try args.callback.validate(context);

    const job = bun.default_allocator.create(PBKDF2Job) catch {
        bun.freeSensitive(bun.default_allocator, password);
        bun.freeSensitive(bun.default_allocator, salt);
        var completion = context.completion();
        completion.outOfMemory();
        return;
    };
    var completion = context.completion();
    const owned_completion = completion.take();
    job.* = .{
        .password = password,
        .salt = salt,
        .iteration_count = iteration_count,
        .length = keylen,
        .digest = digest,
        .completion = owned_completion,
    };
    job.schedule(bun.current_runtime.backgroundTasks());
}

fn pbkdf2Sync(
    context: bun.bindgen.CallContext(PBKDF2SyncSchema),
    args: bun.bindgen.Args(PBKDF2SyncSchema),
) bun.bindgen.CallError(PBKDF2SyncSchema)!bun.bindgen.OwnedBytes {
    const keylen: u32 = @intCast(args.keylen);

    const converted_iterations = try args.iterations.convert(context);
    const iteration_count: u32 = @intCast(converted_iterations.value);

    const digest = try pbkdf2Digest(PBKDF2SyncSchema, context, args.digest);

    const converted_salt = try args.salt.convert(context);
    var salt = try NodeCryptoInput.init(&converted_salt.value);
    defer salt.deinit();
    if (salt.slice().len > std.math.maxInt(i32)) return context.fail(.salt_too_long, {});

    const converted_password = try args.password.convert(context);
    var password = try NodeCryptoInput.init(&converted_password.value);
    defer password.deinit();
    if (password.slice().len > std.math.maxInt(i32)) return context.fail(.password_too_long, {});

    const output = try bun.default_allocator.alloc(u8, keylen);
    errdefer bun.freeSensitive(bun.default_allocator, output);

    if (!PBKDF2.run(output, password.slice(), salt.slice(), iteration_count, digest)) {
        const err_code = BoringSSL.ERR_get_error();
        BoringSSL.ERR_clear_error();
        if (err_code == 0) return context.fail(.derivation_failed, {});
        return context.fail(
            .boring_ssl_error,
            try boringSSLErrorMessage(bun.bindgen.ThreadSafeDOMString, err_code),
        );
    }
    return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(output);
}

pub fn timingSafeEqual(
    context: bun.bindgen.CallContext(TimingSafeEqualSchema),
    args: bun.bindgen.Args(TimingSafeEqualSchema),
) bun.bindgen.CallError(TimingSafeEqualSchema)!bool {
    const l = args.buf1.unsafePtr("the generated entry frame owns the left buffer lease until BoringSSL finishes comparing bytes");
    const r = args.buf2.unsafePtr("the generated entry frame owns the right buffer lease until BoringSSL finishes comparing bytes");

    if (l.len != r.len) {
        return context.fail(.length_mismatch, {});
    }

    return BoringSSL.CRYPTO_memcmp(l.ptr, r.ptr, l.len) == 0;
}

pub fn secureHeapUsed(
    _: bun.bindgen.CallContext(SecureHeapUsedSchema),
    _: bun.bindgen.Args(SecureHeapUsedSchema),
) JSError!void {}

pub fn getFips(
    _: bun.bindgen.CallContext(GetFipsSchema),
    _: bun.bindgen.Args(GetFipsSchema),
) JSError!i32 {
    return 0;
}

pub fn setFips(
    _: bun.bindgen.CallContext(SetFipsSchema),
    _: bun.bindgen.Args(SetFipsSchema),
) JSError!void {}

pub fn setEngine(
    context: bun.bindgen.CallContext(SetEngineSchema),
    _: bun.bindgen.Args(SetEngineSchema),
) bun.bindgen.CallError(SetEngineSchema)!void {
    return context.fail(.custom_engine_not_supported, {});
}

fn forEachHash(_: *const BoringSSL.EVP_MD, maybe_from: ?[*:0]const u8, _: ?[*:0]const u8, ctx: *anyopaque) callconv(.c) void {
    const from = maybe_from orelse return;
    const hashes: *bun.CaseInsensitiveASCIIStringArrayHashMap(void) = @ptrCast(@alignCast(ctx));
    bun.handleOom(hashes.put(bun.default_allocator, bun.span(from), {}));
}

fn getHashes(
    _: bun.bindgen.CallContext(GetHashesSchema),
    _: bun.bindgen.Args(GetHashesSchema),
) JSError!bun.bindgen.Return(GetHashesSchema) {
    var hashes: bun.CaseInsensitiveASCIIStringArrayHashMap(void) = .empty;
    defer hashes.deinit(bun.default_allocator);

    // TODO(dylan-conway): cache the names
    BoringSSL.EVP_MD_do_all_sorted(&forEachHash, @ptrCast(@alignCast(&hashes)));

    return bun.bindgen.Return(GetHashesSchema).fromUTF8Slices(hashes.keys());
}

const ScryptParams = struct {
    N: u32 = 16_384,
    r: u32 = 8,
    p: u32 = 1,
    maxmem: u64 = 32 * 1024 * 1024,
    keylen: u32,
};

fn defaultScryptOption(comptime T: type, value: ?T, default: T) T {
    const resolved = value orelse return default;
    return if (resolved == 0) default else resolved;
}

fn scryptParams(options: anytype, keylen: u32) ScryptParams {
    var params: ScryptParams = .{ .keylen = keylen };
    switch (options.*) {
        .options => |values| {
            params.N = defaultScryptOption(u32, values.N orelse values.cost, params.N);
            params.r = defaultScryptOption(u32, values.r orelse values.block_size, params.r);
            params.p = defaultScryptOption(u32, values.p orelse values.parallelization, params.p);
            params.maxmem = @intCast(defaultScryptOption(i64, values.maxmem, @intCast(params.maxmem)));
        },
        .ignored => {},
    }
    return params;
}

fn scryptErrorMessage(
    comptime StringType: type,
    prefix: []const u8,
    error_code: u32,
) bun.OOM!StringType {
    if (error_code == 0) return StringType.fromUTF8(prefix);

    var openssl_buffer: [256]u8 = undefined;
    const openssl_message = BoringSSL.ERR_error_string_n(error_code, &openssl_buffer, openssl_buffer.len);
    var message_buffer: [320]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, "{s}: {s}", .{ prefix, openssl_message }) catch unreachable;
    return StringType.fromUTF8(message);
}

fn validateScryptParams(
    comptime Schema: type,
    context: bun.bindgen.CallContext(Schema),
    params: ScryptParams,
) bun.bindgen.CallError(Schema)!void {
    BoringSSL.ERR_clear_error();
    const valid = BoringSSL.EVP_PBE_validate_scrypt_params(
        null,
        0,
        null,
        0,
        params.N,
        params.r,
        params.p,
        params.maxmem,
        null,
        0,
    );
    if (valid != 0) {
        BoringSSL.ERR_clear_error();
        return;
    }

    const error_code = BoringSSL.ERR_peek_last_error();
    BoringSSL.ERR_clear_error();
    return context.fail(
        .invalid_params,
        try scryptErrorMessage(bun.bindgen.ThreadSafeDOMString, "Invalid scrypt params", error_code),
    );
}

fn runScrypt(
    output: []u8,
    password: []const u8,
    salt: []const u8,
    params: ScryptParams,
) ?u32 {
    if (output.len == 0) return null;
    if (password.len > std.math.maxInt(i32) or salt.len > std.math.maxInt(i32)) return 0;

    BoringSSL.ERR_clear_error();
    const result = BoringSSL.EVP_PBE_scrypt(
        password.ptr,
        password.len,
        salt.ptr,
        salt.len,
        params.N,
        params.r,
        params.p,
        params.maxmem,
        output.ptr,
        output.len,
    );
    if (result != 0) {
        BoringSSL.ERR_clear_error();
        return null;
    }

    const error_code = BoringSSL.ERR_peek_last_error();
    BoringSSL.ERR_clear_error();
    return error_code;
}

fn ownedNodeCryptoInput(value: anytype) bun.OOM![]u8 {
    var input = try NodeCryptoInput.init(value);
    defer input.deinit();
    return bun.default_allocator.dupe(u8, input.slice());
}

const ScryptJob = struct {
    const Self = @This();

    password: []u8,
    salt: []u8,
    params: ScryptParams,
    output: []u8,
    completion: bun.bindgen.OwnedCompletion(ScryptSchema),
    task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

    pub fn schedule(job: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
        scheduleWithDiagnostic("scrypt operation", job, background_tasks);
    }

    fn run(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        defer job.deinit();
        if (runScrypt(job.output, job.password, job.salt, job.params)) |error_code| {
            const message = scryptErrorMessage(
                bun.bindgen.ThreadSafeDOMString,
                "Scrypt failed",
                error_code,
            ) catch {
                job.completion.outOfMemory();
                return;
            };
            job.completion.fail(.operation_failed, message);
            return;
        }
        const output = bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(job.output);
        job.output = &.{};
        job.completion.resolve(output);
    }

    fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
        const job: *Self = @fieldParentPtr("task", task);
        job.completion.release();
        job.deinit();
    }

    fn deinit(job: *Self) void {
        bun.freeSensitive(bun.default_allocator, job.password);
        bun.freeSensitive(bun.default_allocator, job.salt);
        if (job.output.len > 0) bun.freeSensitive(bun.default_allocator, job.output);
        bun.destroy(job);
    }
};

fn scrypt(
    context: bun.bindgen.CallContext(ScryptSchema),
    args: bun.bindgen.Args(ScryptSchema),
) bun.bindgen.CallError(ScryptSchema)!void {
    const keylen: u32 = @intCast(args.keylen);
    const params = scryptParams(&args.options, keylen);
    try validateScryptParams(ScryptSchema, context, params);

    const password = try ownedNodeCryptoInput(&args.password);
    errdefer bun.freeSensitive(bun.default_allocator, password);
    const salt = try ownedNodeCryptoInput(&args.salt);
    errdefer bun.freeSensitive(bun.default_allocator, salt);

    if (keylen > bun.JavaScriptLimits.syntheticAllocationLimit()) return error.OutOfMemory;

    const output = try bun.default_allocator.alloc(u8, keylen);
    errdefer bun.freeSensitive(bun.default_allocator, output);
    const job = bun.default_allocator.create(ScryptJob) catch return error.OutOfMemory;
    errdefer bun.default_allocator.destroy(job);

    var completion = context.completion();
    const owned_completion = completion.take();

    job.* = .{
        .password = password,
        .salt = salt,
        .params = params,
        .output = output,
        .completion = owned_completion,
    };
    job.schedule(bun.current_runtime.backgroundTasks());
}

fn scryptSync(
    context: bun.bindgen.CallContext(ScryptSyncSchema),
    args: bun.bindgen.Args(ScryptSyncSchema),
) bun.bindgen.CallError(ScryptSyncSchema)!bun.bindgen.OwnedBytes {
    const keylen: u32 = @intCast(args.keylen);
    const params = scryptParams(&args.options, keylen);
    try validateScryptParams(ScryptSyncSchema, context, params);

    var password = try NodeCryptoInput.init(&args.password);
    defer password.deinit();
    var salt = try NodeCryptoInput.init(&args.salt);
    defer salt.deinit();

    const output = try bun.default_allocator.alloc(u8, keylen);
    errdefer bun.freeSensitive(bun.default_allocator, output);

    if (runScrypt(output, password.slice(), salt.slice(), params)) |error_code| {
        return context.fail(
            .operation_failed,
            try scryptErrorMessage(bun.bindgen.ThreadSafeDOMString, "Scrypt failed", error_code),
        );
    }

    return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(output);
}

const string = []const u8;

const std = @import("std");
const bun = @import("bun");
const JSError = bun.JSError;
const String = bun.String;
const UUID = bun.UUID;
const BoringSSL = bun.BoringSSL.c;

const NodeCryptoBackend = @import("../node/NodeCryptoBackend.zig");
const EVP = @import("../../crypto/EVP.zig");
const PBKDF2 = EVP.PBKDF2;

const NodeCryptoBindings = bun.bindgen.Module("NodeCryptoBinding");
const PBKDF2Schema = NodeCryptoBindings.function("pbkdf2");
const PBKDF2SyncSchema = NodeCryptoBindings.function("pbkdf2Sync");
const RandomIntSchema = NodeCryptoBindings.function("randomInt");
const RandomFillSchema = NodeCryptoBindings.function("randomFill");
const RandomFillSyncSchema = NodeCryptoBindings.function("randomFillSync");
const RandomBytesSchema = NodeCryptoBindings.function("randomBytes");
const RandomBytesAsyncSchema = NodeCryptoBindings.function("randomBytesAsync");
const RandomUUIDSchema = NodeCryptoBindings.function("randomUUID");
const TimingSafeEqualSchema = NodeCryptoBindings.function("timingSafeEqual");
const SecureHeapUsedSchema = NodeCryptoBindings.function("secureHeapUsed");
const GetFipsSchema = NodeCryptoBindings.function("getFips");
const SetFipsSchema = NodeCryptoBindings.function("setFips");
const SetEngineSchema = NodeCryptoBindings.function("setEngine");
const GetHashesSchema = NodeCryptoBindings.function("getHashes");
const ScryptSchema = NodeCryptoBindings.function("scrypt");
const ScryptSyncSchema = NodeCryptoBindings.function("scryptSync");
const HkdfSchema = NodeCryptoBindings.function("hkdf");
const HkdfSyncSchema = NodeCryptoBindings.function("hkdfSync");
const CheckPrimeSchema = NodeCryptoBindings.function("checkPrime");
const CheckPrimeSyncSchema = NodeCryptoBindings.function("checkPrimeSync");
const GeneratePrimeSchema = NodeCryptoBindings.function("generatePrime");
const GeneratePrimeSyncSchema = NodeCryptoBindings.function("generatePrimeSync");
const GenerateKeySchema = NodeCryptoBindings.function("generateKey");
const GenerateKeySyncSchema = NodeCryptoBindings.function("generateKeySync");
const DiffieHellmanSchema = NodeCryptoBindings.function("diffieHellman");
const DiffieHellmanSyncSchema = NodeCryptoBindings.function("diffieHellmanSync");
const SignOneShotSchema = NodeCryptoBindings.function("signOneShot");
const SignOneShotSyncSchema = NodeCryptoBindings.function("signOneShotSync");
const VerifyOneShotSchema = NodeCryptoBindings.function("verifyOneShot");
const VerifyOneShotSyncSchema = NodeCryptoBindings.function("verifyOneShotSync");
const GenerateKeyPairSchema = NodeCryptoBindings.function("generateKeyPair");
const GenerateKeyPairSyncSchema = NodeCryptoBindings.function("generateKeyPairSync");

const PBKDF2Binding = bun.bindgen.Fn(PBKDF2Schema, pbkdf2);
const PBKDF2SyncBinding = bun.bindgen.Fn(PBKDF2SyncSchema, pbkdf2Sync);
const RandomIntBinding = bun.bindgen.Fn(RandomIntSchema, random.randomInt);
const RandomFillBinding = bun.bindgen.Fn(RandomFillSchema, random.randomFill);
const RandomFillSyncBinding = bun.bindgen.Fn(RandomFillSyncSchema, random.randomFillSync);
const RandomBytesBinding = bun.bindgen.Fn(RandomBytesSchema, random.randomBytes);
const RandomBytesAsyncBinding = bun.bindgen.Fn(RandomBytesAsyncSchema, random.randomBytesAsync);
const RandomUUIDBinding = bun.bindgen.Fn(RandomUUIDSchema, random.randomUUID);
const TimingSafeEqualBinding = bun.bindgen.Fn(TimingSafeEqualSchema, timingSafeEqual);
const SecureHeapUsedBinding = bun.bindgen.Fn(SecureHeapUsedSchema, secureHeapUsed);
const GetFipsBinding = bun.bindgen.Fn(GetFipsSchema, getFips);
const SetFipsBinding = bun.bindgen.Fn(SetFipsSchema, setFips);
const SetEngineBinding = bun.bindgen.Fn(SetEngineSchema, setEngine);
const GetHashesBinding = bun.bindgen.Fn(GetHashesSchema, getHashes);
const ScryptBinding = bun.bindgen.Fn(ScryptSchema, scrypt);
const ScryptSyncBinding = bun.bindgen.Fn(ScryptSyncSchema, scryptSync);
const HkdfBinding = bun.bindgen.Fn(HkdfSchema, hkdf);
const HkdfSyncBinding = bun.bindgen.Fn(HkdfSyncSchema, hkdfSync);
const CheckPrimeBinding = bun.bindgen.Fn(CheckPrimeSchema, checkPrime);
const CheckPrimeSyncBinding = bun.bindgen.Fn(CheckPrimeSyncSchema, checkPrimeSync);
const GeneratePrimeBinding = bun.bindgen.Fn(GeneratePrimeSchema, generatePrime);
const GeneratePrimeSyncBinding = bun.bindgen.Fn(GeneratePrimeSyncSchema, generatePrimeSync);
const GenerateKeyBinding = bun.bindgen.Fn(GenerateKeySchema, generateKey);
const GenerateKeySyncBinding = bun.bindgen.Fn(GenerateKeySyncSchema, generateKeySync);
const DiffieHellmanBinding = bun.bindgen.Fn(DiffieHellmanSchema, diffieHellman);
const DiffieHellmanSyncBinding = bun.bindgen.Fn(DiffieHellmanSyncSchema, diffieHellmanSync);
const SignOneShotBinding = bun.bindgen.Fn(SignOneShotSchema, signOneShot);
const SignOneShotSyncBinding = bun.bindgen.Fn(SignOneShotSyncSchema, signOneShotSync);
const VerifyOneShotBinding = bun.bindgen.Fn(VerifyOneShotSchema, verifyOneShot);
const VerifyOneShotSyncBinding = bun.bindgen.Fn(VerifyOneShotSyncSchema, verifyOneShotSync);
const GenerateKeyPairBinding = bun.bindgen.Fn(GenerateKeyPairSchema, generateKeyPair);
const GenerateKeyPairSyncBinding = bun.bindgen.Fn(GenerateKeyPairSyncSchema, generateKeyPairSync);

comptime {
    _ = PBKDF2Binding;
    _ = PBKDF2SyncBinding;
    _ = RandomIntBinding;
    _ = RandomFillBinding;
    _ = RandomFillSyncBinding;
    _ = RandomBytesBinding;
    _ = RandomBytesAsyncBinding;
    _ = RandomUUIDBinding;
    _ = TimingSafeEqualBinding;
    _ = SecureHeapUsedBinding;
    _ = GetFipsBinding;
    _ = SetFipsBinding;
    _ = SetEngineBinding;
    _ = GetHashesBinding;
    _ = ScryptBinding;
    _ = ScryptSyncBinding;
    _ = HkdfBinding;
    _ = HkdfSyncBinding;
    _ = CheckPrimeBinding;
    _ = CheckPrimeSyncBinding;
    _ = GeneratePrimeBinding;
    _ = GeneratePrimeSyncBinding;
    _ = GenerateKeyBinding;
    _ = GenerateKeySyncBinding;
    _ = DiffieHellmanBinding;
    _ = DiffieHellmanSyncBinding;
    _ = SignOneShotBinding;
    _ = SignOneShotSyncBinding;
    _ = VerifyOneShotBinding;
    _ = VerifyOneShotSyncBinding;
    _ = GenerateKeyPairBinding;
    _ = GenerateKeyPairSyncBinding;
}

const HkdfOwnedContext = NodeCryptoBackend.Hkdf.Context;
const CheckPrimeOwnedContext = NodeCryptoBackend.CheckPrime.Context;
const GeneratePrimeOwnedContext = NodeCryptoBackend.GeneratePrime.Context;
const DiffieHellmanOwnedContext = NodeCryptoBackend.DiffieHellman.Context;
const SignOwnedContext = NodeCryptoBackend.Sign.Context;
const KeyPairOwnedContext = NodeCryptoBackend.KeyPair.Context;
