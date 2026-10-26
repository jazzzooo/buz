const mod_classes = @import("classes.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const types = @import("types.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

pub fn typeDeclarations(n: *Normalizer) Error![]const ir.TypeScriptDeclaration {
    var result: std.ArrayList(ir.TypeScriptDeclaration) = .empty;
    for (n.types.items[0..n.binding_type_count]) |type_| {
        switch (type_.data) {
            .enumeration => {
                const enumeration = n.get(type_.data.enumeration);
                const raw = n.rawType(type_.id).enumeration;
                var values: std.ArrayList(ir.TypeScriptEnumerationValue) = .empty;
                for (enumeration.enumeration_values, raw.values) |value, declared| {
                    try values.append(n.arena, .{ .string = value.js_value });
                    for (declared.options.aliases) |alias| try values.append(n.arena, .{ .string = alias });
                    if (raw.options.accept_native_numbers) try values.append(n.arena, .{ .number = value.native_value });
                }
                try result.append(n.arena, .{ .enumeration = .{ .name = enumeration.enumeration_name, .values = values.items } });
            },
            .dictionary => |dictionary| {
                const raw = n.rawType(type_.id).dictionary;
                if (raw.options.result_class != null) continue;
                var fields: std.ArrayList(ir.TypeScriptField) = .empty;
                for (dictionary.dictionary_fields, raw.fields) |field, declared| {
                    const options = declared.options;
                    if (options.source_field != null or options.private_symbol != null or options.source == .dictionary) continue;
                    var text = n.projection(field.field_type).inputTypeScript();
                    for (dictionary.dictionary_fields, raw.fields) |other, raw_other| {
                        const source_name = raw_other.options.source_field orelse continue;
                        if (!std.mem.eql(u8, source_name, field.field_name)) continue;
                        text = try n.print("{s} | {s}", .{ text, n.projection(other.field_type).inputTypeScript() });
                    }
                    try fields.append(n.arena, .{
                        .name = declared.propertyName(),
                        .optional = !options.required or (options.missing_required == .convert_undefined and (declared.type == .optional or (declared.type == .lazy and declared.type.lazy.* == .optional))),
                        .value = text,
                    });
                }
                try result.append(n.arena, .{ .dictionary = .{ .name = dictionary.dictionary_name, .fields = fields.items } });
            },
            .union_type => |union_type| {
                const options = n.rawType(type_.id).union_type.options;
                const members = try n.arena.alloc(@typeInfo(@FieldType(@FieldType(ir.TypeScriptDeclaration, "union_type"), "members")).pointer.child, union_type.union_members.len);
                for (union_type.union_members, members) |member, *output| output.* = .{
                    .value = n.projection(member.member_type).inputTypeScript(),
                    .tag = if (options.input_tag) |tag| tag_value: {
                        if (options.fallback_member) |fallback| if (std.mem.eql(u8, member.member_name, fallback)) break :tag_value null;
                        break :tag_value (types.selectorValue(member.member_name, if (tag.selector) |selector| selector.enumeration else null)).js_value;
                    } else null,
                };
                try result.append(n.arena, .{ .union_type = .{
                    .name = union_type.union_name,
                    .members = members,
                    .tag = if (options.input_tag) |tag| .{
                        .property = tag.tag_property,
                        .value_property = tag.value_property,
                        .shorthand = tag.string_shorthand,
                    } else null,
                } });
            },
            .void, .discarded, .boolean, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .usize, .f64, .any, .engine_value, .branded_value, .lazy, .converted, .dom_string, .usv_string, .byte_string, .utf8_string, .node_path, .buffer, .native_slice, .callback, .optional, .sequence, .record, .nominal_handle, .class_ref, .external_ref, .native_instance => {},
        }
    }
    return result.items;
}

pub fn optional(n: *Normalizer, value: ir.OptionalType, child: []const u8, comptime input: bool) Error![]const u8 {
    const absent = switch (value.optional_mode) {
        .matched => return "unknown",
        .undefined => "undefined",
        .nullable => "null",
        .nullish => if (input) "null | undefined" else "null",
        .falsy => if (input) "null | undefined | false | 0 | 0n | \"\"" else "null",
        .nullish_or_empty_string => if (input) "null | undefined | \"\"" else "null",
    };
    return n.print("({s}) | {s}", .{ child, absent });
}

pub fn sequence(n: *Normalizer, container: ir.vocabulary.SequenceContainer, element: []const u8) Error![]const u8 {
    return n.print("{s}<{s}>", .{ if (container == .array_like) "ArrayLike" else "ReadonlyArray", element });
}

pub fn record(n: *Normalizer, value: []const u8) Error![]const u8 {
    return n.print("Record<string, {s}>", .{value});
}

pub fn functionExposed(n: *const Normalizer, id: ir.FunctionId) bool {
    const declared = n.declared_functions.items[id.index];
    return normalize.isTypeScriptExposed(declared.options.exposure) and
        (if (declared.member) |member| normalize.isTypeScriptExposed(member.exposure) else true);
}

pub fn key(value: ir.ClassMemberAliasKey) ?ir.TypeScriptPropertyKey {
    return switch (value) {
        .name => |name| .{ .name = name },
        .symbol => |symbol| .{ .symbol = switch (symbol) {
            .inspect_custom => return null,
            inline else => |tag| @field(ir.TypeScriptPropertySymbol, @tagName(tag)),
        } },
    };
}

fn declarations(n: *Normalizer, function: *const ir.Function) Error![]const ir.FunctionIdRef {
    if (!function.isOverloaded()) return n.arena.dupe(ir.FunctionIdRef, &.{function.id});
    const result = try n.arena.alloc(ir.FunctionIdRef, function.overload_cases.len);
    for (function.overload_cases, result) |id, *output| output.* = .{ .overload = id };
    return result;
}

fn method(n: *Normalizer, output: *std.ArrayList(ir.TypeScriptClassMember), overloads: []const ir.FunctionIdRef, name: ir.TypeScriptPropertyKey, is_static: bool) Error!void {
    for (overloads) |declaration| try output.append(n.arena, .{
        .is_static = is_static,
        .operation = .{ .method = .{ .key = name, .declaration = declaration } },
    });
}

fn declaresIterator(n: *const Normalizer, class_: *const ir.Class, symbol: ir.PropertySymbol) bool {
    for (class_.declarations) |id| {
        const member = n.get(id);
        if (!functionExposed(n, id)) continue;
        const raw = n.declaration(member.id).member.?.raw;
        if (raw.kind.isStatic()) continue;
        if (raw.options.symbol == symbol) return true;
        for (raw.options.aliases) |alias| switch (alias.key) {
            .symbol => |value| if (value == symbol) return true,
            .name => {},
        };
    }
    return false;
}

pub fn class(n: *Normalizer, class_: *const ir.Class) Error!ir.TypeScriptClass {
    const raw = n.declared_classes.items[class_.id.index].class;
    const constructor = n.get(class_.constructor);
    const constructors = if (functionExposed(n, class_.constructor)) try declarations(n, constructor) else &.{};
    const calls = if (class_.constructor_call) |id| if (functionExposed(n, id)) try declarations(n, n.get(id)) else &.{} else &.{};
    const callable = calls.len != 0;
    var members: std.ArrayList(ir.TypeScriptClassMember) = .empty;
    var statics: std.ArrayList(ir.TypeScriptClassMember) = .empty;
    const engine_iterator = if (raw.options.parent) |parent| switch (parent) {
        .engine => |engine| engine.prototype == .iterator,
        .class => false,
    } else false;
    if ((raw.options.prototype_base == .iterator or engine_iterator) and !declaresIterator(n, class_, .iterator))
        try members.append(n.arena, .{ .is_static = false, .operation = .{ .iterator = .synchronous } });
    if (raw.options.prototype_base == .async_iterator and !declaresIterator(n, class_, .async_iterator))
        try members.append(n.arena, .{ .is_static = false, .operation = .{ .iterator = .asynchronous } });
    for (class_.declarations) |id| {
        const function = n.get(id);
        if (!functionExposed(n, id)) continue;
        const member = n.declaration(function.id).member.?.raw;
        if (member.options.private_symbol != null) continue;
        const name = key(if (member.options.symbol) |symbol| .{ .symbol = symbol } else .{ .name = function.js_name }) orelse continue;
        const is_static = member.kind.isStatic();
        const output = if (callable and is_static) &statics else &members;
        const prefix_static = is_static and !callable;
        switch (member.kind) {
            .method, .static_method => {
                const overloads = try declarations(n, function);
                try method(n, output, overloads, name, prefix_static);
                for (member.options.aliases) |alias| if (key(alias.key)) |alias_name| try method(n, output, overloads, alias_name, prefix_static);
            },
            .getter, .static_getter => try output.append(n.arena, .{
                .is_static = prefix_static,
                .operation = .{ .getter = .{ .name = function.js_name, .declaration = function.id, .writable = member.options.writable } },
            }),
            .setter, .static_setter => {
                try output.append(n.arena, .{
                    .is_static = prefix_static,
                    .operation = .{ .setter = .{ .name = function.js_name, .argument = function.args[0].position } },
                });
            },
            .constructor => unreachable,
        }
    }
    for (raw.properties) |property| {
        const name = key(property.key) orelse continue;
        const is_static = property.options.storage == .constructor;
        const output = if (callable and is_static) &statics else &members;
        try output.append(n.arena, .{
            .is_static = is_static and !callable,
            .operation = .{ .property = .{
                .key = name,
                .read_only = !property.options.writable,
                .value = .{ .primitive = switch (property.value) {
                    .boolean => .boolean,
                    .signed, .unsigned, .float => .number,
                    .string => .string,
                    .null => .null_value,
                    .undefined => .undefined_value,
                } },
            } },
        });
    }
    for (class_.instance_properties, raw.instance_properties) |property, declared| {
        if (declared.options.private_symbol != null) continue;
        try members.append(n.arena, .{ .is_static = false, .operation = .{ .property = .{
            .key = .{ .name = property.property_name },
            .read_only = false,
            .value = .{ .type = n.get(property.position).type },
        } } });
    }
    for (class_.slots, raw.slots) |slot, declared| {
        if (!declared.options.exposed or mod_classes.slotCachesMember(n, class_, slot) or declared.options.private_symbol != null) continue;
        const is_static = slot.storage == .constructor;
        const output = if (callable and is_static) &statics else &members;
        try output.append(n.arena, .{ .is_static = is_static and !callable, .operation = .{ .property = .{
            .key = .{ .name = slot.slot_name },
            .read_only = slot.write == null,
            .value = .{ .type = slot.declared_type },
        } } });
    }
    return .{
        .members = members.items,
        .declaration = if (callable) .{ .callable = .{ .constructors = constructors, .calls = calls, .members = statics.items } } else .{ .class = constructors },
    };
}
