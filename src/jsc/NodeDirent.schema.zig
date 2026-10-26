const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const dirent_receiver_object = b.dictionaryWithOptions("DirentReceiverObject", .{
    b.dictionaryField("type", archetypes.int32_or_ignored, .{
        .required = true,
        .missing_required = .convert_undefined,
        .private_symbol = "data",
    }),
}, .{ .cpp_name = "DirentReceiverObject" });
const dirent_receiver = b.unionType("DirentReceiver", .{
    b.unionMember("object", dirent_receiver_object),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "DirentReceiver" });

fn predicate(comptime name: []const u8) b.ClassMember {
    return b.method(name, .{}, b.boolean, .{
        .length = 0,
        .configurable = true,
        .this_value_type = dirent_receiver,
    });
}

fn direntArgument(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, value_type, .{ .presence = .optional, .missing = .omitted });
}

pub const schema = b.moduleWithClasses("NodeDirent", .{}, .{
    b.plainClass(
        "Dirent",
        b.constructor(.{
            direntArgument("name", b.dom_string),
            direntArgument("type", b.int32),
            direntArgument("path", b.dom_string),
        }, .{ .length = 3 }),
        .{
            predicate("isBlockDevice"),
            predicate("isCharacterDevice"),
            predicate("isDirectory"),
            predicate("isFIFO"),
            predicate("isFile"),
            predicate("isSocket"),
            predicate("isSymbolicLink"),
        },
        .{
            b.instanceProperty("name", .{ .value = b.dom_string, .initializer = .{ .argument = "name" } }),
            b.instanceProperty("path", .{ .value = b.dom_string, .initializer = .{ .argument = "path" } }),
            b.instanceProperty("data", .{
                .value = b.int32,
                .private_symbol = "data",
                .initializer = .{ .argument = "type" },
            }),
            b.instanceProperty("parentPath", .{ .value = b.dom_string, .initializer = .{ .argument = "path" } }),
        },
        .{
            .constructor_call_error = .{ .kind = .{ .code = "ERR_ILLEGAL_CONSTRUCTOR" }, .message = "Dirent constructor cannot be called as a function" },
            .backend = .cpp,
            .profile = .exact,
            .representation = .plain,
            .plain_reason = "Dirent is a JavaScript field snapshot with no native identity",
        },
    ),
});

pub const dirent = schema.class("Dirent");
