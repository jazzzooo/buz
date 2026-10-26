const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const diagnostics = @import("binding_schema_Diagnostics");

const resolve_message_json = b.dictionary("ResolveMessageJSON", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("position", diagnostics.nullable_position, .{ .required = true }),
    b.dictionaryField("message", b.dom_string, .{ .required = true }),
    b.dictionaryField("level", diagnostics.level, .{ .required = true }),
    b.dictionaryField("specifier", b.dom_string, .{ .required = true }),
    b.dictionaryField("import_kind", b.dom_string, .{ .required = true, .js_name = "importKind" }),
    b.dictionaryField("referrer", archetypes.nullable_dom_string, .{ .required = true }),
});

const resolve_message_class = b.classWithDataProperties(
    "ResolveMessage",
    b.illegalConstructor(),
    .{
        b.method(
            "toPrimitive",
            .{archetypes.optionalPrimitiveHint("hint")},
            archetypes.nullable_dom_string,
            .{ .symbol = .to_primitive, .length = 1 },
        ),
        b.getter("code", archetypes.optional_dom_string, .{ .implementation = "getCode", .cache = "code" }),
        b.getter("column", b.int32, .{ .implementation = "getColumn" }),
        b.getter("importKind", b.dom_string, .{ .implementation = "getImportKind", .cache = "importKind" }),
        b.getter("level", diagnostics.level, .{ .implementation = "getLevel", .cache = "level" }),
        b.getter("line", b.int32, .{ .implementation = "getLine" }),
        b.getter("message", b.dom_string, .{ .implementation = "getMessage", .cache = "message", .writable = true }),
        b.getter("position", diagnostics.nullable_position, .{ .implementation = "getPosition", .cache = "position" }),
        b.getter("referrer", archetypes.nullable_dom_string, .{ .implementation = "getReferrer", .cache = "referrer" }),
        b.getter("specifier", b.dom_string, .{ .implementation = "getSpecifier", .cache = "specifier" }),
        b.method("toJSON", .{}, resolve_message_json, .{ .length = 0 }),
        b.method("toString", .{}, b.dom_string, .{ .length = 0 }),
        b.method("inspectCustom", diagnostics.inspect_arguments, b.dom_string, .{ .symbol = .inspect_custom, .length = 2 }),
    },
    .{
        b.cachedSlot("code", archetypes.optional_dom_string, .{}),
        b.cachedSlot("importKind", b.dom_string, .{}),
        b.cachedSlot("level", diagnostics.level, .{}),
        b.cachedSlot("message", b.dom_string, .{}),
        b.cachedSlot("position", diagnostics.nullable_position, .{}),
        b.cachedSlot("referrer", archetypes.nullable_dom_string, .{}),
        b.cachedSlot("specifier", b.dom_string, .{}),
    },
    .{b.dataProperty("name", .{ .string = "ResolveMessage" }, .{})},
    .{
        .illegal_constructor_errors = .{
            .call = archetypes.constructorRequiresNew("ResolveMessage"),
            .construct = .{ .kind = .generic_error, .message = "ResolveMessage is not constructable" },
        },
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

pub const schema = b.moduleWithClasses("ResolveMessage", .{}, .{resolve_message_class});
pub const resolve_message = schema.class("ResolveMessage");
