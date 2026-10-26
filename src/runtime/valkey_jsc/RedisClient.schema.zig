const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const ssl = @import("binding_schema_SSLConfig");

const deferred_command_arguments = "Redis validates subscriber mode before converting command operands";
const deferred_list_arguments = "Redis rejects a nullish or file-backed operand before converting later operands";
const deferred_constructor_options = "Redis validates the connection URL before reading or coercing option properties";
const deferred_subscription_arguments = "subscription state and channel presence determine which listener operands are observed";

const redis_response_value = b.brandedValueWithBrand(b.cppBrand("RedisResponseValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isRedisResponseValue",
    .header = "BindgenTypePredicates.h",
}, "string | number | boolean | null | object"), .{
    .expectation = "a Redis response value",
});
const redis_command_result = b.optionalUndefined(redis_response_value);
const redis_argument = b.unionType("RedisArgument", .{
    b.unionMember("scalar", archetypes.redis_scalar_bytes),
    b.unionMember("bytes", b.bufferWithOptions(.copy, .{ .allow_detached = false })),
    b.unionMember("blob", b.blob),
}, .{ .ordered = true });
const optional_redis_argument = b.optionalNullish(redis_argument);
const redis_arguments = b.sequence(optional_redis_argument);

const tls_value = b.unionType("RedisTLSValue", .{
    b.unionMember("enabled", b.boolean),
    b.unionMember("config", ssl.ssl_config),
}, .{ .ordered = true });

const redis_options = b.dictionary("RedisOptions", .{
    b.dictionaryField("idle_timeout", b.uint32, .{
        .js_name = "idleTimeout",
        .profile = .node,
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 4294967295 } },
    }),
    b.dictionaryField("connection_timeout", b.uint32, .{
        .js_name = "connectionTimeout",
        .profile = .node,
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 4294967295 } },
    }),
    b.dictionaryField("auto_reconnect", b.boolean, .{
        .js_name = "autoReconnect",
        .boolean_conversion = .truthy,
    }),
    b.dictionaryField("max_retries", b.uint32, .{
        .js_name = "maxRetries",
        .profile = .node,
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 4294967295 } },
    }),
    b.dictionaryField("enable_offline_queue", b.boolean, .{
        .js_name = "enableOfflineQueue",
        .boolean_conversion = .truthy,
    }),
    b.dictionaryField("enable_auto_pipelining", b.boolean, .{
        .js_name = "enableAutoPipelining",
        .boolean_conversion = .truthy,
    }),
    b.dictionaryField("tls", b.optionalNullish(tls_value), .{
        .default_value = .null,
        .profile = .node,
    }),
});

const options_or_ignored = b.unionType("RedisOptionsOrIgnored", .{
    b.unionMember("options", redis_options),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

pub const connection_url_error_list = .{
    b.domainError("invalid_url", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Invalid URL format" },
    }),
    b.domainError("invalid_protocol", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Expected URL protocol to be one of redis, rediss, redis+tls, redis+unix, redis+tls+unix, valkey, valkeys, valkey+tls, valkey+unix, valkey+tls+unix" },
    }),
    b.domainError("unix_path_required", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Expected unix socket path after valkey+unix:// or valkey+tls+unix://" },
    }),
    b.domainError("tcp_port_zero", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "Port 0 is not valid for TCP connections" },
    }),
    b.domainError("invalid_database", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
};

const constructor_errors = b.domainErrors(connection_url_error_list ++ ssl.ssl_config_error_list ++ .{
    b.domainError("tls_options_required", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "tls must contain at least one TLS option" },
    }),
});

const hmget_fields = b.unionType("RedisHMGetFields", .{
    b.unionMember("array", redis_arguments),
    b.unionMember("single", optional_redis_argument),
}, .{ .ordered = true });

