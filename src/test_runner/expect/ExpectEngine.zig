/// https://jestjs.io/docs/expect
// To support async tests, we need to track the test ID
pub const Expect = struct {
    pub const Flags = ExpectState.Flags;
    pub const getSignature = ExpectState.signature;
    pub const JSBinding = struct {
        bindgen_state: bindgen.ClassState = .{},
        expect: bindgen.OwnedNative(Expect, .vm),

        pub fn destroy(binding: *JSBinding) void {
            binding.expect.deinit();
            bun.destroy(binding);
        }

        fn Matcher(comptime member_name: []const u8) type {
            const MemberSchema = ExpectSchema.memberKind(member_name, .method);
            return struct {
                pub fn invoke(
                    binding: *JSBinding,
                    context: bindgen.CallContext(MemberSchema),
                    args: bindgen.Args(MemberSchema),
                ) bindgen.CallError(MemberSchema)!bindgen.Return(MemberSchema) {
                    return MatcherEngine.run(
                        context.viewToken().globalObject(),
                        context,
                        binding.expect.get(),
                        args,
                        comptime MatcherDefinition.Matcher.fromBindingImplementation("bind_instance_" ++ member_name),
                    );
                }
            };
        }

        fn Modifier(comptime member_name: []const u8) type {
            const MemberSchema = ExpectSchema.memberKind(member_name, .getter);
            return struct {
                pub fn invoke(
                    binding: *JSBinding,
                    context: bindgen.CallContext(MemberSchema),
                    args: bindgen.Args(MemberSchema),
                ) bun.JSError!bindgen.Return(MemberSchema) {
                    const global = context.viewToken().globalObject();
                    if (comptime std.mem.eql(u8, member_name, "not")) {
                        try binding.expect.get().getNot(global);
                    } else if (comptime std.mem.eql(u8, member_name, "rejects")) {
                        try binding.expect.get().getRejects(global);
                    } else if (comptime std.mem.eql(u8, member_name, "resolves")) {
                        try binding.expect.get().getResolves(global);
                    } else @compileError("unsupported expect modifier " ++ member_name);
                    return args.bindingThis.toOwned();
                }
            };
        }

        fn GlobalAction(comptime member_name: []const u8, comptime kind: anytype) type {
            const MemberSchema = ExpectSchema.memberKind(member_name, kind);
            return struct {
                pub fn invoke(
                    context: bindgen.CallContext(MemberSchema),
                    args: bindgen.Args(MemberSchema),
                ) bun.JSError!bindgen.Return(MemberSchema) {
                    return runExpectGlobalAction(@field(ExpectGlobalAction, member_name), context, args);
                }
            };
        }

        pub const bind_instance_fail = Matcher("fail").invoke;
        pub const bind_instance_lastCalledWith = Matcher("lastCalledWith").invoke;
        pub const bind_instance_lastReturnedWith = Matcher("lastReturnedWith").invoke;
        pub const bind_instance_not = Modifier("not").invoke;
        pub const bind_instance_nthCalledWith = Matcher("nthCalledWith").invoke;
        pub const bind_instance_nthReturnedWith = Matcher("nthReturnedWith").invoke;
        pub const bind_instance_pass = Matcher("pass").invoke;
        pub const bind_instance_rejects = Modifier("rejects").invoke;
        pub const bind_instance_resolves = Modifier("resolves").invoke;
        pub const bind_instance_toBe = Matcher("toBe").invoke;
        pub const bind_instance_toBeArray = Matcher("toBeArray").invoke;
        pub const bind_instance_toBeArrayOfSize = Matcher("toBeArrayOfSize").invoke;
        pub const bind_instance_toBeBoolean = Matcher("toBeBoolean").invoke;
        pub const bind_instance_toBeCalled = Matcher("toBeCalled").invoke;
        pub const bind_instance_toBeCalledTimes = Matcher("toBeCalledTimes").invoke;
        pub const bind_instance_toBeCalledWith = Matcher("toBeCalledWith").invoke;
        pub const bind_instance_toBeCloseTo = Matcher("toBeCloseTo").invoke;
        pub const bind_instance_toBeDate = Matcher("toBeDate").invoke;
        pub const bind_instance_toBeDefined = Matcher("toBeDefined").invoke;
        pub const bind_instance_toBeEmpty = Matcher("toBeEmpty").invoke;
        pub const bind_instance_toBeEmptyObject = Matcher("toBeEmptyObject").invoke;
        pub const bind_instance_toBeEven = Matcher("toBeEven").invoke;
        pub const bind_instance_toBeFalse = Matcher("toBeFalse").invoke;
        pub const bind_instance_toBeFalsy = Matcher("toBeFalsy").invoke;
        pub const bind_instance_toBeFinite = Matcher("toBeFinite").invoke;
        pub const bind_instance_toBeFunction = Matcher("toBeFunction").invoke;
        pub const bind_instance_toBeGreaterThan = Matcher("toBeGreaterThan").invoke;
        pub const bind_instance_toBeGreaterThanOrEqual = Matcher("toBeGreaterThanOrEqual").invoke;
        pub const bind_instance_toBeInstanceOf = Matcher("toBeInstanceOf").invoke;
        pub const bind_instance_toBeInteger = Matcher("toBeInteger").invoke;
        pub const bind_instance_toBeLessThan = Matcher("toBeLessThan").invoke;
        pub const bind_instance_toBeLessThanOrEqual = Matcher("toBeLessThanOrEqual").invoke;
        pub const bind_instance_toBeNaN = Matcher("toBeNaN").invoke;
        pub const bind_instance_toBeNegative = Matcher("toBeNegative").invoke;
        pub const bind_instance_toBeNil = Matcher("toBeNil").invoke;
        pub const bind_instance_toBeNull = Matcher("toBeNull").invoke;
        pub const bind_instance_toBeNumber = Matcher("toBeNumber").invoke;
        pub const bind_instance_toBeObject = Matcher("toBeObject").invoke;
        pub const bind_instance_toBeOdd = Matcher("toBeOdd").invoke;
        pub const bind_instance_toBeOneOf = Matcher("toBeOneOf").invoke;
        pub const bind_instance_toBePositive = Matcher("toBePositive").invoke;
        pub const bind_instance_toBeString = Matcher("toBeString").invoke;
        pub const bind_instance_toBeSymbol = Matcher("toBeSymbol").invoke;
        pub const bind_instance_toBeTrue = Matcher("toBeTrue").invoke;
        pub const bind_instance_toBeTruthy = Matcher("toBeTruthy").invoke;
        pub const bind_instance_toBeTypeOf = Matcher("toBeTypeOf").invoke;
        pub const bind_instance_toBeUndefined = Matcher("toBeUndefined").invoke;
        pub const bind_instance_toBeValidDate = Matcher("toBeValidDate").invoke;
        pub const bind_instance_toBeWithin = Matcher("toBeWithin").invoke;
        pub const bind_instance_toContain = Matcher("toContain").invoke;
        pub const bind_instance_toContainAllKeys = Matcher("toContainAllKeys").invoke;
        pub const bind_instance_toContainAllValues = Matcher("toContainAllValues").invoke;
        pub const bind_instance_toContainAnyKeys = Matcher("toContainAnyKeys").invoke;
        pub const bind_instance_toContainAnyValues = Matcher("toContainAnyValues").invoke;
        pub const bind_instance_toContainEqual = Matcher("toContainEqual").invoke;
        pub const bind_instance_toContainKey = Matcher("toContainKey").invoke;
        pub const bind_instance_toContainKeys = Matcher("toContainKeys").invoke;
        pub const bind_instance_toContainValue = Matcher("toContainValue").invoke;
        pub const bind_instance_toContainValues = Matcher("toContainValues").invoke;
        pub const bind_instance_toEndWith = Matcher("toEndWith").invoke;
        pub const bind_instance_toEqual = Matcher("toEqual").invoke;
        pub const bind_instance_toEqualIgnoringWhitespace = Matcher("toEqualIgnoringWhitespace").invoke;
        pub const bind_instance_toHaveBeenCalled = Matcher("toHaveBeenCalled").invoke;
        pub const bind_instance_toHaveBeenCalledOnce = Matcher("toHaveBeenCalledOnce").invoke;
        pub const bind_instance_toHaveBeenCalledTimes = Matcher("toHaveBeenCalledTimes").invoke;
        pub const bind_instance_toHaveBeenCalledWith = Matcher("toHaveBeenCalledWith").invoke;
        pub const bind_instance_toHaveBeenLastCalledWith = Matcher("toHaveBeenLastCalledWith").invoke;
        pub const bind_instance_toHaveBeenNthCalledWith = Matcher("toHaveBeenNthCalledWith").invoke;
        pub const bind_instance_toHaveLastReturnedWith = Matcher("toHaveLastReturnedWith").invoke;
        pub const bind_instance_toHaveLength = Matcher("toHaveLength").invoke;
        pub const bind_instance_toHaveNthReturnedWith = Matcher("toHaveNthReturnedWith").invoke;
        pub const bind_instance_toHaveProperty = Matcher("toHaveProperty").invoke;
        pub const bind_instance_toHaveReturned = Matcher("toHaveReturned").invoke;
        pub const bind_instance_toHaveReturnedTimes = Matcher("toHaveReturnedTimes").invoke;
        pub const bind_instance_toHaveReturnedWith = Matcher("toHaveReturnedWith").invoke;
        pub const bind_instance_toInclude = Matcher("toInclude").invoke;
        pub const bind_instance_toIncludeRepeated = Matcher("toIncludeRepeated").invoke;
        pub const bind_instance_toMatch = Matcher("toMatch").invoke;
        pub const bind_instance_toMatchInlineSnapshot = Matcher("toMatchInlineSnapshot").invoke;
        pub const bind_instance_toMatchObject = Matcher("toMatchObject").invoke;
        pub const bind_instance_toMatchSnapshot = Matcher("toMatchSnapshot").invoke;
        pub const bind_instance_toReturn = Matcher("toReturn").invoke;
        pub const bind_instance_toSatisfy = Matcher("toSatisfy").invoke;
        pub const bind_instance_toStartWith = Matcher("toStartWith").invoke;
        pub const bind_instance_toStrictEqual = Matcher("toStrictEqual").invoke;
        pub const bind_instance_toThrow = Matcher("toThrow").invoke;
        pub const bind_instance_toThrowError = Matcher("toThrowError").invoke;
        pub const bind_instance_toThrowErrorMatchingInlineSnapshot = Matcher("toThrowErrorMatchingInlineSnapshot").invoke;
        pub const bind_instance_toThrowErrorMatchingSnapshot = Matcher("toThrowErrorMatchingSnapshot").invoke;
        pub const bind_static_addSnapshotSerializer = GlobalAction("addSnapshotSerializer", .static_method).invoke;
        pub const bind_static_any = GlobalAction("any", .static_method).invoke;
        pub const bind_static_anything = GlobalAction("anything", .static_method).invoke;
        pub const bind_static_arrayContaining = GlobalAction("arrayContaining", .static_method).invoke;
        pub const bind_static_assertions = GlobalAction("assertions", .static_method).invoke;
        pub const bind_static_closeTo = GlobalAction("closeTo", .static_method).invoke;
        pub const bind_static_extend = GlobalAction("extend", .static_method).invoke;
        pub const bind_static_hasAssertions = GlobalAction("hasAssertions", .static_method).invoke;
        pub const bind_static_not = GlobalAction("not", .static_getter).invoke;
        pub const bind_static_objectContaining = GlobalAction("objectContaining", .static_method).invoke;
        pub const bind_static_rejectsTo = GlobalAction("rejectsTo", .static_getter).invoke;
        pub const bind_static_resolvesTo = GlobalAction("resolvesTo", .static_getter).invoke;
        pub const bind_static_stringContaining = GlobalAction("stringContaining", .static_method).invoke;
        pub const bind_static_stringMatching = GlobalAction("stringMatching", .static_method).invoke;
        pub const bind_static_unreachable = GlobalAction("unreachable", .static_method).invoke;
    };

    pub const Binding = bindgen.Class(ExpectSchema, JSBinding);

    flags: Flags = .{},
    allocator: std.mem.Allocator,
    parent: ?*bun.jsc.Jest.bun_test.BunTest.RefData,
    custom_label: bun.String = bun.String.empty,
    captured_value: bindgen.EngineRoot,

    pub fn incrementExpectCallCounter(this: *Expect) void {
        CounterEngine.increment(this.parent);
    }
    pub fn bunTest(this: *Expect) ?bun.jsc.Jest.bun_test.BunTestPtr {
        const parent = this.parent orelse return null;
        return parent.bunTest();
    }

    pub fn getNot(this: *Expect, _: *JSGlobalObject) bun.JSError!void {
        this.flags.not = !this.flags.not;
    }

    pub fn getResolves(this: *Expect, globalThis: *JSGlobalObject) bun.JSError!void {
        this.flags.promise = switch (this.flags.promise) {
            .resolves, .none => .resolves,
            .rejects => {
                return globalThis.throw("Cannot chain .resolves() after .rejects()", .{});
            },
        };
    }

    pub fn getRejects(this: *Expect, globalThis: *JSGlobalObject) bun.JSError!void {
        this.flags.promise = switch (this.flags.promise) {
            .none, .rejects => .rejects,
            .resolves => {
                return globalThis.throw("Cannot chain .rejects() after .resolves()", .{});
            },
        };
    }

    pub fn getScopedValue(this: *Expect, context: anytype, matcher_name: string, comptime matcher_params_fmt: string) bun.JSError!bindgen.EngineValueResult {
        const value = try this.captured_value.engineView(context);
        const matcher_params = switch (Output.enable_ansi_colors_stderr) {
            inline else => |colors| comptime Output.prettyFmt(matcher_params_fmt, colors),
        };
        return PromiseMatcherEngine.process(this.custom_label, this.flags, context, value, matcher_name, matcher_params, false);
    }

    pub fn getSnapshotName(this: *Expect, allocator: std.mem.Allocator, hint: string) ![]const u8 {
        const parent = this.parent orelse return error.NoTest;
        var buntest_strong = parent.bunTest() orelse return error.TestNotActive;
        defer buntest_strong.deinit();
        const buntest = buntest_strong.get();
        const execution_entry = parent.phase.entry(buntest) orelse return error.SnapshotInConcurrentGroup;

        const test_name = execution_entry.base.name orelse "(unnamed)";

        var length: usize = 0;
        var curr_scope = execution_entry.base.parent;
        while (curr_scope) |scope| {
            if (scope.base.name != null and scope.base.name.?.len > 0) {
                length += scope.base.name.?.len + 1;
            }
            curr_scope = scope.base.parent;
        }
        length += test_name.len;
        if (hint.len > 0) {
            length += hint.len + 2;
        }

        var buf = try allocator.alloc(u8, length);

        var index = buf.len;
        if (hint.len > 0) {
            index -= hint.len;
            bun.copy(u8, buf[index..], hint);
            index -= test_name.len + 2;
            bun.copy(u8, buf[index..], test_name);
            bun.copy(u8, buf[index + test_name.len ..], ": ");
        } else {
            index -= test_name.len;
            bun.copy(u8, buf[index..], test_name);
        }
        // copy describe scopes in reverse order
        curr_scope = execution_entry.base.parent;
        while (curr_scope) |scope| {
            if (scope.base.name != null and scope.base.name.?.len > 0) {
                index -= scope.base.name.?.len + 1;
                bun.copy(u8, buf[index..], scope.base.name.?);
                buf[index + scope.base.name.?.len] = ' ';
            }
            curr_scope = scope.base.parent;
        }

        return buf;
    }

    pub fn destroy(
        this: *Expect,
    ) void {
        this.captured_value.deinit();
        this.custom_label.deref();
        if (this.parent) |parent| parent.deref();
        this.allocator.destroy(this);
    }

    fn createResult(
        context: bindgen.CallContext(CreateExpectSchema),
        args: bindgen.Args(CreateExpectSchema),
    ) bun.JSError!bindgen.Return(CreateExpectSchema) {
        const globalThis = context.viewToken().globalObject();
        var captured_root = try args.value.toRoot();
        errdefer captured_root.deinit();
        var custom_label = args.customLabel.toOwned();
        defer custom_label.deinit();
        const allocator = globalThis.bunVM().allocator;
        const expect = try allocator.create(Expect);
        const binding = bun.default_allocator.create(JSBinding) catch |err| {
            allocator.destroy(expect);
            return err;
        };

        const active_execution_entry_ref = if (bun.jsc.Jest.bun_test.cloneActiveStrong()) |buntest_strong_| blk: {
            var buntest_strong = buntest_strong_;
            defer buntest_strong.deinit();
            break :blk bun.jsc.Jest.bun_test.BunTest.ref(buntest_strong, buntest_strong.get().getCurrentStateData());
        } else null;
        expect.* = .{
            .allocator = allocator,
            .custom_label = custom_label.takeBunString(),
            .parent = active_execution_entry_ref,
            .captured_value = captured_root.take(),
        };
        binding.* = .{ .expect = .init(expect) };
        var reference = try Binding.adoptResult(binding, context);
        errdefer reference.deinit();

        expect.postMatch(globalThis);
        return reference;
    }

    pub fn throw(this: *Expect, globalThis: *JSGlobalObject, comptime signature: []const u8, comptime fmt: []const u8, args: anytype) bun.JSError {
        if (this.custom_label.isEmpty()) {
            return globalThis.throwPretty(comptime std.fmt.comptimePrint("{s}{s}", .{ signature, fmt }), args);
        } else {
            return globalThis.throwPretty(comptime std.fmt.comptimePrint("{{f}}{s}", .{fmt}), .{this.custom_label} ++ args);
        }
    }

    pub fn bindApplyCustomMatcher(
        context: bindgen.CallContext(ApplyCustomMatcherSchema),
        args: bindgen.Args(ApplyCustomMatcherSchema),
    ) bun.JSError!bindgen.Return(ApplyCustomMatcherSchema) {
        const global = context.viewToken().globalObject();
        var stack: [8]bindgen.Root = undefined;
        var allocator_state: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack), global.allocator());
        const matcher_fn_result = try context.engineIn("Expect", "wrappingFunctionWrapped").call(.{
            .function = args.bindingCallee.operand(context),
        });
        const matcher_fn = try matcher_fn_result.view(context);
        var builder = try bindgen.RetainedArguments.Builder.init(allocator_state.allocator(), args.values.length());
        defer builder.deinit();
        for (0..args.values.length()) |index| builder.appendOwned(try args.values.at(index).?.toRoot());
        var arguments = builder.finish();
        defer arguments.deinit();
        return applyCustomMatcherFromBinding(
            context,
            args.bindingThis,
            matcher_fn,
            arguments.values(),
        );
    }

    fn applyCustomMatcherFromBinding(
        context: bindgen.CallContext(ApplyCustomMatcherSchema),
        receiver: @FieldType(bindgen.Args(ApplyCustomMatcherSchema), "bindingThis"),
        matcher_fn: CustomMatcherEngine.CallableView,
        args: []const bindgen.Root,
    ) bun.JSError!bindgen.Return(ApplyCustomMatcherSchema) {
        const globalThis = context.viewToken().globalObject();
        defer globalThis.bunVM().autoGarbageCollect();
        return switch (receiver) {
            .expect => |reference| result: {
                const expect = reference.get(JSBinding).expect.get();
                try CustomMatcherEngine.apply(
                    context,
                    matcher_fn,
                    args,
                    &expect.captured_value,
                    expect.custom_label,
                    expect.flags,
                    expect.parent,
                );
                break :result .{ .expect = try reference.toOwned() };
            },
            .expect_static => |reference| result: {
                const asymmetric = try ExpectCustomAsymmetricMatcher.create(
                    context,
                    args,
                    matcher_fn,
                    reference.get(ExpectStatic).flags,
                );
                break :result .{ .asymmetric = asymmetric };
            },
            .other => result: {
                const asymmetric = try ExpectCustomAsymmetricMatcher.create(context, args, matcher_fn, .{});
                break :result .{ .asymmetric = asymmetric };
            },
        };
    }

    fn hasAssertions(globalThis: *JSGlobalObject) bun.JSError!void {
        defer globalThis.bunVM().autoGarbageCollect();

        var buntest_strong = bun.jsc.Jest.bun_test.cloneActiveStrong() orelse return globalThis.throw("expect.assertions() must be called within a test", .{});
        defer buntest_strong.deinit();
        const buntest = buntest_strong.get();
        const state_data = buntest.getCurrentStateData();
        const execution = state_data.sequence(buntest) orelse return globalThis.throw("expect.assertions() is not supported in the describe phase, in concurrent tests, between tests, or after test execution has completed", .{});
        if (execution.expect_assertions != .exact) {
            execution.expect_assertions = .at_least_one;
        }
    }

    fn assertions(globalThis: *JSGlobalObject, expected_assertions: u32) bun.JSError!void {
        defer globalThis.bunVM().autoGarbageCollect();

        var buntest_strong = bun.jsc.Jest.bun_test.cloneActiveStrong() orelse return globalThis.throw("expect.assertions() must be called within a test", .{});
        defer buntest_strong.deinit();
        const buntest = buntest_strong.get();
        const state_data = buntest.getCurrentStateData();
        const execution = state_data.sequence(buntest) orelse return globalThis.throw("expect.assertions() is not supported in the describe phase, in concurrent tests, between tests, or after test execution has completed", .{});
        execution.expect_assertions = .{ .exact = expected_assertions };
    }

    fn notImplementedStaticFn(globalThis: *JSGlobalObject) bun.JSError!void {
        return globalThis.throw("Not implemented", .{});
    }

    pub fn postMatch(_: *Expect, globalThis: *JSGlobalObject) void {
        var vm = globalThis.bunVM();
        vm.autoGarbageCollect();
    }

    fn doUnreachable(context: anytype, arg: anytype) bun.JSError!void {
        const globalThis = context.viewToken().globalObject();
        if (arg orelse null) |value| switch (value) {
            .message => |text| {
                var message = text.toOwned();
                defer message.deinit();
                return MatcherErrorEngine.throwNamed(globalThis, &message, "UnreachableError");
            },
            .thrown => |thrown| {
                const result = thrown.toResult();
                return result.throwException(context);
            },
        };
        var message = try bindgen.DOMString.fromUTF8("reached unreachable code");
        defer message.deinit();
        return MatcherErrorEngine.throwNamed(globalThis, &message, "UnreachableError");
    }
};

