const bun = @import("bun");
const std = @import("std");
const ExpectState = @import("./State.zig");

const bindgen = bun.bindgen;
const ExpectBindings = bindgen.Module("Expect");
const JSGlobalObject = bun.jsc.JSGlobalObject;
const VirtualMachine = bun.jsc.VirtualMachine;
const string = []const u8;

pub const ExpectAnyConstructorValueSchema = ExpectBindings.nativeExport("expectAnyConstructorValue");
pub const ExpectArrayContainingValueSchema = ExpectBindings.nativeExport("expectArrayContainingValue");
const ExpectCloseToMatchesSchema = ExpectBindings.nativeExport("expectCloseToMatches");
pub const ExpectObjectContainingValueSchema = ExpectBindings.nativeExport("expectObjectContainingValue");
pub const ExpectStringContainingValueSchema = ExpectBindings.nativeExport("expectStringContainingValue");
pub const ExpectStringMatchingValueSchema = ExpectBindings.nativeExport("expectStringMatchingValue");

const ExpectStaticAction = enum {
    not,
    resolvesTo,
    rejectsTo,
    anything,
    any,
    arrayContaining,
    closeTo,
    objectContaining,
    stringContaining,
    stringMatching,
};

/// Static instance of expect, holding a set of flags.
/// Returned for example when executing `expect.not`
pub const ExpectStatic = struct {
    pub const Action = ExpectStaticAction;

    const ClassSchema = ExpectBindings.class("ExpectStatic");
    pub const Binding = bindgen.Class(ClassSchema, @This());

    bindgen_state: bindgen.ClassState = .{},

    flags: ExpectState.Flags = .{},

    pub fn destroy(this: *ExpectStatic) void {
        VirtualMachine.get().allocator.destroy(this);
    }

    pub fn create(globalThis: *JSGlobalObject, flags: ExpectState.Flags) bun.JSError!bindgen.ClassRef(ClassSchema) {
        return adoptAsymmetricMatcher(@This(), Binding, globalThis, flags);
    }

    pub const getNot = Member(.not).invoke;

    pub const getResolvesTo = Member(.resolvesTo).invoke;

    pub const getRejectsTo = Member(.rejectsTo).invoke;

    fn asyncChainingError(globalThis: *JSGlobalObject, flags: ExpectState.Flags, name: string) bun.JSError {
        @branchHint(.cold);
        const str = switch (flags.promise) {
            .resolves => "resolvesTo",
            .rejects => "rejectsTo",
            else => unreachable,
        };
        return globalThis.throw("expect.{s}: already called expect.{s} on this chain", .{ name, str });
    }

    pub const anything = Member(.anything).invoke;

    pub const any = Member(.any).invoke;

    pub const arrayContaining = Member(.arrayContaining).invoke;

    pub const closeTo = Member(.closeTo).invoke;

    pub const objectContaining = Member(.objectContaining).invoke;

    pub const stringContaining = Member(.stringContaining).invoke;

    pub const stringMatching = Member(.stringMatching).invoke;

    fn Member(comptime action: Action) type {
        const Schema = ClassSchema.member(@tagName(action));
        return struct {
            fn invoke(
                this: *ExpectStatic,
                context: bindgen.CallContext(Schema),
                args: bindgen.Args(Schema),
            ) bun.JSError!bindgen.Return(Schema) {
                return this.resultFromBinding(action, context, args);
            }
        };
    }

    pub fn resultFromBinding(
        this: *ExpectStatic,
        comptime operation: ExpectStaticAction,
        context: anytype,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        const globalThis = context.viewToken().globalObject();
        return switch (operation) {
            .not => result: {
                var flags = this.flags;
                flags.not = !flags.not;
                break :result create(globalThis, flags);
            },
            .resolvesTo => result: {
                var flags = this.flags;
                if (flags.promise != .none) return asyncChainingError(globalThis, flags, "resolvesTo");
                flags.promise = .resolves;
                break :result create(globalThis, flags);
            },
            .rejectsTo => result: {
                var flags = this.flags;
                if (flags.promise != .none) return asyncChainingError(globalThis, flags, "rejectsTo");
                flags.promise = .rejects;
                break :result create(globalThis, flags);
            },
            .anything => ExpectAnything.create(globalThis, this.flags),
            .any => ExpectAny.create(globalThis, context, args.constructorValue, this.flags),
            .arrayContaining => ExpectArrayContaining.create(globalThis, args.arrayValue, this.flags),
            .closeTo => ExpectCloseTo.create(globalThis, args.numberValue, args.precisionValue, this.flags),
            .objectContaining => ExpectObjectContaining.create(globalThis, args.objectValue, this.flags),
            .stringContaining => ExpectStringContaining.create(globalThis, args.stringValue, this.flags),
            .stringMatching => ExpectStringMatching.create(globalThis, args.testValue, this.flags),
        };
    }
};

