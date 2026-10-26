pub fn ScopeFunctions(comptime Types: type) type {
    const BaseScopeCfg = Types.BaseScopeCfg;

    return struct {
        bindgen_state: bindgen.ClassState = .{},
        mode: Mode,
        cfg: BaseScopeCfg,
        each: ?EachArray = null,

        const Self = @This();
        const Mode = enum { describe, @"test" };

        pub const EachArray = EachArrayType;

        fn createState(
            context: anytype,
            mode: Mode,
            cfg: BaseScopeCfg,
            each: *?EachArray,
        ) bun.JSError!ScopeRef {
            const state = bun.new(Self, .{
                .mode = mode,
                .cfg = cfg,
                .each = each.*,
            });
            each.* = null;

            return Binding.adoptResult(state, context);
        }

        fn createEmptyState(context: anytype, mode: Mode, cfg: BaseScopeCfg) bun.JSError!ScopeRef {
            var each: ?EachArray = null;
            return createState(context, mode, cfg, &each);
        }

        fn cloneState(context: anytype, this: *const Self, cfg: BaseScopeCfg) bun.JSError!ScopeRef {
            var each: ?EachArray = if (this.each) |*array| array.clone() else null;
            defer if (each) |*array| array.deinit();
            return createState(context, this.mode, cfg, &each);
        }

        pub fn createTestState(
            context: bindgen.CallContext(CreateTestStateSchema),
            _: bindgen.Args(CreateTestStateSchema),
        ) bun.JSError!bindgen.Return(CreateTestStateSchema) {
            return createEmptyState(context, .@"test", .{});
        }

        pub fn createSkippedTestState(
            context: bindgen.CallContext(CreateSkippedTestStateSchema),
            _: bindgen.Args(CreateSkippedTestStateSchema),
        ) bun.JSError!bindgen.Return(CreateSkippedTestStateSchema) {
            return createEmptyState(context, .@"test", .{ .self_mode = .skip });
        }

        pub fn createDescribeState(
            context: bindgen.CallContext(CreateDescribeStateSchema),
            _: bindgen.Args(CreateDescribeStateSchema),
        ) bun.JSError!bindgen.Return(CreateDescribeStateSchema) {
            return createEmptyState(context, .describe, .{});
        }

        pub fn createSkippedDescribeState(
            context: bindgen.CallContext(CreateSkippedDescribeStateSchema),
            _: bindgen.Args(CreateSkippedDescribeStateSchema),
        ) bun.JSError!bindgen.Return(CreateSkippedDescribeStateSchema) {
            return createEmptyState(context, .describe, .{ .self_mode = .skip });
        }

        fn failInvalidScope(context: anytype, comptime name: []const u8, this: *const Self) bindgen.CallError(@TypeOf(context)) {
            const message = try std.fmt.allocPrint(bun.default_allocator, "Cannot {s} on {f}", .{ name, this.* });
            defer bun.default_allocator.free(message);
            return context.fail(.invalid_scope, try bindgen.DOMString.fromUTF8(message));
        }

        fn genericExtend(
            this: *Self,
            context: anytype,
            comptime cfg: BaseScopeCfg,
            comptime name: []const u8,
        ) bindgen.CallError(@TypeOf(context))!ScopeRef {
            if (comptime cfg.self_only) @compileError("only scopes require the deriveOnly runtime operation");
            return extendScope(this, context, cfg, name);
        }

        pub fn extendScope(
            this: *Self,
            context: anytype,
            comptime cfg: BaseScopeCfg,
            comptime name: []const u8,
        ) bindgen.CallError(@TypeOf(context))!ScopeRef {
            groupLog.begin(@src());
            defer groupLog.end();

            if (comptime cfg.self_mode == .failing) {
                if (this.mode == .describe) return failInvalidScope(context, name, this);
            }
            const extended = this.cfg.extend(cfg) orelse return failInvalidScope(context, name, this);
            return cloneState(context, this, extended);
        }

        fn genericIf(
            this: *Self,
            context: anytype,
            condition: ?bool,
            comptime conditional_cfg: BaseScopeCfg,
            comptime name: []const u8,
            comptime invert: bool,
        ) bindgen.CallError(@TypeOf(context))!ScopeRef {
            groupLog.begin(@src());
            defer groupLog.end();

            const cond = condition orelse return context.fail(.condition_required, {});
            if (cond != invert) {
                return genericExtend(this, context, conditional_cfg, name);
            }
            return cloneState(context, this, this.cfg);
        }

        pub fn deriveSkip(
            context: bindgen.CallContext(DeriveSkipSchema),
            args: bindgen.Args(DeriveSkipSchema),
        ) bindgen.CallError(DeriveSkipSchema)!bindgen.Return(DeriveSkipSchema) {
            return genericExtend(args.state.get(Self), context, .{ .self_mode = .skip }, "get .skip");
        }

        pub fn deriveTodo(
            context: bindgen.CallContext(DeriveTodoSchema),
            args: bindgen.Args(DeriveTodoSchema),
        ) bindgen.CallError(DeriveTodoSchema)!bindgen.Return(DeriveTodoSchema) {
            return genericExtend(args.state.get(Self), context, .{ .self_mode = .todo }, "get .todo");
        }

        pub fn deriveFailing(
            context: bindgen.CallContext(DeriveFailingSchema),
            args: bindgen.Args(DeriveFailingSchema),
        ) bindgen.CallError(DeriveFailingSchema)!bindgen.Return(DeriveFailingSchema) {
            return genericExtend(args.state.get(Self), context, .{ .self_mode = .failing }, "get .failing");
        }

        pub fn deriveConcurrent(
            context: bindgen.CallContext(DeriveConcurrentSchema),
            args: bindgen.Args(DeriveConcurrentSchema),
        ) bindgen.CallError(DeriveConcurrentSchema)!bindgen.Return(DeriveConcurrentSchema) {
            return genericExtend(args.state.get(Self), context, .{ .self_concurrent = .yes }, "get .concurrent");
        }

        pub fn deriveSerial(
            context: bindgen.CallContext(DeriveSerialSchema),
            args: bindgen.Args(DeriveSerialSchema),
        ) bindgen.CallError(DeriveSerialSchema)!bindgen.Return(DeriveSerialSchema) {
            return genericExtend(args.state.get(Self), context, .{ .self_concurrent = .no }, "get .serial");
        }

        pub fn deriveOnly(
            context: bindgen.CallContext(DeriveOnlySchema),
            args: bindgen.Args(DeriveOnlySchema),
        ) bindgen.CallError(DeriveOnlySchema)!bindgen.Return(DeriveOnlySchema) {
            return bun.jsc.Jest.bun_test.ScopeFunctionsEngine.deriveOnly(context, args);
        }

        pub fn deriveIf(
            context: bindgen.CallContext(DeriveIfSchema),
            args: bindgen.Args(DeriveIfSchema),
        ) bindgen.CallError(DeriveIfSchema)!bindgen.Return(DeriveIfSchema) {
            return genericIf(args.state.get(Self), context, args.condition, .{ .self_mode = .skip }, "call .if()", true);
        }

        pub fn deriveSkipIf(
            context: bindgen.CallContext(DeriveSkipIfSchema),
            args: bindgen.Args(DeriveSkipIfSchema),
        ) bindgen.CallError(DeriveSkipIfSchema)!bindgen.Return(DeriveSkipIfSchema) {
            return genericIf(args.state.get(Self), context, args.condition, .{ .self_mode = .skip }, "call .skipIf()", false);
        }

        pub fn deriveTodoIf(
            context: bindgen.CallContext(DeriveTodoIfSchema),
            args: bindgen.Args(DeriveTodoIfSchema),
        ) bindgen.CallError(DeriveTodoIfSchema)!bindgen.Return(DeriveTodoIfSchema) {
            return genericIf(args.state.get(Self), context, args.condition, .{ .self_mode = .todo }, "call .todoIf()", false);
        }

        pub fn deriveFailingIf(
            context: bindgen.CallContext(DeriveFailingIfSchema),
            args: bindgen.Args(DeriveFailingIfSchema),
        ) bindgen.CallError(DeriveFailingIfSchema)!bindgen.Return(DeriveFailingIfSchema) {
            return genericIf(args.state.get(Self), context, args.condition, .{ .self_mode = .failing }, "call .failingIf()", false);
        }

        pub fn deriveConcurrentIf(
            context: bindgen.CallContext(DeriveConcurrentIfSchema),
            args: bindgen.Args(DeriveConcurrentIfSchema),
        ) bindgen.CallError(DeriveConcurrentIfSchema)!bindgen.Return(DeriveConcurrentIfSchema) {
            return genericIf(args.state.get(Self), context, args.condition, .{ .self_concurrent = .yes }, "call .concurrentIf()", false);
        }

        pub fn deriveSerialIf(
            context: bindgen.CallContext(DeriveSerialIfSchema),
            args: bindgen.Args(DeriveSerialIfSchema),
        ) bindgen.CallError(DeriveSerialIfSchema)!bindgen.Return(DeriveSerialIfSchema) {
            return genericIf(args.state.get(Self), context, args.condition, .{ .self_concurrent = .no }, "call .serialIf()", false);
        }

        pub fn deriveEach(
            context: bindgen.CallContext(DeriveEachSchema),
            args: bindgen.Args(DeriveEachSchema),
        ) bindgen.CallError(DeriveEachSchema)!bindgen.Return(DeriveEachSchema) {
            groupLog.begin(@src());
            defer groupLog.end();

            const this = args.state.get(Self);
            if (this.each != null) return failInvalidScope(context, "each", this);

            var each: ?EachArray = try args.array.toOwned();
            defer if (each) |*array| array.deinit();
            return createState(context, this.mode, this.cfg, &each);
        }

        pub fn callAsFunction(
            context: bindgen.CallContext(ScopeFunctionsCallSchema),
            args: bindgen.Args(ScopeFunctionsCallSchema),
        ) bindgen.CallError(ScopeFunctionsCallSchema)!void {
            return bun.jsc.Jest.bun_test.ScopeFunctionsEngine.call(context, args);
        }

        pub fn format(this: Self, writer: *std.Io.Writer) !void {
            try writer.print("{s}", .{@tagName(this.mode)});
            switch (this.cfg.self_concurrent) {
                .yes => try writer.print(".concurrent", .{}),
                .no => try writer.print(".serial", .{}),
                .inherit => {},
            }
            if (this.cfg.self_mode != .normal) try writer.print(".{s}", .{@tagName(this.cfg.self_mode)});
            if (this.cfg.self_only) try writer.print(".only", .{});
            if (this.each != null) try writer.print(".each()", .{});
        }

        pub fn destroy(this: *Self) void {
            groupLog.begin(@src());
            defer groupLog.end();

            if (this.each) |*each| each.deinit();
            this.each = null;
            bun.destroy(this);
        }

        pub fn memoryUsage(_: *const Self, _: bindgen.MemoryUsageContext(.vm)) usize {
            return @sizeOf(Self);
        }

        const Binding = bindgen.Class(ScopeFunctionsSchema, Self);

        comptime {
            _ = Binding;
            _ = bindgen.Fn(CreateTestStateSchema, createTestState);
            _ = bindgen.Fn(CreateSkippedTestStateSchema, createSkippedTestState);
            _ = bindgen.Fn(CreateDescribeStateSchema, createDescribeState);
            _ = bindgen.Fn(CreateSkippedDescribeStateSchema, createSkippedDescribeState);
            _ = bindgen.Fn(DeriveConcurrentSchema, deriveConcurrent);
            _ = bindgen.Fn(DeriveConcurrentIfSchema, deriveConcurrentIf);
            _ = bindgen.Fn(DeriveEachSchema, deriveEach);
            _ = bindgen.Fn(DeriveFailingSchema, deriveFailing);
            _ = bindgen.Fn(DeriveFailingIfSchema, deriveFailingIf);
            _ = bindgen.Fn(DeriveIfSchema, deriveIf);
            _ = bindgen.Fn(DeriveOnlySchema, deriveOnly);
            _ = bindgen.Fn(DeriveSerialSchema, deriveSerial);
            _ = bindgen.Fn(DeriveSerialIfSchema, deriveSerialIf);
            _ = bindgen.Fn(DeriveSkipSchema, deriveSkip);
            _ = bindgen.Fn(DeriveSkipIfSchema, deriveSkipIf);
            _ = bindgen.Fn(DeriveTodoSchema, deriveTodo);
            _ = bindgen.Fn(DeriveTodoIfSchema, deriveTodoIf);
            _ = bindgen.Fn(ScopeFunctionsCallSchema, callAsFunction);
        }
    };
}

