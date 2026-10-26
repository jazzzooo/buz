const std = @import("std");

const protocol = @import("../../valkey/valkey_protocol.zig");

const bun = @import("bun");
const bindgen = bun.bindgen;

const RedisClient = bindgen.Module("RedisClient").class("RedisClient");
pub const MaterializeResponseSchema = bindgen.Module("RedisClient").engineShim("materializeResponse");
pub const CreateErrorSchema = bindgen.Module("RedisClient").engineShim("createError");

pub const Failure = @FieldType(bindgen.Args(CreateErrorSchema), "kind");

pub const CommandFailure = union(enum) {
    protocol: struct {
        kind: protocol.RedisError,
        message: []const u8,
    },
    tls_verification: struct {
        code: []const u8,
        reason: []const u8,
    },
    tls_hostname: []const u8,

    pub fn apply(this: CommandFailure, completion: *ResponseCompletions.Owned) void {
        switch (this) {
            .protocol => |failure| fail(completion, failure.kind, failure.message),
            .tls_verification => |failure| {
                const payload = bindgen.SystemError.init(.{
                    .errno = 0,
                    .code = failure.code,
                    .message = failure.reason,
                }) catch {
                    completion.outOfMemory();
                    return;
                };
                completion.fail(.tls_verification, payload);
            },
            .tls_hostname => |hostname| {
                const message = std.fmt.allocPrint(bun.default_allocator, "Hostname/IP does not match certificate's altnames: Host: {s}", .{hostname}) catch {
                    completion.outOfMemory();
                    return;
                };
                defer bun.default_allocator.free(message);
                const payload = bindgen.ThreadSafeDOMString.fromUTF8(message) catch {
                    completion.outOfMemory();
                    return;
                };
                completion.fail(.tls_hostname, payload);
            },
        }
    }
};

pub const Payload = union(enum) {
    response: struct {
        value: protocol.RESPValue,
        return_as_buffer: bool,
    },
    undefined,
};

const ResponseNode = std.meta.Elem(@FieldType(bindgen.Args(MaterializeResponseSchema), "nodes"));

fn countNodes(value: *const protocol.RESPValue) bun.OOM!usize {
    var count: usize = 0;
    try flattenResponse(value, null, &count);
    return count;
}

fn appendNode(nodes: ?[]ResponseNode, index: *usize, node: ResponseNode) bun.OOM!void {
    const next = std.math.add(usize, index.*, 1) catch return error.OutOfMemory;
    if (nodes) |storage| {
        if (index.* >= storage.len) @panic("Valkey response carrier exceeded its planned length");
        storage[index.*] = node;
    }
    index.* = next;
}

fn flattenResponse(value: *const protocol.RESPValue, nodes: ?[]ResponseNode, index: *usize) bun.OOM!void {
    switch (value.*) {
        .SimpleString => |bytes| try appendNode(nodes, index, .{ .text = .{ .kind = .simple_string, .bytes = bytes } }),
        .Error => |bytes| try appendNode(nodes, index, .{ .text = .{ .kind = .@"error", .bytes = bytes } }),
        .Integer => |integer| try appendNode(nodes, index, .{ .integer = integer }),
        .BulkString => |bytes| try appendNode(nodes, index, .{ .bulk_string = .{ .bytes = bytes } }),
        .Array => |values| {
            try appendNode(nodes, index, .{ .collection = .{ .kind = .array, .length = values.len } });
            for (values) |*child| try flattenResponse(child, nodes, index);
        },
        .Null => try appendNode(nodes, index, .{ .null_value = .null_value }),
        .Double => |double| try appendNode(nodes, index, .{ .double_value = double }),
        .Boolean => |boolean| try appendNode(nodes, index, .{ .boolean_value = boolean }),
        .BlobError => |bytes| try appendNode(nodes, index, .{ .text = .{ .kind = .blob_error, .bytes = bytes } }),
        .VerbatimString => |verbatim| try appendNode(nodes, index, .{ .text = .{ .kind = .verbatim_string, .bytes = verbatim.content } }),
        .Map => |entries| {
            try appendNode(nodes, index, .{ .map = .{ .length = entries.len } });
            for (entries) |*entry| {
                try flattenResponse(&entry.key, nodes, index);
                try flattenResponse(&entry.value, nodes, index);
            }
        },
        .Set => |values| {
            try appendNode(nodes, index, .{ .collection = .{ .kind = .set, .length = values.len } });
            for (values) |*child| try flattenResponse(child, nodes, index);
        },
        .Attribute => |attribute| {
            try appendNode(nodes, index, .{ .attribute = .{ .length = attribute.attributes.len } });
            for (attribute.attributes) |*entry| {
                try flattenResponse(&entry.key, nodes, index);
                try flattenResponse(&entry.value, nodes, index);
            }
            try flattenResponse(attribute.value, nodes, index);
        },
        .Push => |push| {
            try appendNode(nodes, index, .{ .push = .{ .kind = push.kind, .length = push.data.len } });
            for (push.data) |*child| try flattenResponse(child, nodes, index);
        },
        .BigNumber => |bytes| try appendNode(nodes, index, .{ .text = .{ .kind = .big_number, .bytes = bytes } }),
    }
}

