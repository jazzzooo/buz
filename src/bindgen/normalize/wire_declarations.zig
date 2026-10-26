const std = @import("std");
const ir = @import("bindgen_ir");
const normalize = @import("../normalize.zig");
const wire = @import("wire.zig");
const Error = normalize.Error;

pub fn build(builder: *wire.Builder) Error!void {
    var d: Declarations = .{ .b = builder };
    try d.runtime();
    const n = builder.n;
    for (n.types.items[0..n.binding_type_count]) |t| switch (t.data) {
        .external_ref => |reference| {
            const external = n.get(reference);
            const handle = try builder.pointer(external.wire, false);
            try d.function(external.clone_symbol, handle, &.{parameter("handle", try builder.pointer(external.wire, true))}, .{});
            try d.function(external.release_symbol, try builder.scalar(.void), &.{parameter("handle", handle)}, .{});
        },
        .nominal_handle => |handle| switch (handle.ownership) {
            .borrowed => {},
            .owned => |owner_id| {
                const owner = n.get(owner_id);
                const pointer = try builder.pointer(handle.wire, false);
                try d.function(owner.release_symbol, try builder.scalar(.void), &.{parameter("handle", pointer)}, .{});
                if (owner.byte_access) |access| try d.function(access.symbol, try builder.scalar(.void), &.{ parameter("handle", pointer), parameter("out", try builder.pointer(builder.named("BindConstByteSlice"), false)) }, .{});
            },
        },
        .callback => |id| try d.outbound(&n.callback_calls[id.index]),
        else => {},
    };
    for (n.rolePlans(.inbound_argument), 0..) |position, index| {
        const id: ir.InboundArgumentPlanId = .of(index);
        if (position.representation != .leaf or position.representation.leaf != .lazy_field) continue;
        const child = position.representation.leaf.lazy_field;
        const symbol = try n.lazyFieldSymbol(id);
        try d.lazyField(.{ .lazy_field_convert = symbol }, n.get(child).wire);
        try d.lazyField(.{ .lazy_field_discard = symbol }, null);
    }
    for (n.modules, 0..) |module, module_index| {
        for (0..module.functions.len) |index| {
            const f = &n.functions.items[n.function_module_offsets[module_index] + index];
            if (!(f.exposed and f.backend == .zig) and f.completion == null) continue;
            try d.functionEntries(f);
        }
    }
    for (n.engine_shims.items) |shim| {
        try d.outbound(&shim.outbound);
        try d.destructor(shim.destroy_result_symbol, shim.outbound.wire_result);
    }
    for (n.native_exports.items) |native_export| {
        if (!native_export.exposed) continue;
        try d.lazyArguments(native_export.args, native_export.call_plan);
        try d.dispatch(native_export.dispatch_symbol, native_export.wire_args, native_export.wire_result, native_export.call_plan.non_returning);
        try d.destructor(native_export.destroy_result_symbol, native_export.wire_result);
        try d.nativeAdapter(&native_export);
    }
    for (n.classes.items) |class| if (class.exposed) try d.class(&class);
}

fn parameter(name: []const u8, value: ir.WireTypeId) ir.WireField {
    return .{ .name = name, .type = value };
}

