//! Binding adapters for `src/install/hosted_git_info.zig`.

fn invalidGitUrl(context: anytype) bun.bindgen.CallError(@TypeOf(context)) {
    const message = bun.bindgen.DOMString.fromUTF8("Invalid Git URL: InvalidGitUrl") catch return error.OutOfMemory;
    return context.fail(.operation_failed, message);
}

pub fn jsParseUrl(
    context: bun.bindgen.CallContext(HostedGitParseUrlSchema),
    args: bun.bindgen.Args(HostedGitParseUrlSchema),
) bun.bindgen.CallError(HostedGitParseUrlSchema)!bun.bindgen.DOMString {
    const allocator = bun.default_allocator;

    var as_utf8 = try args.url.toUTF8(allocator);
    defer as_utf8.deinit();
    const parsed = hgi.parseUrl(PackageManagerEngine.javascript_semantics, allocator, as_utf8.slice()) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidGitUrl => invalidGitUrl(context),
        };
    };
    defer parsed.url.deinit();

    return bun.bindgen.DOMString.fromBunString(parsed.url.href.dupeRef());
}

pub fn jsFromUrl(
    context: bun.bindgen.CallContext(HostedGitFromUrlSchema),
    args: bun.bindgen.Args(HostedGitFromUrlSchema),
) bun.bindgen.CallError(HostedGitFromUrlSchema)!bun.bindgen.Return(HostedGitFromUrlSchema) {
    const allocator = bun.default_allocator;

    var as_utf8 = try args.url.toUTF8(allocator);
    defer as_utf8.deinit();
    const parsed = hgi.HostedGitInfo.fromUrl(PackageManagerEngine.javascript_semantics, allocator, as_utf8.slice()) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidURL => invalidGitUrl(context),
        };
    } orelse return null;
    defer parsed.deinit();

    var result: bun.bindgen.Return(HostedGitFromUrlSchema) = .{
        .type = .empty(),
        .domain = .empty(),
        .project = .empty(),
        .user = null,
        .committish = null,
        .default_representation = .empty(),
    };
    errdefer bun.bindgen.deinitReturn(HostedGitFromUrlSchema, &result);
    const value = &result.?;
    value.type = try bun.bindgen.DOMString.fromUTF8(parsed.host_provider.typeStr());
    value.domain = try bun.bindgen.DOMString.fromUTF8(parsed.host_provider.domain());
    value.project = try bun.bindgen.DOMString.fromUTF8(parsed.project);
    value.user = try bun.bindgen.DOMString.fromOptionalUTF8(parsed.user);
    value.committish = try bun.bindgen.DOMString.fromOptionalUTF8(parsed.committish);
    value.default_representation = try bun.bindgen.DOMString.fromUTF8(@tagName(parsed.default_representation));
    return result;
}

const hgi = @import("../install/hosted_git_info.zig");
const PackageManagerEngine = @import("../install/PackageManagerEngine.zig");

const bun = @import("bun");

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const HostedGitParseUrlSchema = InternalTestingBindings.function("hostedGitParseUrl");
const HostedGitFromUrlSchema = InternalTestingBindings.function("hostedGitFromUrl");
const HostedGitParseUrlBinding = bun.bindgen.Fn(HostedGitParseUrlSchema, jsParseUrl);
const HostedGitFromUrlBinding = bun.bindgen.Fn(HostedGitFromUrlSchema, jsFromUrl);

comptime {
    _ = HostedGitParseUrlBinding;
    _ = HostedGitFromUrlBinding;
}
