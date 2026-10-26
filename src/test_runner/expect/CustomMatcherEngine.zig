const bun = @import("bun");
const std = @import("std");
const CounterEngine = @import("./CounterEngine.zig");
const CustomMatcherResult = @import("./CustomMatcherResult.zig");
const ExpectState = @import("./State.zig");
const MatcherErrorEngine = @import("./MatcherErrorEngine.zig");
const MatcherUtilsEngine = @import("./MatcherUtilsEngine.zig");
const PromiseMatcherEngine = @import("./PromiseMatcherEngine.zig");

const bindgen = bun.bindgen;
const ExpectBindings = bindgen.Module("Expect");
const ExpectCustomAsymmetricMatcherExecuteSchema = ExpectBindings.nativeExport("expectCustomAsymmetricMatcherExecute");
const CallableType = ExpectBindings.engineShim("wrappingFunctionWrapped").ReturnType;
pub const CallableView = bindgen.BrandedValueView(CallableType);
const Output = bun.Output;
const jsc = bun.jsc;

pub fn extend(context: anytype, matchers: anytype) bun.JSError!void {
    const global = context.viewToken().globalObject();
    {
        const matchers_result = matchers.toResult();
        var matchers_root = try matchers_result.eraseBrandToEngineRoot();
        defer matchers_root.deinit();
        var iter = try jsc.JSPropertyIterator(.{
            .skip_empty_name = false,
            .own_properties_only = false,
        }).init(context, &matchers_root);
        defer iter.deinit();

        while (try iter.next(context)) |owned_entry| {
            var entry = owned_entry;
            defer entry.deinit();
            if (!context.engineIn("js_value_inspection", "jsValueIsCallable").call(.{ .value = entry.value.operand(context).asEngine() }))
                return MatcherErrorEngine.throwInvalidMatcherFunction(context, &entry.name, entry.value);

            try context.engineIn("Expect", "installCustomMatcher").call(.{
                .symbolName = entry.name.operand(),
                .wrappedFunction = entry.value.operand(context).asEngine(),
            });
        }
    }

    global.bunVM().autoGarbageCollect();
}

fn CustomMatcherParamsFormatter(comptime Context: type) type {
    return struct {
        colors: bool,
        context: Context,
        matcher_fn: CallableView,

        pub fn format(this: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const global = this.context.viewToken().globalObject();
            var source_result = this.context.engineIn("js_strings", "jsFunctionSourceCode").call(.{ .value = this.matcher_fn.operand(this.context).asEngine() }) catch |err|
                return global.formatErrorToWriterError(err);
            if (source_result) |*source_str| {
                defer source_str.deinit();
                const source_slice = source_str.toUTF8(global.allocator()) catch |err| return global.formatErrorToWriterError(err);
                defer source_slice.deinit();

                const source = source_slice.slice();
                if (std.mem.indexOfScalar(u8, source, '(')) |lparen| {
                    if (std.mem.indexOfScalarPos(u8, source, lparen, ')')) |rparen| {
                        const params_str = source[(lparen + 1)..rparen];
                        var param_index: usize = 0;
                        var iter = std.mem.splitScalar(u8, params_str, ',');
                        while (iter.next()) |param_name| : (param_index += 1) {
                            // The received value occupies the first parameter.
                            if (param_index == 0) continue;
                            if (param_index > 1) {
                                try writer.writeAll(if (this.colors) Output.prettyFmt("<r><d>, <r><green>", true) else ", ");
                            } else if (this.colors) {
                                try writer.writeAll("<green>");
                            }
                            const param_name_trimmed = std.mem.trim(u8, param_name, " ");
                            if (param_name_trimmed.len > 0) {
                                try writer.writeAll(param_name_trimmed);
                            } else {
                                try writer.print("arg{d}", .{param_index - 1});
                            }
                        }
                        if (param_index > 1 and this.colors) {
                            try writer.writeAll("<r>");
                        }
                        return;
                    }
                }
            }

            switch (this.colors) {
                inline else => |colors| try writer.print(Output.prettyFmt("<green>...args<r>", colors), .{}),
            }
        }
    };
}

fn borrowArguments(context: anytype, roots: []const bindgen.Root) bun.OOM![]bindgen.AnyOperand {
    const arguments = try bun.default_allocator.alloc(bindgen.AnyOperand, roots.len);
    for (roots, arguments) |*root, *argument| argument.* = root.operand(context);
    return arguments;
}

