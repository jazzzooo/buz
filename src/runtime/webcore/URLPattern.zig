const URLPattern = @This();

bindgen_state: bindgen.ClassState = .{},
pattern: bindgen.Return(CreateSchema),

const InputView = @typeInfo(@FieldType(bindgen.Args(TestSchema), "input")).optional.child;
const InputOperand = @typeInfo(@FieldType(bindgen.Args(CreateSchema), "input")).optional.child;

fn inputOperand(value: InputView) InputOperand {
    return switch (value) {
        .string => |text| .{ .string = text.operand() },
        .init => |input| .{ .init = fields: {
            var result: @FieldType(InputOperand, "init") = undefined;
            inline for (@typeInfo(@TypeOf(result)).@"struct".field_names) |name| {
                @field(result, name) = if (@field(input, name)) |text| text.operand() else null;
            }
            break :fields result;
        } },
    };
}

pub fn construct(context: bindgen.CallContext(ConstructorSchema), args: bindgen.Args(ConstructorSchema)) bun.JSError!*URLPattern {
    var pattern = switch (args) {
        .base_url => |values| try context.engineIn("url_pattern", "urlPatternCreateWithBase").call(.{
            .input = inputOperand(values.input),
            .baseURL = values.baseURL.operand(),
            .ignoreCase = if (values.options) |options| options.ignoreCase orelse false else false,
        }),
        .options => |values| try context.engineIn("url_pattern", "urlPatternCreate").call(.{
            .input = if (values.input) |input| inputOperand(input) else null,
            .ignoreCase = if (values.options) |options| options.ignoreCase orelse false else false,
        }),
    };
    errdefer pattern.deinit();
    const object = try bun.default_allocator.create(URLPattern);
    object.* = .{ .pattern = pattern };
    return object;
}

pub fn destroy(this: *URLPattern) void {
    this.pattern.deinit();
    bun.default_allocator.destroy(this);
}

pub fn getProtocol(this: *URLPattern, context: bindgen.CallContext(ProtocolSchema), _: bindgen.Args(ProtocolSchema)) bun.JSError!bindgen.Return(ProtocolSchema) {
    return context.engineIn("url_pattern", "urlPatternProtocol").call(.{ .pattern = &this.pattern });
}

pub fn getUsername(this: *URLPattern, context: bindgen.CallContext(UsernameSchema), _: bindgen.Args(UsernameSchema)) bun.JSError!bindgen.Return(UsernameSchema) {
    return context.engineIn("url_pattern", "urlPatternUsername").call(.{ .pattern = &this.pattern });
}

pub fn getPassword(this: *URLPattern, context: bindgen.CallContext(PasswordSchema), _: bindgen.Args(PasswordSchema)) bun.JSError!bindgen.Return(PasswordSchema) {
    return context.engineIn("url_pattern", "urlPatternPassword").call(.{ .pattern = &this.pattern });
}

pub fn getHostname(this: *URLPattern, context: bindgen.CallContext(HostnameSchema), _: bindgen.Args(HostnameSchema)) bun.JSError!bindgen.Return(HostnameSchema) {
    return context.engineIn("url_pattern", "urlPatternHostname").call(.{ .pattern = &this.pattern });
}

pub fn getPort(this: *URLPattern, context: bindgen.CallContext(PortSchema), _: bindgen.Args(PortSchema)) bun.JSError!bindgen.Return(PortSchema) {
    return context.engineIn("url_pattern", "urlPatternPort").call(.{ .pattern = &this.pattern });
}

pub fn getPathname(this: *URLPattern, context: bindgen.CallContext(PathnameSchema), _: bindgen.Args(PathnameSchema)) bun.JSError!bindgen.Return(PathnameSchema) {
    return context.engineIn("url_pattern", "urlPatternPathname").call(.{ .pattern = &this.pattern });
}

pub fn getSearch(this: *URLPattern, context: bindgen.CallContext(SearchSchema), _: bindgen.Args(SearchSchema)) bun.JSError!bindgen.Return(SearchSchema) {
    return context.engineIn("url_pattern", "urlPatternSearch").call(.{ .pattern = &this.pattern });
}

pub fn getHash(this: *URLPattern, context: bindgen.CallContext(HashSchema), _: bindgen.Args(HashSchema)) bun.JSError!bindgen.Return(HashSchema) {
    return context.engineIn("url_pattern", "urlPatternHash").call(.{ .pattern = &this.pattern });
}

pub fn getHasRegExpGroups(this: *URLPattern, context: bindgen.CallContext(HasRegExpGroupsSchema), _: bindgen.Args(HasRegExpGroupsSchema)) bun.JSError!bool {
    return context.engineIn("url_pattern", "urlPatternHasRegExpGroups").call(.{ .pattern = &this.pattern });
}

pub fn @"test"(this: *URLPattern, context: bindgen.CallContext(TestSchema), args: bindgen.Args(TestSchema)) bun.JSError!bool {
    return context.engineIn("url_pattern", "urlPatternTest").call(.{ .pattern = &this.pattern, .input = if (args.input) |input| inputOperand(input) else null, .baseURL = if (args.baseURL) |base| base.operand() else null });
}

pub fn exec(this: *URLPattern, context: bindgen.CallContext(ExecSchema), args: bindgen.Args(ExecSchema)) bun.JSError!bindgen.Return(ExecSchema) {
    return context.engineIn("url_pattern", "urlPatternExec").call(.{ .pattern = &this.pattern, .input = if (args.input) |input| inputOperand(input) else null, .baseURL = if (args.baseURL) |base| base.operand() else null });
}

const bun = @import("bun");
const bindgen = bun.bindgen;
const CreateSchema = bindgen.Module("url_pattern").engineShim("urlPatternCreate");
const ClassSchema = bindgen.Module("WebCoreURL").class("URLPattern");
const ConstructorSchema = ClassSchema.constructor();
const ProtocolSchema = ClassSchema.member("protocol");
const UsernameSchema = ClassSchema.member("username");
const PasswordSchema = ClassSchema.member("password");
const HostnameSchema = ClassSchema.member("hostname");
const PortSchema = ClassSchema.member("port");
const PathnameSchema = ClassSchema.member("pathname");
const SearchSchema = ClassSchema.member("search");
const HashSchema = ClassSchema.member("hash");
const HasRegExpGroupsSchema = ClassSchema.member("hasRegExpGroups");
const TestSchema = ClassSchema.member("test");
const ExecSchema = ClassSchema.member("exec");

comptime {
    _ = bindgen.Class(ClassSchema, URLPattern);
}
