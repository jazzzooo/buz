pub const Copyfile = constants.Copyfile;

pub const Arguments = struct {
    src: PathLike,
    dest: PathLike,
    flags: Flags,

    pub const Flags = struct {
        mode: constants.Copyfile,
        recursive: bool,
        errorOnExist: bool,
        force: bool,
        deinit_paths: bool = true,

        pub fn skipsExisting(this: Flags) bool {
            return !this.force and !this.errorOnExist;
        }
    };

    pub fn deinit(this: *const Arguments) void {
        if (this.flags.deinit_paths) {
            this.src.deinit();
            this.dest.deinit();
        }
    }

    pub fn toThreadSafe(this: *Arguments) bun.OOM!void {
        try this.src.toThreadSafe();
        try this.dest.toThreadSafe();
    }
};

pub const Copy = struct {
    // Returned errors borrow these buffers until the caller materializes them.
    sync_error_buf: *align(@alignOf(u16)) bun.PathBuffer,
    sync_message_buf: *[2048]u8,
    runtime_io: ?std.Io = null,

    pub fn io(this: *const Copy) std.Io {
        return this.runtime_io orelse bun.cli.Cli.io;
    }

    fn mkdirRecursive(this: *Copy, args: NodeFSCore.Mkdir) Maybe(NodeFSCore.MkdirResult) {
        return NodeFSCore.mkdirFromArgs(this.sync_error_buf, &args, void, {});
    }

    fn mkdirRecursiveOSPath(this: *Copy, path: bun.OSPathSliceZ, mode: Mode, comptime return_path: bool) Maybe(NodeFSCore.MkdirResult) {
        return NodeFSCore.mkdirRecursiveOSPath(this.sync_error_buf, void, {}, path, mode, return_path);
    }

    pub const copyFileUsingReadWriteLoop = NodeFSCore.copyFileUsingReadWriteLoop;

    pub fn cp(this: *Copy, args: Arguments) Maybe(void) {
        var src_buf: bun.OSPathBuffer = undefined;
        var dest_buf: bun.OSPathBuffer = undefined;

        if (this.cpValidate(args.src.slice(), args.dest.slice())) |err| {
            return .{ .err = err };
        }

        const src = args.src.osPathIntoBuf(&src_buf);
        const dest = args.dest.osPathIntoBuf(&dest_buf);

        return this.cpSyncInner(&src_buf, @intCast(src.len), &dest_buf, @intCast(dest.len), args);
    }

    pub fn osPathIntoSyncErrorBuf(this: *Copy, slice: anytype) []const u8 {
        if (Environment.isWindows) {
            return bun.strings.fromWPath(this.sync_error_buf, slice);
        } else {
            @memcpy(this.sync_error_buf[0..slice.len], slice);
            return this.sync_error_buf[0..slice.len];
        }
    }

    pub fn osPathIntoSyncErrorBufOverlap(this: *Copy, slice: anytype) []const u8 {
        if (Environment.isWindows) {
            const tmp = bun.os_path_buffer_pool.get();
            defer bun.os_path_buffer_pool.put(tmp);
            @memcpy(tmp[0..slice.len], slice);
            return bun.strings.fromWPath(this.sync_error_buf, tmp[0..slice.len]);
        }
    }

    /// A copy Node refuses to perform, rejected on inspection rather than by a
    /// failing syscall. `EINVAL` covers three of these, so rejection sites name
    /// the reason and not the code.
    pub const CpReason = enum {
        identical,
        into_subdirectory_of_self,
        symlink_into_subdirectory_of_self,
        dir_to_non_dir,
        non_dir_to_dir,
        not_recursive,
        exists,
        fifo,
        socket,
        unknown_file_type,

        fn code(this: CpReason) NodeErrorCode {
            return switch (this) {
                .identical, .into_subdirectory_of_self => .ERR_FS_CP_EINVAL,
                .symlink_into_subdirectory_of_self => .ERR_FS_CP_SYMLINK_TO_SUBDIRECTORY,
                .dir_to_non_dir => .ERR_FS_CP_DIR_TO_NON_DIR,
                .non_dir_to_dir => .ERR_FS_CP_NON_DIR_TO_DIR,
                .not_recursive => .ERR_FS_EISDIR,
                .exists => .ERR_FS_CP_EEXIST,
                .fifo => .ERR_FS_CP_FIFO_PIPE,
                .socket => .ERR_FS_CP_SOCKET,
                .unknown_file_type => .ERR_FS_CP_UNKNOWN,
            };
        }

        fn errno(this: CpReason) E {
            return switch (this) {
                .not_recursive => .ISDIR,
                .exists => .EXIST,
                else => .INVAL,
            };
        }

        /// Which of the two paths Node puts on the error.
        fn reportsDest(this: CpReason) bool {
            return this == .exists;
        }
    };

    /// Wording is Node's verbatim; tests match on it.
    ///
    /// True when `dest` is `src` or sits underneath it. Compared component by
    /// component, so `/a/bc` does not count as being under `/a/b`.
    fn isPathUnder(src: []const u8, dest: []const u8) bool {
        var src_components = std.mem.tokenizeScalar(u8, src, std.fs.path.sep);
        var dest_components = std.mem.tokenizeScalar(u8, dest, std.fs.path.sep);
        while (src_components.next()) |src_component| {
            const dest_component = dest_components.next() orelse return false;
            if (!bun.strings.eql(src_component, dest_component)) return false;
        }
        return true;
    }

    fn isSameFile(a: bun.Stat, b: bun.Stat) bool {
        return a.ino == b.ino and a.dev == b.dev;
    }

    /// Resolves a directory through symlinks by asking the OS for the opened
    /// directory's own path.
    fn cpResolveDir(path: [:0]const u8, buf: *bun.PathBuffer) ?[]const u8 {
        const fd = switch (Syscall.open(path, bun.O.DIRECTORY | bun.O.RDONLY, 0)) {
            .result => |fd| fd,
            .err => return null,
        };
        defer fd.close();
        return bun.getFdPath(fd, buf) catch null;
    }

    /// Whether copying `src` into `dest` would nest the copy inside its own
    /// source once every symlink on both paths is resolved.
    fn cpNestsInsideSelf(src_abs: [:0]const u8, dest_abs: [:0]const u8) bool {
        const src_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(src_buf);
        const dest_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(dest_buf);

        const src_real = cpResolveDir(src_abs, src_buf) orelse return false;

        // `dest` need not exist yet, so resolve its parent and re-attach the
        // final component.
        const dest_dir = std.fs.path.dirname(dest_abs) orelse return false;
        const dest_name = std.fs.path.basename(dest_abs);
        const parent_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(parent_buf);
        @memcpy(parent_buf[0..dest_dir.len], dest_dir);
        parent_buf[dest_dir.len] = 0;

        const dest_dir_real = cpResolveDir(parent_buf[0..dest_dir.len :0], dest_buf) orelse return false;
        if (dest_dir_real.len + 1 + dest_name.len >= dest_buf.len) return false;
        dest_buf[dest_dir_real.len] = std.fs.path.sep;
        @memcpy(dest_buf[dest_dir_real.len + 1 ..][0..dest_name.len], dest_name);

        return isPathUnder(src_real, dest_buf[0 .. dest_dir_real.len + 1 + dest_name.len]);
    }

    /// Copies that Node rejects on inspection, before anything is written.
    /// Runs once per `cp` call, not once per entry.
    fn cpValidate(this: *Copy, src: []const u8, dest: []const u8) ?Syscall.Error {
        if (comptime Environment.isPosix) {
            inline for (.{ src, dest }) |path| {
                if (path.len >= @sizeOf(bun.OSPathBuffer))
                    return Syscall.Error.fromCode(.NAMETOOLONG, .copyfile).withPath(path);
            }
        }
        const src_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(src_buf);
        const dest_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(dest_buf);
        var cwd_buf: bun.PathBuffer = undefined;
        const cwd = bun.getcwd(&cwd_buf) catch return null;

        const src_abs = bun.path.joinAbsStringBufZChecked(cwd, src_buf, &.{src}, .auto) orelse
            return Syscall.Error.fromCode(.NAMETOOLONG, .copyfile).withPath(src);
        const dest_abs = bun.path.joinAbsStringBufZChecked(cwd, dest_buf, &.{dest}, .auto) orelse
            return Syscall.Error.fromCode(.NAMETOOLONG, .copyfile).withPath(dest);

        // A source that cannot be stat'd is left to the copy, which reports the
        // syscall's own error.
        const src_stat = switch (Syscall.lstat(src_abs)) {
            .result => |s| s,
            .err => return null,
        };
        const src_is_dir = bun.S.ISDIR(@intCast(src_stat.mode));

        switch (Syscall.lstat(dest_abs)) {
            .err => {},
            .result => |dest_stat| {
                const dest_is_dir = bun.S.ISDIR(@intCast(dest_stat.mode));
                if (isSameFile(src_stat, dest_stat)) {
                    return this.cpRejected(.identical, src_abs, dest_abs);
                }
                if (src_is_dir and !dest_is_dir) {
                    return this.cpRejected(.dir_to_non_dir, src_abs, dest_abs);
                }
                if (!src_is_dir and dest_is_dir) {
                    return this.cpRejected(.non_dir_to_dir, src_abs, dest_abs);
                }
            },
        }

        if (!src_is_dir) return null;

        // Resolving needs the destination's parent to exist; the lexical form
        // does not.
        if (isPathUnder(src_abs, dest_abs) or cpNestsInsideSelf(src_abs, dest_abs)) {
            return this.cpRejected(.into_subdirectory_of_self, src_abs, dest_abs);
        }

        return null;
    }

    fn cpUnsupportedReason(mode: u32) CpReason {
        if (bun.S.ISFIFO(mode)) return .fifo;
        if (bun.S.ISSOCK(mode)) return .socket;
        return .unknown_file_type;
    }

    /// Reports a path as UTF-8 whatever the platform's path encoding is.
    fn cpPathToUtf8(buf: *bun.PathBuffer, path: anytype) []const u8 {
        if (comptime std.meta.Elem(@TypeOf(path)) == u16) {
            return bun.strings.fromWPath(buf, path);
        }
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }

    /// `src_path` and `dest_path` may be OS paths or UTF-8.
    fn cpRejected(this: *Copy, reason: CpReason, src_path: anytype, dest_path: anytype) Syscall.Error {
        const scratch = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(scratch);

        // The path on the error outlives this call, so it takes the long-lived
        // buffer; the other only has to survive formatting.
        const src_buf, const dest_buf = if (reason.reportsDest())
            .{ scratch, this.sync_error_buf }
        else
            .{ this.sync_error_buf, scratch };

        const src = cpPathToUtf8(src_buf, src_path);
        const dest = cpPathToUtf8(dest_buf, dest_path);

        var writer = std.Io.Writer.fixed(this.sync_message_buf);
        // Truncation is acceptable: only the code is load-bearing.
        (switch (reason) {
            .identical => writer.print("src and dest cannot be the same {s}", .{dest}),
            .into_subdirectory_of_self => writer.print("cannot copy {s} to a subdirectory of self {s}", .{ src, dest }),
            .symlink_into_subdirectory_of_self => writer.print("cannot overwrite {s} with {s}", .{ dest, src }),
            .dir_to_non_dir => writer.print("cannot overwrite non-directory {s} with directory {s}", .{ dest, src }),
            .non_dir_to_dir => writer.print("cannot overwrite directory {s} with non-directory {s}", .{ dest, src }),
            .not_recursive => writer.print("Recursive option not enabled, cannot copy a directory: {s}", .{src}),
            .exists => writer.print("{s} already exists", .{dest}),
            .fifo => writer.print("cannot copy a FIFO pipe: {s}", .{src}),
            .socket => writer.print("cannot copy a socket file: {s}", .{src}),
            .unknown_file_type => writer.print("cannot copy an unknown file type: {s}", .{src}),
        }) catch {};

        return .{
            .errno = @backingInt(reason.errno()),
            .syscall = .copyfile,
            .path = if (reason.reportsDest()) dest else src,
            .node_code = reason.code(),
            .node_message = writer.buffered(),
        };
    }

    /// Appends `sep ++ rel` to the OS path held in `buf[0..base_len]`, encoding
    /// the walker's WTF-8 relative path as `bun.OSPathChar`. Returns null when
    /// the result would not fit, which callers report as ENAMETOOLONG.
    ///
    /// One UTF-16 code unit never takes fewer than one WTF-8 byte, so the byte
    /// length of `rel` bounds the converted length on Windows too.
    ///
    /// TODO: this caps nesting at whatever fits in `bun.OSPathBuffer`.
    /// `std.Io.Dir.Walker.Entry` carries the containing directory handle, so the
    /// copy could work from that and a basename instead, with no accumulated
    /// path and no limit. It needs `_copySingleFileSync` to become fd-relative:
    /// `clonefileat`/`fcopyfile` on macOS, `openat` on Linux, and `NtCreateFile`
    /// with a root handle on Windows.
    fn appendWalkPath(buf: *bun.OSPathBuffer, base_len: usize, rel: []const u8) ?[:0]const bun.OSPathChar {
        if (base_len + rel.len + 2 > buf.len) return null;
        buf[base_len] = std.fs.path.sep;
        if (Environment.isWindows) {
            const converted = bun.strings.toWPathWtf8(buf[base_len + 1 ..], rel) catch return null;
            return buf[0 .. base_len + 1 + converted.len :0];
        }
        @memcpy(buf[base_len + 1 ..][0..rel.len], rel);
        buf[base_len + 1 + rel.len] = 0;
        return buf[0 .. base_len + 1 + rel.len :0];
    }

    fn cpWalkError(this: *Copy, err: anyerror, path: []const bun.OSPathChar) Syscall.Error {
        return bun.sys.Error.fromStdIo(err, .copyfile).withPath(this.osPathIntoSyncErrorBuf(path));
    }

    fn cpNameTooLong(this: *Copy, path: []const bun.OSPathChar) Syscall.Error {
        return .{
            .errno = @backingInt(E.NAMETOOLONG),
            .syscall = .copyfile,
            .path = this.osPathIntoSyncErrorBuf(path),
        };
    }

    /// Creates `dest` for a directory that is about to be descended into.
    /// Returns true when `clonefile` copied the whole subtree already, in which
    /// case the caller must not descend.
    fn cpPrepareDirectory(this: *Copy, args: Arguments, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ) Maybe(bool) {
        if (comptime Environment.isMac) try_with_clonefile: {
            if (Maybe(void).errnoSysP(c.clonefile(src, dest, 0), .clonefile, src)) |err| {
                switch (err.getErrno()) {
                    .NAMETOOLONG, .ROFS, .INVAL, .ACCES, .PERM => |errno| {
                        if (errno == .ACCES or errno == .PERM) {
                            if (args.flags.force) {
                                break :try_with_clonefile;
                            }
                        }

                        @memcpy(this.sync_error_buf[0..src.len], src);
                        return .{ .err = err.err.withPath(this.sync_error_buf[0..src.len]) };
                    },

                    // Other errors may be due to clonefile() not being supported
                    // We'll fall back to other implementations
                    else => {},
                }
            } else {
                return .{ .result = true };
            }
        }

        // A copied directory keeps the source's permissions. Windows has no
        // mode to carry over.
        const mode: Mode = if (comptime Environment.isWindows) NodeFSCore.Mkdir.DefaultMode else switch (Syscall.stat(src)) {
            .result => |s| @intCast(s.mode & 0o777),
            .err => NodeFSCore.Mkdir.DefaultMode,
        };

        switch (this.mkdirRecursiveOSPath(dest, mode, false)) {
            .err => |err| return .{ .err = err },
            .result => {},
        }

        // mkdir's mode is masked by the umask, and the directory may already
        // exist.
        if (comptime !Environment.isWindows) {
            _ = Syscall.chmod(dest, mode);
        }
        return .{ .result = false };
    }

    /// Copies the contents of the directory `src_buf[0..src_root_len]` into
    /// `dest_buf[0..dest_root_len]`.
    ///
    /// Nesting is bounded by what fits in `bun.OSPathBuffer`, not by the stack,
    /// so traversal state lives on the heap in `std.Io.Dir.SelectiveWalker`.
    /// Opting in to each descent is what lets `clonefile` skip a subtree it has
    /// already copied wholesale.
    ///
    /// `visitor` decides what each entry means:
    ///   fn enterDirectory(self, src, dest) Maybe(bool)  // true = do not descend
    ///   fn copyFile(self, src, dest) Maybe(void)
    fn cpTree(
        this: *Copy,
        src_buf: *bun.OSPathBuffer,
        src_root_len: usize,
        dest_buf: *bun.OSPathBuffer,
        dest_root_len: usize,
        visitor: anytype,
    ) Maybe(void) {
        switch (visitor.enterDirectory(src_buf[0..src_root_len :0], dest_buf[0..dest_root_len :0])) {
            .err => |err| return .{ .err = err },
            .result => |cloned| if (cloned) return .success,
        }

        const fd = switch (Syscall.openatOSPath(
            .cwd(),
            src_buf[0..src_root_len :0],
            bun.O.DIRECTORY | bun.O.RDONLY,
            0,
        )) {
            .err => |err| return .{ .err = err.withPath(this.osPathIntoSyncErrorBuf(src_buf[0..src_root_len])) },
            .result => |fd_| fd_,
        };
        defer fd.close();

        var walker = fd.stdDir().walkSelectively(bun.default_allocator) catch |err| bun.handleOom(err);
        defer walker.deinit(this.io());

        while (walker.next(this.io()) catch |err| {
            return .{ .err = this.cpWalkError(err, src_buf[0..src_root_len]) };
        }) |entry| {
            const src = appendWalkPath(src_buf, src_root_len, entry.path) orelse
                return .{ .err = this.cpNameTooLong(src_buf[0..src_root_len]) };
            const dest = appendWalkPath(dest_buf, dest_root_len, entry.path) orelse
                return .{ .err = this.cpNameTooLong(src_buf[0..src_root_len]) };

            if (entry.kind == .directory) {
                switch (visitor.enterDirectory(src, dest)) {
                    .err => |err| return .{ .err = err },
                    .result => |cloned| if (cloned) continue,
                }
                walker.enter(this.io(), entry) catch |err| {
                    return .{ .err = this.cpWalkError(err, src) };
                };
            } else {
                switch (visitor.copyFile(src, dest)) {
                    .err => |err| return .{ .err = err },
                    .result => {},
                }
            }
        }

        return .success;
    }

    const SyncCpVisitor = struct {
        nodefs: *Copy,
        args: Arguments,

        fn enterDirectory(this: SyncCpVisitor, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ) Maybe(bool) {
            return this.nodefs.cpPrepareDirectory(this.args, src, dest);
        }

        fn copyFile(this: SyncCpVisitor, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ) Maybe(void) {
            const cp_flags = this.args.flags;
            const r = this.nodefs._copySingleFileSync(
                src,
                dest,
                @fromBackingInt(@intCast((if (cp_flags.errorOnExist or !cp_flags.force) constants.COPYFILE_EXCL else @as(u8, 0)))),
                null,
                this.args,
            );
            switch (r) {
                .err => |err| {
                    if (err.errno == @backingInt(E.EXIST) and cp_flags.skipsExisting()) {
                        return .success;
                    }
                    return .{ .err = err };
                },
                .result => return .success,
            }
        }
    };

    fn cpSyncInner(
        this: *Copy,
        src_buf: *bun.OSPathBuffer,
        src_dir_len: PathString.PathInt,
        dest_buf: *bun.OSPathBuffer,
        dest_dir_len: PathString.PathInt,
        args: Arguments,
    ) Maybe(void) {
        const cp_flags = args.flags;
        const src = src_buf[0..src_dir_len :0];
        const dest = dest_buf[0..dest_dir_len :0];

        if (Environment.isWindows) {
            const attributes = c.GetFileAttributesW(src);
            if (attributes == c.INVALID_FILE_ATTRIBUTES) {
                return .{ .err = .{
                    .errno = @backingInt(SystemErrno.ENOENT),
                    .syscall = .copyfile,
                    .path = this.osPathIntoSyncErrorBuf(src),
                } };
            }

            if ((attributes & c.FILE_ATTRIBUTE_DIRECTORY) == 0) {
                const r = this._copySingleFileSync(
                    src,
                    dest,
                    @fromBackingInt(@intCast(if (cp_flags.errorOnExist or !cp_flags.force) constants.COPYFILE_EXCL else @as(u8, 0))),
                    attributes,
                    args,
                );
                if (r == .err and r.err.errno == @backingInt(E.EXIST) and cp_flags.skipsExisting()) {
                    return .success;
                }
                return r;
            }
        } else {
            const stat_ = switch (Syscall.lstat(src)) {
                .result => |result| result,
                .err => |err| {
                    @memcpy(this.sync_error_buf[0..src.len], src);
                    return .{ .err = err.withPath(this.sync_error_buf[0..src.len]) };
                },
            };

            if (!posix.S.ISDIR(@intCast(stat_.mode))) {
                const r = this._copySingleFileSync(
                    src,
                    dest,
                    @fromBackingInt(@intCast((if (cp_flags.errorOnExist or !cp_flags.force) constants.COPYFILE_EXCL else @as(u8, 0)))),
                    stat_,
                    args,
                );
                if (r == .err and r.err.errno == @backingInt(E.EXIST) and cp_flags.skipsExisting()) {
                    return .success;
                }
                return r;
            }
        }

        if (!cp_flags.recursive) {
            return .{ .err = this.cpRejected(.not_recursive, src, dest) };
        }

        return this.cpTree(src_buf, src_dir_len, dest_buf, dest_dir_len, SyncCpVisitor{
            .nodefs = this,
            .args = args,
        });
    }

    /// On Windows, copying a file onto itself will return EBUSY, which is an
    /// unintuitive and cryptic error to return to the user for an operation
    /// that should seemingly be a no-op.
    ///
    /// So we check if the source and destination are the same file, and if they
    /// are, we return success.
    ///
    /// This is copied directly from libuv's implementation of `uv_fs_copyfile`
    /// for Windows:
    ///
    /// https://github.com/libuv/libuv/blob/497f3168d13ea9a92ad18c28e8282777ec2acf73/src/win/fs.c#L2069
    ///
    /// **This function does nothing on non-Windows platforms**.
    pub fn shouldIgnoreEbusy(src: PathLike, dest: PathLike, result: Maybe(void)) Maybe(void) {
        if (comptime !Environment.isWindows) return result;
        if (result != .err or result.err.getErrno() != .BUSY) return result;

        var buf: bun.PathBuffer = undefined;
        const statbuf = switch (Syscall.stat(src.sliceZ(&buf))) {
            .result => |b| b,
            .err => return result,
        };
        const new_statbuf = switch (Syscall.stat(dest.sliceZ(&buf))) {
            .result => |b| b,
            .err => return result,
        };

        if (statbuf.dev == new_statbuf.dev and statbuf.ino == new_statbuf.ino) {
            return .success;
        }

        return result;
    }

    /// Recreate the symlink at `src` as a symlink at `dest`.
    ///
    /// Used by `_copySingleFileSync` when `open(src, O_NOFOLLOW)` fails with
    /// ELOOP/EMLINK. The previous implementation called `symlink(src, dest)`,
    /// which created a link whose *target string* was the path of the source
    /// symlink instead of the target that the source symlink pointed at, so
    /// every copied link pointed back into the source tree.
    ///
    /// The native fast path only runs when `verbatimSymlinks` is not set (the
    /// JS fallback handles that option), so we match Node's default here:
    /// `readlink(src)`, then resolve a relative target against `dirname(src)`.
    fn _cpSymlink(this: *Copy, src: [:0]const u8, dest: [:0]const u8) Maybe(void) {
        var target_buf: bun.PathBuffer = undefined;
        const link_target = switch (Syscall.readlink(src, &target_buf)) {
            .result => |result| result,
            .err => |err| {
                @memcpy(this.sync_error_buf[0..src.len], src);
                return .{ .err = err.withPath(this.sync_error_buf[0..src.len]) };
            },
        };

        const resolved_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(resolved_buf);
        const resolved_src = cpResolveLinkTarget(src, link_target, resolved_buf) orelse {
            @memcpy(this.sync_error_buf[0..src.len], src);
            return .{ .err = .{
                .errno = @backingInt(E.NAMETOOLONG),
                .syscall = .symlink,
                .path = this.sync_error_buf[0..src.len],
            } };
        };

        // Anything at the destination that is not a link is left alone, so that
        // `symlink` below fails with EEXIST rather than discarding a file.
        const dest_target_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(dest_target_buf);
        switch (Syscall.readlink(dest, dest_target_buf)) {
            .err => {},
            .result => |dest_target| {
                if (this.cpSymlinkOverLink(resolved_src, dest, dest_target)) |err| return .{ .err = err };
                _ = Syscall.unlink(dest);
            },
        }

        return Syscall.symlink(resolved_src, dest);
    }

    /// Resolves a symlink's target the way Node does when `verbatimSymlinks` is
    /// not set: absolute targets stand, relative ones resolve against the
    /// directory holding the link. Returns null when the result does not fit,
    /// which callers report as ENAMETOOLONG.
    fn cpResolveLinkTarget(link_path: []const u8, target: []const u8, buf: *bun.PathBuffer) ?[:0]const u8 {
        if (std.fs.path.isAbsolute(target)) {
            if (target.len >= buf.len) return null;
            @memcpy(buf[0..target.len], target);
            buf[target.len] = 0;
            return buf[0..target.len :0];
        }

        var cwd_buf: bun.PathBuffer = undefined;
        const cwd = bun.getcwd(&cwd_buf) catch return null;
        const link_dir = std.fs.path.dirnamePosix(link_path) orelse "";
        // `target` can approach PATH_MAX on its own, so prepending `link_dir`
        // may not fit.
        const resolved = bun.path.joinAbsStringBufChecked(
            cwd,
            buf[0 .. buf.len - 1],
            &.{ link_dir, target },
            .posix,
        ) orelse return null;
        buf[resolved.len] = 0;
        return buf[0..resolved.len :0];
    }

    /// Whether replacing the existing link at `dest`, which points at
    /// `dest_target`, with one pointing at `resolved_src` would put either tree
    /// inside the other.
    fn cpSymlinkOverLink(this: *Copy, resolved_src: [:0]const u8, dest: [:0]const u8, dest_target: []const u8) ?Syscall.Error {
        // Only a link that resolves to a directory can nest a tree.
        switch (Syscall.stat(resolved_src)) {
            .result => |s| if (!bun.S.ISDIR(@intCast(s.mode))) return null,
            .err => return null,
        }

        const resolved_buf = bun.path_buffer_pool.get();
        defer bun.path_buffer_pool.put(resolved_buf);
        const resolved_dest = cpResolveLinkTarget(dest, dest_target, resolved_buf) orelse return null;

        if (isPathUnder(resolved_src, resolved_dest)) {
            return this.cpRejected(.into_subdirectory_of_self, resolved_src, resolved_dest);
        }

        const dest_is_dir = switch (Syscall.stat(dest)) {
            .result => |s| bun.S.ISDIR(@intCast(s.mode)),
            .err => false,
        };
        if (dest_is_dir and isPathUnder(resolved_dest, resolved_src)) {
            return this.cpRejected(.symlink_into_subdirectory_of_self, resolved_src, resolved_dest);
        }

        return null;
    }

    /// Opens the destination of a single-file copy, created with the source's
    /// permissions so the file is never briefly readable. A missing parent
    /// directory is created, which `cp` promises and `copyFile` does not.
    ///
    /// `O_EXCL` is set by the caller exactly when it must not clobber, so an
    /// EEXIST here always means the caller asked to be told.
    fn openCopyDest(this: *Copy, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ, flags: i32, mode: Mode) Maybe(FD) {
        switch (Syscall.open(dest, flags, mode)) {
            .result => |fd| return .{ .result = fd },
            .err => |err| {
                if (err.getErrno() == .EXIST) {
                    return .{ .err = this.cpRejected(.exists, src, dest) };
                }

                if (err.getErrno() == .ISDIR) {
                    return .{ .err = this.cpRejected(.non_dir_to_dir, src, dest) };
                }

                if (err.getErrno() == .NOENT) {
                    var len = dest.len;
                    while (len > 0 and dest[len - 1] != std.fs.path.sep) {
                        len -= 1;
                    }
                    const mkdir_result = this.mkdirRecursive(.{
                        .path = PathLike{ .string = PathString.init(dest[0..len]) },
                        .recursive = true,
                    });
                    if (mkdir_result == .err) {
                        return .{ .err = mkdir_result.err };
                    }

                    if (Syscall.open(dest, flags, mode).asValue()) |fd| {
                        return .{ .result = fd };
                    }
                }

                @memcpy(this.sync_error_buf[0..dest.len], dest);
                return .{ .err = err.withPath(this.sync_error_buf[0..dest.len]) };
            },
        }
    }

    /// This is `copyFile`, but it copies symlinks as-is
    pub fn _copySingleFileSync(
        this: *Copy,
        src: bun.OSPathSliceZ,
        dest: bun.OSPathSliceZ,
        mode: constants.Copyfile,
        /// Stat on posix, file attributes on windows
        reuse_stat: ?if (Environment.isWindows) windows.DWORD else bun.Stat,
        args: Arguments,
    ) Maybe(void) {
        const ret = Maybe(void);

        // TODO: do we need to fchown?
        if (Environment.isMac) {
            if (mode.isForceClone()) {
                // https://www.manpagez.com/man/2/clonefile/
                return ret.errnoSysP(c.clonefile(src, dest, 0), .clonefile, src) orelse ret.success;
            } else {
                const stat_ = reuse_stat orelse switch (Syscall.lstat(src)) {
                    .result => |result| result,
                    .err => |err| {
                        @memcpy(this.sync_error_buf[0..src.len], src);
                        return .{ .err = err.withPath(this.sync_error_buf[0..src.len]) };
                    },
                };

                if (!posix.S.ISREG(@intCast(stat_.mode))) {
                    if (posix.S.ISLNK(@intCast(stat_.mode))) {
                        var mode_: u32 = c.COPYFILE_ACL | c.COPYFILE_DATA | c.COPYFILE_NOFOLLOW_SRC;
                        if (mode.shouldntOverwrite()) {
                            mode_ |= c.COPYFILE_EXCL;
                        }

                        return ret.errnoSysP(c.copyfile(src, dest, null, mode_), .copyfile, src) orelse ret.success;
                    }
                    return .{ .err = this.cpRejected(cpUnsupportedReason(@intCast(stat_.mode)), src, dest) };
                }

                // 64 KB is about the break-even point for clonefile() to be worth it
                // at least, on an M1 with an NVME SSD.
                if (stat_.size > 128 * 1024) {
                    if (!mode.shouldntOverwrite()) {
                        // clonefile() will fail if it already exists
                        _ = Syscall.unlink(dest);
                    }

                    if (ret.errnoSysP(c.clonefile(src, dest, 0), .clonefile, src) == null) {
                        _ = Syscall.chmod(dest, @intCast(stat_.mode));
                        return ret.success;
                    }
                } else {
                    const src_fd = switch (Syscall.open(src, bun.O.RDONLY, 0o644)) {
                        .result => |result| result,
                        .err => |err| {
                            @memcpy(this.sync_error_buf[0..src.len], src);
                            return .{ .err = err.withPath(this.sync_error_buf[0..src.len]) };
                        },
                    };
                    defer {
                        src_fd.close();
                    }

                    var flags: i32 = bun.O.CREAT | bun.O.WRONLY;
                    var wrote: usize = 0;
                    if (mode.shouldntOverwrite()) {
                        flags |= bun.O.EXCL;
                    }

                    const dest_fd = switch (this.openCopyDest(src, dest, flags, @intCast(stat_.mode & 0o777))) {
                        .result => |fd| fd,
                        .err => |err| return .{ .err = err },
                    };
                    defer {
                        _ = Syscall.ftruncate(dest_fd, @intCast(@as(u63, @truncate(wrote))));
                        _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                        dest_fd.close();
                    }

                    return copyFileUsingReadWriteLoop(src, dest, src_fd, dest_fd, @intCast(@max(stat_.size, 0)), &wrote);
                }
            }

            // we fallback to copyfile() when the file is > 128 KB and clonefile fails
            // clonefile() isn't supported on all devices
            // nor is it supported across devices
            var mode_: u32 = c.COPYFILE_ACL | c.COPYFILE_DATA | c.COPYFILE_NOFOLLOW_SRC;
            if (mode.shouldntOverwrite()) {
                mode_ |= c.COPYFILE_EXCL;
            }

            const first_try = ret.errnoSysP(c.copyfile(src, dest, null, mode_), .copyfile, src) orelse return ret.success;
            if (first_try == .err and first_try.err.errno == @backingInt(Syscall.E.NOENT)) {
                const mkdir_result = this.mkdirRecursive(.{
                    .path = PathLike{ .string = PathString.init(std.fs.path.dirname(dest) orelse "") },
                    .recursive = true,
                });
                if (mkdir_result == .err) return .{ .err = mkdir_result.err };
                return ret.errnoSysP(c.copyfile(src, dest, null, mode_), .copyfile, src) orelse ret.success;
            }
            return first_try;
        }

        if (Environment.isLinux) {
            // https://manpages.debian.org/testing/manpages-dev/ioctl_ficlone.2.en.html
            if (mode.isForceClone()) {
                return Maybe(void).todo();
            }

            // O_NONBLOCK so that opening a FIFO returns instead of waiting for a
            // writer that will never arrive; the file type is rejected below.
            const src_fd = switch (Syscall.open(src, bun.O.RDONLY | bun.O.NOFOLLOW | bun.O.NONBLOCK, 0o644)) {
                .result => |result| result,
                .err => |err| {
                    switch (err.getErrno()) {
                        // ELOOP is returned when you open a symlink with NOFOLLOW.
                        // as in, it does not actually let you open it.
                        .LOOP => return this._cpSymlink(src, dest),
                        // Sockets and some device nodes cannot be opened at all.
                        // Report what the file is rather than how opening it failed.
                        .NXIO, .NODEV => switch (Syscall.lstat(src)) {
                            .result => |stat_| return .{
                                .err = this.cpRejected(cpUnsupportedReason(@intCast(stat_.mode)), src, dest),
                            },
                            .err => {},
                        },
                        else => {},
                    }

                    return .{ .err = err };
                },
            };
            defer {
                src_fd.close();
            }

            const stat_: bun.Stat = switch (Syscall.fstat(src_fd)) {
                .result => |result| result,
                .err => |err| return Maybe(void){ .err = err.withFd(src_fd) },
            };

            if (!posix.S.ISREG(@intCast(stat_.mode))) {
                return .{ .err = this.cpRejected(cpUnsupportedReason(@intCast(stat_.mode)), src, dest) };
            }

            var flags: i32 = bun.O.CREAT | bun.O.WRONLY;
            var wrote: usize = 0;
            if (mode.shouldntOverwrite()) {
                flags |= bun.O.EXCL;
            }

            const dest_fd = switch (this.openCopyDest(src, dest, flags, @intCast(stat_.mode & 0o777))) {
                .result => |fd| fd,
                .err => |err| return .{ .err = err },
            };

            const size: usize = @intCast(@max(stat_.size, 0));

            if (posix.S.ISREG(@intCast(stat_.mode)) and bun.can_use_ioctl_ficlone()) {
                const rc = bun.linux.ioctl_ficlone(dest_fd, src_fd);
                if (rc == 0) {
                    _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                    dest_fd.close();
                    return ret.success;
                }

                bun.disable_ioctl_ficlone();
            }

            defer {
                _ = Syscall.ftruncate(dest_fd, @as(i64, @intCast(@as(u63, @truncate(wrote)))));
                _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                dest_fd.close();
            }

            return NodeFSCore.copyFileDataOnLinux(src, dest, src_fd, dest_fd, size, &wrote);
        }

        if (Environment.isFreeBSD) {
            if (mode.isForceClone()) {
                return Maybe(void){ .err = .{ .errno = @backingInt(SystemErrno.EOPNOTSUPP), .syscall = .copyfile } };
            }

            const src_fd = switch (Syscall.open(src, bun.O.RDONLY | bun.O.NOFOLLOW, 0o644)) {
                .result => |result| result,
                .err => |err| {
                    // O_NOFOLLOW on a symlink → recreate the link. FreeBSD's
                    // open(2) returns EMLINK for this case, though POSIX
                    // specifies ELOOP; accept either.
                    if (err.getErrno() == .MLINK or err.getErrno() == .LOOP) {
                        return this._cpSymlink(src, dest);
                    }
                    return .{ .err = err };
                },
            };
            defer src_fd.close();

            const stat_: bun.Stat = switch (Syscall.fstat(src_fd)) {
                .result => |result| result,
                .err => |err| return Maybe(void){ .err = err.withFd(src_fd) },
            };
            if (!posix.S.ISREG(@intCast(stat_.mode))) {
                return Maybe(void){ .err = .{ .errno = @backingInt(SystemErrno.EOPNOTSUPP), .syscall = .copyfile } };
            }

            var flags: i32 = bun.O.CREAT | bun.O.WRONLY;
            var wrote: u64 = 0;
            if (mode.shouldntOverwrite()) {
                flags |= bun.O.EXCL;
            }

            const dest_fd = switch (this.openCopyDest(src, dest, flags, @intCast(stat_.mode & 0o777))) {
                .result => |fd| fd,
                .err => |err| return .{ .err = err },
            };

            // No O_TRUNC at open: if src and dest resolve to the same inode,
            // that would zero the file before the first read.
            if (Syscall.fstat(dest_fd).asValue()) |dst_stat| {
                if (stat_.ino == dst_stat.ino and stat_.dev == dst_stat.dev) {
                    dest_fd.close();
                    @memcpy(this.sync_error_buf[0..src.len], src);
                    return Maybe(void){ .err = .{ .errno = @backingInt(SystemErrno.EINVAL), .syscall = .copyfile, .path = this.sync_error_buf[0..src.len] } };
                }
            }

            defer {
                _ = Syscall.ftruncate(dest_fd, @as(i64, @intCast(@as(u63, @truncate(wrote)))));
                _ = Syscall.fchmod(dest_fd, @intCast(stat_.mode));
                dest_fd.close();
            }

            const size: usize = @intCast(@max(stat_.size, 0));

            // FreeBSD 13+ has copy_file_range(2). std.c declares it returning
            // usize on FreeBSD, so bitcast to isize before getErrno (see
            // freebsd_errno.getErrno).
            var off_in: i64 = 0;
            var off_out: i64 = 0;
            cfr: while (true) {
                const rc: isize = @bitCast(std.c.copy_file_range(src_fd.native(), &off_in, dest_fd.native(), &off_out, if (size == 0) std.math.maxInt(i32) - 1 else size -| wrote, 0));
                switch (bun.sys.getErrno(rc)) {
                    .SUCCESS => {
                        if (rc == 0) return ret.success;
                        wrote +|= @intCast(rc);
                        if (size != 0 and wrote >= size) return ret.success;
                    },
                    .INTR => continue,
                    .XDEV, .INVAL, .OPNOTSUPP, .NOSYS, .BADF => break :cfr,
                    else => |e| {
                        @memcpy(this.sync_error_buf[0..dest.len], dest);
                        return Maybe(void){ .err = .{ .errno = @backingInt(e), .syscall = .copyfile, .path = this.sync_error_buf[0..dest.len] } };
                    },
                }
            }

            return copyFileUsingReadWriteLoop(src, dest, src_fd, dest_fd, size, &wrote);
        }

        if (Environment.isWindows) {
            const src_enoent_maybe = ret.initErrWithP(.ENOENT, .copyfile, this.osPathIntoSyncErrorBuf(src));
            const dst_enoent_maybe = ret.initErrWithP(.ENOENT, .copyfile, this.osPathIntoSyncErrorBuf(dest));
            const stat_ = reuse_stat orelse switch (c.GetFileAttributesW(src)) {
                c.INVALID_FILE_ATTRIBUTES => return ret.errnoSysP(0, .copyfile, this.osPathIntoSyncErrorBuf(src)).?,
                else => |result| result,
            };
            if (stat_ & c.FILE_ATTRIBUTE_REPARSE_POINT == 0) {
                if (c.CopyFileW(src, dest, @intFromBool(mode.shouldntOverwrite())) == 0) {
                    var err = windows.GetLastError();
                    var errpath: bun.OSPathSliceZ = undefined;
                    switch (err) {
                        .FILE_EXISTS, .ALREADY_EXISTS => errpath = dest,
                        .PATH_NOT_FOUND => {
                            const parent = parent: {
                                var it = std.fs.path.ComponentIterator(.windows, u16).init(dest);
                                _ = it.last() orelse break :parent null;
                                const up = it.previous() orelse break :parent it.root();
                                break :parent up.path;
                            };
                            if (parent) |dir| bun.makePathW(std.Io.Dir.cwd(), this.io(), dir) catch {};
                            const second_try = windows.CopyFileW(src, dest, windows.BOOL.fromBool(mode.shouldntOverwrite()));
                            if (second_try.toBool()) return ret.success;
                            err = windows.GetLastError();
                            errpath = dest;
                            if (err == .FILE_EXISTS or err == .ALREADY_EXISTS) errpath = src;
                        },
                        else => errpath = src,
                    }
                    const result = ret.errnoSysP(0, .copyfile, this.osPathIntoSyncErrorBuf(dest)) orelse src_enoent_maybe;
                    return shouldIgnoreEbusy(args.src, args.dest, result);
                }
                return ret.success;
            } else {
                const handle = switch (bun.sys.openatWindows(bun.invalid_fd, src, bun.O.RDONLY, 0)) {
                    .err => |err| return .{ .err = err },
                    .result => |src_fd| src_fd,
                };
                defer handle.close();
                const wbuf = bun.os_path_buffer_pool.get();
                defer bun.os_path_buffer_pool.put(wbuf);
                const len = bun.windows.GetFinalPathNameByHandleW(handle.cast(), wbuf, wbuf.len, 0);
                if (len == 0 or len >= wbuf.len) {
                    return ret.errnoSysP(0, .copyfile, this.osPathIntoSyncErrorBuf(dest)) orelse dst_enoent_maybe;
                }
                const flags = if (stat_ & windows.FILE_ATTRIBUTE_DIRECTORY != 0)
                    std.os.windows.SYMBOLIC_LINK_FLAG_DIRECTORY
                else
                    0;
                if (!windows.CreateSymbolicLinkW(dest, wbuf[0..len :0], flags).toBool()) {
                    return ret.errnoSysP(0, .copyfile, this.osPathIntoSyncErrorBuf(dest)) orelse dst_enoent_maybe;
                }
                return ret.success;
            }
        }

        return ret.todo();
    }
};