/// Execute the custom matcher for the given args (the left value + the args passed to the matcher call).
/// This function is called both for symmetric and asymmetric matching.
/// If silent=false, throws an exception in JS if the matcher result didn't result in a pass (or if the matcher result is invalid).
fn execute(context: anytype, matcher_name: *const bindgen.DOMString, matcher_fn: CallableView, received: bindgen.EngineValueResult, args: []const bindgen.Root, flags: ExpectState.Flags, silent: bool) bun.JSError!bool {
    var received_root = try received.toRoot();
    defer received_root.deinit();
    const globalThis = context.viewToken().globalObject();
    const matcher_context = try globalThis.bunVM().allocator.create(MatcherUtilsEngine.ExpectMatcherContext);
    matcher_context.* = .{ .flags = flags };
    var matcher_context_ref = try MatcherUtilsEngine.ExpectMatcherContext.Binding.adoptNativeRef(matcher_context, globalThis);
    defer matcher_context_ref.deinit();

    const operation = context.engineIn("js_functions", "jsValueCall");
    var stack: [8]bindgen.AnyOperand = undefined;
    var allocator_state: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack), globalThis.allocator());
    const allocator = allocator_state.allocator();
    const argument_count = std.math.add(usize, args.len, 1) catch return error.OutOfMemory;
    const arguments = try allocator.alloc(bindgen.AnyOperand, argument_count);
    defer allocator.free(arguments);
    arguments[0] = received_root.operand(context).asAny();
    for (args, arguments[1..]) |*root, *argument| argument.* = root.operand(context);
    var result = try operation.call(.{
        .function = matcher_fn.operand(context).asEngine(),
        .this_value = matcher_context_ref.operand(context).asEngine(),
        .arguments = arguments,
    });
    if (try context.engineIn("promises", "jsValueAsPromise").call(.{ .value = result.operand(context).asEngine() })) |promise_result| {
        const settlement = (try context.waitForPromiseResult(promise_result.operand(context).asPromise(), null)).?;
        switch (settlement) {
            .fulfilled => |value| result = value,
            .rejected => |reason| {
                // TODO: rewrite this code to use .then() instead of blocking the event loop
                context.runErrorHandler(reason.operand(context).asAny());
                return globalThis.throw("Matcher `{f}` returned a promise that rejected", .{matcher_name});
            },
        }
    }

    var parsed = (try CustomMatcherResult.parse(context, result)) orelse
        return MatcherErrorEngine.throwInvalidMatcherResult(context, matcher_name, result);
    defer parsed.deinit();
    var pass = parsed.pass;
    if (flags.not) pass = !pass;
    if (pass or silent) return pass;

    var message_text = try CustomMatcherResult.messageText(context, &parsed.message);
    defer message_text.deinit();

    const matcher_params = CustomMatcherParamsFormatter(@TypeOf(context)){
        .colors = Output.enable_ansi_colors_stderr,
        .context = context,
        .matcher_fn = matcher_fn,
    };
    return MatcherErrorEngine.throwPretty(globalThis, bun.String.empty, matcher_name, matcher_params, .{}, "{f}", .{message_text});
}

/// Function that is run for either `expect.myMatcher()` call or `expect().myMatcher` call,
/// distinguished by whether the receiver is an instance of Expect.
pub fn apply(
    context: anytype,
    matcher_fn: CallableView,
    args: []const bindgen.Root,
    captured_value: *bindgen.EngineRoot,
    custom_label: bun.String,
    flags: ExpectState.Flags,
    parent: ?*bun.jsc.Jest.bun_test.BunTest.RefData,
) bun.JSError!void {
    var matcher_name = try context.engineIn("js_value_inspection", "jsValueGetName").call(.{ .value = matcher_fn.operand(context).asEngine() });
    defer matcher_name.deinit();
    const matcher_params = CustomMatcherParamsFormatter(@TypeOf(context)){
        .colors = Output.enable_ansi_colors_stderr,
        .context = context,
        .matcher_fn = matcher_fn,
    };

    const value = try PromiseMatcherEngine.process(custom_label, flags, context, try captured_value.engineView(context), &matcher_name, matcher_params, false);

    CounterEngine.increment(parent);

    _ = try execute(context, &matcher_name, matcher_fn, value, args, flags, false);
}