comptime {
    _ = Expect.Binding;
    _ = ExpectStatic.Binding;
    _ = ExpectAnything.Binding;
    _ = ExpectStringMatching.Binding;
    _ = ExpectCloseTo.Binding;
    _ = ExpectObjectContaining.Binding;
    _ = ExpectStringContaining.Binding;
    _ = ExpectAny.Binding;
    _ = ExpectArrayContaining.Binding;
    _ = ExpectCustomAsymmetricMatcher.Binding;
    _ = ExpectTypeOf.Binding;
    _ = CreateExpectBinding;
    _ = ApplyCustomMatcherBinding;
    _ = ExpectReadFlagsAndProcessPromiseBinding;
}

const string = []const u8;

const std = @import("std");
pub const AsymmetricMatcherEngine = @import("./AsymmetricMatcherEngine.zig");
const CounterEngine = @import("./CounterEngine.zig");
pub const CustomMatcherEngine = @import("./CustomMatcherEngine.zig");
const ExpectState = @import("./State.zig");
pub const MatcherUtilsEngine = @import("./MatcherUtilsEngine.zig");
pub const MatcherErrorEngine = @import("./MatcherErrorEngine.zig");
const MatcherEngine = @import("./MatcherEngine.zig");
const MatcherDefinition = @import("./Matcher.zig");
const PromiseMatcherEngine = @import("./PromiseMatcherEngine.zig");
pub const ExpectMatcherContext = MatcherUtilsEngine.ExpectMatcherContext;
pub const ExpectMatcherUtils = MatcherUtilsEngine.ExpectMatcherUtils;
pub const ExpectAny = AsymmetricMatcherEngine.ExpectAny;
pub const ExpectAnything = AsymmetricMatcherEngine.ExpectAnything;
pub const ExpectArrayContaining = AsymmetricMatcherEngine.ExpectArrayContaining;
pub const ExpectCloseTo = AsymmetricMatcherEngine.ExpectCloseTo;
pub const ExpectCustomAsymmetricMatcher = CustomMatcherEngine.ExpectCustomAsymmetricMatcher;
pub const ExpectObjectContaining = AsymmetricMatcherEngine.ExpectObjectContaining;
pub const ExpectStatic = AsymmetricMatcherEngine.ExpectStatic;
pub const ExpectStringContaining = AsymmetricMatcherEngine.ExpectStringContaining;
pub const ExpectStringMatching = AsymmetricMatcherEngine.ExpectStringMatching;
pub const ExpectTypeOf = @import("./TypeMatcherEngine.zig").ExpectTypeOf;

