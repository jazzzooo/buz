//! JSC bridges for `bun.install.Dependency`. Aliased back into
//! `src/install/dependency.zig` so call sites are unchanged.

pub fn versionToJS(dep: *const Dependency.Version, buf: []const u8, globalThis: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
    const object = jsc.JSObject.createEmpty(globalThis, 0);
    object.putDirect(globalThis, "type", try bun.String.static(@tagName(dep.tag)).toJS(globalThis));

    switch (dep.tag) {
        .dist_tag => {
            object.putDirect(globalThis, "name", try dep.value.dist_tag.name.toJS(buf, globalThis));
            object.putDirect(globalThis, "tag", try dep.value.dist_tag.tag.toJS(buf, globalThis));
        },
        .folder => {
            object.putDirect(globalThis, "folder", try dep.value.folder.toJS(buf, globalThis));
        },
        .git => {
            object.putDirect(globalThis, "owner", try dep.value.git.owner.toJS(buf, globalThis));
            object.putDirect(globalThis, "repo", try dep.value.git.repo.toJS(buf, globalThis));
            object.putDirect(globalThis, "ref", try dep.value.git.committish.toJS(buf, globalThis));
        },
        .github => {
            object.putDirect(globalThis, "owner", try dep.value.github.owner.toJS(buf, globalThis));
            object.putDirect(globalThis, "repo", try dep.value.github.repo.toJS(buf, globalThis));
            object.putDirect(globalThis, "ref", try dep.value.github.committish.toJS(buf, globalThis));
        },
        .npm => {
            object.putDirect(globalThis, "name", try dep.value.npm.name.toJS(buf, globalThis));
            var version_str = try bun.String.createFormat("{f}", .{dep.value.npm.version.fmt(buf)});
            object.putDirect(globalThis, "version", try version_str.transferToJS(globalThis));
            object.putDirect(globalThis, "alias", jsc.JSValue.jsBoolean(dep.value.npm.is_alias));
        },
        .symlink => {
            object.putDirect(globalThis, "path", try dep.value.symlink.toJS(buf, globalThis));
        },
        .workspace => {
            object.putDirect(globalThis, "name", try dep.value.workspace.toJS(buf, globalThis));
        },
        .tarball => {
            object.putDirect(globalThis, "name", try dep.value.tarball.package_name.toJS(buf, globalThis));
            switch (dep.value.tarball.uri) {
                .local => |*local| {
                    object.putDirect(globalThis, "path", try local.toJS(buf, globalThis));
                },
                .remote => |*remote| {
                    object.putDirect(globalThis, "url", try remote.toJS(buf, globalThis));
                },
            }
        },
        else => {
            return globalThis.throwTODO("Unsupported dependency type");
        },
    }

    return object.toJS();
}

pub fn tagInferFromJS(globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const arguments = callframe.arguments_old(1).slice();
    if (arguments.len == 0 or !arguments[0].isString()) {
        return .js_undefined;
    }

    const dependency_str = try arguments[0].toBunString(globalObject);
    defer dependency_str.deref();
    var as_utf8 = dependency_str.toUTF8(bun.default_allocator);
    defer as_utf8.deinit();

    const tag = Dependency.Version.Tag.infer(as_utf8.slice());
    var str = bun.String.init(@tagName(tag));
    return str.transferToJS(globalObject);
}

pub fn dependencyFromJS(globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
    const arguments = callframe.arguments_old(2).slice();
    if (arguments.len == 1) {
        return try bun.install.PackageManager.UpdateRequest.fromJS(globalThis, arguments[0]);
    }
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    var stack_buffer: [1024]u8 = undefined;
    var stack: std.heap.BufferFirstAllocator = .init(&stack_buffer, arena.allocator());
    const allocator = stack.allocator();

    const alias_value: jsc.JSValue = if (arguments.len > 0) arguments[0] else .js_undefined;

    if (!alias_value.isString()) {
        return .js_undefined;
    }
    const alias_slice = try alias_value.toSlice(globalThis, allocator);
    defer alias_slice.deinit();

    if (alias_slice.len == 0) {
        return .js_undefined;
    }

    const name_value: jsc.JSValue = if (arguments.len > 1) arguments[1] else .js_undefined;
    const name_slice = try name_value.toSlice(globalThis, allocator);
    defer name_slice.deinit();

    var name = alias_slice.slice();
    var alias = alias_slice.slice();

    var buf = alias;

    if (name_value.isString()) {
        var builder = bun.handleOom(bun.StringBuilder.initCapacity(allocator, name_slice.len + alias_slice.len));
        name = builder.append(name_slice.slice());
        alias = builder.append(alias_slice.slice());
        buf = builder.allocatedSlice();
    }

    var log = logger.Log.init(allocator);
    const sliced = SlicedString.init(buf, name);

    const dep: Dependency.Version = Dependency.parse(allocator, SlicedString.init(buf, alias).value(), null, buf, &sliced, &log, null) orelse {
        if (log.msgs.items.len > 0) {
            return globalThis.throwValue(try log.toJS(globalThis, bun.default_allocator, "Failed to parse dependency"));
        }

        return .js_undefined;
    };

    if (log.msgs.items.len > 0) {
        return globalThis.throwValue(try log.toJS(globalThis, bun.default_allocator, "Failed to parse dependency"));
    }
    log.deinit();

    return dep.toJS(buf, globalThis);
}

const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;
const logger = bun.logger;
const Dependency = bun.install.Dependency;
const SlicedString = bun.Semver.SlicedString;