const hset_fields = b.unionType("RedisHSetFields", .{
    b.unionMember("array", b.sequence(archetypes.coerced_dom_string)),
    b.unionMember("record", b.record(b.dom_string, archetypes.coerced_dom_string)),
    b.unionMember("single", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "single" });

const subscription_listener = b.callback(
    "RedisSubscriptionListener",
    .{
        b.argument("message", b.dom_string, .{}),
        b.argument("channel", b.dom_string, .{}),
    },
    b.none,
    .{ .receiver = null, .profile = .exact, .retains_async_context = true },
);

const connect_listener = b.callback(
    "RedisConnectListener",
    .{},
    b.none,
    .{ .receiver = b.classRefByName("RedisClient", "RedisClient"), .profile = .exact, .retains_async_context = true },
);

const close_listener = b.callback(
    "RedisCloseListener",
    .{b.argument("error", b.js_error_instance, .{})},
    b.none,
    .{ .receiver = b.classRefByName("RedisClient", "RedisClient"), .profile = .exact, .retains_async_context = true },
);

const connection_errors = b.domainErrors(.{
    b.domainError("connection_closed", b.none, .{
        .class = .generic_error,
        .code = "ERR_REDIS_CONNECTION_CLOSED",
        .message = .{ .literal = "Connection closed" },
    }),
});

const redis_error_kind = b.enumerationWithOptions("RedisErrorKind", .{
    b.enumerationValue("authentication_failed", "authentication_failed"),
    b.enumerationValue("connection_closed", "connection_closed"),
    b.enumerationValue("connection_timeout", "connection_timeout"),
    b.enumerationValue("idle_timeout", "idle_timeout"),
    b.enumerationValue("invalid_argument", "invalid_argument"),
    b.enumerationValue("invalid_array", "invalid_array"),
    b.enumerationValue("invalid_bulk_string", "invalid_bulk_string"),
    b.enumerationValue("invalid_command", "invalid_command"),
    b.enumerationValue("invalid_error_string", "invalid_error_string"),
    b.enumerationValue("invalid_integer", "invalid_integer"),
    b.enumerationValue("invalid_response", "invalid_response"),
    b.enumerationValue("invalid_response_type", "invalid_response_type"),
    b.enumerationValue("invalid_simple_string", "invalid_simple_string"),
    b.enumerationValue("socket_closed_before_connection", "socket_closed_before_connection"),
}, .{ .cpp_name = "RedisErrorKind" });

fn redisError(
    comptime name: []const u8,
    comptime code: []const u8,
) b.DomainError {
    return b.domainError(name, b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = code,
        .message = .payload,
        .name_override = "RedisError",
    });
}

const command_error_list = .{
    b.domainError("argument_type", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .payload,
    }),
    b.domainError("missing_argument", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_MISSING_ARGS",
        .message = .payload,
    }),
    b.domainError("invalid_state", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_REDIS_INVALID_STATE",
        .message = .payload,
    }),
    b.domainError("command_usage", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.domainError("file_blob_argument", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "File blob cannot be used here" },
    }),
    b.systemError("tls_verification"),
    b.domainError("tls_hostname", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_TLS_CERT_ALTNAME_INVALID",
        .message = .payload,
    }),
    redisError("authentication_failed", "ERR_REDIS_AUTHENTICATION_FAILED"),
    redisError("connection_closed", "ERR_REDIS_CONNECTION_CLOSED"),
    redisError("connection_timeout", "ERR_REDIS_CONNECTION_TIMEOUT"),
    redisError("idle_timeout", "ERR_REDIS_IDLE_TIMEOUT"),
    redisError("invalid_argument", "ERR_REDIS_INVALID_ARGUMENT"),
    redisError("invalid_array", "ERR_REDIS_INVALID_ARRAY"),
    redisError("invalid_bulk_string", "ERR_REDIS_INVALID_BULK_STRING"),
    redisError("invalid_command", "ERR_REDIS_INVALID_COMMAND"),
    redisError("invalid_error_string", "ERR_REDIS_INVALID_ERROR_STRING"),
    redisError("invalid_integer", "ERR_REDIS_INVALID_INTEGER"),
    redisError("invalid_response", "ERR_REDIS_INVALID_RESPONSE"),
    redisError("invalid_response_type", "ERR_REDIS_INVALID_RESPONSE_TYPE"),
    redisError("invalid_simple_string", "ERR_REDIS_INVALID_SIMPLE_STRING"),
    b.domainError("socket_closed_before_connection", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .code = "ERR_SOCKET_CLOSED_BEFORE_CONNECTION",
        .message = .payload,
    }),
};
const command_errors = b.domainErrors(command_error_list);