const bun = @import("bun");
const Output = bun.Output;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const JSGlobalObject = jsc.JSGlobalObject;

const ExpectBindings = bun.bindgen.Module("Expect");
const ExpectSchema = ExpectBindings.class("Expect");
const CreateExpectSchema = bindgen.Module("Expect").function("createExpect");
const CreateExpectBinding = bindgen.Fn(CreateExpectSchema, Expect.createResult);
const ApplyCustomMatcherSchema = ExpectBindings.function("applyCustomMatcher");
const ApplyCustomMatcherBinding = bun.bindgen.Fn(ApplyCustomMatcherSchema, Expect.bindApplyCustomMatcher);
const ExpectReadFlagsAndProcessPromiseSchema = ExpectBindings.nativeExport("readFlagsAndProcessPromise");
const ExpectReadFlagsAndProcessPromiseBinding = bun.bindgen.Fn(ExpectReadFlagsAndProcessPromiseSchema, bindReadFlagsAndProcessPromise);

const ExpectGlobalAction = enum {
    addSnapshotSerializer,
    any,
    anything,
    arrayContaining,
    assertions,
    closeTo,
    extend,
    hasAssertions,
    not,
    objectContaining,
    rejectsTo,
    resolvesTo,
    stringContaining,
    stringMatching,
    @"unreachable",
};



