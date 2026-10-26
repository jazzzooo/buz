fn requireNotSubscriber(this: *JSValkeyClient, context: anytype, comptime function_name: []const u8) CallError(@TypeOf(context))!void {
    if (this.isSubscriber()) {
        return context.fail(.invalid_state, try bindgen.ThreadSafeDOMString.fromUTF8("RedisClient.prototype." ++ function_name ++ " cannot be called while in subscriber mode."));
    }
}

fn requireSubscriber(this: *JSValkeyClient, context: anytype, comptime function_name: []const u8) CallError(@TypeOf(context))!void {
    if (!this.isSubscriber()) {
        return context.fail(.invalid_state, try bindgen.ThreadSafeDOMString.fromUTF8("RedisClient.prototype." ++ function_name ++ " can only be called while in subscriber mode."));
    }
}

fn failArgument(context: anytype, comptime name: []const u8, comptime field: []const u8, comptime expected: []const u8) CallError(@TypeOf(context)) {
    const message = bindgen.ThreadSafeDOMString.fromUTF8("Expected " ++ field ++ " to be a " ++ expected ++ " for '" ++ name ++ "'.") catch return error.OutOfMemory;
    return context.fail(.argument_type, message);
}

fn failMissing(context: anytype, comptime field: []const u8) CallError(@TypeOf(context)) {
    const message = bindgen.ThreadSafeDOMString.fromUTF8("The \"" ++ field ++ "\" argument must be specified") catch return error.OutOfMemory;
    return context.fail(.missing_argument, message);
}

fn failUsage(context: anytype, text: []const u8) CallError(@TypeOf(context)) {
    return context.fail(.command_usage, bindgen.ThreadSafeDOMString.fromUTF8(text) catch return error.OutOfMemory);
}

pub fn Arguments(comptime Rest: type, comptime Context: type) type {
    const Result = struct {
        rest: Rest,
        context: Context,

        const Self = @This();

        pub fn argumentsCount(self: *const Self) usize {
            return self.rest.len();
        }

        pub fn convertArgument(self: *const Self, index: usize) CallError(Context)!?JSArgument {
            if (index >= self.rest.len()) return null;
            const converted = try self.rest.convert(index, self.context);
            const value = if (converted.value) |*value| value else return null;
            return try argumentFromBindgen(self.context, value);
        }
    };
    return Result;
}

fn argumentFromBindgen(context: anytype, value: anytype) CallError(@TypeOf(context))!JSArgument {
    return switch (value.*) {
        inline .bytes, .scalar => |bytes| .{ .bytes = bytes.unsafePtr("the generated command frame owns the copied bytes until synchronous command serialization finishes") },
        .blob => |view| blob: {
            const source = view.get();
            if (source.needsToReadFile()) return context.fail(.file_blob_argument, {});
            break :blob .{ .blob = source.retainBytes() };
        },
    };
}

fn stringArgumentFromBindgen(value: anytype) bun.OOM!JSArgument {
    return .{ .text = try value.toUTF8(bun.default_allocator) };
}

fn appendOwnedArgument(args: *std.array_list.Managed(JSArgument), argument: JSArgument) bun.OOM!void {
    errdefer argument.deinit();
    try args.append(argument);
}

fn resolveUndefined(context: anytype) void {
    var completion_view = context.completion();
    var completion = ValkeyCompletion.ResponseCompletions.takeForContext(
        context,
        &completion_view,
    );
    ValkeyCompletion.completeUndefined(&completion);
}

pub fn jsSend(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    var args = try std.array_list.Managed(JSArgument).initCapacity(
        bun.default_allocator,
        binding_args.values.len(),
    );
    defer {
        for (args.items) |*item| {
            item.deinit();
        }
        args.deinit();
    }

    for (0..binding_args.values.len()) |index| {
        const converted_item = binding_args.values.at(index).?;
        if (converted_item) |*value| {
            args.appendAssumeCapacity(try argumentFromBindgen(context, value));
        } else {
            return failArgument(context, "sendCommand", "argument", "string or buffer");
        }
    }

    const cmd_str = try binding_args.command.toUTF8(bun.default_allocator);
    defer cmd_str.deinit();
    var cmd: Command = .{
        .command = cmd_str.slice(),
        .args = .{ .args = args.items },
        .meta = .{},
    };
    cmd.meta = cmd.meta.check(&cmd);
    this.send(context, &cmd);
}

fn FixedCommand(comptime name: []const u8, comptime command: []const u8, comptime fields: []const []const u8, comptime meta: @FieldType(Command, "meta")) type {
    return struct {
        pub fn call(this: *JSValkeyClient, arguments: anytype) CallError(@TypeOf(arguments.context))!void {
            try requireNotSubscriber(this, arguments.context, name);
            var args: [fields.len]JSArgument = undefined;
            var initialized: usize = 0;
            defer {
                while (initialized > 0) {
                    initialized -= 1;
                    args[initialized].deinit();
                }
            }
            inline for (fields, 0..) |field, index| {
                args[index] = (try arguments.convertArgument(index)) orelse
                    return failArgument(arguments.context, name, field, "string or buffer");
                initialized += 1;
            }
            this.send(arguments.context, &.{
                .command = command,
                .args = .{ .args = &args },
                .meta = meta,
            });
        }
    };
}

