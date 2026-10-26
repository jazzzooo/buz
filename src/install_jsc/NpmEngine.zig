//! JSC host fns extracted from `src/install/npm.zig` so that `install/` has
//! no `JSValue`/`JSGlobalObject`/`CallFrame` references. Registered enums keep a
//! `pub const jsFunction… = @import(...)` alias so domain call sites are unchanged.

pub fn operatingSystemIsMatch(
    _: bun.bindgen.CallContext(OperatingSystemIsMatchSchema),
    args: bun.bindgen.Args(OperatingSystemIsMatchSchema),
) bun.JSError!bool {
    var operating_system = npm.OperatingSystem.negatable(.none);
    for (0..args.constraints.len()) |index| {
        const slice = try args.constraints.at(index).?.toUTF8(bun.default_allocator);
        operating_system.apply(slice.slice());
        slice.deinit();
    }
    return operating_system.combine().isMatch(npm.OperatingSystem.current);
}

pub fn architectureIsMatch(
    _: bun.bindgen.CallContext(ArchitectureIsMatchSchema),
    args: bun.bindgen.Args(ArchitectureIsMatchSchema),
) bun.JSError!bool {
    var architecture = npm.Architecture.negatable(.none);
    for (0..args.constraints.len()) |index| {
        const slice = try args.constraints.at(index).?.toUTF8(bun.default_allocator);
        architecture.apply(slice.slice());
        slice.deinit();
    }
    return architecture.combine().isMatch(npm.Architecture.current);
}

/// Formerly `npm.PackageManifest.bindings` — testing-only (`internal-for-testing.ts`).
pub const ManifestBindings = struct {
    pub fn jsParseManifest(
        context: bun.bindgen.CallContext(ParseManifestSchema),
        args: bun.bindgen.Args(ParseManifestSchema),
    ) bun.bindgen.CallError(ParseManifestSchema)!bun.bindgen.DOMString {
        return parseManifestFromBinding(context, args);
    }

    fn parseManifestFromBinding(
        context: anytype,
        args: bun.bindgen.Args(ParseManifestSchema),
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        const globalThis = context.viewToken().globalObject();
        const io = globalThis.bunVM().io;
        const manifest_filename = try args.filename.toUTF8(bun.default_allocator);
        defer manifest_filename.deinit();
        const registry = try args.registry.toUTF8(bun.default_allocator);
        defer registry.deinit();

        const manifest_file = std.Io.Dir.cwd().openFile(io, manifest_filename.slice(), .{}) catch |err| {
            return failParseManifest(context, "failed to open manifest file \"{s}\": {s}", .{ manifest_filename.slice(), @errorName(err) });
        };
        defer manifest_file.close(io);

        const scope: npm.Registry.Scope = .{
            .url_hash = npm.Registry.Scope.hash(strings.withoutTrailingSlash(registry.slice())),
            .url = .{
                .host = strings.withoutTrailingSlash(strings.withoutPrefixComptime(registry.slice(), "http://")),
                .hostname = strings.withoutTrailingSlash(strings.withoutPrefixComptime(registry.slice(), "http://")),
                .href = registry.slice(),
                .origin = strings.withoutTrailingSlash(registry.slice()),
                .protocol = if (strings.indexOfChar(registry.slice(), ':')) |colon| registry.slice()[0..colon] else "",
            },
        };

        const maybe_package_manifest = npm.PackageManifest.Serializer.loadByFile(bun.default_allocator, &scope, bun.sys.File.from(manifest_file)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return failParseManifest(context, "failed to load manifest file: {s}", .{@errorName(err)});
        };

        const package_manifest: npm.PackageManifest = maybe_package_manifest orelse {
            return failParseManifest(context, "manifest is invalid", .{});
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(bun.default_allocator);
        var writer_state = bun.UnmanagedWriter.init(&buf, bun.default_allocator);
        var writer_finished = false;
        defer if (!writer_finished) writer_state.finish();
        const writer = writer_state.writer();

        writer.print("{{\"name\":{f},\"versions\":[", .{std.json.fmt(package_manifest.name(), .{})}) catch return error.OutOfMemory;

        for (package_manifest.versions, 0..) |version, i| {
            if (i > 0) writer.writeByte(',') catch return error.OutOfMemory;
            const version_string = std.fmt.allocPrint(
                bun.default_allocator,
                "{f}",
                .{version.fmt(package_manifest.string_buf)},
            ) catch return error.OutOfMemory;
            defer bun.default_allocator.free(version_string);
            writer.print("{f}", .{std.json.fmt(version_string, .{})}) catch return error.OutOfMemory;
        }
        writer.writeAll("]}") catch return error.OutOfMemory;

        writer_state.finish();
        writer_finished = true;

        return bun.bindgen.DOMString.fromUTF8(buf.items);
    }

    fn failParseManifest(
        context: bun.bindgen.CallContext(ParseManifestSchema),
        comptime format: [:0]const u8,
        values: anytype,
    ) bun.bindgen.CallError(ParseManifestSchema) {
        const message = bun.String.createFormat(format, values) catch return error.OutOfMemory;
        const payload = bun.bindgen.DOMString.fromBunString(message) catch return error.OutOfMemory;
        return context.fail(.operation_failed, payload);
    }
};

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const npm = bun.install.Npm;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const ParseManifestSchema = InternalTestingBindings.function("parseManifest");
const ParseManifestBinding = bun.bindgen.Fn(ParseManifestSchema, ManifestBindings.jsParseManifest);
const OperatingSystemIsMatchSchema = InternalTestingBindings.function("operatingSystemIsMatch");
const ArchitectureIsMatchSchema = InternalTestingBindings.function("architectureIsMatch");
const OperatingSystemIsMatchBinding = bun.bindgen.Fn(OperatingSystemIsMatchSchema, operatingSystemIsMatch);
const ArchitectureIsMatchBinding = bun.bindgen.Fn(ArchitectureIsMatchSchema, architectureIsMatch);

comptime {
    _ = ParseManifestBinding;
    _ = OperatingSystemIsMatchBinding;
    _ = ArchitectureIsMatchBinding;
}