/// An instantiated asymmetric custom matcher, returned from calls to `expect.toCustomMatch(...)`
///
/// Reference: `AsymmetricMatcher` in https://github.com/jestjs/jest/blob/main/packages/expect/src/types.ts
/// (but only created for *custom* matchers, as built-ins have their own classes)
pub const ExpectCustomAsymmetricMatcher = struct {
    const ClassSchema = ExpectBindings.class("ExpectCustomAsymmetricMatcher");
    const AsymmetricMatchSchema = ClassSchema.member("asymmetricMatch");
    pub const Binding = bindgen.Class(ClassSchema, ExpectCustomAsymmetricMatcher);

    bindgen_state: bindgen.ClassState = .{},
    flags: ExpectState.Flags = .{},
    matcher_fn: bindgen.OwnedBrandedValue(CallableType),
    captured_args: bindgen.RetainedArguments,

    pub const Handle = Binding.Handle;

    pub fn destroy(this: *ExpectCustomAsymmetricMatcher) void {
        this.matcher_fn.deinit();
        this.captured_args.deinit();
        bun.default_allocator.destroy(this);
    }

    /// Implements the static call of the custom matcher (`expect.myCustomMatcher(<args>)`),
    /// which creates an asymmetric matcher instance (`ExpectCustomAsymmetricMatcher`).
    /// This will not run the matcher, but just capture the args etc.
    pub fn create(context: anytype, args: []const bindgen.Root, matcher_fn: CallableView, flags: ExpectState.Flags) bun.JSError!bindgen.ClassRef(ClassSchema) {
        const allocator = bun.default_allocator;
        var builder = try bindgen.RetainedArguments.Builder.init(allocator, args.len);
        defer builder.deinit();
        for (args) |*source| builder.appendOwned(source.clone());
        var retained_args = builder.finish();
        defer retained_args.deinit();

        var retained_matcher = try matcher_fn.toOwned();
        defer retained_matcher.deinit();
        const instance = try allocator.create(ExpectCustomAsymmetricMatcher);
        instance.* = .{
            .flags = flags,
            .matcher_fn = retained_matcher.take(),
            .captured_args = retained_args.take(),
        };

        return Binding.adoptResult(instance, context);
    }

    fn executeImpl(this: *ExpectCustomAsymmetricMatcher, context: anytype, received: bindgen.EngineValueResult) bun.JSError!bool {
        const matcher_fn = try this.matcher_fn.view(context);
        var matcher_name = try context.engineIn("js_value_inspection", "jsValueGetName").call(.{ .value = matcher_fn.operand(context).asEngine() });
        defer matcher_name.deinit();
        return execute(context, &matcher_name, matcher_fn, received, this.captured_args.values(), this.flags, true);
    }

    pub fn asymmetricMatch(
        this: *ExpectCustomAsymmetricMatcher,
        context: bindgen.CallContext(AsymmetricMatchSchema),
        args: bindgen.Args(AsymmetricMatchSchema),
    ) bun.JSError!bool {
        return this.executeImpl(
            context,
            if (args.received) |received|
                received.toResult()
            else
                bindgen.EngineValueResult.initUndefined(context),
        );
    }

    fn maybeClear(comptime dontThrow: bool, context: anytype, err: bun.JSError) bun.JSError!bool {
        if (dontThrow and err == error.JSError) {
            if (!context.engineIn("errors", "globalObjectClearExceptionExceptTermination").call(.{}))
                return error.JSTerminated;
            return false;
        }
        return err;
    }

    /// Returns whether the custom hook successfully printed the matcher.
    pub fn customPrint(this: *ExpectCustomAsymmetricMatcher, context: anytype, this_value: bindgen.EngineOperand, writer: anytype, comptime dontThrow: bool) !bool {
        var property_name = try bindgen.DOMString.fromUTF8("toAsymmetricMatcher");
        defer property_name.deinit();
        const hook_value = (context.engineIn("property_accessors", "getIfPropertyExists").call(.{
            .target = this.matcher_fn.operand(context).asEngine(),
            .property = property_name.operand(),
        }) catch |err| return maybeClear(dontThrow, context, err)) orelse return false;
        const hook = context.engineIn("Expect", "tryCastCallableValue").call(.{ .value = hook_value.operand(context).asEngine() }) orelse return false;
        const arguments = borrowArguments(context, this.captured_args.values()) catch |err| return maybeClear(dontThrow, context, err);
        defer bun.default_allocator.free(arguments);
        const result = context.engineIn("js_functions", "jsValueCall").call(.{
            .function = hook.operand(context).asEngine(),
            .this_value = this_value.operand(context).asEngine(),
            .arguments = arguments,
        }) catch |err| return maybeClear(dontThrow, context, err);
        var text = context.engineIn("js_strings", "stringFromJS").call(.{ .value = result.operand(context).asEngine() }) catch |err|
            return maybeClear(dontThrow, context, err);
        defer text.deinit();
        try writer.print("{f}", .{text});
        return true;
    }
};

fn bindExpectCustomAsymmetricMatcherExecute(
    context: bindgen.CallContext(ExpectCustomAsymmetricMatcherExecuteSchema),
    args: bindgen.Args(ExpectCustomAsymmetricMatcherExecuteSchema),
) bun.JSError!bindgen.Return(ExpectCustomAsymmetricMatcherExecuteSchema) {
    return args.matcher.get(ExpectCustomAsymmetricMatcher).executeImpl(context, args.received.toResult());
}

const ExpectCustomAsymmetricMatcherExecuteBinding = bindgen.Fn(
    ExpectCustomAsymmetricMatcherExecuteSchema,
    bindExpectCustomAsymmetricMatcherExecute,
);

comptime {
    _ = ExpectCustomAsymmetricMatcher.Binding;
    _ = ExpectCustomAsymmetricMatcherExecuteBinding;
}
