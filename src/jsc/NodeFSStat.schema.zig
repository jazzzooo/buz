const b = @import("bindgen_schema");

const stat_value_brand = b.cppRealmBrand("NodeFSStatValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isNodeFSStatValue",
    .header = "BindgenTypePredicates.h",
}, "Stats | BigIntStats");

pub const stat_value = b.brandedValueWithBrand(stat_value_brand, .{
    .expectation = "a Stats or BigIntStats instance",
    .node_requirement = "Stats or BigIntStats",
});
const stat_fs_value_brand = b.cppRealmBrand("NodeFSStatFsValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isNodeFSStatFsValue",
    .header = "BindgenTypePredicates.h",
}, "StatFs | BigIntStatFs");
const stat_fs_value = b.brandedValueWithBrand(stat_fs_value_brand, .{
    .expectation = "a StatFs or BigIntStatFs instance",
    .node_requirement = "StatFs or BigIntStatFs",
});

const stats_setter_receiver = b.optionalMatch(b.js_object);

fn modeReceiver(comptime big: bool) b.Type {
    const object_name = if (big) "BigIntStatsModeReceiverObject" else "StatsModeReceiverObject";
    const receiver_name = if (big) "BigIntStatsModeReceiver" else "StatsModeReceiver";
    const mode = if (big) b.integerRepresentation(b.int64, .bigint) else b.int32;
    const object = b.dictionaryWithOptions(object_name, .{
        b.dictionaryField("mode", mode, if (big) .{
            .required = true,
            .missing_required = .convert_undefined,
        } else .{
            .required = true,
            .missing_required = .convert_undefined,
            .integer_conversion = .coerce,
            .profile = .webidl,
        }),
    }, .{ .cpp_name = object_name });
    const receiver = b.unionType(receiver_name, .{
        b.unionMember("object", object),
        b.unionMember("invalid", b.discarded),
    }, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = receiver_name });
    return receiver;
}

fn dateReceiver(comptime name: []const u8, comptime big: bool) b.Type {
    const prefix = if (big) "BigIntStats" else "Stats";
    const object = b.dictionaryWithOptions(prefix ++ name ++ "DateReceiverObject", .{
        b.dictionarySource("source_identity"),
        b.dictionaryField("milliseconds", if (big) b.js_big_int else b.double, if (big) .{
            .required = true,
            .missing_required = .convert_undefined,
            .js_name = name ++ "Ms",
        } else .{
            .required = true,
            .missing_required = .convert_undefined,
            .number_conversion = .coerce,
            .js_name = name ++ "Ms",
        }),
    }, .{
        .cpp_name = prefix ++ name ++ "DateReceiverObject",
        .node_allow_array = true,
        .node_allow_callable = true,
    });
    return b.unionType(prefix ++ name ++ "DateReceiver", .{
        b.unionMember("object", object),
        b.unionMember("invalid", b.discarded),
    }, .{
        .ordered = true,
        .fallback_member = "invalid",
        .cpp_name = prefix ++ name ++ "DateReceiver",
    });
}

fn statValue(comptime big: bool) b.Type {
    return if (big) b.js_big_int else b.double;
}

fn predicate(comptime name: []const u8, comptime big: bool) b.ClassMember {
    return b.method(name, .{}, b.boolean, .{
        .length = 0,
        .configurable = true,
        .this_value_type = modeReceiver(big),
    });
}

fn dateAccessorPair(comptime name: []const u8, comptime big: bool) [2]b.ClassMember {
    return .{
        b.getter(name, b.optionalUndefined(b.js_date), .{ .configurable = true, .this_value_type = dateReceiver(name, big) }),
        b.setter(name, b.engine_value, .{ .configurable = true, .this_value_type = stats_setter_receiver }),
    };
}

fn statArgument(comptime name: []const u8, comptime big: bool) b.Argument {
    return b.argument(name, statValue(big), .{ .presence = .optional, .missing = .omitted });
}

fn statTimestampArgument(comptime name: []const u8, comptime big: bool) b.Argument {
    return b.argument(name, if (big) b.js_big_int else b.double, .{ .presence = .optional, .missing = .omitted });
}

fn statsArguments(comptime big: bool) [14]b.Argument {
    return .{
        statArgument("dev", big),
        statArgument("mode", big),
        statArgument("nlink", big),
        statArgument("uid", big),
        statArgument("gid", big),
        statArgument("rdev", big),
        statArgument("blksize", big),
        statArgument("ino", big),
        statArgument("size", big),
        statArgument("blocks", big),
        statTimestampArgument("atime", big),
        statTimestampArgument("mtime", big),
        statTimestampArgument("ctime", big),
        statTimestampArgument("birthtime", big),
    };
}

fn statsMembers(comptime big: bool) [15]b.ClassMember {
    const atime = dateAccessorPair("atime", big);
    const mtime = dateAccessorPair("mtime", big);
    const ctime = dateAccessorPair("ctime", big);
    const birthtime = dateAccessorPair("birthtime", big);
    return .{
        predicate("isBlockDevice", big),
        predicate("isCharacterDevice", big),
        predicate("isDirectory", big),
        predicate("isFIFO", big),
        predicate("isFile", big),
        predicate("isSocket", big),
        predicate("isSymbolicLink", big),
        atime[0],
        atime[1],
        mtime[0],
        mtime[1],
        ctime[0],
        ctime[1],
        birthtime[0],
        birthtime[1],
    };
}

