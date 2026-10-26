pub fn StringPairIterator(comptime ClassSchema: type, comptime CreateSchema: type, comptime NextSchema: type) type {
    const Iterator = struct {
        const Self = @This();
        pub const Kind = enum { entries, keys, values };
        pub const Binding = bun.bindgen.Class(ClassSchema, Self);
        const MemberSchema = ClassSchema.member("next");
        const ValueSchema = bun.bindgen.DictionaryFieldType(MemberSchema.ReturnType, "value").child;
        const Value = bun.bindgen.ResultType(ValueSchema);
        const EntrySequence = @FieldType(Value, "entry");

        bindgen_state: bun.bindgen.ClassState = .{},
        handle: bun.bindgen.Return(CreateSchema),
        kind: Kind,
        done: bool = false,

        pub fn create(context: anytype, args: bun.bindgen.Args(CreateSchema), kind: Kind) bun.JSError!bun.bindgen.ClassRef(ClassSchema) {
            var handle = try bun.bindgen.Engine(CreateSchema).call(args);
            defer handle.deinit();
            const iterator = try bun.default_allocator.create(Self);
            iterator.* = .{ .handle = handle.take(), .kind = kind };
            return Binding.adoptResult(iterator, context);
        }

        pub fn destroy(this: *Self) void {
            this.handle.deinit();
            bun.destroy(this);
        }

        pub fn forEach(comptime receiver_name: []const u8, context: anytype, args: anytype, create_args: bun.bindgen.Args(CreateSchema)) bun.JSError!void {
            var receiver = try args.bindingThis.toOwned();
            defer receiver.deinit();
            var iterator = try bun.bindgen.Engine(CreateSchema).call(create_args);
            defer iterator.deinit();
            while (try bun.bindgen.Engine(NextSchema).call(.{ .iterator = &iterator })) |item| {
                var result: bun.bindgen.Return(NextSchema) = item;
                defer bun.bindgen.deinitReturn(NextSchema, &result);
                const entry = &result.?;
                var callback_args: bun.bindgen.Args(@TypeOf(args.callback).SemanticType) = undefined;
                callback_args.value = entry.value.operand();
                callback_args.key = entry.key.operand();
                @field(callback_args, receiver_name) = receiver.operand(context);
                callback_args.bindingThis = if (args.thisArg) |value| value.operand(context) else null;
                try args.callback.call(callback_args);
            }
        }

        pub fn next(this: *Self, _: bun.bindgen.CallContext(MemberSchema), _: bun.bindgen.Args(MemberSchema)) bun.JSError!bun.bindgen.Return(MemberSchema) {
            if (this.done) return .{ .done = true, .value = null };
            var result = try bun.bindgen.Engine(NextSchema).call(.{ .iterator = &this.handle });
            defer bun.bindgen.deinitReturn(NextSchema, &result);
            const entry = if (result) |*value| value else {
                this.done = true;
                this.handle.deinit();
                return .{ .done = true, .value = null };
            };
            return .{ .done = false, .value = switch (this.kind) {
                .entries => pair: {
                    var builder = try EntrySequence.Builder.init(2);
                    builder.appendOwned(entry.key.take());
                    builder.appendOwned(entry.value.take());
                    break :pair .{ .entry = builder.finish() };
                },
                .keys => .{ .string = entry.key.take() },
                .values => .{ .string = entry.value.take() },
            } };

        }
    };
    return Iterator;
}

const bun = @import("bun");
