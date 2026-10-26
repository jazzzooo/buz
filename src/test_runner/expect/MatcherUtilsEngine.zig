const BindingEscape = bun.bindgen.Escape(@This());
const bun = @import("bun");
const DiffFormatter = @import("../DiffFormatEngine.zig").DiffFormatter;
const ExpectState = @import("./State.zig");

const bindgen = bun.bindgen;
const ExpectBindings = bindgen.Module("Expect");
const ExpectMatcherUtilsCreateSchema = ExpectBindings.nativeExport("expectMatcherUtilsCreate");
const JSGlobalObject = bun.jsc.JSGlobalObject;
const JSValue = bindgen.EngineOperand;
const Output = bun.Output;
const VirtualMachine = bun.jsc.VirtualMachine;
const jsc = bun.jsc;


/// Reference: `MatcherContext` in https://github.com/jestjs/jest/blob/main/packages/expect/src/types.ts
pub const ExpectMatcherContext = struct {
    bindgen_state: bindgen.ClassState = .{},
    flags: ExpectState.Flags = .{},

    const ClassSchema = ExpectBindings.class("ExpectMatcherContext");
    const EqualsSchema = ClassSchema.member("equals");
    const ExpandSchema = ClassSchema.member("expand");
    const IsNotSchema = ClassSchema.member("isNot");
    const PromiseSchema = ClassSchema.member("promise");
    const UtilsSchema = ClassSchema.member("utils");
    pub const Binding = bindgen.Class(ClassSchema, @This());

    pub fn destroy(
        this: *ExpectMatcherContext,
    ) void {
        VirtualMachine.get().allocator.destroy(this);
    }

    pub fn getUtils(
        _: *ExpectMatcherContext,
        context: bindgen.CallContext(UtilsSchema),
        _: bindgen.Args(UtilsSchema),
    ) bun.JSError!bindgen.Return(UtilsSchema) {
        return (try context.engineIn("Expect", "expectMatcherUtilsObject").call(.{})).toOwned();
    }

    pub fn getIsNot(
        this: *ExpectMatcherContext,
        _: bindgen.CallContext(IsNotSchema),
        _: bindgen.Args(IsNotSchema),
    ) bun.JSError!bool {
        return this.flags.not;
    }

    pub fn getPromise(
        this: *ExpectMatcherContext,
        _: bindgen.CallContext(PromiseSchema),
        _: bindgen.Args(PromiseSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromUTF8(switch (this.flags.promise) {
            .rejects => "rejects",
            .resolves => "resolves",
            else => "",
        });
    }

    pub fn getExpand(
        _: *ExpectMatcherContext,
        _: bindgen.CallContext(ExpandSchema),
        _: bindgen.Args(ExpandSchema),
    ) bun.JSError!bool {
        return false;
    }

    pub fn equals(
        _: *ExpectMatcherContext,
        context: bindgen.CallContext(EqualsSchema),
        args: bindgen.Args(EqualsSchema),
    ) bun.JSError!bool {
        const globalThis = context.viewToken().globalObject();
        const received = args.received orelse {
            return globalThis.throw("expect.extends matcher: this.util.equals expects at least 2 arguments", .{});
        };
        const expected = args.expected orelse {
            return globalThis.throw("expect.extends matcher: this.util.equals expects at least 2 arguments", .{});
        };
        return context.engineIn("js_value_inspection", "jsValueJestDeepEquals").call(.{
            .input = .{ .left = received.operand(context).asEngine(), .right = expected.operand(context).asEngine() },
        });
    }
};

/// Reference: `MatcherUtils` in https://github.com/jestjs/jest/blob/main/packages/expect/src/types.ts
pub const ExpectMatcherUtils = struct {
    bindgen_state: bindgen.ClassState = .{},

    const ClassSchema = ExpectBindings.class("ExpectMatcherUtils");
    const ExpectedColorSchema = ClassSchema.member("EXPECTED_COLOR");
    const MatcherHintSchema = ClassSchema.member("matcherHint");
    const PrintExpectedSchema = ClassSchema.member("printExpected");
    const PrintReceivedSchema = ClassSchema.member("printReceived");
    const ReceivedColorSchema = ClassSchema.member("RECEIVED_COLOR");
    const StringifySchema = ClassSchema.member("stringify");
    pub const Binding = bindgen.Class(ClassSchema, @This());

    fn createSingleton(globalThis: *JSGlobalObject) bun.JSError!bindgen.ClassRef(ClassSchema) {
        const instance = globalThis.bunVM().allocator.create(ExpectMatcherUtils) catch {
            return globalThis.throwOutOfMemory();
        };
        instance.* = .{};
        return Binding.adoptNativeRef(instance, globalThis);
    }

    fn bindCreateSingleton(
        context: bun.bindgen.CallContext(ExpectMatcherUtilsCreateSchema),
        _: bun.bindgen.Args(ExpectMatcherUtilsCreateSchema),
    ) bun.JSError!bun.bindgen.Return(ExpectMatcherUtilsCreateSchema) {
        return createSingleton(context.viewToken().globalObject());
    }

    pub fn destroy(
        this: *ExpectMatcherUtils,
    ) void {
        VirtualMachine.get().allocator.destroy(this);
    }

    fn printValue(globalThis: *JSGlobalObject, value: JSValue, comptime color_or_null: ?[]const u8) bun.JSError!bindgen.DOMString {
        var formatter = jsc.ConsoleObject.Formatter{ .globalThis = globalThis, .quote_strings = true };
        defer formatter.deinit();
        if (comptime color_or_null) |color| {
            if (Output.enable_ansi_colors_stderr) {
                return globalThis.formatErrorMessage(comptime Output.prettyFmt(color ++ "{f}<r>", true), .{value.toFmt(&formatter)});
            }
        }
        return globalThis.formatErrorMessage("{f}", .{value.toFmt(&formatter)});
    }

    fn printArgument(
        context: anytype,
        value: ?JSValue,
        comptime color_or_null: ?[]const u8,
    ) bun.JSError!bindgen.DOMString {
        return printValue(context.viewToken().globalObject(), value orelse BindingEscape.borrowEngineValue(context, .js_undefined), color_or_null);
    }

    fn PrintMember(comptime Schema: type, comptime color: ?[]const u8) type {
        return struct {
            fn invoke(
                _: *ExpectMatcherUtils,
                context: bindgen.CallContext(Schema),
                args: bindgen.Args(Schema),
            ) bun.JSError!bindgen.Return(Schema) {
                return printArgument(context, if (args.value) |value| value.operand(context).asEngine() else null, color);
            }
        };
    }

    pub const stringify = PrintMember(StringifySchema, null).invoke;
    pub const printExpected = PrintMember(PrintExpectedSchema, "<green>").invoke;
    pub const printExpectedColor = PrintMember(ExpectedColorSchema, "<green>").invoke;
    pub const printReceived = PrintMember(PrintReceivedSchema, "<red>").invoke;
    pub const printReceivedColor = PrintMember(ReceivedColorSchema, "<red>").invoke;

    pub fn matcherHint(
        _: *ExpectMatcherUtils,
        context: bindgen.CallContext(MatcherHintSchema),
        args: bindgen.Args(MatcherHintSchema),
    ) bun.JSError!bindgen.Return(MatcherHintSchema) {
        return matcherHintFromBinding(
            context,
            args,
            if (args.received) |value| value.operand(context).asEngine() else null,
            if (args.expected) |value| value.operand(context).asEngine() else null,
        );
    }

    fn matcherHintFromBinding(
        context: anytype,
        args: anytype,
        received_value: ?JSValue,
        expected_value: ?JSValue,
    ) bun.JSError!bindgen.DOMString {
        const globalThis = context.viewToken().globalObject();
        const matcher_name_view = args.matcherName orelse
            return globalThis.throw("matcherHint: the first argument (matcher name) must be a string", .{});
        var matcher_name_owned = matcher_name_view.toOwned();
        const matcher_name = matcher_name_owned.takeBunString();
        defer matcher_name.deref();

        var is_not = false;
        if (args.options) |provided| {
            if (provided) |options| is_not = options.is_not orelse false;
        }

        const diff_formatter = DiffFormatter{
            .received = received_value,
            .expected = expected_value,
            .received_string = if (received_value == null) "\"received\"" else null,
            .expected_string = if (expected_value == null) "\"expected\"" else null,
            .globalThis = globalThis,
            .not = is_not,
        };

        switch (is_not) {
            inline else => |negated| {
                const signature = comptime ExpectState.signature("{f}", "<green>expected<r>", negated);
                switch (Output.enable_ansi_colors_stderr) {
                    inline else => |colors| return globalThis.formatErrorMessage(
                        comptime Output.prettyFmt(signature ++ "\n\n{f}\n", colors),
                        .{ matcher_name, diff_formatter },
                    ),
                }
            },
        }
    }
};

const ExpectMatcherUtilsCreateBinding = bindgen.Fn(
    ExpectMatcherUtilsCreateSchema,
    ExpectMatcherUtils.bindCreateSingleton,
);

comptime {
    _ = ExpectMatcherContext.Binding;
    _ = ExpectMatcherUtils.Binding;
    _ = ExpectMatcherUtilsCreateBinding;
}