pub fn AsyncTask(comptime Hooks: type) type {
    return struct {
        hooks: Hooks,
        args: Arguments,
        background_tasks: *bun.BackgroundTaskGroup,
        io: ?std.Io,
        root_file_mode: ?constants.Copyfile,
        task: bun.BackgroundTaskGroup.Task = .{ .callback = &workPoolCallback, .on_cancel = &cancelWork },
        result: Maybe(void),
        out_of_memory: bool = false,
        has_result: std.atomic.Value(bool),
        subtask_count: std.atomic.Value(usize),

        const Self = @This();

        pub const SingleTask = struct {
            parent: *Self,
            src: bun.OSPathSliceZ,
            dest: bun.OSPathSliceZ,
            task: bun.BackgroundTaskGroup.Task = .{ .callback = &Single.workPoolCallback, .on_cancel = &Single.cancelWork },

            const Single = @This();

            fn create(parent: *Self, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ) bun.OOM!void {
                const task = try bun.default_allocator.create(Single);
                task.* = .{
                    .parent = parent,
                    .src = src,
                    .dest = dest,
                };
                bun.assert(parent.subtask_count.fetchAdd(1, .monotonic) > 0);
                bun.BackgroundWork.scheduleContinuation(parent.background_tasks, &task.task);
            }

            fn workPoolCallback(task: *bun.BackgroundTaskGroup.Task) void {
                const this: *Single = @fieldParentPtr("task", task);
                const parent = this.parent;
                const args = parent.args;
                var error_buf: bun.PathBuffer align(@alignOf(u16)) = undefined;
                var message_buf: [2048]u8 = undefined;
                var copy: Copy = .{
                    .sync_error_buf = &error_buf,
                    .sync_message_buf = &message_buf,
                    .runtime_io = parent.io,
                };
                const result = copy._copySingleFileSync(
                    this.src,
                    this.dest,
                    copyMode(args.flags),
                    null,
                    args,
                );

                switch (result) {
                    .err => |err| {
                        if (!(err.errno == @backingInt(E.EXIST) and args.flags.skipsExisting())) {
                            parent.finishConcurrently(result);
                        }
                    },
                    .result => parent.hooks.onCopy(this.src, this.dest),
                }

                this.deinit();
                parent.onSubtaskDone();
            }

            fn cancelWork(task: *bun.BackgroundTaskGroup.Task) void {
                const this: *Single = @fieldParentPtr("task", task);
                const parent = this.parent;
                parent.finishConcurrently(.{ .err = bun.sys.Error.fromCode(.AGAIN, .copyfile) });
                this.deinit();
                parent.onSubtaskDone();
            }

            fn deinit(this: *Single) void {
                bun.default_allocator.free(this.src.ptr[0 .. this.src.len + this.dest.len + 2]);
                bun.destroy(this);
            }
        };

        pub fn init(
            args: Arguments,
            background_tasks: *bun.BackgroundTaskGroup,
            io: ?std.Io,
            root_file_mode: ?constants.Copyfile,
            hooks: Hooks,
        ) bun.OOM!*Self {
            var owned_args = args;
            errdefer owned_args.deinit();
            try owned_args.toThreadSafe();
            const self = try bun.default_allocator.create(Self);
            self.* = .{
                .hooks = hooks,
                .args = owned_args,
                .background_tasks = background_tasks,
                .io = io,
                .root_file_mode = root_file_mode,
                .has_result = .{ .raw = false },
                .result = undefined,
                .subtask_count = .{ .raw = 1 },
            };
            return self;
        }

        pub fn schedule(self: *Self) void {
            bun.BackgroundWork.schedule(self.background_tasks, &self.task) catch {
                self.finishConcurrently(.{ .err = bun.sys.Error.fromCode(.AGAIN, .copyfile) });
                self.onSubtaskDone();
            };
        }

        fn workPoolCallback(task: *bun.BackgroundTaskGroup.Task) void {
            const self: *Self = @alignCast(@fieldParentPtr("task", task));
            self.run();
        }

        fn cancelWork(task: *bun.BackgroundTaskGroup.Task) void {
            const self: *Self = @alignCast(@fieldParentPtr("task", task));
            if (self.hooks.cancel()) {
                self.cancelAndComplete();
            } else {
                self.destroyUnfinished();
            }
        }

        pub fn cancelAndComplete(this: *Self) void {
            this.finishConcurrently(.{ .err = bun.sys.Error.fromCode(.AGAIN, .copyfile) });
            this.onSubtaskDone();
        }

        pub fn destroyUnfinished(this: *Self) void {
            this.args.deinit();
            bun.destroy(this);
        }

        pub fn deinit(this: *Self) void {
            if (this.result == .err) this.result.err.deinit();
            this.args.deinit();
            bun.destroy(this);
        }

        fn copyMode(flags: Arguments.Flags) constants.Copyfile {
            return @fromBackingInt(@intCast(if (flags.errorOnExist or !flags.force) constants.COPYFILE_EXCL else @as(u8, 0)));
        }

        fn finishConcurrently(this: *Self, result: Maybe(void)) void {
            if (this.has_result.cmpxchgStrong(false, true, .monotonic, .monotonic)) |_| return;
            this.result = result;
            if (this.result == .err) {
                this.result.err = this.result.err.cloneFallible(bun.default_allocator) catch {
                    this.out_of_memory = true;
                    this.result = .{ .err = bun.sys.Error.fromCode(.NOMEM, .copyfile) };
                    return;
                };
            }
        }

        fn finishOutOfMemory(this: *Self) Maybe(void) {
            const result: Maybe(void) = .{ .err = bun.sys.Error.fromCode(.NOMEM, .copyfile) };
            if (this.has_result.cmpxchgStrong(false, true, .monotonic, .monotonic) == null) {
                this.out_of_memory = true;
                this.result = result;
            }
            return result;
        }

        fn onSubtaskDone(this: *Self) void {
            const old_count = this.subtask_count.fetchSub(1, .acq_rel);
            bun.assert(old_count > 0);
            if (old_count != 1) return;

            if (!this.has_result.load(.monotonic)) {
                this.has_result.store(true, .monotonic);
                this.result = .success;
            }
            this.hooks.finish(this);
        }

        fn run(this: *Self) void {
            defer this.onSubtaskDone();

            const args = this.args;
            var error_buf: bun.PathBuffer align(@alignOf(u16)) = undefined;
            var message_buf: [2048]u8 = undefined;
            var copy: Copy = .{
                .sync_error_buf = &error_buf,
                .sync_message_buf = &message_buf,
                .runtime_io = this.io,
            };
            if (copy.cpValidate(args.src.slice(), args.dest.slice())) |err| {
                this.finishConcurrently(.{ .err = err });
                return;
            }

            var src_buf: bun.OSPathBuffer = undefined;
            var dest_buf: bun.OSPathBuffer = undefined;
            const src = args.src.osPathIntoBuf(&src_buf);
            const dest = args.dest.osPathIntoBuf(&dest_buf);

            if (Environment.isWindows) {
                const attributes = c.GetFileAttributesW(src);
                if (attributes == c.INVALID_FILE_ATTRIBUTES) {
                    this.finishConcurrently(.{ .err = .{
                        .errno = @backingInt(SystemErrno.ENOENT),
                        .syscall = .copyfile,
                        .path = copy.osPathIntoSyncErrorBuf(src),
                    } });
                    return;
                }
                const file_or_symlink = (attributes & c.FILE_ATTRIBUTE_DIRECTORY) == 0 or
                    (attributes & c.FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                if (file_or_symlink) {
                    const result = copy._copySingleFileSync(
                        src,
                        dest,
                        this.root_file_mode orelse copyMode(args.flags),
                        attributes,
                        args,
                    );
                    if (result == .err and result.err.errno == @backingInt(E.EXIST) and args.flags.skipsExisting()) {
                        this.finishConcurrently(.success);
                        return;
                    }
                    this.hooks.onCopy(src, dest);
                    this.finishConcurrently(result);
                    return;
                }
            } else {
                const stat = switch (Syscall.lstat(src)) {
                    .result => |value| value,
                    .err => |err| {
                        this.finishConcurrently(.{ .err = err.withPath(copy.osPathIntoSyncErrorBuf(src)) });
                        return;
                    },
                };

                if (!bun.S.ISDIR(@intCast(stat.mode))) {
                    const result = copy._copySingleFileSync(src, dest, copyMode(args.flags), stat, args);
                    if (result == .err and result.err.errno == @backingInt(E.EXIST) and args.flags.skipsExisting()) {
                        this.hooks.onCopy(src, dest);
                        this.finishConcurrently(.success);
                        return;
                    }
                    this.hooks.onCopy(src, dest);
                    this.finishConcurrently(result);
                    return;
                }
            }

            if (!args.flags.recursive) {
                this.finishConcurrently(.{ .err = copy.cpRejected(.not_recursive, src, dest) });
                return;
            }

            switch (copy.cpTree(&src_buf, src.len, &dest_buf, dest.len, AsyncCpVisitor{
                .copy = &copy,
                .task = this,
            })) {
                .result => {},
                .err => |err| this.finishConcurrently(.{ .err = err }),
            }
        }

        const AsyncCpVisitor = struct {
            copy: *Copy,
            task: *Self,

            fn enterDirectory(this: AsyncCpVisitor, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ) Maybe(bool) {
                var normalized_buffer: bun.OSPathBuffer = undefined;
                const normalized_dest: bun.OSPathSliceZ = if (Environment.isWindows)
                    switch (bun.sys.normalizePathWindows(u16, bun.invalid_fd, dest, &normalized_buffer, .{ .add_nt_prefix = false })) {
                        .err => |err| return .{ .err = err },
                        .result => |value| value,
                    }
                else
                    dest;

                return switch (this.copy.cpPrepareDirectory(this.task.args, src, normalized_dest)) {
                    .err => |err| .{ .err = err },
                    .result => |cloned| result: {
                        if (!cloned) this.task.hooks.onCopy(src, normalized_dest);
                        break :result .{ .result = cloned };
                    },
                };
            }

            fn copyFile(this: AsyncCpVisitor, src: bun.OSPathSliceZ, dest: bun.OSPathSliceZ) Maybe(void) {
                const path_length = std.math.add(usize, src.len, dest.len) catch return this.task.finishOutOfMemory();
                const allocation_length = std.math.add(usize, path_length, 2) catch return this.task.finishOutOfMemory();
                const paths = bun.default_allocator.alloc(bun.OSPathChar, allocation_length) catch return this.task.finishOutOfMemory();
                @memcpy(paths[0..src.len], src);
                paths[src.len] = 0;
                @memcpy(paths[src.len + 1 ..][0..dest.len], dest);
                paths[src.len + 1 + dest.len] = 0;
                SingleTask.create(
                    this.task,
                    paths[0..src.len :0],
                    paths[src.len + 1 ..][0..dest.len :0],
                ) catch {
                    bun.default_allocator.free(paths);
                    return this.task.finishOutOfMemory();
                };
                return .success;
            }
        };
    };
}

const constants = @import("./node_fs_constant.zig");
const NodeErrorCode = @import("./nodejs_error_code.zig").Code;
const NodeFSCore = @import("./NodeFSCore.zig");
const NodeTypes = @import("./types.zig");

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const Mode = bun.Mode;
const PathLike = NodeTypes.PathLike;
const PathString = bun.PathString;
const Syscall = if (Environment.isWindows) bun.sys.sys_uv else bun.sys;
const Maybe = bun.sys.Maybe;
const E = bun.sys.E;
const SystemErrno = bun.sys.SystemErrno;
const c = bun.c;
const windows = bun.windows;

const std = @import("std");
const posix = std.posix;