const CompletionOps = struct {
    pub fn materialize(
        comptime FunctionSchema: type,
        context: bindgen.MaterializationContext(FunctionSchema),
        payload: *Payload,
    ) bindgen.CallError(FunctionSchema)!bindgen.Return(FunctionSchema) {
        return switch (payload.*) {
            .undefined => null,
            .response => |*response| response: {
                const count = try countNodes(&response.value);
                const operation = context.engineIn("RedisClient", "materializeResponse");
                const nodes = try bun.default_allocator.alloc(ResponseNode, count);
                defer bun.default_allocator.free(nodes);
                var index: usize = 0;
                try flattenResponse(&response.value, nodes, &index);
                if (index != nodes.len) @panic("Valkey response carrier length mismatch");
                break :response try operation.call(.{
                    .nodes = nodes,
                    .returnAsBuffer = response.return_as_buffer,
                });
            },
        };
    }

    pub fn destroyPayload(payload: *Payload) void {
        switch (payload.*) {
            .response => |*response| response.value.deinit(bun.default_allocator),
            .undefined => {},
        }
        bun.default_allocator.destroy(payload);
    }

};

pub const ResponseCompletions = bindgen.MaterializedCompletionSet(.{
    RedisClient.member("append"),
    RedisClient.member("bitcount"),
    RedisClient.member("blmove"),
    RedisClient.member("blmpop"),
    RedisClient.member("blpop"),
    RedisClient.member("brpop"),
    RedisClient.member("brpoplpush"),
    RedisClient.member("bzmpop"),
    RedisClient.member("bzpopmax"),
    RedisClient.member("bzpopmin"),
    RedisClient.member("copy"),
    RedisClient.member("decr"),
    RedisClient.member("decrby"),
    RedisClient.member("del"),
    RedisClient.member("dump"),
    RedisClient.member("exists"),
    RedisClient.member("expire"),
    RedisClient.member("expireat"),
    RedisClient.member("expiretime"),
    RedisClient.member("get"),
    RedisClient.member("getbit"),
    RedisClient.member("getBuffer"),
    RedisClient.member("getdel"),
    RedisClient.member("getex"),
    RedisClient.member("getrange"),
    RedisClient.member("getset"),
    RedisClient.member("hdel"),
    RedisClient.member("hexists"),
    RedisClient.member("hexpire"),
    RedisClient.member("hexpireat"),
    RedisClient.member("hexpiretime"),
    RedisClient.member("hget"),
    RedisClient.member("hgetall"),
    RedisClient.member("hgetdel"),
    RedisClient.member("hgetex"),
    RedisClient.member("hincrby"),
    RedisClient.member("hincrbyfloat"),
    RedisClient.member("hkeys"),
    RedisClient.member("hlen"),
    RedisClient.member("hmget"),
    RedisClient.member("hmset"),
    RedisClient.member("hpersist"),
    RedisClient.member("hpexpire"),
    RedisClient.member("hpexpireat"),
    RedisClient.member("hpexpiretime"),
    RedisClient.member("hpttl"),
    RedisClient.member("hrandfield"),
    RedisClient.member("hscan"),
    RedisClient.member("hset"),
    RedisClient.member("hsetex"),
    RedisClient.member("hsetnx"),
    RedisClient.member("hstrlen"),
    RedisClient.member("httl"),
    RedisClient.member("hvals"),
    RedisClient.member("incr"),
    RedisClient.member("incrby"),
    RedisClient.member("incrbyfloat"),
    RedisClient.member("keys"),
    RedisClient.member("lindex"),
    RedisClient.member("linsert"),
    RedisClient.member("llen"),
    RedisClient.member("lmove"),
    RedisClient.member("lmpop"),
    RedisClient.member("lpop"),
    RedisClient.member("lpos"),
    RedisClient.member("lpush"),
    RedisClient.member("lpushx"),
    RedisClient.member("lrange"),
    RedisClient.member("lrem"),
    RedisClient.member("lset"),
    RedisClient.member("ltrim"),
    RedisClient.member("mget"),
    RedisClient.member("mset"),
    RedisClient.member("msetnx"),
    RedisClient.member("persist"),
    RedisClient.member("pexpire"),
    RedisClient.member("pexpireat"),
    RedisClient.member("pexpiretime"),
    RedisClient.member("pfadd"),
    RedisClient.member("ping"),
    RedisClient.member("psetex"),
    RedisClient.member("psubscribe"),
    RedisClient.member("pttl"),
    RedisClient.member("publish"),
    RedisClient.member("pubsub"),
    RedisClient.member("punsubscribe"),
    RedisClient.member("randomkey"),
    RedisClient.member("rename"),
    RedisClient.member("renamenx"),
    RedisClient.member("rpop"),
    RedisClient.member("rpoplpush"),
    RedisClient.member("rpush"),
    RedisClient.member("rpushx"),
    RedisClient.member("sadd"),
    RedisClient.member("scan"),
    RedisClient.member("scard"),
    RedisClient.member("script"),
    RedisClient.member("sdiff"),
    RedisClient.member("sdiffstore"),
    RedisClient.member("select"),
    RedisClient.member("send"),
    RedisClient.member("set"),
    RedisClient.member("setbit"),
    RedisClient.member("setex"),
    RedisClient.member("setnx"),
    RedisClient.member("setrange"),
    RedisClient.member("sinter"),
    RedisClient.member("sintercard"),
    RedisClient.member("sinterstore"),
    RedisClient.member("sismember"),
    RedisClient.member("smembers"),
    RedisClient.member("smismember"),
    RedisClient.member("smove"),
    RedisClient.member("spop"),
    RedisClient.member("spublish"),
    RedisClient.member("srandmember"),
    RedisClient.member("srem"),
    RedisClient.member("sscan"),
    RedisClient.member("strlen"),
    RedisClient.member("subscribe"),
    RedisClient.member("substr"),
    RedisClient.member("sunion"),
    RedisClient.member("sunionstore"),
    RedisClient.member("touch"),
    RedisClient.member("ttl"),
    RedisClient.member("type"),
    RedisClient.member("unlink"),
    RedisClient.member("unsubscribe"),
    RedisClient.member("zadd"),
    RedisClient.member("zcard"),
    RedisClient.member("zcount"),
    RedisClient.member("zdiff"),
    RedisClient.member("zdiffstore"),
    RedisClient.member("zincrby"),
    RedisClient.member("zinter"),
    RedisClient.member("zintercard"),
    RedisClient.member("zinterstore"),
    RedisClient.member("zlexcount"),
    RedisClient.member("zmpop"),
    RedisClient.member("zmscore"),
    RedisClient.member("zpopmax"),
    RedisClient.member("zpopmin"),
    RedisClient.member("zrandmember"),
    RedisClient.member("zrange"),
    RedisClient.member("zrangebylex"),
    RedisClient.member("zrangebyscore"),
    RedisClient.member("zrangestore"),
    RedisClient.member("zrank"),
    RedisClient.member("zrem"),
    RedisClient.member("zremrangebylex"),
    RedisClient.member("zremrangebyrank"),
    RedisClient.member("zremrangebyscore"),
    RedisClient.member("zrevrange"),
    RedisClient.member("zrevrangebylex"),
    RedisClient.member("zrevrangebyscore"),
    RedisClient.member("zrevrank"),
    RedisClient.member("zscan"),
    RedisClient.member("zscore"),
    RedisClient.member("zunion"),
    RedisClient.member("zunionstore"),
}, Payload, CompletionOps);