fn adoptAsymmetricMatcher(
    comptime T: type,
    comptime ClassBinding: type,
    global: *JSGlobalObject,
    flags: ExpectState.Flags,
) bun.JSError!bindgen.ClassRef(T.ClassSchema) {
    const instance = try global.bunVM().allocator.create(T);
    instance.* = .{ .flags = flags };
    return ClassBinding.adoptNativeRef(instance, global);
}

pub const ExpectAnything = struct {
    const ClassSchema = ExpectBindings.class("ExpectAnything");
    pub const Binding = bindgen.Class(ClassSchema, @This());

    bindgen_state: bindgen.ClassState = .{},

    flags: ExpectState.Flags = .{},

    pub fn destroy(
        this: *ExpectAnything,
    ) void {
        VirtualMachine.get().allocator.destroy(this);
    }

    pub fn create(globalThis: *JSGlobalObject, flags: ExpectState.Flags) bun.JSError!bindgen.ClassRef(ClassSchema) {
        const reference = try adoptAsymmetricMatcher(@This(), Binding, globalThis, flags);

        var vm = globalThis.bunVM();
        vm.autoGarbageCollect();

        return reference;
    }
};

pub const ExpectStringMatching = StoredMatcher("ExpectStringMatching", ExpectStringMatchingValueSchema);

pub const ExpectCloseTo = struct {
    const ClassSchema = ExpectBindings.class("ExpectCloseTo");
    pub const Binding = bindgen.Class(ClassSchema, @This());

    bindgen_state: bindgen.ClassState = .{},

    flags: ExpectState.Flags = .{},
    number_value: f64,
    digits_value: f64,

    pub fn destroy(this: *ExpectCloseTo) void {
        VirtualMachine.get().allocator.destroy(this);
    }

    pub fn matches(
        _: bindgen.CallContext(ExpectCloseToMatchesSchema),
        args: bindgen.Args(ExpectCloseToMatchesSchema),
    ) bool {
        const matcher = args.matcher.get(ExpectCloseTo);
        return @import("./Matcher.zig").closeTo(args.received, matcher.number_value, matcher.digits_value).matched;
    }

    pub fn create(
        globalThis: *JSGlobalObject,
        number_value: f64,
        precision: ?f64,
        flags: ExpectState.Flags,
    ) bun.JSError!bindgen.ClassRef(ClassSchema) {
        const allocator = globalThis.bunVM().allocator;
        const instance = try allocator.create(@This());
        instance.* = .{
            .flags = flags,
            .number_value = number_value,
            .digits_value = precision orelse 2.0,
        };
        const reference = try Binding.adoptNativeRef(instance, globalThis);

        var vm = globalThis.bunVM();
        vm.autoGarbageCollect();
        return reference;
    }
};

pub const ExpectObjectContaining = StoredMatcher("ExpectObjectContaining", ExpectObjectContainingValueSchema);

pub const ExpectStringContaining = StoredMatcher("ExpectStringContaining", ExpectStringContainingValueSchema);

pub const ExpectAny = struct {
    const ClassSchema = ExpectBindings.class("ExpectAny");
    pub const Binding = bindgen.Class(ClassSchema, @This());

    bindgen_state: bindgen.ClassState = .{},

    flags: ExpectState.Flags = .{},
    constructor_value: bindgen.OwnedBrandedValue(ExpectAnyConstructorValueSchema.ReturnType),

    pub fn destroy(this: *ExpectAny) void {
        this.constructor_value.deinit();
        VirtualMachine.get().allocator.destroy(this);
    }

    pub fn create(globalThis: *JSGlobalObject, context: anytype, constructor: bindgen.BrandedValueView(ExpectAnyConstructorValueSchema.ReturnType), flags: ExpectState.Flags) bun.JSError!bindgen.ClassRef(ClassSchema) {
        const asymmetric_matcher_constructor_type: ExpectState.Flags.AsymmetricMatcherConstructorType = switch (try context.engineIn("Expect", "asymmetricMatcherConstructorTypeFromJS").call(.{ .value = constructor.operand(context) })) {
            .none => .none,
            .Symbol => .Symbol,
            .String => .String,
            .Object => .Object,
            .Array => .Array,
            .BigInt => .BigInt,
            .Boolean => .Boolean,
            .Number => .Number,
            .Promise => .Promise,
            .InstanceOf => .InstanceOf,
        };

        var matcher_flags = flags;
        matcher_flags.asymmetric_matcher_constructor_type = asymmetric_matcher_constructor_type;

        var retained = try constructor.toOwned();
        defer retained.deinit();
        const allocator = globalThis.bunVM().allocator;
        const instance = try allocator.create(@This());
        instance.* = .{
            .flags = matcher_flags,
            .constructor_value = retained.take(),
        };
        const reference = try Binding.adoptNativeRef(instance, globalThis);

        var vm = globalThis.bunVM();
        vm.autoGarbageCollect();

        return reference;
    }
};