fn runExpectGlobalAction(
    comptime action: ExpectGlobalAction,
    context: anytype,
    args: anytype,
) bindgen.CallError(@TypeOf(context))!bindgen.Return(@TypeOf(context)) {
    const globalThis = context.viewToken().globalObject();
    var target: ExpectStatic = .{};
    switch (action) {
        .addSnapshotSerializer => return Expect.notImplementedStaticFn(globalThis),
        .assertions => return Expect.assertions(globalThis, args.expected),
        .extend => return CustomMatcherEngine.extend(context, args.matchers),
        .hasAssertions => return Expect.hasAssertions(globalThis),
        .@"unreachable" => return Expect.doUnreachable(context, args.value),
        inline .any, .anything, .arrayContaining, .closeTo, .not, .objectContaining,
        .rejectsTo, .resolvesTo, .stringContaining, .stringMatching => |tag|
            return target.resultFromBinding(@field(ExpectStatic.Action, @tagName(tag)), context, args),
    }
}

fn readFlagsAndProcessPromise(
    context: bindgen.CallContext(ExpectReadFlagsAndProcessPromiseSchema),
    args: bindgen.Args(ExpectReadFlagsAndProcessPromiseSchema),
) bun.JSError!bindgen.Return(ExpectReadFlagsAndProcessPromiseSchema) {
    const flags = asymmetricMatcherFlags(args.instanceValue);
    const processed = try PromiseMatcherEngine.process(
        bun.String.empty,
        Expect.Flags.decode(flags),
        context,
        args.value,
        "",
        "",
        true,
    );
    return .{
        .value = processed,
        .flags = flags,
    };
}