pub fn completeResponse(
    completion: *ResponseCompletions.Owned,
    value: *protocol.RESPValue,
    return_as_buffer: bool,
) void {
    const payload = bun.default_allocator.create(Payload) catch {
        completion.outOfMemory();
        return;
    };
    payload.* = .{ .response = .{
        .value = value.*,
        .return_as_buffer = return_as_buffer,
    } };
    value.* = .Null;
    completion.complete(payload);
}

pub fn completeUndefined(completion: *ResponseCompletions.Owned) void {
    const payload = bun.default_allocator.create(Payload) catch {
        completion.outOfMemory();
        return;
    };
    payload.* = .undefined;
    completion.complete(payload);
}

pub fn completeInteger(completion: *ResponseCompletions.Owned, value: i64) void {
    var response: protocol.RESPValue = .{ .Integer = value };
    completeResponse(completion, &response, false);
}

pub fn failureKind(err: protocol.RedisError) Failure {
    return switch (err) {
        error.AuthenticationFailed => .authentication_failed,
        error.ConnectionClosed => .connection_closed,
        error.ConnectionTimeout => .connection_timeout,
        error.IdleTimeout => .idle_timeout,
        error.InvalidArgument => .invalid_argument,
        error.InvalidArray => .invalid_array,
        error.InvalidBulkString => .invalid_bulk_string,
        error.InvalidCommand => .invalid_command,
        error.InvalidErrorString => .invalid_error_string,
        error.InvalidInteger => .invalid_integer,
        error.InvalidResponseType => .invalid_response_type,
        error.InvalidSimpleString => .invalid_simple_string,
        error.InvalidAttribute,
        error.InvalidBigNumber,
        error.InvalidBlobError,
        error.InvalidBoolean,
        error.InvalidDouble,
        error.InvalidMap,
        error.InvalidNull,
        error.InvalidPush,
        error.InvalidResponse,
        error.InvalidSet,
        error.InvalidVerbatimString,
        error.NestingDepthExceeded,
        error.UnsupportedProtocol,
        => .invalid_response,
        error.OutOfMemory => unreachable,
    };
}

