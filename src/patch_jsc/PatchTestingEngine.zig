//! JS testing bindings for `bun.patch`. Keeps `src/patch/` free of JSC types.

pub const TestingAPIs = struct {
    pub fn makeDiff(
        context: bun.bindgen.CallContext(MakePatchDiffSchema),
        args: bun.bindgen.Args(MakePatchDiffSchema),
    ) bun.bindgen.CallError(MakePatchDiffSchema)!bun.bindgen.DOMString {
        return makeDiffFromBinding(context, args);
    }

    fn makeDiffFromBinding(
        context: bun.bindgen.CallContext(MakePatchDiffSchema),
        args: bun.bindgen.Args(MakePatchDiffSchema),
    ) bun.bindgen.CallError(MakePatchDiffSchema)!bun.bindgen.DOMString {
        const old_folder = try args.oldDirectory.toUTF8(bun.default_allocator);
        defer old_folder.deinit();

        const new_folder = try args.newDirectory.toUTF8(bun.default_allocator);
        defer new_folder.deinit();

        var cwd_buffer: bun.PathBuffer = undefined;
        const cwd_slice = bun.getcwd(&cwd_buffer) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return context.fail(.operation_failed, try errorMessage("failed to make diff", err));
        };
        const cwd = try bun.default_allocator.dupeSentinel(u8, cwd_slice, 0);
        defer bun.default_allocator.free(cwd);

        var git_buffer: bun.PathBuffer = undefined;
        const git = bun.which(
            &git_buffer,
            bun.env_var.PATH.get() orelse "",
            cwd,
            "git",
        ) orelse return context.fail(
            .operation_failed,
            try bun.bindgen.DOMString.fromUTF8("failed to make diff: git executable was not found"),
        );

        var command = try bun.patch.GitDiffCommand.init(
            bun.default_allocator,
            old_folder.slice(),
            new_folder.slice(),
            cwd,
            git,
        );
        defer command.deinit();

        if (comptime bun.Environment.isWindows) {
            command.options.windows.loop = bun.jsc.EventLoopHandle.init(bun.jsc.VirtualMachine.get().eventLoop()).parentEventLoop();
        }
        var spawn_result = switch (bun.spawnSync(&command.options) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return context.fail(.operation_failed, try errorMessage("failed to make diff", err));
        }) {
            .result => |result| result,
            .err => |err| return context.fail(
                .system,
                try bun.bindgen.SystemError.fromSysError(err),
            ),
        };
        defer spawn_result.deinit();

        return switch (try bun.patch.diffPostProcess(
            &spawn_result,
            command.old_folder,
            command.new_folder,
        )) {
            .result => |result| {
                defer result.deinit();
                return try bun.bindgen.DOMString.fromUTF8(result.items);
            },
            .err => |stderr| {
                defer stderr.deinit();
                return context.fail(
                    .operation_failed,
                    try formattedMessage("failed to make diff: {s}", .{stderr.items}),
                );
            },
        };
    }

    pub fn apply(
        context: bun.bindgen.CallContext(ApplyPatchSchema),
        binding_args: bun.bindgen.Args(ApplyPatchSchema),
    ) bun.bindgen.CallError(ApplyPatchSchema)!bool {
        var directory = bun.FD.cwd();
        var owns_directory = false;
        defer if (owns_directory) directory.close();

        if (binding_args.directory) |directory_view| {
            var directory_utf8 = try directory_view.toUTF8(bun.default_allocator);
            const path = try directory_utf8.intoOwnedSliceZ(bun.default_allocator);
            defer bun.default_allocator.free(path);

            directory = switch (bun.sys.open(path, bun.O.DIRECTORY | bun.O.RDONLY, 0)) {
                .result => |fd| fd,
                .err => |err| return context.fail(
                    .system,
                    try bun.bindgen.SystemError.fromSysError(err.withPath(path)),
                ),
            };
            owns_directory = true;
        }

        const patch_source = try binding_args.patch.toUTF8(bun.default_allocator);
        defer patch_source.deinit();
        var patch_file = parsePatchFile(patch_source.slice()) catch |err| {
            return context.fail(.parse_failed, try errorMessage("failed to parse patchfile", err));
        };
        defer patch_file.deinit();

        if (patch_file.apply(bun.default_allocator, directory)) |err| {
            return context.fail(
                .system,
                try bun.bindgen.SystemError.fromSysError(err),
            );
        }

        return true;
    }
    /// Used in JS tests, see `internal-for-testing.ts` and patch tests.
    pub fn parse(
        context: bun.bindgen.CallContext(ParsePatchSchema),
        args: bun.bindgen.Args(ParsePatchSchema),
    ) bun.bindgen.CallError(ParsePatchSchema)!bun.bindgen.DOMString {
        const patchfile_src = try args.patch.toUTF8(bun.default_allocator);
        defer patchfile_src.deinit();

        var patchfile = parsePatchFile(patchfile_src.slice()) catch |err| {
            const prefix = if (err == error.hunk_header_integrity_check_failed)
                "this indicates either that the supplied patch file was incorrect, or there is a bug in Bun. Please check your .patch file, or open a GitHub issue :)"
            else
                "failed to parse patch file";
            return context.fail(.parse_failed, try errorMessage(prefix, err));
        };
        defer patchfile.deinit();

        const str = try std.fmt.allocPrint(bun.default_allocator, "{f}", .{std.json.fmt(patchfile, .{})});
        defer bun.default_allocator.free(str);
        return try bun.bindgen.DOMString.fromUTF8(str);
    }
};

fn errorMessage(prefix: []const u8, err: anyerror) bun.OOM!bun.bindgen.DOMString {
    return formattedMessage("{s}: {s}", .{ prefix, @errorName(err) });
}

fn formattedMessage(
    comptime format: []const u8,
    args: anytype,
) bun.OOM!bun.bindgen.DOMString {
    const message = try std.fmt.allocPrint(bun.default_allocator, format, args);
    defer bun.default_allocator.free(message);
    return bun.bindgen.DOMString.fromUTF8(message);
}

const std = @import("std");

const bun = @import("bun");

const parsePatchFile = bun.patch.parsePatchFile;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const MakePatchDiffSchema = InternalTestingBindings.function("makePatchDiff");
const ApplyPatchSchema = InternalTestingBindings.function("applyPatch");
const ParsePatchSchema = InternalTestingBindings.function("parsePatch");
const MakePatchDiffBinding = bun.bindgen.Fn(MakePatchDiffSchema, TestingAPIs.makeDiff);
const ApplyPatchBinding = bun.bindgen.Fn(ApplyPatchSchema, TestingAPIs.apply);
const ParsePatchBinding = bun.bindgen.Fn(ParsePatchSchema, TestingAPIs.parse);

comptime {
    _ = MakePatchDiffBinding;
    _ = ApplyPatchBinding;
    _ = ParsePatchBinding;
}
