const DependencyResult = @typeInfo(bun.bindgen.Return(DependencyFromJSSchema)).optional.child;
const DependencyVersionResult = @FieldType(DependencyResult, "version");
const UpdateRequestResult = @FieldType(DependencyResult, "update_request");

fn dependencyVersionResult(
    context: anytype,
    dep: *const Dependency.Version,
    buf: []const u8,
) bun.bindgen.CallError(@TypeOf(context))!DependencyVersionResult {
    return switch (dep.tag) {
        .dist_tag => blk: {
            var name = try bun.bindgen.DOMString.fromUTF8(dep.value.dist_tag.name.slice(buf));
            errdefer name.deinit();
            var tag = try bun.bindgen.DOMString.fromUTF8(dep.value.dist_tag.tag.slice(buf));
            errdefer tag.deinit();
            break :blk .{ .dist_tag = .{ .type = .dist_tag, .name = name, .tag = tag } };
        },
        .folder => blk: {
            var folder = try bun.bindgen.DOMString.fromUTF8(dep.value.folder.slice(buf));
            errdefer folder.deinit();
            break :blk .{ .folder = .{ .type = .folder, .folder = folder } };
        },
        .git => blk: {
            var owner = try bun.bindgen.DOMString.fromUTF8(dep.value.git.owner.slice(buf));
            errdefer owner.deinit();
            var repo = try bun.bindgen.DOMString.fromUTF8(dep.value.git.repo.slice(buf));
            errdefer repo.deinit();
            var ref = try bun.bindgen.DOMString.fromUTF8(dep.value.git.committish.slice(buf));
            errdefer ref.deinit();
            break :blk .{ .git = .{ .type = .git, .owner = owner, .repo = repo, .ref = ref } };
        },
        .github => blk: {
            var owner = try bun.bindgen.DOMString.fromUTF8(dep.value.github.owner.slice(buf));
            errdefer owner.deinit();
            var repo = try bun.bindgen.DOMString.fromUTF8(dep.value.github.repo.slice(buf));
            errdefer repo.deinit();
            var ref = try bun.bindgen.DOMString.fromUTF8(dep.value.github.committish.slice(buf));
            errdefer ref.deinit();
            break :blk .{ .github = .{ .type = .github, .owner = owner, .repo = repo, .ref = ref } };
        },
        .npm => blk: {
            var name = try bun.bindgen.DOMString.fromUTF8(dep.value.npm.name.slice(buf));
            errdefer name.deinit();
            const formatted = try bun.String.createFormat("{f}", .{dep.value.npm.version.fmt(buf)});
            var version = try bun.bindgen.DOMString.fromBunString(formatted);
            errdefer version.deinit();
            break :blk .{ .npm = .{
                .type = .npm,
                .name = name,
                .version = version,
                .alias = dep.value.npm.is_alias,
            } };
        },
        .symlink => blk: {
            var path = try bun.bindgen.DOMString.fromUTF8(dep.value.symlink.slice(buf));
            errdefer path.deinit();
            break :blk .{ .symlink = .{ .type = .symlink, .path = path } };
        },
        .workspace => blk: {
            var name = try bun.bindgen.DOMString.fromUTF8(dep.value.workspace.slice(buf));
            errdefer name.deinit();
            break :blk .{ .workspace = .{ .type = .workspace, .name = name } };
        },
        .tarball => blk: {
            var name = try bun.bindgen.DOMString.fromUTF8(dep.value.tarball.package_name.slice(buf));
            errdefer name.deinit();
            switch (dep.value.tarball.uri) {
                .local => |local| {
                    var path = try bun.bindgen.DOMString.fromUTF8(local.slice(buf));
                    errdefer path.deinit();
                    break :blk .{ .tarball_local = .{ .type = .tarball, .name = name, .path = path } };
                },
                .remote => |remote| {
                    var url = try bun.bindgen.DOMString.fromUTF8(remote.slice(buf));
                    errdefer url.deinit();
                    break :blk .{ .tarball_remote = .{ .type = .tarball, .name = name, .url = url } };
                },
            }
        },
        .uninitialized, .catalog => return failDependency(context, "Unsupported dependency type"),
    };
}

pub fn tagInferFromJS(
    _: bun.bindgen.CallContext(InferDependencyTagSchema),
    args: bun.bindgen.Args(InferDependencyTagSchema),
) bun.JSError!bun.bindgen.Return(InferDependencyTagSchema) {
    const specifier = args.specifier orelse return null;
    const string = switch (specifier) {
        .string => |value| value,
        .ignored => return null,
    };
    const as_utf8 = try string.toUTF8(bun.default_allocator);
    defer as_utf8.deinit();

    const Result = @typeInfo(bun.bindgen.Return(InferDependencyTagSchema)).optional.child;
    return @as(Result, @fromBackingInt(@intCast(@backingInt(Dependency.Version.Tag.infer(PackageManagerEngine.javascript_semantics, as_utf8.slice())))));
}

pub fn dependencyFromJS(
    context: bun.bindgen.CallContext(DependencyFromJSSchema),
    args: bun.bindgen.Args(DependencyFromJSSchema),
) bun.bindgen.CallError(DependencyFromJSSchema)!bun.bindgen.Return(DependencyFromJSSchema) {
    return switch (args) {
        .value => |values| updateRequestResult(context, values.request),
        .strings => |values| dependencyFromStrings(context, values.alias, values.name),
    };
}