fn KeyTailCommand(comptime name: []const u8, comptime command: []const u8, comptime tail: enum { members, optional_count }) type {
    return struct {
        pub fn call(this: *JSValkeyClient, arguments: anytype) CallError(@TypeOf(arguments.context))!void {
            try requireNotSubscriber(this, arguments.context, name);
            const count = arguments.argumentsCount();
            if (tail == .members and count < 2) {
                return failUsage(arguments.context, command ++ " requires at least a key and one member");
            }
            const limit = if (tail == .optional_count) @min(count, 2) else count;
            var buffer: [512]u8 = undefined;
            var fallback: std.heap.BufferFirstAllocator = .init(&buffer, bun.default_allocator);
            var args = try std.array_list.Managed(JSArgument).initCapacity(fallback.allocator(), limit);
            defer {
                for (args.items) |*item| item.deinit();
                args.deinit();
            }
            args.appendAssumeCapacity((try arguments.convertArgument(0)) orelse
                return failArgument(arguments.context, name, "key", "string or buffer"));
            for (1..@max(1, limit)) |index| {
                args.appendAssumeCapacity((try arguments.convertArgument(index)) orelse break);
            }
            this.send(arguments.context, &.{ .command = command, .args = .{ .args = args.items } });
        }
    };
}

pub const get = FixedCommand("get", "GET", &.{"key"}, .{}).call;

pub const getBuffer = FixedCommand("getBuffer", "GET", &.{"key"}, .{ .return_as_buffer = true }).call;

pub fn set(this: *JSValkeyClient, callframe: anytype) CallError(@TypeOf(callframe.context))!void {
    try requireNotSubscriber(this, callframe.context, @src().fn_name);

    const args_count = callframe.argumentsCount();
    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var args = try std.array_list.Managed(JSArgument).initCapacity(stack_fallback.allocator(), args_count);
    defer {
        for (args.items) |*item| {
            item.deinit();
        }
        args.deinit();
    }
    const key = (try callframe.convertArgument(0)) orelse {
        return failArgument(callframe.context, "set", "key", "string or buffer");
    };
    args.appendAssumeCapacity(key);

    const value = (try callframe.convertArgument(1)) orelse {
        return failArgument(callframe.context, "set", "value", "string or buffer or number");
    };
    args.appendAssumeCapacity(value);

    if (args_count > 2) {
        for (2..args_count) |index| {
            args.appendAssumeCapacity((try callframe.convertArgument(index)) orelse {
                break;
            });
        }
    }

    this.send(
        callframe.context,
        &.{
            .command = "SET",
            .args = .{ .args = args.items },
        },
    );
}

pub const incr = FixedCommand("incr", "INCR", &.{"key"}, .{}).call;

pub const decr = FixedCommand("decr", "DECR", &.{"key"}, .{}).call;

pub const exists = FixedCommand("exists", "EXISTS", &.{"key"}, .{ .return_as_bool = true }).call;

pub fn expire(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, @src().fn_name);

    const converted_key = try binding_args.key.convert(context);
    const key = if (converted_key.value) |*value|
        try argumentFromBindgen(context, value)
    else
        return failArgument(context, "expire", "key", "string or buffer");
    defer key.deinit();

    const converted_seconds = try binding_args.seconds.convert(context);
    const seconds = converted_seconds.value orelse 0;

    // Convert seconds to a string
    var int_buf: [64]u8 = undefined;
    const seconds_len = std.fmt.printInt(&int_buf, seconds, 10, .lower, .{});
    const seconds_slice = int_buf[0..seconds_len];

    this.send(
        context,
        &.{
            .command = "EXPIRE",
            .args = .{ .raw = &.{ key.slice(), seconds_slice } },
        },
    );
}

pub const ttl = FixedCommand("ttl", "TTL", &.{"key"}, .{}).call;

// Implement srem (remove value from a set)
pub const srem = KeyTailCommand("srem", "SREM", .members).call;

// Implement srandmember (get random member from set)
pub const srandmember = KeyTailCommand("srandmember", "SRANDMEMBER", .optional_count).call;

// Implement smembers (get all members of a set)
pub const smembers = FixedCommand("smembers", "SMEMBERS", &.{"key"}, .{}).call;

// Implement spop (pop a random member from a set)
pub const spop = KeyTailCommand("spop", "SPOP", .optional_count).call;

// Implement sadd (add member to a set)
pub const sadd = KeyTailCommand("sadd", "SADD", .members).call;

// Implement sismember (check if value is member of a set)
pub const sismember = FixedCommand("sismember", "SISMEMBER", &.{ "key", "value" }, .{ .return_as_bool = true }).call;