fn bindReadFlagsAndProcessPromise(
    context: bun.bindgen.CallContext(ExpectReadFlagsAndProcessPromiseSchema),
    args: bun.bindgen.Args(ExpectReadFlagsAndProcessPromiseSchema),
) bun.JSError!bun.bindgen.Return(ExpectReadFlagsAndProcessPromiseSchema) {
    return readFlagsAndProcessPromise(context, args);
}

fn asymmetricMatcherFlags(
    instance_value: @FieldType(bun.bindgen.Args(ExpectReadFlagsAndProcessPromiseSchema), "instanceValue"),
) u8 {
    return switch (instance_value) {
        .custom => |matcher| matcher.get(ExpectCustomAsymmetricMatcher).flags.encode(),
        .any => |matcher| matcher.get(ExpectAny).flags.encode(),
        .anything => |matcher| matcher.get(ExpectAnything).flags.encode(),
        .string_matching => |matcher| matcher.get(ExpectStringMatching).flags.encode(),
        .close_to => |matcher| matcher.get(ExpectCloseTo).flags.encode(),
        .object_containing => |matcher| matcher.get(ExpectObjectContaining).flags.encode(),
        .string_containing => |matcher| matcher.get(ExpectStringContaining).flags.encode(),
        .array_containing => |matcher| matcher.get(ExpectArrayContaining).flags.encode(),
    };
}