pub fn fail(completion: *ResponseCompletions.Owned, err: protocol.RedisError, message: []const u8) void {
    if (err == error.OutOfMemory) {
        completion.outOfMemory();
        return;
    }
    const kind = failureKind(err);
    const payload = bindgen.ThreadSafeDOMString.fromUTF8(message) catch {
        completion.outOfMemory();
        return;
    };
    switch (kind) {
        .authentication_failed => completion.fail(.authentication_failed, payload),
        .connection_closed => completion.fail(.connection_closed, payload),
        .connection_timeout => completion.fail(.connection_timeout, payload),
        .idle_timeout => completion.fail(.idle_timeout, payload),
        .invalid_argument => completion.fail(.invalid_argument, payload),
        .invalid_array => completion.fail(.invalid_array, payload),
        .invalid_bulk_string => completion.fail(.invalid_bulk_string, payload),
        .invalid_command => completion.fail(.invalid_command, payload),
        .invalid_error_string => completion.fail(.invalid_error_string, payload),
        .invalid_integer => completion.fail(.invalid_integer, payload),
        .invalid_response => completion.fail(.invalid_response, payload),
        .invalid_response_type => completion.fail(.invalid_response_type, payload),
        .invalid_simple_string => completion.fail(.invalid_simple_string, payload),
        .socket_closed_before_connection => completion.fail(.socket_closed_before_connection, payload),
    }
}

pub fn failSocketClosedBeforeConnection(completion: *ResponseCompletions.Owned, message: []const u8) void {
    const payload = bindgen.ThreadSafeDOMString.fromUTF8(message) catch {
        completion.outOfMemory();
        return;
    };
    completion.fail(.socket_closed_before_connection, payload);
}