// Implement hmget (get multiple values from hash)
pub fn hmget(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, @src().fn_name);

    const fields_argument = binding_args.fields orelse {
        return failUsage(context, "HMGET requires at least a key and one field");
    };

    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var args = std.array_list.Managed(JSArgument).init(stack_fallback.allocator());
    defer {
        for (args.items) |*item| {
            item.deinit();
        }
        args.deinit();
    }

    const converted_key = try binding_args.key.convert(context);
    const key = if (converted_key.value) |*value|
        try argumentFromBindgen(context, value)
    else
        return failArgument(context, "hmget", "key", "string or buffer");
    try appendOwnedArgument(&args, key);

    const converted_fields = try fields_argument.convert(context);
    switch (converted_fields.value) {
        .array => |*fields| {
            if (fields.len() == 0) {
                return failUsage(context, "HMGET requires at least one field");
            }
            try args.ensureUnusedCapacity(fields.len());
            for (0..fields.len()) |index| {
                const converted_field = fields.at(index).?;
                const field = if (converted_field) |*value|
                    try argumentFromBindgen(context, value)
                else
                    return failArgument(context, "hmget", "field", "string or buffer");
                args.appendAssumeCapacity(field);
            }
        },
        .single => |*field| single: {
            const value = field.* orelse break :single;
            try appendOwnedArgument(&args, try argumentFromBindgen(context, &value));
            for (0..binding_args.additional.len()) |index| {
                const converted_field = try binding_args.additional.convert(index, context);
                if (converted_field.value) |*additional| {
                    try appendOwnedArgument(&args, try argumentFromBindgen(context, additional));
                } else {
                    break;
                }
            }
        },
    }

    this.send(
        context,
        &.{
            .command = "HMGET",
            .args = .{ .args = args.items },
        },
    );
}

// Implement hincrby (increment hash field by integer value)
pub fn hincrby(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, @src().fn_name);

    const key = try binding_args.key.convert(context);
    const field = try binding_args.field.convert(context);
    const value = try binding_args.value.convert(context);

    const key_slice = try key.value.toUTF8(bun.default_allocator);
    defer key_slice.deinit();
    const field_slice = try field.value.toUTF8(bun.default_allocator);
    defer field_slice.deinit();
    const value_slice = try value.value.toUTF8(bun.default_allocator);
    defer value_slice.deinit();

    this.send(
        context,
        &.{
            .command = "HINCRBY",
            .args = .{ .slices = &.{ key_slice, field_slice, value_slice } },
        },
    );
}

// Implement hincrbyfloat (increment hash field by float value)
pub fn hincrbyfloat(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, @src().fn_name);

    const key = try binding_args.key.convert(context);
    const field = try binding_args.field.convert(context);
    const value = try binding_args.value.convert(context);

    const key_slice = try key.value.toUTF8(bun.default_allocator);
    defer key_slice.deinit();
    const field_slice = try field.value.toUTF8(bun.default_allocator);
    defer field_slice.deinit();
    const value_slice = try value.value.toUTF8(bun.default_allocator);
    defer value_slice.deinit();

    this.send(
        context,
        &.{
            .command = "HINCRBYFLOAT",
            .args = .{ .slices = &.{ key_slice, field_slice, value_slice } },
        },
    );
}

fn hsetImpl(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
    comptime command: []const u8,
) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, command);

    const converted_key = try binding_args.key.convert(context);
    var args = std.array_list.Managed(JSArgument).init(bun.default_allocator);
    defer {
        for (args.items) |*item| item.deinit();
        args.deinit();
    }

    try appendOwnedArgument(&args, try stringArgumentFromBindgen(&converted_key.value));

    const fields_argument = binding_args.fields orelse {
        return failUsage(context, "HSET requires at least key, field, and value arguments");
    };
    const converted_fields = try fields_argument.convert(context);
    switch (converted_fields.value) {
        .array => |*fields| {
            if (fields.len() % 2 != 0) {
                return failUsage(context, "Array must have an even number of elements (field-value pairs)");
            }
            try args.ensureUnusedCapacity(fields.len());
            for (0..fields.len()) |index| {
                const field = fields.at(index).?;
                args.appendAssumeCapacity(try stringArgumentFromBindgen(&field));
            }
        },
        .record => |*fields| {
            const field_value_count = std.math.mul(usize, fields.len(), 2) catch return error.OutOfMemory;
            const capacity = std.math.add(usize, args.items.len, field_value_count) catch return error.OutOfMemory;
            try args.ensureTotalCapacity(capacity);
            for (0..fields.len()) |index| {
                const field = fields.at(index).?;
                args.appendAssumeCapacity(try stringArgumentFromBindgen(&field.key));
                args.appendAssumeCapacity(try stringArgumentFromBindgen(&field.value));
            }
        },
        .single => |*field| {
            const field_value_count = std.math.add(usize, 1, binding_args.additional.len()) catch return error.OutOfMemory;
            if (field_value_count < 2) {
                return failUsage(context, "HSET requires at least key, field, and value arguments");
            }
            if (field_value_count % 2 != 0) {
                return failUsage(context, "HSET requires field-value pairs (even number of arguments after key)");
            }
            const capacity = std.math.add(usize, args.items.len, field_value_count) catch return error.OutOfMemory;
            try args.ensureTotalCapacity(capacity);
            args.appendAssumeCapacity(try stringArgumentFromBindgen(field));
            for (0..binding_args.additional.len()) |index| {
                const additional = try binding_args.additional.convert(index, context);
                args.appendAssumeCapacity(try stringArgumentFromBindgen(&additional.value));
            }
        },
    }

    if (args.items.len == 1) {
        return failUsage(context, "HSET requires at least one field-value pair");
    }

    this.send(
        context,
        &.{
            .command = command,
            .args = .{ .args = args.items },
        },
    );
}

