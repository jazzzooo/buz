const b = @import("bindgen_schema");

const mime_params_map = b.brandedValueWithBrand(b.cppBrand("MIMEParamsMap", .{
    .symbol = "Bun::Bindgen::TypePredicates::isMap",
    .header = "BindgenTypePredicates.h",
}, "Map<string, string>"), .{});
const mime_params_object = b.brandedValueWithBrand(b.cppRealmBrand("MIMEParamsObject", .{
    .symbol = "Bun::Bindgen::TypePredicates::isMIMEParamsObject",
    .header = "BindgenTypePredicates.h",
}, "MIMEParams"), .{});

const mime_params_receiver = b.dictionaryWithOptions("MIMEParamsReceiver", .{
    b.dictionaryField("map", mime_params_map, .{
        .required = true,
        .private_symbol = "mimeParams",
    }),
}, .{
    .cpp_name = "MIMEParamsReceiver",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const mime_type_receiver = b.dictionaryWithOptions("MIMETypeReceiver", .{
    b.dictionarySource("source_identity"),
    b.dictionaryField("type", b.dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "mimeType",
        .profile = .exact,
    }),
    b.dictionaryField("subtype", b.dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "mimeSubtype",
        .profile = .exact,
    }),
    b.dictionaryField("params", mime_params_object, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "mimeParams",
        .profile = .exact,
    }),
}, .{
    .cpp_name = "MIMETypeReceiver",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const mime_type_string_receiver = b.dictionary("MIMETypeStringReceiver", .{
    b.dictionaryField("type", b.dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "mimeType",
        .profile = .exact,
    }),
    b.dictionaryField("subtype", b.dom_string, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "mimeSubtype",
        .profile = .exact,
    }),
    b.dictionaryField("params", mime_params_receiver, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "mimeParams",
        .profile = .exact,
    }),
});

fn argument(comptime name: []const u8) b.Argument {
    return b.argument(name, b.dom_string, .{});
}

fn paramsMethod(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime options: b.ClassMemberOptions,
) b.ClassMember {
    var resolved = options;
    resolved.backend = .cpp;
    resolved.profile = .webidl;
    resolved.configurable = true;
    resolved.this_value_type = mime_params_receiver;
    return b.method(name, arguments, result, resolved);
}

const mime_params_class = b.plainClass(
    "MIMEParams",
    b.constructor(.{}, .{ .backend = .cpp, .length = 0 }),
    .{
        paramsMethod("get", .{argument("name")}, b.optional(b.dom_string), .{ .length = 1 }),
        paramsMethod("has", .{argument("name")}, b.boolean, .{ .length = 1 }),
        paramsMethod("set", .{ argument("name"), argument("value") }, b.none, .{ .length = 2 }),
        paramsMethod("delete", .{argument("name")}, b.none, .{ .length = 1 }),
        paramsMethod("toString", .{}, b.dom_string, .{
            .length = 0,
            .aliases = &.{b.memberAlias("toJSON", .{})},
        }),
        paramsMethod("entries", .{}, b.js_map_iterator, .{
            .length = 0,
            .aliases = &.{b.memberSymbolAlias(.iterator, .{ .enumerable = false })},
        }),
        paramsMethod("keys", .{}, b.js_map_iterator, .{ .length = 0 }),
        paramsMethod("values", .{}, b.js_map_iterator, .{ .length = 0 }),
    },
    .{b.instanceProperty("map", .{ .value = mime_params_map, .private_symbol = "mimeParams" })},
    .{
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "MIME state is stored in declared JavaScript properties with no native lifetime",
    },
);

const mime_type_class = b.plainClass(
    "MIMEType",
    b.constructor(.{argument("input")}, .{ .backend = .cpp, .length = 1 }),
    .{
        b.getter("type", b.dom_string, .{
            .backend = .cpp,
            .configurable = true,
            .this_value_type = mime_type_receiver,
        }),
        b.setter("type", b.dom_string, .{
            .backend = .cpp,
            .profile = .webidl,
            .configurable = true,
            .this_value_type = mime_type_receiver,
        }),
        b.getter("subtype", b.dom_string, .{
            .backend = .cpp,
            .configurable = true,
            .this_value_type = mime_type_receiver,
        }),
        b.setter("subtype", b.dom_string, .{
            .backend = .cpp,
            .profile = .webidl,
            .configurable = true,
            .this_value_type = mime_type_receiver,
        }),
        b.getter("essence", b.dom_string, .{
            .backend = .cpp,
            .configurable = true,
            .this_value_type = mime_type_receiver,
        }),
        b.getter("params", mime_params_object, .{
            .backend = .cpp,
            .configurable = true,
            .this_value_type = mime_type_receiver,
        }),
        b.method("toString", .{}, b.dom_string, .{
            .backend = .cpp,
            .length = 0,
            .configurable = true,
            .this_value_type = mime_type_string_receiver,
            .aliases = &.{b.memberAlias("toJSON", .{})},
        }),
    },
    .{
        b.instanceProperty("type", .{ .value = b.js_string, .private_symbol = "mimeType" }),
        b.instanceProperty("subtype", .{ .value = b.js_string, .private_symbol = "mimeSubtype" }),
        b.instanceProperty("params", .{ .value = mime_params_object, .private_symbol = "mimeParams" }),
    },
    .{
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "MIME state is stored in declared JavaScript properties with no native lifetime",
    },
);

pub const schema = b.moduleWithClasses("MIMEParamsHost", .{}, .{ mime_params_class, mime_type_class });

pub const mime_params = schema.class("MIMEParams");
pub const mime_type = schema.class("MIMEType");
