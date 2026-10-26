pub const PasswordObject = struct {
    pub const pwhash = std.crypto.pwhash;
    pub const Algorithm = enum {
        argon2i,
        argon2d,
        argon2id,
        bcrypt,

        pub const Value = union(Algorithm) {
            argon2i: Argon2Params,
            argon2d: Argon2Params,
            argon2id: Argon2Params,
            bcrypt: u6,

            pub const default = Algorithm.Value{
                .argon2id = .{},
            };
        };

        pub const Argon2Params = struct {
            // we don't support the other options right now, but can add them later if someone asks
            memory_cost: u32 = pwhash.argon2.Params.interactive_2id.m,
            time_cost: u32 = pwhash.argon2.Params.interactive_2id.t,

            pub fn toParams(this: Argon2Params) pwhash.argon2.Params {
                return pwhash.argon2.Params{
                    .t = this.time_cost,
                    .m = this.memory_cost,
                    .p = 1,
                };
            }
        };

        pub fn get(pw: []const u8) ?Algorithm {
            if (pw[0] != '$') {
                return null;
            }

            // PHC format looks like $<algorithm>$<params>$<salt>$<hash><optional stuff>
            if (strings.hasPrefixComptime(pw[1..], "argon2d$")) {
                return .argon2d;
            }
            if (strings.hasPrefixComptime(pw[1..], "argon2i$")) {
                return .argon2i;
            }
            if (strings.hasPrefixComptime(pw[1..], "argon2id$")) {
                return .argon2id;
            }

            if (strings.hasPrefixComptime(pw[1..], "bcrypt")) {
                return .bcrypt;
            }

            // https://en.wikipedia.org/wiki/Crypt_(C)
            if (strings.hasPrefixComptime(pw[1..], "2")) {
                return .bcrypt;
            }

            return null;
        }
    };

    pub const HashError = pwhash.Error || error{ UnsupportedAlgorithm, ConcurrencyUnavailable };

    // This is purposely simple because nobody asked to make it more complicated
    pub fn hash(
        allocator: std.mem.Allocator,
        io: std.Io,
        password: []const u8,
        algorithm: Algorithm.Value,
    ) HashError![]u8 {
        switch (algorithm) {
            inline .argon2i, .argon2d, .argon2id => |argon| {
                var outbuf: [4096]u8 = undefined;
                const hash_options = pwhash.argon2.HashOptions{
                    .params = argon.toParams(),
                    .allocator = allocator,
                    .mode = switch (algorithm) {
                        .argon2i => .argon2i,
                        .argon2d => .argon2d,
                        .argon2id => .argon2id,
                        else => unreachable,
                    },
                    .encoding = .phc,
                };
                // warning: argon2's code may spin up threads if paralellism is set to > 0
                // we don't expose this option
                // but since it parses from phc format, it's possible that it will be set
                // eventually we should do something that about that.
                const out_bytes = try pwhash.argon2.strHash(password, hash_options, &outbuf, io);
                return try allocator.dupe(u8, out_bytes);
            },
            .bcrypt => |cost| {
                var outbuf: [4096]u8 = undefined;
                var outbuf_slice: []u8 = outbuf[0..];
                var password_to_use = password;
                // bcrypt silently truncates passwords longer than 72 bytes
                // we use SHA512 to hash the password if it's longer than 72 bytes
                if (password.len > 72) {
                    var sha_512 = bun.sha.SHA512.init();
                    defer sha_512.deinit();
                    sha_512.update(password);
                    sha_512.final(outbuf[0..bun.sha.SHA512.digest]);
                    password_to_use = outbuf[0..bun.sha.SHA512.digest];
                    outbuf_slice = outbuf[bun.sha.SHA512.digest..];
                }

                const hash_options = pwhash.bcrypt.HashOptions{
                    .params = pwhash.bcrypt.Params{
                        .rounds_log = cost,
                        .silently_truncate_password = true,
                    },
                    .allocator = allocator,
                    .encoding = .crypt,
                };
                const out_bytes = try pwhash.bcrypt.strHash(password_to_use, hash_options, outbuf_slice, io);
                return try allocator.dupe(u8, out_bytes);
            },
        }
    }

    pub fn verify(
        allocator: std.mem.Allocator,
        io: std.Io,
        password: []const u8,
        previous_hash: []const u8,
        algorithm: ?Algorithm,
    ) HashError!bool {
        if (previous_hash.len == 0) {
            return false;
        }

        return verifyWithAlgorithm(
            allocator,
            io,
            password,
            previous_hash,
            algorithm orelse Algorithm.get(previous_hash) orelse return error.UnsupportedAlgorithm,
        );
    }

    pub fn verifyWithAlgorithm(
        allocator: std.mem.Allocator,
        io: std.Io,
        password: []const u8,
        previous_hash: []const u8,
        algorithm: Algorithm,
    ) HashError!bool {
        switch (algorithm) {
            .argon2id, .argon2d, .argon2i => {
                pwhash.argon2.strVerify(previous_hash, password, .{ .allocator = allocator }, io) catch |err| {
                    if (err == error.PasswordVerificationFailed) {
                        return false;
                    }

                    return err;
                };
                return true;
            },
            .bcrypt => {
                var password_to_use = password;
                var outbuf: [bun.sha.SHA512.digest]u8 = undefined;

                // bcrypt silently truncates passwords longer than 72 bytes
                // we use SHA512 to hash the password if it's longer than 72 bytes
                if (password.len > 72) {
                    var sha_512 = bun.sha.SHA512.init();
                    defer sha_512.deinit();
                    sha_512.update(password);
                    sha_512.final(&outbuf);
                    password_to_use = &outbuf;
                }
                pwhash.bcrypt.strVerify(previous_hash, password_to_use, .{
                    .allocator = allocator,
                    .silently_truncate_password = true,
                }) catch |err| {
                    if (err == error.PasswordVerificationFailed) {
                        return false;
                    }

                    return err;
                };
                return true;
            },
        }
    }
};