fn numberField(comptime name: []const u8) b.InstanceProperty {
    return b.instanceProperty(name, .{ .value = b.uint64, .initializer = .{ .argument = name } });
}

fn brandProperty(comptime symbol: []const u8) b.InstanceProperty {
    return b.instanceProperty("brand", .{
        .value = b.boolean,
        .private_symbol = symbol,
        .initializer = .{ .constant = .{ .boolean = true } },
    });
}

fn argumentProperty(
    comptime name: []const u8,
    comptime value: b.Type,
    comptime argument_name: []const u8,
) b.InstanceProperty {
    return b.instanceProperty(name, .{ .value = value, .initializer = .{ .argument = argument_name } });
}

fn argumentBigIntQuotientProperty(
    comptime name: []const u8,
    comptime value: b.Type,
    comptime argument_name: []const u8,
) b.InstanceProperty {
    return b.instanceProperty(name, .{
        .value = value,
        .initializer = .{ .argument_bigint_quotient = .{ .argument = argument_name, .divisor = 1_000_000 } },
    });
}

fn statsClass(comptime name: []const u8, comptime big: bool) b.Class {
    const bigint_i64 = b.integerRepresentation(b.int64, .bigint);
    const bigint_u64 = b.integerRepresentation(b.uint64, .bigint);
    const properties = if (big) .{
        argumentProperty("dev", bigint_i64, "dev"),
        argumentProperty("ino", bigint_i64, "ino"),
        argumentProperty("mode", bigint_i64, "mode"),
        argumentProperty("nlink", bigint_i64, "nlink"),
        argumentProperty("uid", bigint_i64, "uid"),
        argumentProperty("gid", bigint_i64, "gid"),
        argumentProperty("rdev", bigint_i64, "rdev"),
        argumentProperty("size", bigint_i64, "size"),
        argumentProperty("blksize", bigint_i64, "blksize"),
        argumentProperty("blocks", bigint_i64, "blocks"),
        argumentBigIntQuotientProperty("atimeMs", bigint_i64, "atime"),
        argumentBigIntQuotientProperty("mtimeMs", bigint_i64, "mtime"),
        argumentBigIntQuotientProperty("ctimeMs", bigint_i64, "ctime"),
        argumentBigIntQuotientProperty("birthtimeMs", bigint_i64, "birthtime"),
        argumentProperty("atimeNs", bigint_u64, "atime"),
        argumentProperty("mtimeNs", bigint_u64, "mtime"),
        argumentProperty("ctimeNs", bigint_u64, "ctime"),
        argumentProperty("birthtimeNs", bigint_u64, "birthtime"),
    } else .{
        numberField("dev"),
        numberField("ino"),
        numberField("mode"),
        numberField("nlink"),
        numberField("uid"),
        numberField("gid"),
        numberField("rdev"),
        numberField("size"),
        numberField("blksize"),
        numberField("blocks"),
        argumentProperty("atimeMs", b.double, "atime"),
        argumentProperty("mtimeMs", b.double, "mtime"),
        argumentProperty("ctimeMs", b.double, "ctime"),
        argumentProperty("birthtimeMs", b.double, "birthtime"),
    };
    return b.plainClass(
        name,
        b.constructor(statsArguments(big), .{ .length = 0 }),
        statsMembers(big),
        .{brandProperty("nodeFSStatBrand")} ++ properties,
        .{
            .backend = .cpp,
            .brand = stat_value_brand,
            .profile = .exact,
            .representation = .plain,
            .plain_reason = "stat results are JavaScript field snapshots with no native identity",
            .constructor_call = b.constructorCall(statsArguments(big), stat_value, .{ .length = 0 }),
        },
    );
}

fn statFSArguments(comptime big: bool) [7]b.Argument {
    return .{
        statArgument("fstype", big),
        statArgument("bsize", big),
        statArgument("blocks", big),
        statArgument("bfree", big),
        statArgument("bavail", big),
        statArgument("files", big),
        statArgument("ffree", big),
    };
}

fn statFSClass(comptime name: []const u8, comptime big: bool) b.Class {
    const value = if (big) b.integerRepresentation(b.int64, .bigint) else b.int64;
    return b.plainClass(
        name,
        b.constructor(statFSArguments(big), .{ .length = 0 }),
        .{},
        .{
            brandProperty("nodeFSStatFsBrand"),
            argumentProperty("type", value, "fstype"),
            argumentProperty("bsize", value, "bsize"),
            argumentProperty("blocks", value, "blocks"),
            argumentProperty("bfree", value, "bfree"),
            argumentProperty("bavail", value, "bavail"),
            argumentProperty("files", value, "files"),
            argumentProperty("ffree", value, "ffree"),
        },
        .{
            .backend = .cpp,
            .brand = stat_fs_value_brand,
            .profile = .exact,
            .representation = .plain,
            .plain_reason = "stat results are JavaScript field snapshots with no native identity",
            .constructor_call = b.constructorCall(statFSArguments(big), stat_fs_value, .{ .length = 0 }),
        },
    );
}

pub const schema = b.moduleWithClasses("NodeFSStat", .{}, .{
    statsClass("Stats", false),
    statsClass("BigIntStats", true),
    statFSClass("StatFs", false),
    statFSClass("BigIntStatFs", true),
});

pub const stats = schema.class("Stats");
pub const big_int_stats = schema.class("BigIntStats");
pub const stat_fs = schema.class("StatFs");
pub const big_int_stat_fs = schema.class("BigIntStatFs");
