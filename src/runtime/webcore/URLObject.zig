const URLObject = @This();

bindgen_state: bindgen.ClassState = .{},
resource: bindgen.Return(RetainSchema),

fn create(resource: bindgen.Return(RetainSchema)) bun.OOM!*URLObject {
    var owned = resource;
    errdefer owned.deinit();
    const object = try bun.default_allocator.create(URLObject);
    object.* = .{ .resource = owned };
    return object;
}

pub fn construct(context: bindgen.CallContext(ConstructorSchema), args: bindgen.Args(ConstructorSchema)) bindgen.CallError(ConstructorSchema)!*URLObject {
    return createFromInput(context, args.url.asDOMString(), if (args.base) |base| base.asDOMString() else null);
}

fn createFromInput(context: anytype, url: bindgen.DOMStringView, base: ?bindgen.DOMStringView) bindgen.CallError(ConstructorSchema)!*URLObject {
    const result = try context.engineIn("urls", "domURLCreate").call(.{ .url = url.operand(), .base = if (base) |text| text.operand() else null });
    return switch (result) {
        .url => |resource| create(resource),
        .invalid => |message| context.fail(.invalid_url, message),
    };
}

pub fn destroy(this: *URLObject) void {
    this.resource.deinit();
    bun.default_allocator.destroy(this);
}

pub fn memoryUsage(this: *const URLObject, _: bindgen.MemoryUsageContext(.vm)) usize {
    return @sizeOf(URLObject) +| bindgen.Engine(MemoryCostSchema).call(.{ .url = &this.resource });
}

pub fn href(this: *URLObject, context: anytype) bun.JSError!bindgen.USVString {
    return context.engineIn("urls", "domURLGet").call(.{ .url = &this.resource, .component = .href });
}

fn Getter(comptime name: []const u8) type {
    const Member = Schema.memberKind(name, .getter);
    return struct {
        fn call(this: *URLObject, context: bindgen.CallContext(Member), _: bindgen.Args(Member)) bun.JSError!bindgen.USVString {
            const Component = bindgen.EngineArgumentType(GetSchema, "component");
            return context.engineIn("urls", "domURLGet").call(.{ .url = &this.resource, .component = @field(Component, name) });
        }
    };
}

fn Setter(comptime name: []const u8) type {
    const Member = Schema.memberKind(name, .setter);
    return struct {
        fn call(this: *URLObject, context: bindgen.CallContext(Member), args: bindgen.Args(Member)) bun.JSError!void {
            const Component = bindgen.EngineArgumentType(SetSchema, "component");
            return context.engineIn("urls", "domURLSet").call(.{
                .url = &this.resource,
                .component = @field(Component, name),
                .value = args.value.operand(),
            });
        }
    };
}

pub const getHref = Getter("href").call;
pub const getOrigin = Getter("origin").call;
pub const getProtocol = Getter("protocol").call;
pub const getUsername = Getter("username").call;
pub const getPassword = Getter("password").call;
pub const getHost = Getter("host").call;
pub const getHostname = Getter("hostname").call;
pub const getPort = Getter("port").call;
pub const getPathname = Getter("pathname").call;
pub const getSearch = Getter("search").call;
pub const getHash = Getter("hash").call;
pub const setProtocol = Setter("protocol").call;
pub const setUsername = Setter("username").call;
pub const setPassword = Setter("password").call;
pub const setHost = Setter("host").call;
pub const setHostname = Setter("hostname").call;
pub const setPort = Setter("port").call;
pub const setPathname = Setter("pathname").call;
pub const setSearch = Setter("search").call;
pub const setHash = Setter("hash").call;

pub fn setHref(this: *URLObject, context: bindgen.CallContext(SetHrefSchema), args: bindgen.Args(SetHrefSchema)) bindgen.CallError(SetHrefSchema)!void {
    if (try context.engineIn("urls", "domURLSetHref").call(.{ .url = &this.resource, .value = args.value.operand() })) |message|
        return context.fail(.invalid_url, message);
}

pub fn getSearchParams(this: *URLObject, context: bindgen.CallContext(SearchParamsSchema), _: bindgen.Args(SearchParamsSchema)) bun.JSError!bindgen.Return(SearchParamsSchema) {
    const resource = try context.engineIn("urls", "domURLSearchParams").call(.{ .url = &this.resource });
    return Params.Binding.adoptResult(try Params.create(resource), context);
}