const response_text_kind = b.enumerationWithOptions("RedisResponseTextKind", .{
    b.enumerationValue("simple_string", "simple_string"),
    b.enumerationValue("error", "error"),
    b.enumerationValue("blob_error", "blob_error"),
    b.enumerationValue("verbatim_string", "verbatim_string"),
    b.enumerationValue("big_number", "big_number"),
}, .{ .cpp_name = "RedisResponseTextKind" });

const response_text = b.dictionaryWithOptions("RedisResponseText", .{
    b.dictionaryField("kind", response_text_kind, .{ .required = true }),
    b.dictionaryField("bytes", b.sequence(b.uint8), .{ .required = true }),
}, .{ .cpp_name = "RedisResponseText" });

const response_bulk_string = b.dictionaryWithOptions("RedisResponseBulkString", .{
    b.dictionaryField("bytes", b.optional(b.sequence(b.uint8)), .{ .required = true }),
}, .{ .cpp_name = "RedisResponseBulkString" });

const response_collection_kind = b.enumerationWithOptions("RedisResponseCollectionKind", .{
    b.enumerationValue("array", "array"),
    b.enumerationValue("set", "set"),
}, .{ .cpp_name = "RedisResponseCollectionKind" });

const response_collection = b.dictionaryWithOptions("RedisResponseCollection", .{
    b.dictionaryField("kind", response_collection_kind, .{ .required = true }),
    b.dictionaryField("length", b.size, .{ .required = true }),
}, .{ .cpp_name = "RedisResponseCollection" });

const response_push = b.dictionaryWithOptions("RedisResponsePush", .{
    b.dictionaryField("kind", b.sequence(b.uint8), .{ .required = true }),
    b.dictionaryField("length", b.size, .{ .required = true }),
}, .{ .cpp_name = "RedisResponsePush" });

const response_map = b.dictionaryWithOptions("RedisResponseMap", .{
    b.dictionaryField("length", b.size, .{ .required = true }),
}, .{ .cpp_name = "RedisResponseMap" });

const response_attribute = b.dictionaryWithOptions("RedisResponseAttribute", .{
    b.dictionaryField("length", b.size, .{ .required = true }),
}, .{ .cpp_name = "RedisResponseAttribute" });

const response_null = b.enumerationWithOptions("RedisResponseNull", .{
    b.enumerationValue("null_value", "null"),
}, .{ .cpp_name = "RedisResponseNull" });

const redis_receiver = b.classRefByName("RedisClient", "RedisClient");

const response_node = b.unionType("RedisResponseNode", .{
    b.unionMember("text", response_text),
    b.unionMember("integer", b.int64),
    b.unionMember("double_value", b.double),
    b.unionMember("boolean_value", b.boolean),
    b.unionMember("bulk_string", response_bulk_string),
    b.unionMember("collection", response_collection),
    b.unionMember("map", response_map),
    b.unionMember("attribute", response_attribute),
    b.unionMember("push", response_push),
    b.unionMember("null_value", response_null),
}, .{ .ordered = true, .cpp_name = "RedisResponseNode" });

const engine_shims = .{
    b.engineShim("materializeResponse", .{
        b.argument("nodes", b.sequence(response_node), .{}),
        b.argument("returnAsBuffer", b.boolean, .{}),
    }, redis_response_value, .current_realm_throwing),
    b.engineShim("createError", .{
        b.argument("kind", redis_error_kind, .{}),
        b.argument("message", b.buffer(.copy), .{}),
    }, b.js_error_instance, .current_realm_throwing),
};

