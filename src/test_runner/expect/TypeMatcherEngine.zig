const bun = @import("bun");

const bindgen = bun.bindgen;
const ClassSchema = bindgen.Module("Expect").class("ExpectTypeOf");
const CallSchema = ClassSchema.constructorCall();

pub const ExpectTypeOf = struct {
    pub const Binding = bindgen.Class(ClassSchema, @This());

    bindgen_state: bindgen.ClassState = .{},

    pub fn destroy(type_matcher: *ExpectTypeOf) void {
        bun.destroy(type_matcher);
    }

    fn create(context: anytype) bun.JSError!bindgen.ClassRef(ClassSchema) {
        const native = bun.new(ExpectTypeOf, .{});
        return Binding.adoptResult(native, context);
    }

    fn VoidMember(comptime name: []const u8) type {
        const MemberSchema = ClassSchema.member(name);
        return struct {
            pub fn invoke(
                _: *ExpectTypeOf,
                _: bindgen.CallContext(MemberSchema),
                _: bindgen.Args(MemberSchema),
            ) bun.JSError!void {}
        };
    }

    fn SelfMember(comptime name: []const u8) type {
        const MemberSchema = ClassSchema.member(name);
        return struct {
            pub fn invoke(
                _: *ExpectTypeOf,
                context: bindgen.CallContext(MemberSchema),
                _: bindgen.Args(MemberSchema),
            ) bun.JSError!bindgen.Return(MemberSchema) {
                return ExpectTypeOf.create(context);
            }
        };
    }

    pub const asserts = SelfMember("asserts").invoke;
    pub const branded = SelfMember("branded").invoke;
    pub const constructorParameters = SelfMember("constructorParameters").invoke;
    pub const guards = SelfMember("guards").invoke;
    pub const instance = SelfMember("instance").invoke;
    pub const items = SelfMember("items").invoke;
    pub const map = SelfMember("map").invoke;
    pub const not = SelfMember("not").invoke;
    pub const parameters = SelfMember("parameters").invoke;
    pub const resolves = SelfMember("resolves").invoke;
    pub const returns = SelfMember("returns").invoke;
    pub const thisParameter = SelfMember("thisParameter").invoke;

    pub const exclude = VoidMember("exclude").invoke;
    pub const extract = VoidMember("extract").invoke;
    pub const omit = VoidMember("omit").invoke;
    pub const parameter = VoidMember("parameter").invoke;
    pub const pick = VoidMember("pick").invoke;
    pub const toBeAny = VoidMember("toBeAny").invoke;
    pub const toBeArray = VoidMember("toBeArray").invoke;
    pub const toBeBigInt = VoidMember("toBeBigInt").invoke;
    pub const toBeBoolean = VoidMember("toBeBoolean").invoke;
    pub const toBeCallableWith = VoidMember("toBeCallableWith").invoke;
    pub const toBeConstructibleWith = VoidMember("toBeConstructibleWith").invoke;
    pub const toBeFunction = VoidMember("toBeFunction").invoke;
    pub const toBeNever = VoidMember("toBeNever").invoke;
    pub const toBeNull = VoidMember("toBeNull").invoke;
    pub const toBeNumber = VoidMember("toBeNumber").invoke;
    pub const toBeObject = VoidMember("toBeObject").invoke;
    pub const toBeString = VoidMember("toBeString").invoke;
    pub const toBeSymbol = VoidMember("toBeSymbol").invoke;
    pub const toBeUndefined = VoidMember("toBeUndefined").invoke;
    pub const toBeUnknown = VoidMember("toBeUnknown").invoke;
    pub const toBeVoid = VoidMember("toBeVoid").invoke;
    pub const toEqualTypeOf = VoidMember("toEqualTypeOf").invoke;
    pub const toExtend = VoidMember("toExtend").invoke;
    pub const toHaveProperty = VoidMember("toHaveProperty").invoke;
    pub const toMatchObjectType = VoidMember("toMatchObjectType").invoke;
    pub const toMatchTypeOf = VoidMember("toMatchTypeOf").invoke;

    pub fn call(
        context: bindgen.CallContext(CallSchema),
        _: bindgen.Args(CallSchema),
    ) bun.JSError!bindgen.Return(CallSchema) {
        return create(context);
    }
};
