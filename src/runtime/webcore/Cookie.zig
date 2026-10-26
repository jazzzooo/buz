const Cookie = @This();

bindgen_state: bindgen.ClassState = .{},
resource: Resource,

pub const Resource = bindgen.Return(CreateSchema);

fn create(resource: Resource) bun.OOM!*Cookie {
    var owned = resource;
    errdefer owned.deinit();
    const cookie = try bun.default_allocator.create(Cookie);
    cookie.* = .{ .resource = owned };
    return cookie;
}

pub fn createResource(context: anytype, name: anytype, value: anytype, options: anytype) bun.JSError!Resource {
    return context.engineIn("cookie", "cookieCreate").call(.{
        .name = name.operand(),
        .value = if (value) |text| text.operand() else null,
        .domain = if (if (options) |o| o.domain orelse null else null) |option| option.operand() else null,
        .path = if (if (options) |o| o.path orelse null else null) |option| option.operand() else null,
        .expires = if (options) |o| o.expires orelse null else null,
        .secure = if (options) |o| o.secure orelse false else false,
        .same_site = if (options) |o| (o.same_site orelse null) orelse .lax else .lax,
        .http_only = if (options) |o| o.http_only orelse false else false,
        .max_age = if (options) |o| o.max_age orelse null else null,
        .partitioned = if (options) |o| o.partitioned orelse false else false,
    });
}

pub fn construct(context: bindgen.CallContext(ConstructorSchema), args: bindgen.Args(ConstructorSchema)) bun.JSError!*Cookie {
    const resource = switch (args) {
        .parse => |values| try context.engineIn("cookie", "cookieParse").call(.{ .input = values.cookieString.operand() }),
        .init => |values| try createResource(context, values.init.name, values.init.value, @as(?@TypeOf(values.init), values.init)),
        .pair => |values| try createResource(context, values.name, @as(?@TypeOf(values.value), values.value), values.options),
    };
    return create(resource);
}

pub fn destroy(this: *Cookie) void {
    this.resource.deinit();
    bun.default_allocator.destroy(this);
}

pub fn memoryUsage(this: *const Cookie, _: bindgen.MemoryUsageContext(.vm)) usize {
    return @sizeOf(Cookie) +| bindgen.Engine(MemoryCostSchema).call(.{ .cookie = &this.resource });
}

fn Method(comptime FunctionSchema: type, comptime operation: []const u8) type {
    return struct {
        pub fn call(this: *Cookie, context: bindgen.CallContext(FunctionSchema), args: bindgen.Args(FunctionSchema)) bun.JSError!bindgen.Return(FunctionSchema) {
            return context.engineIn("cookie", operation).callForwarded(args, .{ .cookie = &this.resource });
        }
    };
}

pub const getName = Method(CookieSchema.memberKind("name", .getter), "cookieName").call;

pub const getValue = Method(CookieSchema.memberKind("value", .getter), "cookieValue").call;

pub const setValue = Method(CookieSchema.memberKind("value", .setter), "cookieSetValue").call;

pub const getDomain = Method(CookieSchema.memberKind("domain", .getter), "cookieDomain").call;

pub const setDomain = Method(CookieSchema.memberKind("domain", .setter), "cookieSetDomain").call;

pub const getPath = Method(CookieSchema.memberKind("path", .getter), "cookiePath").call;

pub const setPath = Method(CookieSchema.memberKind("path", .setter), "cookieSetPath").call;

pub const getExpires = Method(CookieSchema.memberKind("expires", .getter), "cookieExpires").call;

pub fn setExpires(this: *Cookie, context: bindgen.CallContext(SetExpiresSchema), args: bindgen.Args(SetExpiresSchema)) bun.JSError!void {
    try context.engineIn("cookie", "cookieSetExpires").call(.{ .cookie = &this.resource, .value = args.value });
    Binding.CachedSlotInvalidator("expires").clearView(args.bindingThis);
}

pub const getSecure = Method(CookieSchema.memberKind("secure", .getter), "cookieSecure").call;

pub const setSecure = Method(CookieSchema.memberKind("secure", .setter), "cookieSetSecure").call;

pub const getSameSite = Method(CookieSchema.memberKind("sameSite", .getter), "cookieSameSite").call;

pub const setSameSite = Method(CookieSchema.memberKind("sameSite", .setter), "cookieSetSameSite").call;

pub const getHttpOnly = Method(CookieSchema.memberKind("httpOnly", .getter), "cookieHttpOnly").call;

pub const setHttpOnly = Method(CookieSchema.memberKind("httpOnly", .setter), "cookieSetHttpOnly").call;

pub const getMaxAge = Method(CookieSchema.memberKind("maxAge", .getter), "cookieMaxAge").call;

pub const setMaxAge = Method(CookieSchema.memberKind("maxAge", .setter), "cookieSetMaxAge").call;

pub const getPartitioned = Method(CookieSchema.memberKind("partitioned", .getter), "cookiePartitioned").call;

pub const setPartitioned = Method(CookieSchema.memberKind("partitioned", .setter), "cookieSetPartitioned").call;

pub const isExpired = Method(CookieSchema.member("isExpired"), "cookieIsExpired").call;

pub const toString = Method(CookieSchema.member("toString"), "cookieToString").call;

pub const serialize = Method(CookieSchema.member("serialize"), "cookieToString").call;

pub const toJSON = Method(CookieSchema.member("toJSON"), "cookieJSON").call;

pub const inspectCustom = Method(CookieSchema.member("inspectCustom"), "cookieJSON").call;

pub fn parse(context: bindgen.CallContext(ParseSchema), args: bindgen.Args(ParseSchema)) bun.JSError!bindgen.Return(ParseSchema) {
    const resource = try context.engineIn("cookie", "cookieParse").call(.{ .input = args.cookieString.operand() });
    return Binding.adoptResult(try create(resource), context);
}

pub fn from(context: bindgen.CallContext(FromSchema), args: bindgen.Args(FromSchema)) bun.JSError!bindgen.Return(FromSchema) {
    const resource = try createResource(context, args.name, @as(?@TypeOf(args.value), args.value), args.options);
    return Binding.adoptResult(try create(resource), context);
}

fn retainFromWrapper(_: bindgen.CallContext(RetainFromWrapperSchema), args: bindgen.Args(RetainFromWrapperSchema)) bun.JSError!bindgen.Return(RetainFromWrapperSchema) {
    return bindgen.Engine(RetainSchema).call(.{ .cookie = &args.value.get(Cookie).resource });
}

const bun = @import("bun");
const bindgen = bun.bindgen;
const CookieModule = bindgen.Module("cookie");
const CreateSchema = CookieModule.engineShim("cookieCreate");
const RetainSchema = CookieModule.engineShim("cookieRetain");
const MemoryCostSchema = CookieModule.engineShim("cookieMemoryCost");
const RetainFromWrapperSchema = CookieModule.nativeExport("cookieRetainFromWrapper");
const CookieSchema = bindgen.Module("WebCoreCookies").class("Cookie");
const Binding = bindgen.Class(CookieSchema, Cookie);
const ConstructorSchema = CookieSchema.constructor();
const SetExpiresSchema = CookieSchema.memberKind("expires", .setter);
const ParseSchema = CookieSchema.member("parse");
const FromSchema = CookieSchema.member("from");

comptime {
    _ = Binding;
    _ = bindgen.Fn(RetainFromWrapperSchema, retainFromWrapper);
}