const command_completion: b.CompletionOptions = archetypes.vmCompletion(.queued);

fn commandOptions(comptime length: u16, comptime errors: b.DomainErrors) b.ClassMemberOptions {
    return .{
        .completion = command_completion,
        .errors = errors,
        .length = length,
        .this_value_type = redis_receiver,
    };
}

const subscription_channels = b.unionType("RedisSubscriptionChannels", .{
    b.unionMember("array", archetypes.dom_strings),
    b.unionMember("single", b.dom_string),
}, .{ .ordered = true });

fn command(comptime name: []const u8, comptime length: u16) b.ClassMember {
    return commandWithReason(name, length, deferred_command_arguments);
}

fn commandWithReason(comptime name: []const u8, comptime length: u16, comptime reason: []const u8) b.ClassMember {
    return b.method(
        name,
        .{b.lazyRest("values", optional_redis_argument, reason)},
        redis_command_result,
        commandOptions(length, command_errors),
    );
}

fn coercedStringCommand(comptime name: []const u8, comptime length: u16) b.ClassMember {
    return b.method(
        name,
        .{
            b.argument("key", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_command_arguments }),
            b.argument("field", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_command_arguments }),
            b.argument("value", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_command_arguments }),
        },
        redis_command_result,
        commandOptions(length, command_errors),
    );
}

fn hsetCommand(comptime name: []const u8) b.ClassMember {
    return b.method(
        name,
        .{
            b.argument("key", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_command_arguments }),
            b.argument("fields", b.lazy(hset_fields), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = deferred_command_arguments,
            }),
            b.lazyRest("additional", archetypes.coerced_dom_string, deferred_command_arguments),
        },
        redis_command_result,
        commandOptions(2, command_errors),
    );
}