pub const JSPasswordObject = struct {
    const BindingModule = bun.bindgen.Module("PasswordObject");
    pub const HashSchema = BindingModule.function("hash");
    pub const HashSyncSchema = BindingModule.function("hashSync");
    pub const VerifySchema = BindingModule.function("verify");
    pub const VerifySyncSchema = BindingModule.function("verifySync");
    pub const HashBinding = bun.bindgen.Fn(HashSchema, bindHash);
    pub const HashSyncBinding = bun.bindgen.Fn(HashSyncSchema, bindHashSync);
    pub const VerifyBinding = bun.bindgen.Fn(VerifySchema, bindVerify);
    pub const VerifySyncBinding = bun.bindgen.Fn(VerifySyncSchema, bindVerifySync);

    comptime {
        _ = HashBinding;
        _ = HashSyncBinding;
        _ = VerifyBinding;
        _ = VerifySyncBinding;
    }

    fn parseAlgorithmName(name: anytype) ?PasswordObject.Algorithm {
        if (name.eqlUTF8("argon2i")) return .argon2i;
        if (name.eqlUTF8("argon2d")) return .argon2d;
        if (name.eqlUTF8("argon2id")) return .argon2id;
        if (name.eqlUTF8("bcrypt")) return .bcrypt;
        return null;
    }

    fn defaultHashAlgorithm(algorithm: PasswordObject.Algorithm) PasswordObject.Algorithm.Value {
        return switch (algorithm) {
            .argon2i => .{ .argon2i = .{} },
            .argon2d => .{ .argon2d = .{} },
            .argon2id => .{ .argon2id = .{} },
            .bcrypt => .{ .bcrypt = 10 },
        };
    }

    fn algorithmNumber(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        input: anytype,
        default: i32,
        comptime invalid_type: anytype,
    ) bun.bindgen.CallError(Schema)!i32 {
        const converted = try input.convert(context);
        return switch (converted.value) {
            .number => |number| number,
            .null_value, .undefined_value => default,
            .invalid => context.fail(invalid_type, {}),
        };
    }

    fn hashAlgorithm(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        argument: anytype,
    ) bun.bindgen.CallError(Schema)!PasswordObject.Algorithm.Value {
        const input = argument orelse return .default;
        return switch (input) {
            .name => |name| defaultHashAlgorithm(parseAlgorithmName(name) orelse return context.fail(.unknown_algorithm, {})),
            .options => |options| options: {
                const algorithm_input = options.algorithm orelse return context.fail(.missing_options_algorithm, {});
                const name = switch (algorithm_input) {
                    .name => |name| name,
                    .null_value, .undefined_value => return context.fail(.missing_options_algorithm, {}),
                    .invalid => return context.fail(.invalid_algorithm_type, {}),
                };
                const algorithm = parseAlgorithmName(name) orelse return context.fail(.unknown_algorithm, {});
                if (algorithm == .bcrypt) {
                    try options.time_cost.discard(context);
                    try options.memory_cost.discard(context);
                    const cost = try algorithmNumber(Schema, context, options.cost, 10, .invalid_cost_type);
                    if (cost < 4 or cost > 31) return context.fail(.invalid_cost_range, {});
                    break :options .{ .bcrypt = @intCast(cost) };
                }

                try options.cost.discard(context);
                const time_cost = try algorithmNumber(Schema, context, options.time_cost, 2, .invalid_time_cost_type);
                if (time_cost < 1) return context.fail(.invalid_time_cost_range, {});
                const memory_cost = try algorithmNumber(Schema, context, options.memory_cost, 65536, .invalid_memory_cost_type);
                if (memory_cost < 1) return context.fail(.invalid_memory_cost_range, {});
                if (memory_cost < 8) return context.fail(.invalid_memory_cost_minimum, {});
                const params: PasswordObject.Algorithm.Argon2Params = .{
                    .time_cost = @intCast(time_cost),
                    .memory_cost = @intCast(memory_cost),
                };
                break :options switch (algorithm) {
                    .argon2i => .{ .argon2i = params },
                    .argon2d => .{ .argon2d = params },
                    .argon2id => .{ .argon2id = params },
                    .bcrypt => unreachable,
                };
            },
            .null_value, .undefined_value => .default,
            .invalid => context.fail(.invalid_algorithm_type, {}),
        };
    }

    fn verifyAlgorithm(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        argument: anytype,
    ) bun.bindgen.CallError(Schema)!?PasswordObject.Algorithm {
        const input = argument orelse return null;
        return switch (input) {
            .name => |name| parseAlgorithmName(name) orelse return context.fail(.unknown_algorithm, {}),
            .null_value, .undefined_value => null,
            .invalid => context.fail(.invalid_algorithm_type, {}),
        };
    }

    fn asyncInput(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        argument: anytype,
    ) bun.bindgen.CallError(Schema)![]u8 {
        const converted = try argument.convert(context);
        return switch (converted.value) {
            .buffer => |bytes| try bytes.dupe(bun.default_allocator),
            .string => |*text| try text.toOwnedSlice(bun.default_allocator),
        };
    }

    const SyncInput = union(enum) {
        buffer: []const u8,
        string: bun.String.Slice,

        fn slice(input: *const SyncInput) []const u8 {
            return switch (input.*) {
                .buffer => |bytes| bytes,
                .string => |*text| text.slice(),
            };
        }

        fn deinit(input: *SyncInput) void {
            switch (input.*) {
                .buffer => {},
                .string => |*text| text.deinit(),
            }
        }
    };

    fn syncInput(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        value: anytype,
        comptime invalid_tag: anytype,
    ) bun.bindgen.CallError(Schema)!SyncInput {
        return switch (value.*) {
            .buffer => |*bytes| .{
                .buffer = bytes.unsafePtr("the generated C++ frame owns this password/hash byte lease through synchronous password processing"),
            },
            .string => |*text| .{ .string = try text.toUTF8(bun.default_allocator) },
            .invalid => context.fail(invalid_tag, {}),
        };
    }

    fn returnOperationError(
        comptime Schema: type,
        comptime Return: type,
        context: bun.bindgen.CallContext(Schema),
        err: PasswordObject.HashError,
    ) bun.bindgen.CallError(Schema)!Return {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.AuthenticationFailed => context.fail(.authentication_failed, {}),
            error.OutputTooLong => context.fail(.output_too_long, {}),
            error.IdentityElement => context.fail(.identity_element, {}),
            error.InvalidEncoding => context.fail(.invalid_encoding, {}),
            error.SignatureVerificationFailed => context.fail(.signature_verification_failed, {}),
            error.KeyMismatch => context.fail(.key_mismatch, {}),
            error.NonCanonical => context.fail(.non_canonical, {}),
            error.NotSquare => context.fail(.not_square, {}),
            error.PasswordVerificationFailed => context.fail(.password_verification_failed, {}),
            error.WeakParameters => context.fail(.weak_parameters, {}),
            error.WeakPublicKey => context.fail(.weak_public_key, {}),
            error.UnexpectedSubgroup => context.fail(.unexpected_subgroup, {}),
            error.ContextTooLong => context.fail(.context_too_long, {}),
            error.ThreadQuotaExceeded => context.fail(.thread_quota_exceeded, {}),
            error.SystemResources => context.fail(.system_resources, {}),
            error.LockedMemoryLimitExceeded => context.fail(.locked_memory_limit_exceeded, {}),
            error.Unexpected => context.fail(.unexpected, {}),
            error.Canceled => context.fail(.canceled, {}),
            error.NoSpaceLeft => context.fail(.no_space_left, {}),
            error.AllocatorRequired => context.fail(.allocator_required, {}),
            error.UnsupportedAlgorithm => context.fail(.unsupported_algorithm, {}),
            error.ConcurrencyUnavailable => context.fail(.concurrency_unavailable, {}),
        };
    }

    fn completeOperationError(completion: anytype, err: PasswordObject.HashError) void {
        switch (err) {
            error.OutOfMemory => completion.outOfMemory(),
            error.AuthenticationFailed => completion.fail(.authentication_failed, {}),
            error.OutputTooLong => completion.fail(.output_too_long, {}),
            error.IdentityElement => completion.fail(.identity_element, {}),
            error.InvalidEncoding => completion.fail(.invalid_encoding, {}),
            error.SignatureVerificationFailed => completion.fail(.signature_verification_failed, {}),
            error.KeyMismatch => completion.fail(.key_mismatch, {}),
            error.NonCanonical => completion.fail(.non_canonical, {}),
            error.NotSquare => completion.fail(.not_square, {}),
            error.PasswordVerificationFailed => completion.fail(.password_verification_failed, {}),
            error.WeakParameters => completion.fail(.weak_parameters, {}),
            error.WeakPublicKey => completion.fail(.weak_public_key, {}),
            error.UnexpectedSubgroup => completion.fail(.unexpected_subgroup, {}),
            error.ContextTooLong => completion.fail(.context_too_long, {}),
            error.ThreadQuotaExceeded => completion.fail(.thread_quota_exceeded, {}),
            error.SystemResources => completion.fail(.system_resources, {}),
            error.LockedMemoryLimitExceeded => completion.fail(.locked_memory_limit_exceeded, {}),
            error.Unexpected => completion.fail(.unexpected, {}),
            error.Canceled => completion.fail(.canceled, {}),
            error.NoSpaceLeft => completion.fail(.no_space_left, {}),
            error.AllocatorRequired => completion.fail(.allocator_required, {}),
            error.UnsupportedAlgorithm => completion.fail(.unsupported_algorithm, {}),
            error.ConcurrencyUnavailable => completion.fail(.concurrency_unavailable, {}),
        }
    }

    const HashJob = struct {
        algorithm: PasswordObject.Algorithm.Value,
        io: std.Io,
        password: []u8,
        completion: bun.bindgen.OwnedCompletion(HashSchema),
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        pub fn schedule(job: *HashJob, background_tasks: *bun.BackgroundTaskGroup) void {
            bun.BackgroundWork.schedule(background_tasks, &job.task) catch {
                job.completion.fail(.concurrency_unavailable, {});
                job.deinit();
            };
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *HashJob = @fieldParentPtr("task", task);
            defer job.deinit();
            const output = PasswordObject.hash(
                bun.default_allocator,
                job.io,
                job.password,
                job.algorithm,
            ) catch |err| {
                completeOperationError(&job.completion, err);
                return;
            };
            defer bun.freeSensitive(bun.default_allocator, output);
            const encoded = bun.bindgen.UTF8String.fromSlice(output) catch {
                job.completion.outOfMemory();
                return;
            };
            job.completion.resolve(encoded);
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *HashJob = @fieldParentPtr("task", task);
            job.completion.release();
            job.deinit();
        }

        fn deinit(job: *HashJob) void {
            bun.freeSensitive(bun.default_allocator, job.password);
            bun.destroy(job);
        }
    };

    const VerifyJob = struct {
        algorithm: ?PasswordObject.Algorithm,
        io: std.Io,
        password: []u8,
        previous_hash: []u8,
        completion: bun.bindgen.OwnedCompletion(VerifySchema),
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

        pub fn schedule(job: *VerifyJob, background_tasks: *bun.BackgroundTaskGroup) void {
            bun.BackgroundWork.schedule(background_tasks, &job.task) catch {
                job.completion.fail(.concurrency_unavailable, {});
                job.deinit();
            };
        }

        fn run(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *VerifyJob = @fieldParentPtr("task", task);
            defer job.deinit();
            const passed = PasswordObject.verify(
                bun.default_allocator,
                job.io,
                job.password,
                job.previous_hash,
                job.algorithm,
            ) catch |err| {
                completeOperationError(&job.completion, err);
                return;
            };
            job.completion.resolve(passed);
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const job: *VerifyJob = @fieldParentPtr("task", task);
            job.completion.release();
            job.deinit();
        }

        fn deinit(job: *VerifyJob) void {
            bun.freeSensitive(bun.default_allocator, job.password);
            bun.freeSensitive(bun.default_allocator, job.previous_hash);
            bun.destroy(job);
        }
    };

    fn bindHash(
        context: bun.bindgen.CallContext(HashSchema),
        args: bun.bindgen.Args(HashSchema),
    ) bun.bindgen.CallError(HashSchema)!void {
        return startHash(bun.current_runtime.io(), bun.current_runtime.backgroundTasks(), context, args);
    }

    pub fn startHash(
        io: std.Io,
        background_tasks: *bun.BackgroundTaskGroup,
        context: bun.bindgen.CallContext(HashSchema),
        args: bun.bindgen.Args(HashSchema),
    ) bun.bindgen.CallError(HashSchema)!void {
        const password_argument = args.password orelse return context.fail(.missing_password, {});
        const algorithm = try hashAlgorithm(HashSchema, context, args.algorithm);
        const password = try asyncInput(HashSchema, context, password_argument);
        errdefer bun.freeSensitive(bun.default_allocator, password);
        if (password.len == 0) return context.fail(.empty_password, {});

        const job = bun.default_allocator.create(HashJob) catch {
            bun.freeSensitive(bun.default_allocator, password);
            var completion = context.completion();
            completion.outOfMemory();
            return;
        };
        var completion = context.completion();
        job.* = .{
            .algorithm = algorithm,
            .io = io,
            .password = password,
            .completion = completion.take(),
        };
        job.schedule(background_tasks);
    }

    fn bindHashSync(
        context: bun.bindgen.CallContext(HashSyncSchema),
        args: bun.bindgen.Args(HashSyncSchema),
    ) bun.bindgen.CallError(HashSyncSchema)!bun.bindgen.UTF8String {
        return hashSync(bun.current_runtime.io(), context, args);
    }

    pub fn hashSync(
        io: std.Io,
        context: bun.bindgen.CallContext(HashSyncSchema),
        args: bun.bindgen.Args(HashSyncSchema),
    ) bun.bindgen.CallError(HashSyncSchema)!bun.bindgen.UTF8String {
        const password_argument = args.password orelse return context.fail(.missing_password, {});
        const algorithm = try hashAlgorithm(HashSyncSchema, context, args.algorithm);
        const forced = try password_argument.convertLast(context);
        try context.lease(forced.proof);
        var password = try syncInput(HashSyncSchema, context, &forced.converted.value, .invalid_password);
        defer password.deinit();
        if (password.slice().len == 0) return context.fail(.empty_password, {});

        const output = PasswordObject.hash(
            bun.default_allocator,
            io,
            password.slice(),
            algorithm,
        ) catch |err| return returnOperationError(HashSyncSchema, bun.bindgen.UTF8String, context, err);
        defer bun.freeSensitive(bun.default_allocator, output);
        return bun.bindgen.UTF8String.fromSlice(output);
    }

    fn bindVerify(
        context: bun.bindgen.CallContext(VerifySchema),
        args: bun.bindgen.Args(VerifySchema),
    ) bun.bindgen.CallError(VerifySchema)!void {
        return startVerify(bun.current_runtime.io(), bun.current_runtime.backgroundTasks(), context, args);
    }

    pub fn startVerify(
        io: std.Io,
        background_tasks: *bun.BackgroundTaskGroup,
        context: bun.bindgen.CallContext(VerifySchema),
        args: bun.bindgen.Args(VerifySchema),
    ) bun.bindgen.CallError(VerifySchema)!void {
        const password_argument = args.password orelse return context.fail(.missing_arguments, {});
        const hash_argument = args.hash orelse return context.fail(.missing_arguments, {});
        const algorithm = try verifyAlgorithm(VerifySchema, context, args.algorithm);

        const password = try asyncInput(VerifySchema, context, password_argument);
        errdefer bun.freeSensitive(bun.default_allocator, password);
        const previous_hash = try asyncInput(VerifySchema, context, hash_argument);
        errdefer bun.freeSensitive(bun.default_allocator, previous_hash);

        if (password.len == 0 or previous_hash.len == 0) {
            bun.freeSensitive(bun.default_allocator, password);
            bun.freeSensitive(bun.default_allocator, previous_hash);
            var completion = context.completion();
            completion.resolve(false);
            return;
        }

        const job = bun.default_allocator.create(VerifyJob) catch {
            bun.freeSensitive(bun.default_allocator, password);
            bun.freeSensitive(bun.default_allocator, previous_hash);
            var completion = context.completion();
            completion.outOfMemory();
            return;
        };
        var completion = context.completion();
        job.* = .{
            .algorithm = algorithm,
            .io = io,
            .password = password,
            .previous_hash = previous_hash,
            .completion = completion.take(),
        };
        job.schedule(background_tasks);
    }

    fn bindVerifySync(
        context: bun.bindgen.CallContext(VerifySyncSchema),
        args: bun.bindgen.Args(VerifySyncSchema),
    ) bun.bindgen.CallError(VerifySyncSchema)!bool {
        return verifySync(bun.current_runtime.io(), context, args);
    }

    pub fn verifySync(
        io: std.Io,
        context: bun.bindgen.CallContext(VerifySyncSchema),
        args: bun.bindgen.Args(VerifySyncSchema),
    ) bun.bindgen.CallError(VerifySyncSchema)!bool {
        const password_argument = args.password orelse return context.fail(.missing_arguments, {});
        const hash_argument = args.hash orelse return context.fail(.missing_arguments, {});
        const algorithm = try verifyAlgorithm(VerifySyncSchema, context, args.algorithm);

        const converted_password = try password_argument.convert(context);
        const forced_hash = try hash_argument.convertLast(context);
        try context.lease(forced_hash.proof);

        var password = try syncInput(VerifySyncSchema, context, &converted_password.value, .invalid_password);
        defer password.deinit();
        var previous_hash = try syncInput(VerifySyncSchema, context, &forced_hash.converted.value, .invalid_hash);
        defer previous_hash.deinit();

        if (password.slice().len == 0 or previous_hash.slice().len == 0) return false;
        return PasswordObject.verify(
            bun.default_allocator,
            io,
            password.slice(),
            previous_hash.slice(),
            algorithm,
        ) catch |err| return returnOperationError(VerifySyncSchema, bool, context, err);
    }
};

comptime {
    _ = JSPasswordObject.HashBinding;
    _ = JSPasswordObject.HashSyncBinding;
    _ = JSPasswordObject.VerifyBinding;
    _ = JSPasswordObject.VerifySyncBinding;
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