const bun = @import("bun");
const std = @import("std");
const bindgen = bun.bindgen;
const groupLog = @import("./debug.zig").group;

const BindingModule = bindgen.Module("ScopeFunctions");
const ScopeFunctionsSchema = BindingModule.class("ScopeFunctions");
const ScopeRef = bindgen.ClassRef(ScopeFunctionsSchema);
const CreateTestStateSchema = BindingModule.function("createTestState");
const CreateSkippedTestStateSchema = BindingModule.function("createSkippedTestState");
const CreateDescribeStateSchema = BindingModule.function("createDescribeState");
const CreateSkippedDescribeStateSchema = BindingModule.function("createSkippedDescribeState");
const DeriveConcurrentSchema = BindingModule.function("deriveConcurrent");
const DeriveConcurrentIfSchema = BindingModule.function("deriveConcurrentIf");
const DeriveEachSchema = BindingModule.function("deriveEach");
const EachArrayType = bindgen.OwnedBrandedValue(DeriveEachSchema.args[1].ArgumentType);
const DeriveFailingSchema = BindingModule.function("deriveFailing");
const DeriveFailingIfSchema = BindingModule.function("deriveFailingIf");
const DeriveIfSchema = BindingModule.function("deriveIf");
const DeriveOnlySchema = BindingModule.function("deriveOnly");
const DeriveSerialSchema = BindingModule.function("deriveSerial");
const DeriveSerialIfSchema = BindingModule.function("deriveSerialIf");
const DeriveSkipSchema = BindingModule.function("deriveSkip");
const DeriveSkipIfSchema = BindingModule.function("deriveSkipIf");
const DeriveTodoSchema = BindingModule.function("deriveTodo");
const DeriveTodoIfSchema = BindingModule.function("deriveTodoIf");
const ScopeFunctionsCallSchema = BindingModule.function("call");