pub fn toJSON(this: *URLObject, context: bindgen.CallContext(JSONSchema), _: bindgen.Args(JSONSchema)) bun.JSError!bindgen.USVString {
    return this.href(context);
}

pub fn toString(this: *URLObject, context: bindgen.CallContext(StringSchema), _: bindgen.Args(StringSchema)) bun.JSError!bindgen.USVString {
    return this.href(context);
}

pub fn parse(context: bindgen.CallContext(ParseSchema), args: bindgen.Args(ParseSchema)) bindgen.CallError(ParseSchema)!bindgen.Return(ParseSchema) {
    const url = args.url orelse return context.fail(.missing_url, {});
    const resource = (try context.engineIn("urls", "domURLParse").call(.{
        .url = url.asDOMString().operand(),
        .base = if (args.base) |base| base.asDOMString().operand() else null,
    })) orelse return null;
    return try Binding.adoptResult(try create(resource), context);
}

pub fn canParse(context: bindgen.CallContext(CanParseSchema), args: bindgen.Args(CanParseSchema)) bindgen.CallError(CanParseSchema)!bool {
    const url = args.url orelse return context.fail(.missing_url, {});
    return context.engineIn("urls", "domURLCanParse").call(.{
        .url = url.asDOMString().operand(),
        .base = if (args.base) |base| base.asDOMString().operand() else null,
    });
}

pub const createObjectURL = @import("./ObjectURLRegistryEngine.zig").urlCreateObjectURL;
pub const revokeObjectURL = @import("./ObjectURLRegistryEngine.zig").urlRevokeObjectURL;

fn fromString(context: bindgen.CallContext(FromStringSchema), args: bindgen.Args(FromStringSchema)) bindgen.CallError(FromStringSchema)!bindgen.Return(FromStringSchema) {
    return Binding.adoptResult(try createFromInput(context, args.url, null), context);
}

fn fromFileSystemPath(context: bindgen.CallContext(FromFileSystemPathSchema), args: bindgen.Args(FromFileSystemPathSchema)) bindgen.CallError(FromFileSystemPathSchema)!bindgen.Return(FromFileSystemPathSchema) {
    const result = try context.engineIn("urls", "domURLCreateFromFileSystemPath").call(.{ .path = args.path.operand() });
    const object = switch (result) {
        .url => |resource| try create(resource),
        .invalid => |message| return context.fail(.invalid_url, message),
    };
    return Binding.adoptResult(object, context);
}

fn retainFromWrapper(_: bindgen.CallContext(RetainFromWrapperSchema), args: bindgen.Args(RetainFromWrapperSchema)) bun.JSError!bindgen.Return(RetainFromWrapperSchema) {
    return bindgen.Engine(RetainSchema).call(.{ .url = &args.value.get(URLObject).resource });
}

const bun = @import("bun");
const bindgen = bun.bindgen;
const Params = @import("../../jsc/URLSearchParams.zig").URLSearchParamsObject;
const Schema = bindgen.Module("WebCoreURL").class("URL");
pub const Binding = bindgen.Class(Schema, URLObject);
const ConstructorSchema = Schema.constructor();
const SetHrefSchema = Schema.memberKind("href", .setter);
const SearchParamsSchema = Schema.member("searchParams");
const JSONSchema = Schema.member("toJSON");
const StringSchema = Schema.member("toString");
const ParseSchema = Schema.member("parse");
const CanParseSchema = Schema.member("canParse");
const ResourceModule = bindgen.Module("urls");
const RetainSchema = ResourceModule.engineShim("domURLRetain");
const MemoryCostSchema = ResourceModule.engineShim("domURLMemoryCost");
const GetSchema = ResourceModule.engineShim("domURLGet");
const SetSchema = ResourceModule.engineShim("domURLSet");
const FromStringSchema = ResourceModule.nativeExport("domURLFromString");
const FromFileSystemPathSchema = ResourceModule.nativeExport("domURLFromFileSystemPath");
const RetainFromWrapperSchema = ResourceModule.nativeExport("domURLRetainFromWrapper");

comptime {
    _ = Binding;
    _ = bindgen.Fn(FromStringSchema, fromString);
    _ = bindgen.Fn(FromFileSystemPathSchema, fromFileSystemPath);
    _ = bindgen.Fn(RetainFromWrapperSchema, retainFromWrapper);
}
