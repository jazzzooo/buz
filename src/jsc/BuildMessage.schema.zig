const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const diagnostics = @import("binding_schema_Diagnostics");

const build_message_json = b.dictionary("BuildMessageJSON", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("position", diagnostics.nullable_position, .{ .required = true }),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
    b.dictionaryField("level", diagnostics.level, .{ .required = true }),
});

const build_message_notes = b.sequence(b.classRefByName("BuildMessage", "BuildMessage"));

const build_message_class = b.classWithDataProperties(
    "BuildMessage",
    b.illegalConstructor(),
    .{
        b.method(
            "toPrimitive",
            .{archetypes.optionalPrimitiveHint("hint")},
            archetypes.nullable_dom_string,
            .{ .symbol = .to_primitive, .length = 1 },
        ),
        b.getter("column", b.int32, .{ .implementation = "getColumn" }),
        b.getter("level", diagnostics.level, .{ .implementation = "getLevel", .cache = "level" }),
        b.getter("line", b.int32, .{ .implementation = "getLine" }),
        b.getter("message", b.dom_string, .{ .implementation = "getMessage", .cache = "message", .writable = true }),
        b.getter("notes", build_message_notes, .{ .implementation = "getNotes", .cache = "notes" }),
        b.getter("position", diagnostics.nullable_position, .{ .implementation = "getPosition", .cache = "position" }),
        b.method("toJSON", .{}, build_message_json, .{ .length = 0 }),
        b.method("toString", .{}, b.dom_string, .{ .length = 0 }),
        b.method("inspectCustom", diagnostics.inspect_arguments, b.dom_string, .{ .symbol = .inspect_custom, .length = 2 }),
    },
    .{
        b.cachedSlot("level", diagnostics.level, .{}),
        b.cachedSlot("message", b.dom_string, .{}),
        b.cachedSlot("notes", build_message_notes, .{}),
        b.cachedSlot("position", diagnostics.nullable_position, .{}),
    },
    .{b.dataProperty("name", .{ .string = "BuildMessage" }, .{})},
    .{
        .illegal_constructor_errors = .{
            .call = archetypes.constructorRequiresNew("BuildMessage"),
            .construct = .{ .kind = .generic_error, .message = "BuildMessage is not constructable" },
        },
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("BuildMessage", .{}, .{build_message_class});
pub const build_message = schema.class("BuildMessage");