const Declarations = struct {
    b: *wire.Builder,

    const Options = struct { non_returning: bool = false };

    fn function(d: *Declarations, name: []const u8, result: ir.WireTypeId, parameters: []const ir.WireField, options: Options) Error!void {
        return d.symbolicFunction(.{ .identifier = name }, result, parameters, options);
    }

    fn symbolicFunction(d: *Declarations, name: ir.WireName, result: ir.WireTypeId, parameters: []const ir.WireField, options: Options) Error!void {
        _ = try d.b.intern(.{ .function = .{
            .name = name,
            .result = result,
            .parameters = try d.b.n.arena.dupe(ir.WireField, parameters),
            .non_returning = options.non_returning,
            .body = .declaration,
        } });
    }

    fn nativePosition(n: *const normalize.Normalizer, id: anytype) @TypeOf(n.get(id)) {
        const position = n.get(id);
        return switch (position.representation) {
            .converted => |conversion| nativePosition(n, conversion.apiValue()),
            .dictionary, .optional, .record, .record_entry, .rest, .sequence, .union_type, .leaf => position,
        };
    }

    fn nativeAdapter(d: *Declarations, native_export: *const ir.NativeExport) Error!void {
        const b = d.b;
        const n = b.n;
        if (n.rawNativeExport(native_export.id).options.standalone_header == null or native_export.call_plan.throws != .never) return;
        const result = nativePosition(n, native_export.result_position);
        if (result.isVoid() == false and (result.representation != .leaf or result.representation.leaf != .scalar)) return;
        var parameter_count: usize = 0;
        for (native_export.args) |argument| {
            const position = nativePosition(n, argument.position);
            switch (position.representation) {
                .converted, .dictionary, .optional, .record, .record_entry, .rest, .sequence, .union_type => return,
                .leaf => |leaf| switch (leaf) {
                    .scalar, .native_slice_view => {},
                    .nominal_borrow, .nominal_owned => if (n.rawType(position.type).nominal_handle.options.c_struct == null) return,
                    else => return,
                },
            }
            parameter_count += if (position.representation.leaf == .native_slice_view) @as(usize, 2) else 1;
        }
        var parameters = try std.ArrayList(ir.WireField).initCapacity(n.arena, parameter_count);
        const inputs = try n.arena.alloc(ir.WireAdapterInput, native_export.args.len);
        for (native_export.args, inputs) |argument, *input| {
            const position = nativePosition(n, argument.position);
            const name = try n.print("nativeArgument_{s}", .{argument.argument_name});
            input.* = .{ .field = argument.argument_name, .parameter = @intCast(parameters.items.len), .operation = .copy };
            switch (position.representation) {
                .converted, .dictionary, .optional, .record, .record_entry, .rest, .sequence, .union_type => unreachable,
                .leaf => |leaf| switch (leaf) {
                    .scalar => {
                        parameters.appendAssumeCapacity(parameter(name, position.wire));
                        if (n.projection(position.type).scalar_kind == .boolean) input.operation = .boolean;
                    },
                    .nominal_borrow, .nominal_owned => {
                        const handle = n.irType(position.type).data.nominal_handle;
                        const c_struct = n.rawType(position.type).nominal_handle.options.c_struct orelse return n.reject(try n.print("{s}.{s}", .{ native_export.module_name, native_export.export_name }), "a native C adapter requires a declared C struct", .{});
                        const pointee = b.names.get(c_struct) orelse try b.intern(.{ .forward_structure = .{ .identifier = c_struct } });
                        switch (b.types.keys()[pointee.index]) {
                            .opaque_handle, .forward_structure, .structure => {},
                            else => return n.reject(try n.print("{s}.{s}", .{ native_export.module_name, native_export.export_name }), "native C struct name conflicts with a generated declaration: {s}", .{c_struct}),
                        }
                        parameters.appendAssumeCapacity(parameter(name, try b.pointer(pointee, handle.const_pointee)));
                        input.operation = .{ .nonnull_pointer = position.wire };
                    },
                    .native_slice_view => {
                        const fields = b.types.keys()[position.wire.index].structure.fields;
                        parameters.appendAssumeCapacity(parameter(name, fields[0].type));
                        input.operation = .{ .slice = @intCast(parameters.items.len) };
                        parameters.appendAssumeCapacity(parameter(try n.print("nativeArgumentLength_{s}", .{argument.argument_name}), fields[1].type));
                    },
                    .void, .enumeration, .js_value_view, .string_view, .bytes_view, .byte_lease, .callback_view, .class_view, .external_view, .native_receiver, .lazy_field, .lazy_view, .lazy_rest => unreachable,
                },
            }
        }
        _ = try b.intern(.{ .function = .{
            .name = .{ .identifier = try n.print("bunBindgenC_{s}_{s}", .{ native_export.module_name, native_export.export_name }) },
            .result = result.wire,
            .parameters = parameters.items,
            .non_returning = native_export.call_plan.non_returning,
            .body = .{ .adapter = .{
                .callee = b.named(native_export.dispatch_symbol),
                .call_id = b.named("bun_bindgen_take_call_id"),
                .context = b.named("BindCallContext"),
                .arguments = native_export.wire_args,
                .result = native_export.wire_result,
                .status = b.named("BindStatus"),
                .result_field = if (result.isVoid()) null else "value",
                .inputs = inputs,
            } },
        } });
    }

    fn dispatch(d: *Declarations, symbol: []const u8, args: ir.WireTypeId, result: ir.WireTypeId, non_returning: bool) Error!void {
        const b = d.b;
        try d.function(symbol, b.named("BindStatus"), &.{
            parameter("context", try b.pointer(b.named("BindCallContext"), false)),
            parameter("args", try b.pointer(args, true)),
            parameter("result", try b.pointer(result, false)),
        }, .{ .non_returning = non_returning });
    }

    fn outbound(d: *Declarations, call: *const ir.OutboundCall) Error!void {
        for (call.entries) |entry| try d.dispatch(entry.symbol, call.wire_args, call.wire_result, false);
    }

    fn destructor(d: *Declarations, symbol: ?[]const u8, result: ir.WireTypeId) Error!void {
        if (symbol) |name| try d.function(name, try d.b.scalar(.void), &.{parameter("result", try d.b.pointer(result, false))}, .{});
    }

    fn functionEntries(d: *Declarations, f: *const ir.Function) Error!void {
        if (f.isOverloaded()) {
            if (f.hasWireResult() and (f.class_member == null or f.class_member.?.member_kind == .constructor)) {
                return d.b.n.reject(try d.b.n.print("{s}.{s}", .{ f.module_name, f.function_name }), "asynchronous overloads require a class member", .{});
            }
            for (f.overload_cases) |id| try d.functionEntry(&d.b.n.overload_cases.items[id.index]);
            if (f.hasWireResult()) try d.functionResult(f);
        } else {
            try d.functionEntry(f);
        }
    }

    fn functionEntry(d: *Declarations, f: *const ir.Function) Error!void {
        try d.lazyArguments(f.args, f.call_plan);
        try d.dispatch(f.dispatch_symbol, f.wire_args.?, f.wire_result, f.call_plan.non_returning);
        try d.functionResult(f);
    }

    fn functionResult(d: *Declarations, f: *const ir.Function) Error!void {
        const b = d.b;
        const void_type = try b.scalar(.void);
        const result = try b.pointer(f.wire_result, false);
        if (f.completion) |completion_id| {
            const completion = b.n.get(completion_id);
            const global = try b.handlePointer("BindGlobalObjectHandle", false);
            const promise = try b.handlePointer("BindPromiseHandle", false);
            const disposition = b.named("BindCompletionDisposition");
            if (completion.cpp_api) |api_id| {
                const api = b.n.get(api_id);
                const handle = try b.pointer(api.handle, false);
                try d.function(api.create, b.named("BindStatus"), &.{ parameter("global", global), parameter("promise", promise), parameter("out", try b.pointer(handle, false)) }, .{});
                try d.function(api.clone, void_type, &.{parameter("handle", handle)}, .{});
                try d.function(api.release, void_type, &.{parameter("handle", handle)}, .{});
                try d.function(api.finish, void_type, &.{ parameter("handle", handle), parameter("status", try b.scalar(.uint8_t)) }, .{});
                try d.function(api.settle, void_type, &.{ parameter("handle", handle), parameter("disposition", disposition), parameter("result", result) }, .{});
            }
            try d.function(completion.deliver_symbol, void_type, &.{ parameter("global", global), parameter("promise", promise), parameter("disposition", disposition), parameter("result", result) }, .{});
        }
        try d.destructor(f.destroy_result_symbol, f.wire_result);
    }

    fn lazyArguments(d: *Declarations, args: []const ir.Argument(.inbound_argument), call_plan: ir.CallPlan(.inbound_argument)) Error!void {
        const b = d.b;
        const status = b.named("BindStatus");
        const global = try b.handlePointer("BindGlobalObjectHandle", false);
        const storage = try b.handlePointer("BindLazyStorageHandle", false);
        const deferred = try b.handlePointer("BindDeferredConversionsHandle", false);
        const proof = try b.pointer(deferred, false);
        const last = try b.scalar(.uint8_t);
        for (args) |argument| {
            if (b.n.input_plans.items[b.n.get(argument.position).input.index].codec != .lazy) continue;
            const protocol = argument.valuePosition();
            const lazy = switch (b.n.get(protocol).representation) {
                .converted, .dictionary, .optional, .record, .record_entry, .rest, .sequence, .union_type => unreachable,
                .leaf => |leaf| switch (leaf) {
                    .lazy_view, .lazy_rest => |position| position,
                    .void, .scalar, .enumeration, .js_value_view, .string_view, .bytes_view, .native_slice_view, .byte_lease, .callback_view, .class_view, .external_view, .nominal_borrow, .nominal_owned, .native_receiver, .lazy_field => unreachable,
                },
            };
            const symbol = try b.n.lazyCallSymbol(lazy);
            const deferred_wire = try b.deferredResult(symbol, lazy.value);
            var parameter_buffer: [8]ir.WireField = undefined;
            var params: std.ArrayList(ir.WireField) = .initBuffer(&parameter_buffer);
            params.appendSliceAssumeCapacity(&.{ parameter("global", global), parameter("storage", storage), parameter("deferred", deferred), parameter("last", last) });
            const lazy_value = if (argument.conversion.rest) try b.handlePointer("BindJSValueHandle", true) else try b.handlePointer("BindLazyArgumentHandle", false);
            params.appendAssumeCapacity(parameter("value", lazy_value));
            if (argument.conversion.rest) params.appendAssumeCapacity(parameter("element_index", try b.scalar(.size_t)));
            params.appendSliceAssumeCapacity(&.{ parameter("proof", proof), parameter("result", try b.pointer(deferred_wire, false)) });
            try d.symbolicFunction(.{ .lazy_convert = symbol }, status, params.items, .{});
            if (call_plan.acquires_byte_lease) try d.symbolicFunction(.{ .lazy_discard = symbol }, status, params.items[0 .. params.items.len - 1], .{});
        }
    }

    fn lazyField(d: *Declarations, symbol: ir.WireName, output: ?ir.WireTypeId) Error!void {
        const b = d.b;
        const deferred = try b.handlePointer("BindDeferredConversionsHandle", false);
        var parameter_buffer: [6]ir.WireField = undefined;
        var params: std.ArrayList(ir.WireField) = .initBuffer(&parameter_buffer);
        params.appendSliceAssumeCapacity(&.{
            parameter("global", try b.handlePointer("BindGlobalObjectHandle", false)),
            parameter("value", try b.handlePointer("BindLazyArgumentHandle", false)),
            parameter("deferred", deferred),
            parameter("last", try b.scalar(.uint8_t)),
            parameter("proof", try b.pointer(deferred, false)),
        });
        if (output) |value| params.appendAssumeCapacity(parameter("out", try b.pointer(value, false)));
        try d.symbolicFunction(symbol, b.named("BindStatus"), params.items, .{});
    }

    fn class(d: *Declarations, c: *const ir.Class) Error!void {
        const b = d.b;
        const void_type = try b.scalar(.void);
        const status = b.named("BindStatus");
        const global = try b.handlePointer("BindGlobalObjectHandle", false);
        const vm = try b.handlePointer("BindVirtualMachineHandle", false);
        const native = try b.handlePointer("BindNativeHandle", false);
        const encoded = b.named("BindEncodedJSValue");
        const out_value = try b.pointer(encoded, false);
        const context = try b.pointer(b.named("BindCallContext"), false);
        for (c.declarations) |id| {
            const member = b.n.functions.items[id.index];
            if (!member.exposed) continue;
            if (member.class_member.?.native_reference_symbol) |symbol| try d.function(symbol, status, &.{ parameter("global", global), parameter("out_value", out_value) }, .{});
        }
        const constructor = &b.n.functions.items[c.constructor.index];
        if (constructor.exposed) try d.function(c.get_constructor_symbol, void_type, &.{ parameter("global", global), parameter("out_value", out_value) }, .{});
        if (c.representation == .plain) {
            const fields = b.named(try b.n.print("{s}_Fields", .{c.create_symbol}));
            try d.function(c.create_symbol, status, &.{ parameter("global", global), parameter("fields", try b.pointer(fields, true)), parameter("out_value", out_value) }, .{});
        } else {
            try d.function(c.try_cast_symbol, native, &.{parameter("value", encoded)}, .{});
            try d.function(c.try_cast_direct_symbol, native, &.{parameter("value", encoded)}, .{});
        }
        for (c.slots) |slot| {
            try d.function(slot.get_symbol, try b.handlePointer("BindJSValueHandle", true), &.{parameter("wrapper", encoded)}, .{});
            if (slot.write) |write| {
                try d.function(write.set, void_type, &.{ parameter("global", global), parameter("wrapper", encoded), parameter("value", encoded) }, .{});
                try d.function(write.clear_weak, void_type, &.{parameter("wrapper", try b.handlePointer("BindWeakRefHandle", true))}, .{});
            }
        }
        if (c.representation == .native) {
            try d.function(c.wrap_native_symbol, status, &.{ parameter("global", global), parameter("native", native), parameter("out_value", out_value) }, .{});
            try d.function(c.destroy_native_symbol, void_type, &.{ parameter("vm", vm), parameter("native", native) }, .{});
            try d.function(c.destroy_pending_native_symbol, void_type, &.{parameter("native", native)}, .{});
            try d.function(c.release_native_on_vm_symbol, void_type, &.{ parameter("vm", vm), parameter("native", native) }, .{});
        }
        const runtime_plan = c.runtime_plan;
        switch (runtime_plan.construction.external_initialization) {
            .native_subclass, .root_native_subclass => |symbol| try d.function(symbol, status, &.{ parameter("global", global), parameter("native", native) }, .{}),
            .none => {},
        }
        switch (runtime_plan.identity) {
            .per_realm_registry => |symbol| try d.function(symbol, try b.scalar(.uint64_t), &.{parameter("native", native)}, .{}),
            .plain_value, .fresh_wrapper, .engine_constructor_only, .engine_wrapper_cache => {},
        }
        if (c.upcast) |upcast| try d.function(upcast.symbol, native, &.{parameter("native", native)}, .{});
        if (c.memory_usage) |memory| {
            const params: []const ir.WireField = if (memory.affinity == .any) &.{parameter("native", native)} else &.{ parameter("vm", vm), parameter("native", native) };
            try d.function(memory.symbol, try b.scalar(.size_t), params, .{});
        }
        if (c.pending_activity) |symbol| try d.function(symbol, try b.scalar(.uint8_t), &.{parameter("native", native)}, .{});
        if (runtime_plan.construction.wrapper_created) |symbol| try d.function(symbol, status, &.{ parameter("context", context), parameter("wrapper", try b.pointer(b.named("BindClassRefView"), true)) }, .{});
        if (c.structured_clone) |clone_id| {
            const clone = b.n.get(clone_id);
            const out_native = try b.pointer(native, false);
            switch (clone.serialization) {
                .shared => |plan| {
                    const shared = try b.pointer(plan.handle, false);
                    try d.function(clone.serialize_symbol, status, &.{ parameter("context", context), parameter("native", native), parameter("out_shared", try b.pointer(shared, false)) }, .{});
                    try d.function(clone.deserialize_symbol, status, &.{ parameter("context", context), parameter("shared", shared), parameter("out_native", out_native) }, .{});
                    try d.function(plan.release_symbol, void_type, &.{parameter("shared", shared)}, .{});
                },
                .bytes => {
                    try d.function(clone.serialize_symbol, status, &.{ parameter("context", context), parameter("native", native), parameter("serializer", try b.handlePointer("BindCloneSerializerHandle", false)) }, .{});
                    try d.function(clone.deserialize_symbol, status, &.{ parameter("context", context), parameter("reader", try b.pointer(b.named("BindCloneReader"), false)), parameter("out_native", out_native) }, .{});
                },
            }
        }
        if (constructor.exposed and constructor.backend == .zig) try d.functionEntries(constructor);
        if (c.constructor_call) |id| {
            const call = b.n.get(id);
            if (call.exposed and call.backend == .zig) try d.functionEntries(call);
        }
        for (c.declarations) |id| {
            const member = &b.n.functions.items[id.index];
            if (!member.exposed or (member.backend != .zig and !member.isAsync())) continue;
            try d.functionEntries(member);
        }
    }

    fn runtime(d: *Declarations) Error!void {
        const b = d.b;
        try d.function("bun_bindgen_take_call_id", try b.scalar(.uint64_t), &.{}, .{});
        try d.function("bun_bindgen_check_traps", b.named("BindStatus"), &.{ parameter("global", try b.pointer(b.named("BindGlobalObjectHandle"), false)), parameter("status", b.named("BindStatus")) }, .{});
        try d.function("bun_bindgen_current_exception", try b.pointer(b.named("BindExceptionHandle"), true), &.{parameter("global", try b.pointer(b.named("BindGlobalObjectHandle"), false))}, .{});
        try d.function("bun_bindgen_check_traps_inheriting", b.named("BindStatus"), &.{ parameter("global", try b.pointer(b.named("BindGlobalObjectHandle"), false)), parameter("status", b.named("BindStatus")), parameter("inherited", try b.pointer(b.named("BindExceptionHandle"), true)) }, .{});
        try d.function("bun_bindgen_check_post_call_traps", b.named("BindStatus"), &.{ parameter("global", try b.pointer(b.named("BindGlobalObjectHandle"), false)), parameter("status", b.named("BindStatus")) }, .{});
        try d.function("bun_bindgen_string_view", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindStringHandle"), true)), parameter("out", try b.pointer(b.named("BindStringView"), false)) }, .{});
        try d.function("bun_bindgen_string_retain", try b.scalar(.void), &.{parameter("handle", try b.pointer(b.named("BindStringHandle"), false))}, .{});
        try d.function("bun_bindgen_string_release", try b.scalar(.void), &.{parameter("handle", try b.pointer(b.named("BindStringHandle"), false))}, .{});
        try d.function("bun_bindgen_string_create_uninitialized", b.named("BindStatus"), &.{ parameter("len", try b.scalar(.size_t)), parameter("encoding", b.named("BindStringEncoding")), parameter("out_handle", try b.pointer(try b.pointer(b.named("BindStringHandle"), false), false)), parameter("out_data", try b.pointer(try b.pointer(try b.scalar(.uint8_t), false), false)) }, .{});
        try d.function("bun_bindgen_string_create_external", b.named("BindStatus"), &.{ parameter("data", try b.pointer(try b.scalar(.uint8_t), true)), parameter("len", try b.scalar(.size_t)), parameter("encoding", b.named("BindStringEncoding")), parameter("context", try b.pointer(try b.scalar(.void), false)), parameter("release", b.named("BindExternalStringReleaseCallback")), parameter("out_handle", try b.pointer(try b.pointer(b.named("BindStringHandle"), false), false)) }, .{});
        try d.function("bun_bindgen_string_create_static_external", b.named("BindStatus"), &.{ parameter("data", try b.pointer(try b.scalar(.uint8_t), true)), parameter("len", try b.scalar(.size_t)), parameter("encoding", b.named("BindStringEncoding")), parameter("out_handle", try b.pointer(try b.pointer(b.named("BindStringHandle"), false), false)) }, .{});
        try d.function("bun_bindgen_string_ensure_hash", try b.scalar(.void), &.{parameter("handle", try b.pointer(b.named("BindStringHandle"), false))}, .{});
        try d.function("bun_bindgen_js_value_read", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindJSValueHandle"), true)), parameter("out_value", try b.pointer(b.named("BindEncodedJSValue"), false)) }, .{});
        try d.function("bun_bindgen_root_borrow", try b.pointer(b.named("BindJSValueHandle"), true), &.{parameter("handle", try b.pointer(b.named("BindRootHandle"), true))}, .{});
        try d.function("bun_bindgen_root_global", try b.pointer(b.named("BindGlobalObjectHandle"), false), &.{parameter("handle", try b.pointer(b.named("BindRootHandle"), true))}, .{});
        try d.function("bun_bindgen_js_value_slice_read", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindJSValueSliceHandle"), true)), parameter("index", try b.scalar(.size_t)), parameter("out_value", try b.pointer(b.named("BindEncodedJSValue"), false)) }, .{});
        try d.function("bun_bindgen_js_value_slice_at", try b.pointer(b.named("BindJSValueHandle"), true), &.{ parameter("handle", try b.pointer(b.named("BindJSValueSliceHandle"), true)), parameter("index", try b.scalar(.size_t)) }, .{});
        try d.function("bun_bindgen_transfer_alloc", try b.pointer(try b.scalar(.uint8_t), false), &.{parameter("len", try b.scalar(.size_t))}, .{});
        try d.function("bun_bindgen_transfer_alloc_aligned", try b.pointer(try b.scalar(.uint8_t), false), &.{ parameter("len", try b.scalar(.size_t)), parameter("alignment", try b.scalar(.size_t)) }, .{});
        try d.function("bun_bindgen_transfer_free_aligned", try b.scalar(.void), &.{ parameter("ptr", try b.pointer(try b.scalar(.uint8_t), false)), parameter("len", try b.scalar(.size_t)), parameter("alignment", try b.scalar(.size_t)) }, .{});
        try d.function("bun_bindgen_transfer_free", try b.scalar(.void), &.{ parameter("ptr", try b.pointer(try b.scalar(.uint8_t), false)), parameter("len", try b.scalar(.size_t)) }, .{});
        try d.function("bun_bindgen_byte_owner_create", try b.pointer(b.named("BindByteOwnerHandle"), false), &.{ parameter("ptr", try b.pointer(try b.scalar(.uint8_t), false)), parameter("len", try b.scalar(.size_t)), parameter("context", try b.pointer(try b.scalar(.void), false)), parameter("release", b.named("BindByteOwnerReleaseCallback")) }, .{});
        try d.function("bun_bindgen_external_byte_owner_adopt", try b.pointer(b.named("BindByteOwnerHandle"), false), &.{ parameter("ptr", try b.pointer(try b.scalar(.uint8_t), false)), parameter("len", try b.scalar(.size_t)), parameter("context", try b.pointer(try b.scalar(.void), false)), parameter("release", b.named("BindExternalBytesReleaseCallback")) }, .{});
        try d.function("bun_bindgen_byte_owner_view", try b.scalar(.void), &.{ parameter("owner", try b.pointer(b.named("BindByteOwnerHandle"), true)), parameter("out", try b.pointer(b.named("BindConstByteSlice"), false)) }, .{});
        try d.function("bun_bindgen_byte_owner_release", try b.scalar(.void), &.{parameter("owner", try b.pointer(b.named("BindByteOwnerHandle"), false))}, .{});
        try d.function("bun_bindgen_byte_lease_data", try b.pointer(try b.scalar(.uint8_t), true), &.{ parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), true)), parameter("len", try b.pointer(try b.scalar(.size_t), false)) }, .{});
        try d.function("bun_bindgen_byte_lease_mutable_data", try b.pointer(try b.scalar(.uint8_t), false), &.{ parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), false)), parameter("len", try b.pointer(try b.scalar(.size_t), false)) }, .{});
        try d.function("bun_bindgen_byte_lease_source", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), true)), parameter("out", try b.pointer(b.named("BindEncodedJSValue"), false)) }, .{});
        try d.function("bun_bindgen_byte_lease_element_size", try b.scalar(.size_t), &.{parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), true))}, .{});
        try d.function("bun_bindgen_byte_lease_prepared_length", try b.scalar(.size_t), &.{parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), true))}, .{});
        try d.function("bun_bindgen_byte_lease_clone", try b.pointer(b.named("BindByteLeaseHandle"), false), &.{parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), true))}, .{});
        try d.function("bun_bindgen_byte_lease_bind_view", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), false)), parameter("slot", try b.pointer(try b.pointer(b.named("BindByteLeaseHandle"), false), false)) }, .{});
        try d.function("bun_bindgen_byte_lease_move_view", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), false)), parameter("previous", try b.pointer(try b.pointer(b.named("BindByteLeaseHandle"), false), false)), parameter("next", try b.pointer(try b.pointer(b.named("BindByteLeaseHandle"), false), false)) }, .{});
        try d.function("bun_bindgen_byte_lease_unbind_view", try b.scalar(.void), &.{ parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), false)), parameter("slot", try b.pointer(try b.pointer(b.named("BindByteLeaseHandle"), false), false)) }, .{});
        try d.function("bun_bindgen_byte_lease_release", try b.scalar(.void), &.{parameter("handle", try b.pointer(b.named("BindByteLeaseHandle"), false))}, .{});
        try d.function("bun_bindgen_deferred_leases_acquire", b.named("BindStatus"), &.{ parameter("global", try b.pointer(b.named("BindGlobalObjectHandle"), false)), parameter("deferred", try b.pointer(b.named("BindDeferredConversionsHandle"), false)) }, .{});
        try d.function("bun_bindgen_clone_write", b.named("BindStatus"), &.{ parameter("serializer", try b.pointer(b.named("BindCloneSerializerHandle"), false)), parameter("ptr", try b.pointer(try b.scalar(.uint8_t), true)), parameter("len", try b.scalar(.uint32_t)) }, .{});
    }
};