pub fn hset(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    return hsetImpl(this, context, binding_args, "HSET");
}

pub fn hmset(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    return hsetImpl(this, context, binding_args, "HMSET");
}

pub const hdel = compile.VariadicCommand("hdel", "HDEL", .not_subscriber, .{ .key = "key" }).call;
pub const hrandfield = compile.VariadicCommand("hrandfield", "HRANDFIELD", .not_subscriber, .{ .key = "key" }).call;
pub const hscan = compile.VariadicCommand("hscan", "HSCAN", .not_subscriber, .{ .key = "key" }).call;
pub const hgetdel = compile.VariadicCommand("hgetdel", "HGETDEL", .not_subscriber, .strict).call;
pub const hgetex = compile.VariadicCommand("hgetex", "HGETEX", .not_subscriber, .strict).call;
pub const hsetex = compile.VariadicCommand("hsetex", "HSETEX", .not_subscriber, .strict).call;
pub const hexpire = compile.VariadicCommand("hexpire", "HEXPIRE", .not_subscriber, .strict).call;
pub const hexpireat = compile.VariadicCommand("hexpireat", "HEXPIREAT", .not_subscriber, .strict).call;
pub const hexpiretime = compile.VariadicCommand("hexpiretime", "HEXPIRETIME", .not_subscriber, .strict).call;
pub const hpersist = compile.VariadicCommand("hpersist", "HPERSIST", .not_subscriber, .strict).call;
pub const hpexpire = compile.VariadicCommand("hpexpire", "HPEXPIRE", .not_subscriber, .strict).call;
pub const hpexpireat = compile.VariadicCommand("hpexpireat", "HPEXPIREAT", .not_subscriber, .strict).call;
pub const hpexpiretime = compile.VariadicCommand("hpexpiretime", "HPEXPIRETIME", .not_subscriber, .strict).call;
pub const hpttl = compile.VariadicCommand("hpttl", "HPTTL", .not_subscriber, .strict).call;
pub const httl = compile.VariadicCommand("httl", "HTTL", .not_subscriber, .strict).call;

pub const hsetnx = FixedCommand("hsetnx", "HSETNX", &.{ "key", "field", "value" }, .{ .return_as_bool = true }).call;

pub const hexists = FixedCommand("hexists", "HEXISTS", &.{ "key", "field" }, .{ .return_as_bool = true }).call;

pub fn ping(this: *JSValkeyClient, context: anytype, binding_args: anytype) CallError(@TypeOf(context))!void {
    if (binding_args.message) |*value| {
        const message = try argumentFromBindgen(context, value);
        defer message.deinit();
        this.send(context, &.{
            .command = "PING",
            .args = .{ .args = &.{message} },
        });
    } else {
        this.send(context, &.{
            .command = "PING",
            .args = .{ .raw = &.{} },
        });
    }
}