const redis_client_class = b.class(
    "RedisClient",
    b.constructor(.{
        b.argument("url", archetypes.coerced_dom_string, .{
            .presence = .optional,
            .missing = .undefined_or_null,
        }),
        b.argument("options", b.lazy(options_or_ignored), .{
            .presence = .optional,
            .missing = .undefined_or_null,
            .deferred_reason = deferred_constructor_options,
        }),
    }, .{
        .errors = constructor_errors,
        .length = 0,
    }),
    .{
        command("append", 0),
        command("bitcount", 0),
        command("blmove", 5),
        command("blmpop", 3),
        command("blpop", 2),
        command("brpop", 2),
        command("brpoplpush", 3),
        b.getter("bufferedAmount", archetypes.byte_count, .{ .implementation = "getBufferedAmount" }),
        command("bzmpop", 3),
        command("bzpopmax", 2),
        command("bzpopmin", 2),
        b.method("close", .{}, b.none, .{ .length = 0, .this_value_type = redis_receiver }),
        b.method("connect", .{}, b.none, .{
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
            .errors = connection_errors,
            .length = 0,
            .this_value_type = redis_receiver,
        }),
        b.getter("connected", b.boolean, .{ .implementation = "getConnected" }),
        command("copy", 0),
        command("decr", 1),
        command("decrby", 2),
        command("del", 1),
        command("dump", 0),
        b.method("duplicate", .{}, redis_receiver, .{
            .completion = archetypes.vmCompletion(.queued),
            .errors = connection_errors,
            .length = 0,
            .this_value_type = redis_receiver,
        }),
        command("exists", 1),
        b.method("expire", .{
            b.argument("key", b.lazy(optional_redis_argument), .{ .deferred_reason = deferred_command_arguments }),
            b.argument("seconds", b.lazy(b.optionalUndefined(b.int32)), .{
                .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 2147483647 } },
                .deferred_reason = deferred_command_arguments,
            }),
        }, redis_command_result, .{
            .completion = command_completion,
            .errors = command_errors,
            .length = 2,
            .profile = .node,
            .this_value_type = redis_receiver,
        }),
        command("expireat", 2),
        command("expiretime", 0),
        command("get", 1),
        command("getbit", 2),
        command("getBuffer", 1),
        command("getdel", 0),
        command("getex", 0),
        command("getrange", 3),
        command("getset", 0),
        command("hdel", 2),
        command("hexists", 2),
        command("hexpire", 3),
        command("hexpireat", 3),
        command("hexpiretime", 2),
        command("hget", 2),
        command("hgetall", 0),
        command("hgetdel", 2),
        command("hgetex", 2),
        coercedStringCommand("hincrby", 3),
        coercedStringCommand("hincrbyfloat", 3),
        command("hkeys", 0),
        command("hlen", 0),
        b.method("hmget", .{
            b.argument("key", b.lazy(optional_redis_argument), .{ .deferred_reason = deferred_command_arguments }),
            b.argument("fields", b.lazy(hmget_fields), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = deferred_command_arguments,
            }),
            b.lazyRest("additional", optional_redis_argument, deferred_command_arguments),
        }, redis_command_result, commandOptions(2, command_errors)),
        hsetCommand("hmset"),
        command("hpersist", 2),
        command("hpexpire", 3),
        command("hpexpireat", 3),
        command("hpexpiretime", 2),
        command("hpttl", 2),
        command("hrandfield", 1),
        command("hscan", 2),
        hsetCommand("hset"),
        command("hsetex", 3),
        command("hsetnx", 3),
        command("hstrlen", 0),
        command("httl", 2),
        command("hvals", 0),
        command("incr", 1),
        command("incrby", 2),
        command("incrbyfloat", 2),
        command("keys", 0),
        command("lindex", 2),
        command("linsert", 4),
        command("llen", 0),
        command("lmove", 4),
        command("lmpop", 2),
        command("lpop", 0),
        command("lpos", 2),
        command("lpush", 0),
        command("lpushx", 0),
        command("lrange", 3),
        command("lrem", 3),
        command("lset", 3),
        command("ltrim", 3),
        command("mget", 0),
        command("mset", 0),
        command("msetnx", 0),
        b.getter("onclose", b.optionalUndefined(close_listener), .{ .implementation = "getOnClose", .this_value_type = redis_receiver }),
        b.setter("onclose", b.optionalNullish(close_listener), .{ .implementation = "setOnClose", .this_value_type = redis_receiver }),
        b.getter("onconnect", b.optionalUndefined(connect_listener), .{ .implementation = "getOnConnect", .this_value_type = redis_receiver }),
        b.setter("onconnect", b.optionalNullish(connect_listener), .{ .implementation = "setOnConnect", .this_value_type = redis_receiver }),
        command("persist", 0),
        command("pexpire", 2),
        command("pexpireat", 2),
        command("pexpiretime", 0),
        command("pfadd", 0),
        b.method("ping", .{
            b.argument("message", redis_argument, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, redis_command_result, commandOptions(0, command_errors)),
        command("psetex", 3),
        commandWithReason("psubscribe", 0, deferred_list_arguments),
        command("pttl", 0),
        b.method("publish", .{
            b.argument("channel", b.lazy(archetypes.optional_dom_string), .{ .deferred_reason = deferred_command_arguments }),
            b.argument("message", b.lazy(archetypes.optional_dom_string), .{ .deferred_reason = deferred_command_arguments }),
        }, redis_command_result, commandOptions(0, command_errors)),
        commandWithReason("pubsub", 0, deferred_list_arguments),
        commandWithReason("punsubscribe", 0, deferred_list_arguments),
        b.method("randomkey", .{}, redis_command_result, commandOptions(0, command_errors)),
        command("rename", 2),
        command("renamenx", 2),
        command("rpop", 0),
        command("rpoplpush", 2),
        command("rpush", 0),
        command("rpushx", 0),
        command("sadd", 2),
        command("scan", 0),
        command("scard", 0),
        command("script", 0),
        command("sdiff", 1),
        command("sdiffstore", 2),
        command("select", 0),
        b.method("send", .{
            b.argument("command", archetypes.coerced_dom_string, .{}),
            b.argument("values", redis_arguments, .{}),
        }, redis_command_result, commandOptions(2, command_errors)),
        command("set", 2),
        command("setbit", 3),
        command("setex", 3),
        command("setnx", 0),
        command("setrange", 3),
        command("sinter", 1),
        command("sintercard", 1),
        command("sinterstore", 2),
        command("sismember", 2),
        command("smembers", 1),
        command("smismember", 2),
        command("smove", 0),
        command("spop", 1),
        command("spublish", 0),
        command("srandmember", 1),
        command("srem", 2),
        command("sscan", 2),
        command("strlen", 0),
        b.method("subscribe", .{
            b.argument("channels", b.lazy(b.optionalUndefined(subscription_channels)), .{ .deferred_reason = "subscribe validates the listener before enumerating channel values" }),
            b.argument("listener", subscription_listener, .{}),
        }, redis_command_result, .{
            .completion = command_completion,
            .errors = b.domainErrors(command_error_list ++ .{b.domainError("no_channels", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "subscribe requires at least one channel" },
            })}),
            .length = 0,
            .this_value_type = redis_receiver,
        }),
        command("substr", 0),
        command("sunion", 1),
        command("sunionstore", 2),
        command("touch", 0),
        command("ttl", 1),
        command("type", 1),
        command("unlink", 0),
        b.method("unsubscribe", .{
            b.argument("channels", b.lazy(subscription_channels), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = deferred_subscription_arguments,
            }),
            b.argument("listener", b.lazy(subscription_listener), .{
                .presence = .optional,
                .missing = .omitted,
                .deferred_reason = deferred_subscription_arguments,
            }),
            b.rest("ignored", b.discarded),
        }, redis_command_result, .{
            .completion = command_completion,
            .errors = b.domainErrors(command_error_list ++ .{b.domainError("no_channels", b.none, .{
                .class = .type_error,
                .code = "ERR_INVALID_ARG_TYPE",
                .message = .{ .literal = "unsubscribe requires at least one channel" },
            })}),
            .length = 0,
            .this_value_type = redis_receiver,
        }),
        command("zadd", 3),
        command("zcard", 0),
        command("zcount", 3),
        command("zdiff", 1),
        command("zdiffstore", 2),
        command("zincrby", 3),
        command("zinter", 2),
        command("zintercard", 1),
        command("zinterstore", 3),
        command("zlexcount", 3),
        command("zmpop", 2),
        command("zmscore", 0),
        command("zpopmax", 0),
        command("zpopmin", 0),
        command("zrandmember", 0),
        command("zrange", 3),
        command("zrangebylex", 3),
        command("zrangebyscore", 3),
        command("zrangestore", 4),
        command("zrank", 0),
        command("zrem", 2),
        command("zremrangebylex", 3),
        command("zremrangebyrank", 3),
        command("zremrangebyscore", 3),
        command("zrevrange", 3),
        command("zrevrangebylex", 3),
        command("zrevrangebyscore", 3),
        command("zrevrank", 0),
        command("zscan", 2),
        command("zscore", 0),
        command("zunion", 2),
        command("zunionstore", 3),
    },
    .{
        b.cachedSlot("onconnect", connect_listener, .{ .writable = true, .exposed = false }),
        b.cachedSlot("onclose", close_listener, .{ .writable = true, .exposed = false }),
    },
    .{
        .constructor_call_error = archetypes.constructorRequiresNew("RedisClient"),
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .memory_usage = .vm,
        .has_pending_activity = true,
    },
);

pub const schema = b.moduleWithClassesAndEngineShims("RedisClient", .{}, .{redis_client_class}, engine_shims);
pub const redis_client = schema.class("RedisClient");
