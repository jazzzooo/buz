pub const HeapProfilerConfig = struct {
    name: []const u8,
    dir: []const u8,
    text_format: bool,
};

// C++ function declarations
extern fn Bun__generateHeapProfile(vm: *jsc.VM) bun.String;
extern fn Bun__generateHeapSnapshotV8(vm: *jsc.VM) bun.String;

pub fn generateAndWriteProfile(io: std.Io, vm: *jsc.VM, config: HeapProfilerConfig) !void {
    const profile_string = if (config.text_format)
        Bun__generateHeapProfile(vm)
    else
        Bun__generateHeapSnapshotV8(vm);
    defer profile_string.deref();

    if (profile_string.isEmpty()) {
        // No profile data generated
        return;
    }

    const profile_slice = profile_string.toUTF8(bun.default_allocator);
    defer profile_slice.deinit();

    const output_path = try buildOutputPath(config);
    defer bun.default_allocator.free(output_path);

    // Convert to OS-specific path (UTF-16 on Windows, UTF-8 elsewhere)
    var path_buf_os: bun.OSPathBuffer = undefined;
    const output_path_os: bun.OSPathSliceZ = if (bun.Environment.isWindows)
        bun.strings.convertUTF8toUTF16InBufferZ(&path_buf_os, output_path)
    else
        output_path;

    // Write the profile to disk using bun.sys.File.writeFile
    const result = bun.sys.File.writeFile(bun.FD.cwd(), output_path_os, profile_slice.slice());
    if (result.asErr()) |err| {
        // If we got ENOENT, PERM, or ACCES, try creating the directory and retry
        const errno = err.getErrno();
        if (errno == .NOENT or errno == .PERM or errno == .ACCES) {
            // Derive directory from the absolute output path
            const dir_path = std.fs.path.dirname(output_path) orelse "";
            if (dir_path.len > 0) {
                bun.FD.cwd().makePath(io, u8, dir_path) catch {};
                // Retry write
                const retry_result = bun.sys.File.writeFile(bun.FD.cwd(), output_path_os, profile_slice.slice());
                if (retry_result.asErr()) |_| {
                    return error.WriteFailed;
                }
            } else {
                return error.WriteFailed;
            }
        } else {
            return error.WriteFailed;
        }
    }

    // Print message to stderr to let user know where the profile was written
    Output.prettyErrorln("Heap profile written to: {s}", .{output_path});
    Output.flush();
}

fn buildOutputPath(config: HeapProfilerConfig) ![:0]u8 {
    // Generate filename
    var filename_buf: bun.PathBuffer = undefined;
    const filename = if (config.name.len > 0)
        config.name
    else
        try generateDefaultFilename(&filename_buf, config.text_format);

    const resolved = try std.fs.path.resolve(
        bun.default_allocator,
        if (config.dir.len > 0)
            &.{ bun.fs.FileSystem.instance.top_level_dir, config.dir, filename }
        else
            &.{ bun.fs.FileSystem.instance.top_level_dir, filename },
    );
    errdefer bun.default_allocator.free(resolved);

    const resolved_z = try bun.default_allocator.realloc(resolved, resolved.len + 1);
    resolved_z[resolved.len] = 0;
    return resolved_z[0..resolved.len :0];
}

fn generateDefaultFilename(buf: *bun.PathBuffer, text_format: bool) ![]const u8 {
    // Generate filename like:
    // - Markdown format: Heap.{timestamp}.{pid}.md
    // - V8 format: Heap.{timestamp}.{pid}.heapsnapshot
    const timespec = bun.timespec.now(.force_real_time);
    const pid = if (bun.Environment.isWindows)
        std.os.windows.GetCurrentProcessId()
    else
        std.c.getpid();

    const epoch_microseconds: u64 = @intCast(timespec.sec *% 1_000_000 +% @divTrunc(timespec.nsec, 1000));

    const extension = if (text_format) "md" else "heapsnapshot";

    return try std.fmt.bufPrint(buf, "Heap.{d}.{d}.{s}", .{
        epoch_microseconds,
        pid,
        extension,
    });
}

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;
const jsc = bun.jsc;
