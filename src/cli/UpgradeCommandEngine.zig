const bun = @import("bun");

const fs = @import("../resolver/fs.zig");
const Environment = bun.Environment;
const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const OpenTempDirWithoutSharingDeleteSchema = InternalTestingBindings.function("openTempDirWithoutSharingDelete");
const CloseTempDirHandleSchema = InternalTestingBindings.function("closeTempDirHandle");

var tempdir_fd: ?bun.FD = null;

pub fn openTempDirWithoutSharingDelete(
    context: bun.bindgen.CallContext(OpenTempDirWithoutSharingDeleteSchema),
    _: bun.bindgen.Args(OpenTempDirWithoutSharingDeleteSchema),
) bun.JSError!void {
    openTempDirWithoutSharingDeleteFromBinding(context);
}

pub fn openTempDirWithoutSharingDeleteFromBinding(context: anytype) void {
    const globalThis = context.viewToken().globalObject();
    if (comptime !Environment.isWindows) return;
    const w = bun.windows;

    var buf: bun.WPathBuffer = undefined;
    const tmpdir_path = fs.FileSystem.RealFS.getDefaultTempDir(globalThis.bunVM().io);
    const path = switch (bun.sys.normalizePathWindows(u8, bun.invalid_fd, tmpdir_path, &buf, .{})) {
        .err => return,
        .result => |norm| norm,
    };

    const path_len_bytes: u16 = @truncate(path.len * 2);
    var nt_name = w.UNICODE_STRING{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @constCast(path.ptr),
    };

    var attr = w.OBJECT_ATTRIBUTES{
        .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
        .RootDirectory = null,
        .Attributes = .{},
        .ObjectName = &nt_name,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };

    const flags: u32 = w.STANDARD_RIGHTS_READ | w.FILE_READ_ATTRIBUTES | w.FILE_READ_EA | w.SYNCHRONIZE | w.FILE_TRAVERSE;

    var fd: w.HANDLE = w.INVALID_HANDLE_VALUE;
    var io: w.IO_STATUS_BLOCK = undefined;

    const rc = w.NtCreateFile(
        &fd,
        flags,
        &attr,
        &io,
        null,
        0,
        w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
        w.FILE_OPEN,
        w.FILE_DIRECTORY_FILE | w.FILE_SYNCHRONOUS_IO_NONALERT | w.FILE_OPEN_FOR_BACKUP_INTENT,
        null,
        0,
    );

    switch (rc) {
        .SUCCESS => {
            if (tempdir_fd) |previous| previous.close();
            tempdir_fd = .fromNative(fd);
        },
        else => {},
    }
}

pub fn closeTempDirHandle(
    _: bun.bindgen.CallContext(CloseTempDirHandleSchema),
    _: bun.bindgen.Args(CloseTempDirHandleSchema),
) bun.JSError!void {
    if (comptime !Environment.isWindows) return;

    if (tempdir_fd) |fd| {
        tempdir_fd = null;
        fd.close();
    }
}