pub const bitcount = FixedCommand("bitcount", "BITCOUNT", &.{ "key" }, .{}).call;
pub const blmove = compile.VariadicCommand("blmove", "BLMOVE", .not_subscriber, .strict).call;
pub const blmpop = compile.VariadicCommand("blmpop", "BLMPOP", .not_subscriber, .strict).call;
pub const blpop = compile.VariadicCommand("blpop", "BLPOP", .not_subscriber, .strict).call;
pub const brpop = compile.VariadicCommand("brpop", "BRPOP", .not_subscriber, .strict).call;
pub const brpoplpush = FixedCommand("brpoplpush", "BRPOPLPUSH", &.{ "source", "destination", "timeout" }, .{}).call;
pub const getbit = FixedCommand("getbit", "GETBIT", &.{ "key", "offset" }, .{}).call;
pub const setbit = FixedCommand("setbit", "SETBIT", &.{ "key", "offset", "value" }, .{}).call;
pub const getrange = FixedCommand("getrange", "GETRANGE", &.{ "key", "start", "end" }, .{}).call;
pub const setrange = FixedCommand("setrange", "SETRANGE", &.{ "key", "offset", "value" }, .{}).call;
pub const dump = FixedCommand("dump", "DUMP", &.{ "key" }, .{}).call;
pub const expireat = FixedCommand("expireat", "EXPIREAT", &.{ "key", "timestamp" }, .{}).call;
pub const expiretime = FixedCommand("expiretime", "EXPIRETIME", &.{ "key" }, .{}).call;
pub const getdel = FixedCommand("getdel", "GETDEL", &.{ "key" }, .{}).call;
pub const getex = compile.VariadicCommand("getex", "GETEX", .not_subscriber, .strict).call;
pub const hgetall = FixedCommand("hgetall", "HGETALL", &.{ "key" }, .{}).call;
pub const hkeys = FixedCommand("hkeys", "HKEYS", &.{ "key" }, .{}).call;
pub const hlen = FixedCommand("hlen", "HLEN", &.{ "key" }, .{}).call;
pub const hvals = FixedCommand("hvals", "HVALS", &.{ "key" }, .{}).call;
pub const keys = FixedCommand("keys", "KEYS", &.{ "key" }, .{}).call;
pub const lindex = FixedCommand("lindex", "LINDEX", &.{ "key", "index" }, .{}).call;
pub const linsert = compile.VariadicCommand("linsert", "LINSERT", .not_subscriber, .strict).call;
pub const llen = FixedCommand("llen", "LLEN", &.{ "key" }, .{}).call;
pub const lmove = compile.VariadicCommand("lmove", "LMOVE", .not_subscriber, .strict).call;
pub const lmpop = compile.VariadicCommand("lmpop", "LMPOP", .not_subscriber, .strict).call;
pub const lpop = compile.VariadicCommand("lpop", "LPOP", .not_subscriber, .{ .key = "key" }).call;
pub const lpos = compile.VariadicCommand("lpos", "LPOS", .not_subscriber, .strict).call;
pub const lrange = FixedCommand("lrange", "LRANGE", &.{ "key", "start", "stop" }, .{}).call;
pub const lrem = FixedCommand("lrem", "LREM", &.{ "key", "count", "element" }, .{}).call;
pub const lset = FixedCommand("lset", "LSET", &.{ "key", "index", "element" }, .{}).call;
pub const ltrim = FixedCommand("ltrim", "LTRIM", &.{ "key", "start", "stop" }, .{}).call;
pub const persist = FixedCommand("persist", "PERSIST", &.{ "key" }, .{}).call;
pub const pexpire = FixedCommand("pexpire", "PEXPIRE", &.{ "key", "milliseconds" }, .{}).call;
pub const pexpireat = FixedCommand("pexpireat", "PEXPIREAT", &.{ "key", "milliseconds-timestamp" }, .{}).call;
pub const pexpiretime = FixedCommand("pexpiretime", "PEXPIRETIME", &.{ "key" }, .{}).call;
pub const pttl = FixedCommand("pttl", "PTTL", &.{ "key" }, .{}).call;
pub fn randomkey(this: *JSValkeyClient, context: anytype, _: anytype) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, "randomkey");
    this.send(context, &.{ .command = "RANDOMKEY", .args = .{ .raw = &.{} } });
}
pub const rpop = compile.VariadicCommand("rpop", "RPOP", .not_subscriber, .{ .key = "key" }).call;
pub const rpoplpush = FixedCommand("rpoplpush", "RPOPLPUSH", &.{ "source", "destination" }, .{}).call;
pub const scan = compile.VariadicCommand("scan", "SCAN", .not_subscriber, .strict).call;
pub const scard = FixedCommand("scard", "SCARD", &.{ "key" }, .{}).call;
pub const sdiff = compile.VariadicCommand("sdiff", "SDIFF", .not_subscriber, .strict).call;
pub const sdiffstore = compile.VariadicCommand("sdiffstore", "SDIFFSTORE", .not_subscriber, .strict).call;
pub const sinter = compile.VariadicCommand("sinter", "SINTER", .not_subscriber, .strict).call;
pub const sintercard = compile.VariadicCommand("sintercard", "SINTERCARD", .not_subscriber, .strict).call;
pub const sinterstore = compile.VariadicCommand("sinterstore", "SINTERSTORE", .not_subscriber, .strict).call;
pub const smismember = compile.VariadicCommand("smismember", "SMISMEMBER", .not_subscriber, .strict).call;
pub const sscan = compile.VariadicCommand("sscan", "SSCAN", .not_subscriber, .strict).call;
pub const strlen = FixedCommand("strlen", "STRLEN", &.{ "key" }, .{}).call;
pub const sunion = compile.VariadicCommand("sunion", "SUNION", .not_subscriber, .strict).call;
pub const sunionstore = compile.VariadicCommand("sunionstore", "SUNIONSTORE", .not_subscriber, .strict).call;
pub const @"type" = FixedCommand("type", "TYPE", &.{ "key" }, .{}).call;
pub const zcard = FixedCommand("zcard", "ZCARD", &.{ "key" }, .{}).call;
pub const zcount = FixedCommand("zcount", "ZCOUNT", &.{ "key", "min", "max" }, .{}).call;
pub const zlexcount = FixedCommand("zlexcount", "ZLEXCOUNT", &.{ "key", "min", "max" }, .{}).call;
pub const zpopmax = compile.VariadicCommand("zpopmax", "ZPOPMAX", .not_subscriber, .{ .key = "key" }).call;
pub const zpopmin = compile.VariadicCommand("zpopmin", "ZPOPMIN", .not_subscriber, .{ .key = "key" }).call;
pub const zrandmember = compile.VariadicCommand("zrandmember", "ZRANDMEMBER", .not_subscriber, .{ .key = "key" }).call;
pub const zrange = compile.VariadicCommand("zrange", "ZRANGE", .not_subscriber, .strict).call;
pub const zrevrange = compile.VariadicCommand("zrevrange", "ZREVRANGE", .not_subscriber, .strict).call;
pub const zrangebyscore = compile.VariadicCommand("zrangebyscore", "ZRANGEBYSCORE", .not_subscriber, .strict).call;
pub const zrevrangebyscore = compile.VariadicCommand("zrevrangebyscore", "ZREVRANGEBYSCORE", .not_subscriber, .strict).call;
pub const zrangebylex = compile.VariadicCommand("zrangebylex", "ZRANGEBYLEX", .not_subscriber, .{ .key = "key" }).call;
pub const zrevrangebylex = compile.VariadicCommand("zrevrangebylex", "ZREVRANGEBYLEX", .not_subscriber, .{ .key = "key" }).call;
pub const append = FixedCommand("append", "APPEND", &.{ "key", "value" }, .{}).call;
pub const getset = FixedCommand("getset", "GETSET", &.{ "key", "value" }, .{}).call;
pub const hget = FixedCommand("hget", "HGET", &.{ "key", "field" }, .{}).call;
pub const incrby = FixedCommand("incrby", "INCRBY", &.{ "key", "increment" }, .{}).call;
pub const incrbyfloat = FixedCommand("incrbyfloat", "INCRBYFLOAT", &.{ "key", "increment" }, .{}).call;
pub const decrby = FixedCommand("decrby", "DECRBY", &.{ "key", "decrement" }, .{}).call;
pub const lpush = compile.VariadicCommand("lpush", "LPUSH", .not_subscriber, .skip_invalid).call;
pub const lpushx = compile.VariadicCommand("lpushx", "LPUSHX", .not_subscriber, .skip_invalid).call;
pub const pfadd = FixedCommand("pfadd", "PFADD", &.{ "key", "value" }, .{}).call;
pub const rpush = compile.VariadicCommand("rpush", "RPUSH", .not_subscriber, .skip_invalid).call;
pub const rpushx = compile.VariadicCommand("rpushx", "RPUSHX", .not_subscriber, .skip_invalid).call;
pub const setnx = FixedCommand("setnx", "SETNX", &.{ "key", "value" }, .{}).call;
pub const setex = FixedCommand("setex", "SETEX", &.{ "key", "seconds", "value" }, .{}).call;
pub const psetex = FixedCommand("psetex", "PSETEX", &.{ "key", "milliseconds", "value" }, .{}).call;
pub const zscore = FixedCommand("zscore", "ZSCORE", &.{ "key", "value" }, .{}).call;
pub const zincrby = FixedCommand("zincrby", "ZINCRBY", &.{ "key", "increment", "member" }, .{}).call;
pub const zmscore = compile.VariadicCommand("zmscore", "ZMSCORE", .not_subscriber, .skip_invalid).call;
pub const zadd = compile.VariadicCommand("zadd", "ZADD", .not_subscriber, .strict).call;
pub const zscan = compile.VariadicCommand("zscan", "ZSCAN", .not_subscriber, .strict).call;
pub const zdiff = compile.VariadicCommand("zdiff", "ZDIFF", .not_subscriber, .strict).call;
pub const zdiffstore = compile.VariadicCommand("zdiffstore", "ZDIFFSTORE", .not_subscriber, .strict).call;
pub const zinter = compile.VariadicCommand("zinter", "ZINTER", .not_subscriber, .strict).call;
pub const zintercard = compile.VariadicCommand("zintercard", "ZINTERCARD", .not_subscriber, .strict).call;
pub const zinterstore = compile.VariadicCommand("zinterstore", "ZINTERSTORE", .not_subscriber, .strict).call;
pub const zunion = compile.VariadicCommand("zunion", "ZUNION", .not_subscriber, .strict).call;
pub const zunionstore = compile.VariadicCommand("zunionstore", "ZUNIONSTORE", .not_subscriber, .strict).call;
pub const zmpop = compile.VariadicCommand("zmpop", "ZMPOP", .not_subscriber, .strict).call;
pub const bzmpop = compile.VariadicCommand("bzmpop", "BZMPOP", .not_subscriber, .strict).call;
pub const bzpopmin = compile.VariadicCommand("bzpopmin", "BZPOPMIN", .not_subscriber, .strict).call;
pub const bzpopmax = compile.VariadicCommand("bzpopmax", "BZPOPMAX", .not_subscriber, .strict).call;
pub const del = compile.VariadicCommand("del", "DEL", .not_subscriber, .{ .key = "key" }).call;
pub const mget = compile.VariadicCommand("mget", "MGET", .not_subscriber, .{ .key = "key" }).call;
pub const mset = compile.VariadicCommand("mset", "MSET", .not_subscriber, .strict).call;
pub const msetnx = compile.VariadicCommand("msetnx", "MSETNX", .not_subscriber, .strict).call;
pub const script = compile.VariadicCommand("script", "SCRIPT", .not_subscriber, .strict).call;
pub const select = compile.VariadicCommand("select", "SELECT", .not_subscriber, .strict).call;
pub const spublish = FixedCommand("spublish", "SPUBLISH", &.{ "channel", "message" }, .{}).call;
pub const smove = FixedCommand("smove", "SMOVE", &.{ "source", "destination", "member" }, .{ .return_as_bool = true }).call;
pub const substr = FixedCommand("substr", "SUBSTR", &.{ "key", "start", "end" }, .{}).call;
pub const hstrlen = FixedCommand("hstrlen", "HSTRLEN", &.{ "key", "field" }, .{}).call;
pub const zrank = compile.VariadicCommand("zrank", "ZRANK", .not_subscriber, .{ .key = "key" }).call;
pub const zrangestore = compile.VariadicCommand("zrangestore", "ZRANGESTORE", .not_subscriber, .strict).call;
pub const zrem = compile.VariadicCommand("zrem", "ZREM", .not_subscriber, .{ .key = "key" }).call;
pub const zremrangebylex = FixedCommand("zremrangebylex", "ZREMRANGEBYLEX", &.{ "key", "min", "max" }, .{}).call;
pub const zremrangebyrank = FixedCommand("zremrangebyrank", "ZREMRANGEBYRANK", &.{ "key", "start", "stop" }, .{}).call;
pub const zremrangebyscore = FixedCommand("zremrangebyscore", "ZREMRANGEBYSCORE", &.{ "key", "min", "max" }, .{}).call;
pub const zrevrank = compile.VariadicCommand("zrevrank", "ZREVRANK", .not_subscriber, .{ .key = "key" }).call;
pub const psubscribe = compile.VariadicCommand("psubscribe", "PSUBSCRIBE", .dont_care, .strict).call;
pub const punsubscribe = compile.VariadicCommand("punsubscribe", "PUNSUBSCRIBE", .dont_care, .strict).call;
pub const pubsub = compile.VariadicCommand("pubsub", "PUBSUB", .dont_care, .strict).call;
pub const copy = compile.VariadicCommand("copy", "COPY", .not_subscriber, .strict).call;
pub const unlink = compile.VariadicCommand("unlink", "UNLINK", .not_subscriber, .{ .key = "key" }).call;
pub const touch = compile.VariadicCommand("touch", "TOUCH", .not_subscriber, .{ .key = "key" }).call;
pub const rename = FixedCommand("rename", "RENAME", &.{ "key", "newkey" }, .{}).call;
pub const renamenx = FixedCommand("renamenx", "RENAMENX", &.{ "key", "newkey" }, .{}).call;

