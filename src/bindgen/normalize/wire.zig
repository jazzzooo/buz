const mod_wire_declarations = @import("wire_declarations.zig");
const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const structural = @import("../structural.zig");
const Normalizer = normalize.Normalizer;
const Error = normalize.Error;

/// The C layout of a semantic type at a crossing; both result roles share one layout.
const Shape = enum {
    argument,
    result,
    engine_argument,

    fn of(role: ir.Role) Shape {
        return switch (role) {
            .inbound_argument => .argument,
            .inbound_result, .outbound_result => .result,
            .outbound_argument => .engine_argument,
        };
    }
};

const Composite = union(enum) {
    optional: @FieldType(ir.TypeData, "optional"),
    dictionary: @FieldType(ir.TypeData, "dictionary"),
    union_type: @FieldType(ir.TypeData, "union_type"),
    sequence: @FieldType(ir.TypeData, "sequence"),
    record: @FieldType(ir.TypeData, "record"),
};

pub const Builder = struct {
    n: *Normalizer,
    types: structural.OrderedMap(ir.WireType, void) = .empty,
    names: std.StringHashMapUnmanaged(ir.WireTypeId) = .empty,
    values: []std.EnumArray(Shape, ?ir.WireTypeId) = &.{},

    pub fn init(n: *Normalizer) Error!Builder {
        var builder: Builder = .{ .n = n };
        try builder.baseTypes();
        return builder;
    }

    pub fn planTypes(b: *Builder) Error!void {
        b.values = try b.n.arena.alloc(std.EnumArray(Shape, ?ir.WireTypeId), b.n.types.items.len);
        @memset(b.values, .initFill(null));
        for (0..b.n.types.items.len) |index| {
            for (std.enums.values(Shape)) |shape| _ = try b.value(.of(index), shape);
        }
    }

    pub fn planned(b: *const Builder, id: ir.TypeId, role: ir.Role) ir.WireTypeId {
        return b.values[id.index].get(.of(role)).?;
    }

    pub fn finish(b: *Builder) Error!void {
        const n = b.n;
        for (n.classes.items) |class| {
            if (!class.exposed) continue;
            if (class.representation == .plain) {
                const fields = try n.arena.alloc(ir.WireField, class.instance_properties.len);
                for (class.instance_properties, fields) |property, *field|
                    field.* = .{ .name = property.property_name, .type = n.get(property.position).wire };
                _ = try b.aggregate(try n.print("{s}_Fields", .{class.create_symbol}), fields, false);
            }
        }
        try mod_wire_declarations.build(b);
    }

    pub fn intern(b: *Builder, t: ir.WireType) Error!ir.WireTypeId {
        const entry = try b.types.getOrPut(b.n.arena, t);
        const id: ir.WireTypeId = .of(entry.index);
        if (!entry.found_existing) if (t.name()) |name| try b.names.putNoClobber(b.n.arena, try name.alloc(b.n.arena), id);
        return id;
    }

    pub fn named(b: *const Builder, name: []const u8) ir.WireTypeId {
        return b.names.get(name).?;
    }

    pub fn scalar(b: *Builder, kind: ir.WireScalar) Error!ir.WireTypeId {
        return b.intern(.{ .scalar = kind });
    }

    pub fn pointer(b: *Builder, child: ir.WireTypeId, is_const: bool) Error!ir.WireTypeId {
        return b.intern(.{ .pointer = .{ .child = child, .is_const = is_const } });
    }

    pub fn handle(b: *Builder, name: []const u8) Error!ir.WireTypeId {
        return b.intern(.{ .opaque_handle = .{ .identifier = name } });
    }

    pub fn handlePointer(b: *Builder, name: []const u8, is_const: bool) Error!ir.WireTypeId {
        return b.pointer(try b.handle(name), is_const);
    }

    pub fn aggregate(b: *Builder, name: []const u8, fields: []const ir.WireField, is_union: bool) Error!ir.WireTypeId {
        const members = if (fields.len == 0)
            try b.n.arena.dupe(ir.WireField, &.{.{ .name = "_reserved", .type = try b.scalar(.uint8_t) }})
        else
            try b.n.arena.dupe(ir.WireField, fields);
        const wire: ir.WireAggregate = .{ .name = .{ .identifier = name }, .fields = members };
        return b.intern(if (is_union) .{ .@"union" = wire } else .{ .structure = wire });
    }

    fn alias(b: *Builder, name: []const u8, child: ir.WireTypeId, constants: []const ir.WireConstant) Error!ir.WireTypeId {
        return b.intern(.{ .alias = .{ .name = .{ .identifier = name }, .child = child, .constants = constants } });
    }

    fn slice(b: *Builder, name: []const u8, child: ir.WireTypeId, is_const: bool) Error!ir.WireTypeId {
        return b.aggregate(name, &.{
            .{ .name = "ptr", .type = try b.pointer(child, is_const) },
            .{ .name = "len", .type = try b.scalar(.size_t) },
        }, false);
    }

    fn baseTypes(b: *Builder) Error!void {
        const byte = try b.scalar(.uint8_t);
        const size = try b.scalar(.size_t);
        const void_type = try b.scalar(.void);
        const void_pointer = try b.pointer(void_type, false);
        const bytes = try b.pointer(byte, false);
        const const_bytes = try b.pointer(byte, true);
        _ = try b.alias("BindStatus", byte, &.{
            .{ .name = "BIND_STATUS_OK", .value = 0 },
            .{ .name = "BIND_STATUS_PENDING_EXCEPTION", .value = 1 },
            .{ .name = "BIND_STATUS_OUT_OF_MEMORY", .value = 2 },
            .{ .name = "BIND_STATUS_FAILED", .value = 3 },
        });
        _ = try b.alias("BindCompletionDisposition", byte, &.{
            .{ .name = "BIND_COMPLETION_VALUE", .value = 0 },
            .{ .name = "BIND_COMPLETION_DOMAIN_ERROR", .value = 1 },
            .{ .name = "BIND_COMPLETION_DROP_REJECT", .value = 2 },
            .{ .name = "BIND_COMPLETION_CANCEL", .value = 3 },
            .{ .name = "BIND_COMPLETION_LEAVE_PENDING", .value = 4 },
            .{ .name = "BIND_COMPLETION_OUT_OF_MEMORY", .value = 5 },
            .{ .name = "BIND_COMPLETION_PENDING_EXCEPTION", .value = 6 },
        });
        _ = try b.alias("BindEncodedJSValue", try b.scalar(.int64_t), &.{});
        const string_encoding = try b.alias("BindStringEncoding", byte, &.{
            .{ .name = "BIND_STRING_LATIN1", .value = 0 },
            .{ .name = "BIND_STRING_UTF16", .value = 1 },
        });
        inline for (.{ "BindByteOwnerReleaseCallback", "BindExternalStringReleaseCallback" }) |name| {
            _ = try b.intern(.{ .function_pointer = .{
                .name = .{ .identifier = name },
                .result = void_type,
                .parameters = try b.n.arena.dupe(ir.WireTypeId, &.{ void_pointer, bytes, size }),
            } });
        }
        _ = try b.intern(.{ .function_pointer = .{
            .name = .{ .identifier = "BindExternalBytesReleaseCallback" },
            .result = void_type,
            .parameters = try b.n.arena.dupe(ir.WireTypeId, &.{ void_pointer, void_pointer }),
        } });
        inline for (.{
            "BindGlobalObjectHandle",    "BindWeakRefHandle",             "BindExceptionHandle",      "BindLazyStorageHandle",
            "BindLazyArgumentHandle",    "BindDeferredConversionsHandle", "BindVirtualMachineHandle", "BindCallFrameHandle",
            "BindJSValueHandle",         "BindRootHandle",                "BindJSValueSliceHandle",   "BindStringHandle",
            "BindByteOwnerHandle",       "BindByteLeaseHandle",           "BindPromiseHandle",        "BindNativeHandle",
            "BindCloneSerializerHandle",
        }) |name| _ = try b.handle(name);
        _ = try b.aggregate("BindCallContext", &.{
            .{ .name = "global_object", .type = try b.handlePointer("BindGlobalObjectHandle", false) },
            .{ .name = "promise", .type = try b.handlePointer("BindPromiseHandle", false) },
            .{ .name = "native_receiver", .type = try b.handlePointer("BindNativeHandle", false) },
            .{ .name = "caller_frame", .type = try b.handlePointer("BindCallFrameHandle", true) },
            .{ .name = "deferred_conversions", .type = try b.handlePointer("BindDeferredConversionsHandle", false) },
            .{ .name = "lazy_storage", .type = try b.handlePointer("BindLazyStorageHandle", false) },
            .{ .name = "call_id", .type = try b.scalar(.uint64_t) },
        }, false);
        _ = try b.aggregate("BindJSValueSlice", &.{
            .{ .name = "handle", .type = try b.handlePointer("BindJSValueSliceHandle", true) },
            .{ .name = "len", .type = size },
        }, false);
        _ = try b.slice("BindEncodedJSValueSlice", b.named("BindEncodedJSValue"), true);
        _ = try b.aggregate("BindClassRefView", &.{
            .{ .name = "native", .type = try b.handlePointer("BindNativeHandle", true) },
            .{ .name = "wrapper", .type = try b.handlePointer("BindJSValueHandle", true) },
        }, false);
        _ = try b.aggregate("BindClassRef", &.{
            .{ .name = "native", .type = try b.handlePointer("BindNativeHandle", false) },
            .{ .name = "wrapper", .type = try b.handlePointer("BindRootHandle", false) },
        }, false);
        _ = try b.aggregate("BindByteSlice", &.{
            .{ .name = "ptr", .type = bytes },
            .{ .name = "len", .type = size },
            .{ .name = "owner", .type = try b.handlePointer("BindByteOwnerHandle", false) },
        }, false);
        _ = try b.slice("BindConstByteSlice", byte, true);
        inline for (.{ "U8", "U16", "U32", "U64" }, .{ .uint8_t, .uint16_t, .uint32_t, .uint64_t }) |suffix, kind| {
            _ = try b.slice("BindConstNative" ++ suffix ++ "Slice", try b.scalar(kind), true);
            _ = try b.slice("BindNative" ++ suffix ++ "Slice", try b.scalar(kind), false);
        }
        _ = try b.aggregate("BindCloneReader", &.{
            .{ .name = "ptr", .type = const_bytes },
            .{ .name = "end", .type = const_bytes },
        }, false);
        _ = try b.aggregate("BindStringView", &.{
            .{ .name = "ptr", .type = const_bytes },
            .{ .name = "len", .type = size },
            .{ .name = "encoding", .type = string_encoding },
        }, false);
    }

    fn value(b: *Builder, id: ir.TypeId, shape: Shape) Error!ir.WireTypeId {
        if (b.values[id.index].get(shape)) |existing| return existing;
        const t = b.n.irType(id);
        const wire = switch (t.data) {
            .void => try b.scalar(.void),
            .boolean, .discarded => try b.scalar(.uint8_t),
            .i8 => try b.scalar(.int8_t),
            .u8 => try b.scalar(.uint8_t),
            .i16 => try b.scalar(.int16_t),
            .u16 => try b.scalar(.uint16_t),
            .i32 => try b.scalar(.int32_t),
            .u32 => try b.scalar(.uint32_t),
            .i64 => try b.scalar(.int64_t),
            .u64, .usize => try b.scalar(.uint64_t),
            .f64 => try b.scalar(.double),
            .any, .branded_value, .engine_value => if (shape == .argument) try b.handlePointer("BindJSValueHandle", true) else b.named("BindEncodedJSValue"),
            .callback => if (shape == .result) try b.handlePointer("BindRootHandle", false) else try b.handlePointer("BindJSValueHandle", true),
            .lazy => |child| if (shape == .result) try b.value(child, .result) else try b.handlePointer("BindLazyArgumentHandle", false),
            .converted => |converted| try b.value(if (shape == .engine_argument) b.n.typeId(b.n.rawType(id).converted.match) else converted.native_type, shape),
            .dom_string, .usv_string, .byte_string => try b.handlePointer("BindStringHandle", shape != .result),
            .utf8_string, .node_path => b.named(if (shape == .result) "BindByteSlice" else "BindConstByteSlice"),
            .buffer => if (b.n.projection(t.id).buffer.?.effective_mode == .lease)
                try b.handlePointer("BindByteLeaseHandle", shape != .result)
            else
                b.named(if (shape == .result) "BindByteSlice" else "BindConstByteSlice"),
            .native_slice => |native_slice| b.named(switch (native_slice.native_slice_element) {
                .uint8 => if (native_slice.native_slice_access == .read_write) "BindNativeU8Slice" else "BindConstNativeU8Slice",
                .uint16 => if (native_slice.native_slice_access == .read_write) "BindNativeU16Slice" else "BindConstNativeU16Slice",
                .uint32 => if (native_slice.native_slice_access == .read_write) "BindNativeU32Slice" else "BindConstNativeU32Slice",
                .uint64 => if (native_slice.native_slice_access == .read_write) "BindNativeU64Slice" else "BindConstNativeU64Slice",
            }),
            .nominal_handle => |nominal| try b.pointer(nominal.wire, false),
            .external_ref => |external| try b.pointer(b.n.get(external).wire, shape != .result),
            .native_instance => try b.handlePointer("BindNativeHandle", shape != .result),
            .class_ref => b.named(if (shape == .result) "BindClassRef" else "BindClassRefView"),
            .enumeration => |enumeration_id| blk: {
                const enumeration = b.n.get(enumeration_id);
                const name = try b.n.print("BunBind_Enumeration_{x:0>16}", .{b.n.type_metadata.items[t.id.index].name_hash});
                const constants = try b.n.arena.alloc(ir.WireConstant, enumeration.enumeration_values.len);
                for (enumeration.enumeration_values, constants) |entry, *constant| constant.* = .{
                    .name = try b.n.print("{s}_{s}", .{ name, entry.value_name }),
                    .value = entry.native_value,
                };
                break :blk try b.alias(name, try b.scalar(switch (enumeration.tag) {
                    .u8 => .uint8_t,
                    .u16 => .uint16_t,
                }), constants);
            },
            inline .optional, .dictionary, .union_type, .sequence, .record => |value_, tag| try b.composite(id, shape, @unionInit(Composite, @tagName(tag), value_)),
        };
        b.values[id.index].set(shape, wire);
        return wire;
    }

    fn composite(b: *Builder, id: ir.TypeId, shape: Shape, data: Composite) Error!ir.WireTypeId {
        const t = b.n.irType(id);
        if (shape == .engine_argument and try b.sameArgumentChildren(data)) return b.value(id, .argument);
        const label = switch (data) {
            .optional => "Optional",
            .dictionary => "Dictionary",
            .union_type => "Union",
            .sequence => "Sequence",
            .record => "Record",
        };
        const suffix = switch (shape) {
            .argument => "Argument",
            .result => "Result",
            .engine_argument => "EngineArgument",
        };
        const name = if (data == .optional)
            try b.n.print("BunBind_Optional_{x:0>16}_{s}", .{ b.n.type_metadata.items[t.id.index].name_hash, suffix })
        else
            try b.n.print("BunBind_{s}_{s}_{x:0>16}", .{ label, suffix, b.n.type_metadata.items[t.id.index].name_hash });
        switch (data) {
            .optional => |optional| return b.aggregate(name, &.{
                .{ .name = "present", .type = try b.scalar(.uint8_t) },
                .{ .name = "value", .type = try b.value(optional.child, shape) },
            }, false),
            .dictionary => |dictionary| {
                var fields: std.ArrayList(ir.WireField) = .empty;
                for (dictionary.dictionary_fields) |field| {
                    if (field.storage == .optional) try fields.append(b.n.arena, .{
                        .name = try b.n.print("{s}_present", .{field.field_name}),
                        .type = try b.scalar(.uint8_t),
                    });
                    try fields.append(b.n.arena, .{ .name = field.field_name, .type = try b.value(field.field_type, shape) });
                }
                return b.aggregate(name, fields.items, false);
            },
            .union_type => |union_type| {
                const fields = try b.n.arena.alloc(ir.WireField, union_type.union_members.len);
                const constants = try b.n.arena.alloc(ir.WireConstant, fields.len);
                for (union_type.union_members, fields, constants, 1..) |member, *field, *constant, tag| {
                    field.* = .{ .name = member.member_name, .type = try b.value(member.member_type, shape) };
                    constant.* = .{ .name = try b.n.print("{s}_TAG_{s}", .{ name, member.member_name }), .value = tag };
                }
                return b.tagged(name, fields, constants);
            },
            .sequence => |sequence| return b.slice(name, try b.value(sequence.child, shape), shape != .result),
            .record => |record| {
                const entry = try b.aggregate(try b.n.print("{s}_Entry", .{name}), &.{
                    .{ .name = "key", .type = try b.value(record.key_type, shape) },
                    .{ .name = "value", .type = try b.value(record.value_type, shape) },
                }, false);
                return b.slice(name, entry, shape != .result);
            },
        }
    }

    fn sameArgumentValue(b: *Builder, id: ir.TypeId) Error!bool {
        return (try b.value(id, .argument)).index == (try b.value(id, .engine_argument)).index;
    }

    fn sameArgumentChildren(b: *Builder, data: Composite) Error!bool {
        return switch (data) {
            .optional => |optional| b.sameArgumentValue(optional.child),
            .sequence => |sequence| b.sameArgumentValue(sequence.child),
            .record => |record| try b.sameArgumentValue(record.key_type) and try b.sameArgumentValue(record.value_type),
            .dictionary => |dictionary| for (dictionary.dictionary_fields) |field| {
                if (!try b.sameArgumentValue(field.field_type)) break false;
            } else true,
            .union_type => |members| for (members.union_members) |member| {
                if (!try b.sameArgumentValue(member.member_type)) break false;
            } else true,
        };
    }

    fn tagged(b: *Builder, name: []const u8, fields: []const ir.WireField, constants: []const ir.WireConstant) Error!ir.WireTypeId {
        const tag = try b.alias(try b.n.print("{s}_Tag", .{name}), try b.scalar(.uint8_t), constants);
        const payload = try b.aggregate(try b.n.print("{s}_Payload", .{name}), fields, true);
        return b.aggregate(name, &.{ .{ .name = "tag", .type = tag }, .{ .name = "payload", .type = payload } }, false);
    }

    pub fn result(b: *Builder, name: []const u8, id: anytype, errors: []const ir.DomainErrorId) Error!ir.WireTypeId {
        const plan = b.n.get(id).*;
        const is_void = plan.isVoid();
        const result_value = if (is_void) try b.scalar(.uint8_t) else plan.wire;
        if (errors.len == 0) {
            return b.aggregate(name, &.{.{ .name = if (is_void) "_reserved" else "value", .type = result_value }}, false);
        }
        const fields = try b.n.arena.alloc(ir.WireField, errors.len + 1);
        const constants = try b.n.arena.alloc(ir.WireConstant, fields.len);
        fields[0] = .{ .name = "value", .type = result_value };
        constants[0] = .{ .name = try b.n.print("{s}_TAG_VALUE", .{name}), .value = 0 };
        for (errors, fields[1..], constants[1..], 1..) |error_id, *field, *constant, tag| {
            const domain_error = b.n.get(error_id);
            const payload = b.n.get(domain_error.position);
            field.* = .{
                .name = try b.n.print("error_{s}", .{domain_error.error_name}),
                .type = if (payload.isVoid()) try b.scalar(.uint8_t) else payload.wire,
            };
            constant.* = .{ .name = try b.n.print("{s}_TAG_ERROR_{s}", .{ name, domain_error.error_name }), .value = tag };
        }
        return b.tagged(name, fields, constants);
    }

    pub fn arguments(b: *Builder, name: []const u8, args: anytype) Error!ir.WireTypeId {
        const fields = try b.n.arena.alloc(ir.WireField, args.len);
        for (args, fields) |argument, *field| field.* = .{ .name = argument.argument_name, .type = b.n.get(argument.position).*.wire };
        return b.aggregate(name, fields, false);
    }

    pub fn functionArguments(b: *Builder, name: []const u8, args: []const ir.Argument(.inbound_argument), invocation: []const ?ir.Argument(.inbound_argument)) Error!ir.WireTypeId {
        var fields: std.ArrayList(ir.WireField) = .empty;
        for (invocation) |argument| if (argument) |invocation_arg| try fields.append(b.n.arena, .{ .name = invocation_arg.argument_name, .type = b.n.get(invocation_arg.position).wire });
        for (args) |argument| {
            if (argument.conversion.rest) {
                try fields.append(b.n.arena, .{ .name = argument.argument_name, .type = b.n.get(argument.rest_position.?.plan()).wire });
            } else {
                if (argument.conversion.presence == .optional) try fields.append(b.n.arena, .{ .name = try b.n.print("{s}_present", .{argument.argument_name}), .type = try b.scalar(.uint8_t) });
                try fields.append(b.n.arena, .{ .name = argument.argument_name, .type = b.n.get(argument.position).wire });
            }
        }
        return b.aggregate(name, fields.items, false);
    }

    pub fn outboundArguments(b: *Builder, name: []const u8, args: []const ir.Argument(.outbound_argument), receiver: ?ir.OutboundArgumentPlanId, callee: ?ir.OutboundArgumentPlanId) Error!ir.WireTypeId {
        var fields: std.ArrayList(ir.WireField) = .empty;
        if (callee) |id| try fields.append(b.n.arena, .{ .name = "bindingCallee", .type = b.n.get(id).wire });
        if (receiver) |id| try fields.append(b.n.arena, .{ .name = "bindingThis", .type = b.n.get(id).wire });
        for (args) |argument| try fields.append(b.n.arena, .{ .name = argument.argument_name, .type = b.n.get(argument.valuePosition()).wire });
        return b.aggregate(name, fields.items, false);
    }

    pub fn deferredResult(b: *Builder, symbol: []const u8, child: ir.InboundArgumentPlanId) Error!ir.WireTypeId {
        return b.intern(.{ .structure = .{ .name = .{ .lazy_result = symbol }, .fields = try b.n.arena.dupe(ir.WireField, &.{.{ .name = "value", .type = b.n.get(child).wire }}) } });
    }
};