pub const ExpectArrayContaining = StoredMatcher("ExpectArrayContaining", ExpectArrayContainingValueSchema);

fn StoredMatcher(comptime class_name: []const u8, comptime ValueSchema: type) type {
    return struct {
        const Self = @This();
        const ClassSchema = ExpectBindings.class(class_name);
        pub const Binding = bindgen.Class(ClassSchema, Self);

        bindgen_state: bindgen.ClassState = .{},
        flags: ExpectState.Flags = .{},
        value: bindgen.OwnedBrandedValue(ValueSchema.ReturnType),

        pub fn destroy(this: *Self) void {
            this.value.deinit();
            VirtualMachine.get().allocator.destroy(this);
        }

        pub fn create(
            global: *JSGlobalObject,
            value: bindgen.BrandedValueView(ValueSchema.ReturnType),
            flags: ExpectState.Flags,
        ) bun.JSError!bindgen.ClassRef(ClassSchema) {
            var retained = try value.toOwned();
            defer retained.deinit();
            const vm = global.bunVM();
            const instance = try vm.allocator.create(Self);
            instance.* = .{ .flags = flags, .value = retained.take() };
            const reference = try Binding.adoptNativeRef(instance, global);
            vm.autoGarbageCollect();
            return reference;
        }
    };
}

fn StoredMatcherValueBinding(
    comptime NativeSchema: type,
    comptime Matcher: type,
    comptime field_name: []const u8,
) type {
    return struct {
        pub fn bind(
            context: bun.bindgen.CallContext(NativeSchema),
            args: bun.bindgen.Args(NativeSchema),
        ) bun.bindgen.Return(NativeSchema) {
            return @field(args.matcher.get(Matcher), field_name).toResult(context);
        }
    };
}

const ExpectAnyConstructorValueBinding = bindgen.Fn(
    ExpectAnyConstructorValueSchema,
    StoredMatcherValueBinding(ExpectAnyConstructorValueSchema, ExpectAny, "constructor_value").bind,
);
const ExpectStringContainingValueBinding = bindgen.Fn(
    ExpectStringContainingValueSchema,
    StoredMatcherValueBinding(ExpectStringContainingValueSchema, ExpectStringContaining, "value").bind,
);
const ExpectStringMatchingValueBinding = bindgen.Fn(
    ExpectStringMatchingValueSchema,
    StoredMatcherValueBinding(ExpectStringMatchingValueSchema, ExpectStringMatching, "value").bind,
);
const ExpectArrayContainingValueBinding = bindgen.Fn(
    ExpectArrayContainingValueSchema,
    StoredMatcherValueBinding(ExpectArrayContainingValueSchema, ExpectArrayContaining, "value").bind,
);
const ExpectObjectContainingValueBinding = bindgen.Fn(
    ExpectObjectContainingValueSchema,
    StoredMatcherValueBinding(ExpectObjectContainingValueSchema, ExpectObjectContaining, "value").bind,
);
const ExpectCloseToMatchesBinding = bindgen.Fn(ExpectCloseToMatchesSchema, ExpectCloseTo.matches);

comptime {
    _ = ExpectStatic.Binding;
    _ = ExpectAnything.Binding;
    _ = ExpectStringMatching.Binding;
    _ = ExpectCloseTo.Binding;
    _ = ExpectObjectContaining.Binding;
    _ = ExpectStringContaining.Binding;
    _ = ExpectAny.Binding;
    _ = ExpectArrayContaining.Binding;
    _ = ExpectAnyConstructorValueBinding;
    _ = ExpectStringContainingValueBinding;
    _ = ExpectStringMatchingValueBinding;
    _ = ExpectArrayContainingValueBinding;
    _ = ExpectObjectContainingValueBinding;
    _ = ExpectCloseToMatchesBinding;
}