pub fn publish(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) CallError(@TypeOf(context))!void {
    try requireNotSubscriber(this, context, @src().fn_name);

    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var args = try std.array_list.Managed(JSArgument).initCapacity(stack_fallback.allocator(), 2);
    defer {
        for (args.items) |*item| {
            item.deinit();
        }
        args.deinit();
    }

    const converted_channel = try binding_args.channel.convert(context);
    const channel = converted_channel.value orelse {
        return failArgument(context, "publish", "channel", "string");
    };
    args.appendAssumeCapacity(try stringArgumentFromBindgen(&channel));

    const converted_message = try binding_args.message.convert(context);
    const message = converted_message.value orelse {
        return failArgument(context, "publish", "message", "string");
    };
    args.appendAssumeCapacity(try stringArgumentFromBindgen(&message));

    this.send(
        context,
        &.{
            .command = "PUBLISH",
            .args = .{ .args = args.items },
        },
    );
}

pub fn subscribe(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var redis_channels = try std.array_list.Managed(JSArgument).initCapacity(stack_fallback.allocator(), 1);
    defer {
        for (redis_channels.items) |*item| {
            item.deinit();
        }
        redis_channels.deinit();
    }

    const converted_channels = try binding_args.channels.convert(context);
    if (converted_channels.value == null) {
        return failArgument(context, "subscribe", "channel", "string or array");
    }
    switch (converted_channels.value.?) {
        .array => |*values| {
            if (values.len() == 0) {
                return context.fail(.no_channels, {});
            }
            try redis_channels.ensureTotalCapacity(values.len());
            for (0..values.len()) |index| {
                const channel = values.at(index).?;
                redis_channels.appendAssumeCapacity(try stringArgumentFromBindgen(&channel));
            }
        },
        .single => |*channel| {
            try appendOwnedArgument(&redis_channels, try stringArgumentFromBindgen(channel));
        },
    }

    var staged_callbacks = try this._subscription_ctx.callbacks.clone();
    defer staged_callbacks.deinit();
    for (redis_channels.items) |*channel| {
        try staged_callbacks.add(channel.slice(), binding_args.listener);
    }

    const command: valkey.Command = .{
        .command = "SUBSCRIBE",
        .args = .{ .args = redis_channels.items },
        .meta = .{
            .subscription_request = true,
        },
    };
    std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
    if (!this.sendWithStatus(context, &command)) {
        std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
    }
}