fn updateRequestResult(
    context: bun.bindgen.CallContext(DependencyFromJSSchema),
    input: anytype,
) bun.bindgen.CallError(DependencyFromJSSchema)!?DependencyResult {
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    var stack_buffer: [1024]u8 = undefined;
    var stack: std.heap.BufferFirstAllocator = .init(&stack_buffer, arena.allocator());
    const allocator = stack.allocator();
    var all_positionals = std.array_list.Managed([]const u8).init(allocator);

    var log = logger.Log.init(allocator);
    defer log.deinit();

    switch (input) {
        .string => |value| {
            const bytes = try value.toOwnedSlice(allocator);
            if (bytes.len > 0) try all_positionals.append(bytes);
        },
        .strings => |values| for (0..values.len()) |index| {
            const bytes = try values.at(index).?.toOwnedSlice(allocator);
            if (bytes.len == 0) continue;
            try all_positionals.append(bytes);
        },
    }

    if (all_positionals.items.len == 0) return null;

    var requests = UpdateRequest.Array.empty;
    defer requests.deinit(allocator);
    const parsed = UpdateRequest.parseWithError(
        allocator,
        .{ .javascript_semantics = PackageManagerEngine.javascript_semantics },
        &log,
        all_positionals.items,
        &requests,
        .add,
        false,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return failDependencyFromLog(context, &log, "Failed to parse dependencies");
    };
    if (parsed.len == 0) return null;
    if (log.msgs.items.len > 0) {
        return failDependencyFromLog(context, &log, "Failed to parse dependencies");
    }
    if (parsed[0].failed) return failDependency(context, "Failed to parse dependencies");

    var name = try bun.bindgen.DOMString.fromUTF8(parsed[0].name);
    errdefer name.deinit();
    const version = try dependencyVersionResult(context, &parsed[0].version, parsed[0].version_buf);
    return .{ .update_request = UpdateRequestResult{
        .name = name,
        .version = version,
    } };
}

fn dependencyFromStrings(
    context: bun.bindgen.CallContext(DependencyFromJSSchema),
    alias_view: bun.bindgen.DOMStringView,
    name_view: bun.bindgen.DOMStringView,
) bun.bindgen.CallError(DependencyFromJSSchema)!?DependencyResult {
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    var stack_buffer: [1024]u8 = undefined;
    var stack: std.heap.BufferFirstAllocator = .init(&stack_buffer, arena.allocator());
    const allocator = stack.allocator();

    const alias_slice = try alias_view.toUTF8(allocator);
    defer alias_slice.deinit();
    if (alias_slice.length() == 0) return null;

    const name_slice = try name_view.toUTF8(allocator);
    defer name_slice.deinit();

    const capacity = std.math.add(usize, name_slice.length(), alias_slice.length()) catch return error.OutOfMemory;
    var builder = try bun.StringBuilder.initCapacity(allocator, capacity);
    const name = builder.append(name_slice.slice());
    const alias = builder.append(alias_slice.slice());
    const buf = builder.allocatedSlice();

    var log = logger.Log.init(allocator);
    defer log.deinit();
    const sliced = SlicedString.init(buf, name);
    const dep = Dependency.parse(
        allocator,
        SlicedString.init(buf, alias).value(),
        null,
        buf,
        &sliced,
        &log,
        .{ .javascript_semantics = PackageManagerEngine.javascript_semantics },
    ) orelse {
        if (log.msgs.items.len > 0) {
            return failDependencyFromLog(context, &log, "Failed to parse dependency");
        }
        return null;
    };

    if (log.msgs.items.len > 0) {
        return failDependencyFromLog(context, &log, "Failed to parse dependency");
    }
    return .{ .version = try dependencyVersionResult(context, &dep, buf) };
}

fn failDependencyFromLog(context: anytype, log: *const logger.Log, fallback: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    return failDependency(
        context,
        if (log.msgs.items.len > 0) log.msgs.items[0].data.text else fallback,
    );
}

fn failDependency(context: anytype, message: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
    const payload = bun.bindgen.DOMString.fromUTF8(message) catch return error.OutOfMemory;
    return context.fail(.parse_failed, payload);
}

const std = @import("std");

const bun = @import("bun");
const logger = bun.logger;
const Dependency = bun.install.Dependency;
const PackageManagerEngine = @import("../install/PackageManagerEngine.zig");
const UpdateRequest = bun.install.PackageManager.UpdateRequest;
const SlicedString = bun.Semver.SlicedString;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const DependencyFromJSSchema = InternalTestingBindings.function("dependencyFromJS");
const InferDependencyTagSchema = InternalTestingBindings.function("inferDependencyTag");
const DependencyFromJSBinding = bun.bindgen.Fn(DependencyFromJSSchema, dependencyFromJS);
const InferDependencyTagBinding = bun.bindgen.Fn(InferDependencyTagSchema, tagInferFromJS);

comptime {
    _ = DependencyFromJSBinding;
    _ = InferDependencyTagBinding;
}
