pub const bun_install_js_bindings = struct {
    pub fn jsParseLockfile(
        context: bun.bindgen.CallContext(ParseLockfileSchema),
        args: bun.bindgen.Args(ParseLockfileSchema),
    ) bun.bindgen.CallError(ParseLockfileSchema)!bun.bindgen.DOMString {
        return parseLockfile(context, args);
    }

    fn parseLockfile(
        context: bun.bindgen.CallContext(ParseLockfileSchema),
        args: bun.bindgen.Args(ParseLockfileSchema),
    ) bun.bindgen.CallError(ParseLockfileSchema)!bun.bindgen.DOMString {
        const vm = bun.jsc.VirtualMachine.get();
        const io = vm.io;
        const allocator = bun.default_allocator;
        var log = logger.Log.init(allocator);
        defer log.deinit();

        const cwd = try args.cwd.toUTF8(allocator);
        defer cwd.deinit();

        var dir = bun.openDirAbsoluteNotForDeletingOrRenaming(cwd.slice()) catch |err| {
            return failParseLockfile(context, "failed to open: {s}, '{s}'", .{ @errorName(err), cwd.slice() });
        };
        defer dir.close(io);

        const lockfile_path = Path.joinAbsStringZ(cwd.slice(), &[_]string{"bun.lockb"}, .auto);

        var lockfile: Lockfile = undefined;
        lockfile.initEmpty(allocator);
        defer lockfile.deinit();

        const transpiler = &vm.transpiler;
        if (transpiler.resolver.env_loader == null) {
            transpiler.resolver.env_loader = transpiler.env;
        }
        const manager = transpiler.resolver.ensurePackageManager() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return failParseLockfile(context, "failed to initialize package manager: {s}", .{@errorName(err)});
        };

        const load_result: Lockfile.LoadResult = lockfile.loadFromDir(.fromStdDir(dir), manager, bun.install.Dependency.ParseContext.fromPackageManager(manager), allocator, &log, true);

        switch (load_result) {
            .err => |err| {
                return failParseLockfile(context, "failed to load lockfile: {s}, '{s}'", .{ @errorName(err.value), lockfile_path });
            },
            .not_found => {
                return failParseLockfile(context, "lockfile not found: '{s}'", .{lockfile_path});
            },
            .ok => {},
        }

        const stringified = bun.handleOom(std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(lockfile, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = true,
            .emit_nonportable_numbers_as_strings = true,
        })}));
        defer allocator.free(stringified);

        return bun.bindgen.DOMString.fromUTF8(stringified);
    }

    fn failParseLockfile(
        context: bun.bindgen.CallContext(ParseLockfileSchema),
        comptime format: [:0]const u8,
        values: anytype,
    ) bun.bindgen.CallError(ParseLockfileSchema) {
        const message = bun.String.createFormat(format, values) catch return error.OutOfMemory;
        const payload = bun.bindgen.DOMString.fromBunString(message) catch return error.OutOfMemory;
        return context.fail(.operation_failed, payload);
    }
};

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const Path = bun.path;
const logger = bun.logger;
const Lockfile = bun.install.Lockfile;
const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const ParseLockfileSchema = InternalTestingBindings.function("parseLockfile");
const ParseLockfileBinding = bun.bindgen.Fn(ParseLockfileSchema, bun_install_js_bindings.jsParseLockfile);

comptime {
    _ = ParseLockfileBinding;
}