pub fn unsubscribe(
    this: *JSValkeyClient,
    context: anytype,
    binding_args: anytype,
) bun.bindgen.CallError(@TypeOf(context))!void {
    try requireSubscriber(this, context, @src().fn_name);

    var stack_fallback_buffer: [512]u8 = undefined;
    var stack_fallback: std.heap.BufferFirstAllocator = .init(&stack_fallback_buffer, bun.default_allocator);
    var redis_channels = try std.array_list.Managed(JSArgument).initCapacity(stack_fallback.allocator(), 1);
    defer {
        for (redis_channels.items) |*item| {
            item.deinit();
        }
        redis_channels.deinit();
    }

    const channels_argument = binding_args.channels orelse {
        var staged_callbacks = try this._subscription_ctx.callbacks.clone();
        defer staged_callbacks.deinit();
        staged_callbacks.clear();
        std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
        const command: valkey.Command = .{
            .command = "UNSUBSCRIBE",
            .args = .{ .args = redis_channels.items },
        };
        if (!this.sendWithStatus(context, &command)) {
            std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
        }
        return;
    };

    const converted_channels = try channels_argument.convert(context);

    if (binding_args.listener != null and binding_args.ignored == 0) {
        const channel = switch (converted_channels.value) {
            .array => return failArgument(context, "unsubscribe", "channel", "string"),
            .single => |*value| value,
        };
        const converted_listener = try binding_args.listener.?.convert(context);
        var channel_key = try channel.toUTF8(bun.default_allocator);
        defer channel_key.deinit();

        redis_channels.appendAssumeCapacity(try stringArgumentFromBindgen(channel));
        var staged_callbacks = try this._subscription_ctx.callbacks.clone();
        defer staged_callbacks.deinit();
        const remaining_listeners = staged_callbacks.remove(
            channel_key.slice(),
            converted_listener.value,
        ) orelse {
            resolveUndefined(context);
            return;
        };

        if (remaining_listeners == 0) {
            std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
            const command: valkey.Command = .{
                .command = "UNSUBSCRIBE",
                .args = .{ .args = redis_channels.items },
            };
            if (!this.sendWithStatus(context, &command)) {
                std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
            }
            return;
        }
        std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
        resolveUndefined(context);
        return;
    }

    switch (converted_channels.value) {
        .array => |*channels| {
            if (channels.len() == 0) {
                return context.fail(.no_channels, {});
            }
            try redis_channels.ensureTotalCapacity(channels.len());
            for (0..channels.len()) |index| {
                const channel = channels.at(index).?;
                redis_channels.appendAssumeCapacity(try stringArgumentFromBindgen(&channel));
            }
        },
        .single => |*channel| {
            redis_channels.appendAssumeCapacity(try stringArgumentFromBindgen(channel));
        },
    }

    var staged_callbacks = try this._subscription_ctx.callbacks.clone();
    defer staged_callbacks.deinit();
    for (redis_channels.items) |*channel| {
        _ = staged_callbacks.removeAll(channel.slice());
    }
    std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
    const command: valkey.Command = .{
        .command = "UNSUBSCRIBE",
        .args = .{ .args = redis_channels.items },
    };
    if (!this.sendWithStatus(context, &command)) {
        std.mem.swap(@TypeOf(staged_callbacks), &this._subscription_ctx.callbacks, &staged_callbacks);
    }
}

// script(subcommand: "LOAD", script: RedisValue)
// select(index: number | string)
// spublish(shardchannel: RedisValue, message: RedisValue)
// smove(source: RedisKey, destination: RedisKey, member: RedisValue)
// substr(key: RedisKey, start: number, end: number)` // Deprecated alias for getrang
// hstrlen(key: RedisKey, field: RedisValue)
// zrank(key: RedisKey, member: RedisValue)
// zrevrank(key: RedisKey, member: RedisValue)
// zscore(key: RedisKey, member: RedisValue)

// cluster(subcommand: "KEYSLOT", key: RedisKey)

const compile = struct {
    pub const ClientStateRequirement = enum {
        /// The client must be a subscriber (in subscription mode).
        subscriber,
        /// The client must not be a subscriber (not in subscription mode).
        not_subscriber,
        /// We don't care about the client state (subscriber or not).
        dont_care,
    };

    fn testCorrectState(
        this: *JSValkeyClient,
        context: anytype,
        comptime js_client_prototype_function_name: []const u8,
        comptime client_state_requirement: ClientStateRequirement,
    ) CallError(@TypeOf(context))!void {
        return switch (client_state_requirement) {
            .subscriber => requireSubscriber(this, context, js_client_prototype_function_name),
            .not_subscriber => requireNotSubscriber(this, context, js_client_prototype_function_name),
            .dont_care => {},
        };
    }



    pub fn VariadicCommand(
        comptime name: []const u8,
        comptime command: []const u8,
        comptime client_state_requirement: ClientStateRequirement,
        comptime policy: union(enum) { key: []const u8, strict, skip_invalid },
    ) type {
        return struct {
            pub fn call(this: *JSValkeyClient, arguments: anytype) CallError(@TypeOf(arguments.context))!void {
                try testCorrectState(this, arguments.context, name, client_state_requirement);
                const count = arguments.argumentsCount();
                var args = try std.array_list.Managed(JSArgument).initCapacity(bun.default_allocator, count);
                defer {
                    for (args.items) |*item| item.deinit();
                    args.deinit();
                }

                const start: usize = switch (policy) {
                    .key => |field| start: {
                        args.appendAssumeCapacity((try arguments.convertArgument(0)) orelse
                            return failMissing(arguments.context, field));
                        break :start 1;
                    },
                    .strict, .skip_invalid => 0,
                };
                for (start..count) |index| {
                    if (try arguments.convertArgument(index)) |argument| {
                        args.appendAssumeCapacity(argument);
                    } else if (policy == .strict) {
                        return failArgument(arguments.context, name, "additional arguments", "string or buffer");
                    }
                }
                this.send(arguments.context, &.{ .command = command, .args = .{ .args = args.items } });
            }
        };
    }

};

const bun = @import("bun");
const std = @import("std");

const JSValkeyClient = @import("./ValkeyClientEngine.zig").JSValkeyClient;
const ValkeyCompletion = @import("./ValkeyCompletion.zig");

const bindgen = bun.bindgen;
const CallError = bindgen.CallError;
const JSArgument = Command.Argument;

const valkey = bun.valkey;
const Command = valkey.Command;
