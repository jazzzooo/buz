const debug = Output.scoped(.TCC, .visible);

/// Get the last dynamic library loading error message in a cross-platform way.
/// On POSIX systems, this calls dlerror().
/// On Windows, this uses GetLastError() and formats the error message.
/// Returns an allocated string that must be freed by the caller.
fn getDlError(allocator: std.mem.Allocator) ![]const u8 {
    if (Environment.isWindows) {
        // On Windows, we need to use GetLastError() and FormatMessageW()
        const err = bun.windows.GetLastError();
        const err_int = @backingInt(err);

        // For now, just return the error code as we'd need to implement FormatMessageW in Zig
        // This is still better than a generic message
        return try std.fmt.allocPrint(allocator, "error code {d}", .{err_int});
    } else {
        // On POSIX systems, use dlerror() to get the actual system error
        const msg = if (std.c.dlerror()) |err_ptr|
            std.mem.span(err_ptr)
        else
            "unknown error";
        // Return a copy since dlerror() string is not stable
        return try allocator.dupe(u8, msg);
    }
}

pub const FFI = struct {
    const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
    pub const ref = RefCount.ref;
    pub const deref = RefCount.deref;

    pub const JSBinding = struct {
        bindgen_state: bun.bindgen.ClassState = .{},
        ffi: bun.bindgen.RefNative(FFI, .vm),

        pub const destroy = @This().deinit;

        fn deinit(this: *JSBinding) void {
            this.ffi.deinit();
            bun.destroy(this);
        }

        pub fn memoryUsage(this: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.vm)) usize {
            return @sizeOf(JSBinding) + this.ffi.get().estimatedSize();
        }

        pub fn bindClose(
            this: *JSBinding,
            _: bun.bindgen.CallContext(FFICloseSchema),
            _: bun.bindgen.Args(FFICloseSchema),
        ) bun.JSError!void {
            this.ffi.get().close();
        }

        pub fn bindGetSymbols(
            _: *JSBinding,
            _: bun.bindgen.CallContext(FFISymbolsSchema),
            _: bun.bindgen.Args(FFISymbolsSchema),
        ) bun.JSError!bun.bindgen.Return(FFISymbolsSchema) {
            unreachable;
        }
    };

    ref_count: RefCount = .init(),
    allocator: Allocator,
    dylib: ?DynLib = null,
    functions: bun.StringArrayHashMap(Function) = .empty,
    closed: bool = false,
    active_calls: usize = 0,
    environment: ?FFIEnvironment = null,
    shared_state: ?*TCC.State = null,

    pub fn toResult(this: *FFI, context: anytype) bun.JSError!FFIRef {
        const binding = bun.default_allocator.create(JSBinding) catch {
            this.deref();
            return error.OutOfMemory;
        };
        binding.* = .{ .ffi = .adopt(this) };
        var reference = try FFIClass.adoptResult(binding, context);
        errdefer reference.deinit();

        const Symbol = struct { name: bun.bindgen.DOMString, index: usize };
        var symbols: std.ArrayListUnmanaged(Symbol) = .empty;
        defer {
            for (symbols.items) |*symbol| {
                symbol.name.deinit();
            }
            symbols.deinit(bun.default_allocator);
        }
        try symbols.ensureTotalCapacity(bun.default_allocator, this.functions.count());
        for (this.functions.values(), 0..) |*function, index| {
            symbols.appendAssumeCapacity(.{
                .name = try bun.bindgen.DOMString.fromUTF8(function.base_name.?),
                .index = index,
            });
        }

        const operation = context.engineIn("FFI", "ffiLibraryInstallSymbols");
        const OperationArgs = @TypeOf(operation).Args;
        const ContextSymbol = @typeInfo(@FieldType(OperationArgs, "symbols")).pointer.child;
        var context_symbols: std.ArrayListUnmanaged(ContextSymbol) = .empty;
        defer context_symbols.deinit(bun.default_allocator);
        try context_symbols.ensureTotalCapacity(bun.default_allocator, symbols.items.len);
        for (symbols.items) |*symbol| {
            context_symbols.appendAssumeCapacity(.{
                .name = symbol.name.operand(),
                .index = symbol.index,
            });
        }

        try operation.call(.{
            .library = reference.operand(context),
            .symbols = context_symbols.items,
        });
        return reference;
    }

    fn estimatedSize(this: *const FFI) usize {
        _ = this;
        return @sizeOf(FFI);
    }

    fn prepare(this: *FFI, context: anytype) bun.JSError!void {
        for (this.functions.values()) |*function| {
            if (function.needsNapiEnv() and this.environment == null)
                this.environment = try context.engineIn("FFI", "createEnvironment").call(.{});
            function.native_data = try context.engineIn("FFI", "prepareFunction").call(.{
                .symbol = function.symbol_from_dynamic_library orelse unreachable,
                .argumentTypes = function.arg_types.items,
                .returnType = function.return_type,
            });
        }
    }

    pub fn copyFilePath(context: anytype, input: anytype) bun.bindgen.CallError(@TypeOf(context))![:0]const u8 {
        const allocator = bun.default_allocator;
        const result = switch (input) {
            .path => |path| copied: {
                const bytes = try allocator.allocSentinel(u8, path.length(), 0);
                if (!path.read(0, bytes)) unreachable;
                break :copied bytes;
            },
            .blob => |blob| copied: {
                const store = blob.get().storePtr() orelse return context.fail(.expected_file_blob, {});
                if (store.data != .file or store.data.file.pathlike != .path)
                    return context.fail(.expected_file_blob, {});
                break :copied try allocator.dupeSentinel(u8, store.data.file.pathlike.path.slice(), 0);
            },
        };
        errdefer allocator.free(result);
        if (result.len == 0) return context.fail(.empty_file_path, {});
        if (std.mem.indexOfScalar(u8, result, 0) != null) return context.fail(.invalid_file_path, {});
        return result;
    }

    const CompileC = struct {
        source: Source = .{ .file = "" },
        current_file_for_errors: [:0]const u8 = "",

        libraries: StringArray = .{},
        library_dirs: StringArray = .{},
        include_dirs: StringArray = .{},
        symbols: SymbolsMap = .{},
        define: std.ArrayListUnmanaged([2][:0]const u8) = .empty,
        // Flags to replace the default flags
        flags: [:0]const u8 = "",
        deferred_errors: std.ArrayListUnmanaged([]const u8) = .empty,
        diagnostic_oom: bool = false,

        const Source = union(enum) {
            file: [:0]const u8,
            files: std.ArrayListUnmanaged([:0]const u8),

            pub fn fromBinding(context: anytype, input: anytype) bun.bindgen.CallError(@TypeOf(context))!Source {
                switch (input) {
                    .single => |path| return .{ .file = try FFI.copyFilePath(context, path) },
                    .files => |files| {
                        if (files.len() == 0) return context.fail(.empty_sources, {});
                        var result: Source = .{ .files = .empty };
                        errdefer result.deinit(bun.default_allocator);
                        try result.files.ensureTotalCapacity(bun.default_allocator, files.len());
                        for (0..files.len()) |index|
                            result.files.appendAssumeCapacity(try FFI.copyFilePath(context, files.at(index).?));
                        return result;
                    },
                }
            }

            pub fn first(this: *const Source) [:0]const u8 {
                return switch (this.*) {
                    .file => this.file,
                    .files => this.files.items[0],
                };
            }

            pub fn deinit(this: *Source, allocator: Allocator) void {
                switch (this.*) {
                    .file => if (this.file.len > 0) allocator.free(this.file),
                    .files => {
                        for (this.files.items) |file| {
                            allocator.free(file);
                        }
                        this.files.deinit(allocator);
                    },
                }

                this.* = .{ .file = "" };
            }

            pub fn add(this: *Source, state: *TCC.State, current_file_for_errors: *[:0]const u8) !void {
                switch (this.*) {
                    .file => {
                        current_file_for_errors.* = this.file;
                        state.addFile(this.file) catch return error.CompilationError;
                        current_file_for_errors.* = "";
                    },
                    .files => {
                        for (this.files.items) |file| {
                            current_file_for_errors.* = file;
                            state.addFile(file) catch return error.CompilationError;
                            current_file_for_errors.* = "";
                        }
                    },
                }
            }
        };

        const stdarg = struct {
            const stdio = @import("tcc-stdio");

            const mac = if (Environment.isMac) struct {
                pub fn inject(state: *TCC.State) TCC.Error!void {
                    try state.addSymbolsComptime(.{
                        .__stdinp = &stdio.__stdinp,
                        .__stdoutp = &stdio.__stdoutp,
                        .__stderrp = &stdio.__stderrp,
                    });
                }
            } else struct {
                pub fn inject(_: *TCC.State) TCC.Error!void {}
            };

            pub fn inject(state: *TCC.State) TCC.Error!void {
                try state.addSymbolsComptime(.{
                    // printf family
                    .vfprintf = stdio.bun_tcc_vfprintf,
                    .vprintf = stdio.bun_tcc_vprintf,
                    .fprintf = stdio.bun_tcc_fprintf,
                    .printf = stdio.bun_tcc_printf,
                    .fscanf = stdio.fscanf,
                    .scanf = stdio.scanf,
                    .sscanf = stdio.sscanf,
                    .vsscanf = stdio.vsscanf,
                    // files
                    .fopen = stdio.fopen,
                    .fclose = stdio.fclose,
                    .fgetc = stdio.fgetc,
                    .fputc = stdio.fputc,
                    .feof = stdio.feof,
                    .fileno = if (Environment.isWindows) stdio._fileno else stdio.fileno,
                    .fwrite = std.c.fwrite,
                    .ungetc = stdio.ungetc,
                    .ftell = stdio.ftell,
                    .fseek = stdio.fseek,
                    .fflush = stdio.fflush,
                    .fread = std.c.fread,
                    // memory
                    .malloc = std.c.malloc,
                    .realloc = std.c.realloc,
                    .calloc = stdio.calloc,
                    .free = std.c.free,
                    // error
                    .perror = stdio.perror,
                });

                if (Environment.isPosix) {
                    try state.addSymbolsComptime(.{
                        .posix_memalign = std.c.posix_memalign,
                        .dlopen = std.c.dlopen,
                        .dlclose = std.c.dlclose,
                        .dlsym = std.c.dlsym,
                        .dlerror = std.c.dlerror,
                    });
                }

                try mac.inject(state);
            }
        };

        pub fn handleCompilationError(this_: ?*CompileC, message: [*:0]const u8) callconv(.c) void {
            const this = this_ orelse return;
            this.addDiagnostic(std.mem.span(message));
        }

        fn addDiagnostic(this: *CompileC, message: []const u8) void {
            if (message.len == 0 or this.diagnostic_oom) return;
            const copy = bun.default_allocator.dupe(u8, message) catch {
                this.diagnostic_oom = true;
                return;
            };
            this.deferred_errors.append(bun.default_allocator, copy) catch {
                bun.default_allocator.free(copy);
                this.diagnostic_oom = true;
            };
        }

        const DeferredError = error{ DeferredErrors, OutOfMemory };

        inline fn hasDeferredErrors(this: *CompileC) bool {
            return this.diagnostic_oom or this.deferred_errors.items.len > 0;
        }

        /// Returns DeferredError if any errors from tinycc were registered
        /// via `handleCompilationError`
        inline fn errorCheck(this: *CompileC) DeferredError!void {
            if (this.diagnostic_oom) return error.OutOfMemory;
            if (this.deferred_errors.items.len > 0) {
                return error.DeferredErrors;
            }
        }

        pub const default_tcc_options: [:0]const u8 = "-std=c11 -Wl,--export-all-symbols -g -O2";

        var cached_default_system_include_dir: [:0]const u8 = "";
        var cached_default_system_library_dir: [:0]const u8 = "";
        var cached_default_system_include_dir_once = bun.once(getSystemRootDirOnce);
        fn getSystemRootDirOnce() void {
            if (Environment.isMac) {
                var which_buf: [bun.MAX_PATH_BYTES]u8 = undefined;

                var process = bun.spawnSync(&.{
                    .stdout = .buffer,
                    .stdin = .ignore,
                    .stderr = .ignore,
                    .argv = &.{
                        bun.which(&which_buf, std.mem.sliceTo(std.c.getenv("PATH") orelse "", 0), Fs.FileSystem.instance.top_level_dir, "xcrun") orelse "/usr/bin/xcrun",
                        "-sdk",
                        "macosx",
                        "-show-sdk-path",
                    },
                    // ?[*:null]?[*:0]const u8
                    //  [*:null]?[*:0]u8
                    .envp = @ptrCast(std.c.environ),
                }) catch return;
                if (process == .result) {
                    defer process.result.deinit();
                    if (process.result.isOK()) {
                        const stdout = process.result.stdout.items;
                        if (stdout.len > 0) {
                            cached_default_system_include_dir = bun.default_allocator.dupeSentinel(u8, strings.trim(stdout, "\n\r"), 0) catch return;
                        }
                    }
                }
            } else if (Environment.isLinux) {
                // On Debian/Ubuntu, the lib and include paths are suffixed with {arch}-linux-gnu
                // e.g. x86_64-linux-gnu or aarch64-linux-gnu
                // On Alpine and RHEL-based distros, the paths are not suffixed

                if (Environment.isX64) {
                    if (bun.FD.cwd().directoryExistsAt("/usr/include/x86_64-linux-gnu").isTrue()) {
                        cached_default_system_include_dir = "/usr/include/x86_64-linux-gnu";
                    } else if (bun.FD.cwd().directoryExistsAt("/usr/include").isTrue()) {
                        cached_default_system_include_dir = "/usr/include";
                    }

                    if (bun.FD.cwd().directoryExistsAt("/usr/lib/x86_64-linux-gnu").isTrue()) {
                        cached_default_system_library_dir = "/usr/lib/x86_64-linux-gnu";
                    } else if (bun.FD.cwd().directoryExistsAt("/usr/lib64").isTrue()) {
                        cached_default_system_library_dir = "/usr/lib64";
                    }
                } else if (Environment.isAarch64) {
                    if (bun.FD.cwd().directoryExistsAt("/usr/include/aarch64-linux-gnu").isTrue()) {
                        cached_default_system_include_dir = "/usr/include/aarch64-linux-gnu";
                    } else if (bun.FD.cwd().directoryExistsAt("/usr/include").isTrue()) {
                        cached_default_system_include_dir = "/usr/include";
                    }

                    if (bun.FD.cwd().directoryExistsAt("/usr/lib/aarch64-linux-gnu").isTrue()) {
                        cached_default_system_library_dir = "/usr/lib/aarch64-linux-gnu";
                    } else if (bun.FD.cwd().directoryExistsAt("/usr/lib64").isTrue()) {
                        cached_default_system_library_dir = "/usr/lib64";
                    }
                }
            }
        }

        fn getSystemIncludeDir(io: std.Io) ?[:0]const u8 {
            cached_default_system_include_dir_once.call(io, .{});
            if (cached_default_system_include_dir.len == 0) return null;
            return cached_default_system_include_dir;
        }

        fn getSystemLibraryDir(io: std.Io) ?[:0]const u8 {
            cached_default_system_include_dir_once.call(io, .{});
            if (cached_default_system_library_dir.len == 0) return null;
            return cached_default_system_library_dir;
        }

        pub fn compile(this: *CompileC, context: anytype, io: std.Io) (bun.bindgen.CallError(@TypeOf(context)) || DeferredError)!*TCC.State {
            const compile_options: [:0]const u8 = if (this.flags.len > 0)
                this.flags
            else if (bun.env_var.BUN_TCC_OPTIONS.get()) |tcc_options|
                @ptrCast(tcc_options)
            else
                default_tcc_options;

            const state = TCC.State.init(CompileC, .{
                .options = compile_options,
                .err = .{ .ctx = this, .handler = &handleCompilationError },
            }, true) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC could not initialize the compiler options");
                    try this.errorCheck();
                    return error.DeferredErrors;
                },
            };
            errdefer state.deinit();

            var pathbuf: [bun.MAX_PATH_BYTES]u8 = undefined;

            if (CompilerRT.dir(io)) |compiler_rt_dir| {
                state.addSysIncludePath(compiler_rt_dir) catch {
                    debug("TinyCC failed to add sysinclude path", .{});
                };
            }

            if (Environment.isMac) {
                add_system_include_dir: {
                    const dirs_to_try = [_][]const u8{
                        bun.env_var.SDKROOT.get() orelse "",
                        getSystemIncludeDir(io) orelse "",
                    };

                    for (dirs_to_try) |sdkroot| {
                        if (sdkroot.len > 0) {
                            const include_dir = bun.path.joinAbsStringBufZ(sdkroot, &pathbuf, &.{ "usr", "include" }, .auto);
                            state.addSysIncludePath(include_dir) catch return failMessage(context, .compile_failed, "TinyCC failed to add sysinclude path", .{});

                            const lib_dir = bun.path.joinAbsStringBufZ(sdkroot, &pathbuf, &.{ "usr", "lib" }, .auto);
                            state.addLibraryPath(lib_dir) catch return failMessage(context, .compile_failed, "TinyCC failed to add library path", .{});

                            break :add_system_include_dir;
                        }
                    }
                }

                if (Environment.isAarch64) {
                    if (bun.FD.cwd().directoryExistsAt("/opt/homebrew/include").isTrue()) {
                        state.addSysIncludePath("/opt/homebrew/include") catch {
                            debug("TinyCC failed to add library path", .{});
                        };
                    }

                    if (bun.FD.cwd().directoryExistsAt("/opt/homebrew/lib").isTrue()) {
                        state.addLibraryPath("/opt/homebrew/lib") catch {
                            debug("TinyCC failed to add library path", .{});
                        };
                    }
                }
            } else if (Environment.isLinux) {
                if (getSystemIncludeDir(io)) |include_dir| {
                    state.addSysIncludePath(include_dir) catch {
                        debug("TinyCC failed to add sysinclude path", .{});
                    };
                }

                if (getSystemLibraryDir(io)) |library_dir| {
                    state.addLibraryPath(library_dir) catch {
                        debug("TinyCC failed to add library path", .{});
                    };
                }
            }

            if (Environment.isPosix) {
                if (bun.FD.cwd().directoryExistsAt("/usr/local/include").isTrue()) {
                    state.addSysIncludePath("/usr/local/include") catch {
                        debug("TinyCC failed to add sysinclude path", .{});
                    };
                }

                if (bun.FD.cwd().directoryExistsAt("/usr/local/lib").isTrue()) {
                    state.addLibraryPath("/usr/local/lib") catch {
                        debug("TinyCC failed to add library path", .{});
                    };
                }

                // Check standard C compiler environment variables for include paths.
                // These are used by systems like NixOS where standard FHS paths don't exist.
                if (bun.env_var.C_INCLUDE_PATH.get()) |c_include_path| {
                    var include_iter = std.mem.splitScalar(u8, c_include_path, ':');
                    while (include_iter.next()) |path| {
                        if (path.len > 0) {
                            const path_z = try bun.default_allocator.dupeSentinel(u8, path, 0);
                            defer bun.default_allocator.free(path_z);
                            state.addSysIncludePath(path_z) catch {
                                debug("TinyCC failed to add C_INCLUDE_PATH: {s}", .{path});
                            };
                        }
                    }
                }

                // Check standard C compiler environment variable for library paths.
                if (bun.env_var.LIBRARY_PATH.get()) |library_path| {
                    var library_iter = std.mem.splitScalar(u8, library_path, ':');
                    while (library_iter.next()) |path| {
                        if (path.len > 0) {
                            const path_z = try bun.default_allocator.dupeSentinel(u8, path, 0);
                            defer bun.default_allocator.free(path_z);
                            state.addLibraryPath(path_z) catch {
                                debug("TinyCC failed to add LIBRARY_PATH: {s}", .{path});
                            };
                        }
                    }
                }
            }

            try this.errorCheck();

            for (this.include_dirs.items) |include_dir| {
                state.addSysIncludePath(include_dir) catch {
                    if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC could not add an include directory");
                    try this.errorCheck();
                    return error.DeferredErrors;
                };
            }

            try this.errorCheck();

            CompilerRT.define(state) catch {
                if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC could not compile its runtime support");
                try this.errorCheck();
                return error.DeferredErrors;
            };

            try this.errorCheck();

            for (this.define.items) |define| {
                state.defineSymbol(define[0], define[1]);
                try this.errorCheck();
            }

            this.source.add(state, &this.current_file_for_errors) catch {
                if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC failed to compile the source");
                try this.errorCheck();
                return error.DeferredErrors;
            };

            CompilerRT.inject(state) catch {
                if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC could not install its memory functions");
                try this.errorCheck();
                return error.DeferredErrors;
            };
            stdarg.inject(state) catch {
                if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC could not install its C library functions");
                try this.errorCheck();
                return error.DeferredErrors;
            };

            try this.errorCheck();

            for (this.library_dirs.items) |library_dir| {
                // register all, even if some fail. Only fail after all have been registered.
                state.addLibraryPath(library_dir) catch {
                    debug("TinyCC failed to add library path", .{});
                };
            }
            try this.errorCheck();

            for (this.libraries.items) |library| {
                // register all, even if some fail.
                state.addLibrary(library) catch {};
            }
            try this.errorCheck();

            state.relocate() catch {
                if (!this.hasDeferredErrors()) this.addDiagnostic("TinyCC could not relocate the compiled code");
                try this.errorCheck();
                return error.DeferredErrors;
            };

            try this.errorCheck();

            for (this.symbols.map.values()) |*function| {
                const name = function.base_name.?;
                function.symbol_from_dynamic_library = @ptrCast(state.getSymbol(name) orelse {
                    return failMessage(context, .symbol_not_found, "{f} is missing from {s}. Was it included in the source code?", .{ bun.fmt.quote(name), this.source.first() });
                });
            }

            try this.errorCheck();
            state.clearErrorFunc();
            return state;
        }

        pub fn deinit(this: *CompileC) void {
            this.symbols.deinit();

            this.libraries.deinit();
            this.library_dirs.deinit();
            this.include_dirs.deinit();

            for (this.deferred_errors.items) |deferred_error| {
                bun.default_allocator.free(deferred_error);
            }
            this.deferred_errors.clearAndFree(bun.default_allocator);

            for (this.define.items) |define| {
                bun.default_allocator.free(define[0]);
                if (define[1].len > 0) bun.default_allocator.free(define[1]);
            }
            this.define.clearAndFree(bun.default_allocator);

            this.source.deinit(bun.default_allocator);
            if (this.flags.len > 0) bun.default_allocator.free(this.flags);
            this.flags = "";
        }
    };
    const SymbolsMap = struct {
        map: bun.StringArrayHashMap(Function) = .empty,
        pub fn deinit(this: *SymbolsMap) void {
            for (this.map.values()) |*function| function.deinit();
            this.map.clearAndFree(bun.default_allocator);
        }
    };

    const StringArray = struct {
        items: []const [:0]const u8 = &.{},
        pub fn deinit(this: *StringArray) void {
            for (this.items) |item| {
                // Attempting to free an empty null-terminated slice will crash if it was a default value
                bun.debugAssert(item.len > 0);

                bun.default_allocator.free(@constCast(item));
            }

            if (this.items.len > 0)
                bun.default_allocator.free(this.items);
        }

        fn append(context: anytype, items: *std.ArrayListUnmanaged([:0]const u8), value: anytype) bun.bindgen.CallError(@TypeOf(context))!void {
            if (value.length() == 0) return;
            const text = try value.toOwnedSliceZ(bun.default_allocator);
            errdefer bun.default_allocator.free(text);
            if (std.mem.indexOfScalar(u8, text, 0) != null) return context.fail(.invalid_compile_string, {});
            try items.append(bun.default_allocator, text);
        }

        pub fn fromBinding(context: anytype, value: anytype) bun.bindgen.CallError(@TypeOf(context))!StringArray {
            var items: std.ArrayListUnmanaged([:0]const u8) = .empty;
            errdefer {
                for (items.items) |item| bun.default_allocator.free(item);
                items.deinit(bun.default_allocator);
            }
            switch (value.*) {
                .string => |*string_value| try append(context, &items, string_value),
                .strings => |*string_values| {
                    try items.ensureTotalCapacity(bun.default_allocator, string_values.len());
                    for (0..string_values.len()) |index| {
                        const item = string_values.at(index).?;
                        try append(context, &items, &item);
                    }
                },
            }
            return .{ .items = try items.toOwnedSlice(bun.default_allocator) };
        }
    };

    pub fn compile(
        io: std.Io,
        context: bun.bindgen.CallContext(CompileSchema),
        args: bun.bindgen.Args(CompileSchema),
    ) bun.bindgen.CallError(CompileSchema)!bun.bindgen.Return(CompileSchema) {
        if (comptime !Environment.enable_tinycc) {
            return context.fail(.compile_disabled, {});
        }
        const compile_options = args.options orelse return context.fail(.expected_object, {});
        const converted_options = try compile_options.convert(context);
        const compile_options_value = switch (converted_options.value) {
            .options => |*options_value| options_value,
            .invalid => return context.fail(.expected_object, {}),
        };
        const allocator = bun.default_allocator;

        var compile_c = CompileC{};
        defer compile_c.deinit();
        compile_c.symbols.map = try parseSymbols(context, allocator, &compile_options_value.symbols);
        if (compile_c.symbols.map.count() == 0) return context.fail(.no_symbols, {});

        if (compile_options_value.library) |*library| {
            compile_c.libraries = try StringArray.fromBinding(context, library);
        }

        if (compile_options_value.flags) |*flags_input| {
            const is_array = flags_input.* == .strings;
            var values = try StringArray.fromBinding(context, flags_input);
            defer values.deinit();
            if (values.items.len > 0 or is_array) {
                var flags: std.ArrayListUnmanaged(u8) = .empty;
                defer flags.deinit(allocator);
                if (is_array) {
                    try flags.appendSlice(allocator, CompileC.default_tcc_options);
                }
                for (values.items) |value| {
                    if (value.len == 0) continue;
                    if (flags.items.len > 0) {
                        try flags.append(allocator, ' ');
                    }
                    try flags.appendSlice(allocator, value);
                }
                compile_c.flags = try flags.toOwnedSliceSentinel(allocator, 0);
            }
        }

        if (compile_options_value.define) |*define_input| switch (define_input.*) {
            .values => |*definitions| {
                for (0..definitions.len()) |index| {
                    const entry = definitions.at(index).?;
                    const key_utf8 = try entry.key.toUTF8(allocator);
                    defer key_utf8.deinit();
                    if (key_utf8.length() == 0) continue;
                    if (std.mem.indexOfScalar(u8, key_utf8.slice(), 0) != null) return context.fail(.invalid_compile_string, {});
                    const key = try allocator.dupeSentinel(u8, key_utf8.slice(), 0);
                    errdefer allocator.free(key);
                    var owned_value: [:0]const u8 = "";
                    errdefer if (owned_value.len > 0) allocator.free(owned_value);
                    switch (entry.value) {
                        .string => |*string_value| {
                            const value_utf8 = try string_value.toUTF8(allocator);
                            defer value_utf8.deinit();
                            if (std.mem.indexOfScalar(u8, value_utf8.slice(), 0) != null) return context.fail(.invalid_compile_string, {});
                            if (value_utf8.length() > 0) {
                                owned_value = try allocator.dupeSentinel(u8, value_utf8.slice(), 0);
                            }
                        },
                        .ignored => {},
                    }
                    try compile_c.define.append(allocator, .{ key, owned_value });
                }
            },
            .ignored => {},
        };

        if (compile_options_value.include) |*include| {
            compile_c.include_dirs = try StringArray.fromBinding(context, include);
        }

        compile_c.source = try CompileC.Source.fromBinding(context, compile_options_value.source);

        var tcc_state: ?*TCC.State = compile_c.compile(context, io) catch |err| {
            switch (err) {
                error.DeferredErrors => {
                    var combined = std.Io.Writer.Allocating.init(bun.default_allocator);
                    defer combined.deinit();
                    const writer = &combined.writer;
                    writer.print("{d} errors while compiling {s}\n", .{ compile_c.deferred_errors.items.len, if (compile_c.current_file_for_errors.len > 0) compile_c.current_file_for_errors else compile_c.source.first() }) catch return error.OutOfMemory;

                    for (compile_c.deferred_errors.items) |deferred_error| {
                        writer.print("{s}\n", .{deferred_error}) catch return error.OutOfMemory;
                    }

                    return context.fail(.compile_failed, try bun.bindgen.DOMString.fromUTF8(combined.written()));
                },
                else => |failure| return failure,
            }
        };
        defer {
            if (tcc_state) |state| state.deinit();
        }

        const lib = try bun.default_allocator.create(FFI);
        lib.* = .{
            .allocator = allocator,
            .dylib = null,
            .shared_state = tcc_state,
            .functions = compile_c.symbols.map,
        };
        tcc_state = null;
        compile_c.symbols = .{};
        lib.prepare(context) catch |err| {
            lib.deref();
            return err;
        };
        return try lib.toResult(context);
    }

    pub fn callback(
        context: bun.bindgen.CallContext(CallbackSchema),
        args: bun.bindgen.Args(CallbackSchema),
    ) bun.bindgen.CallError(CallbackSchema)!bun.bindgen.Return(CallbackSchema) {
        const allocator = bun.default_allocator;
        var function = try parseSignature(context, allocator, &args.definition, .callback);
        defer function.deinit();
        const callable = try args.factory.call(.{
            .callback = args.callback.operand(context),
            .returnType = function.return_type,
        });

        const resource = try allocator.create(FFICallbackContext);
        resource.* = .{};
        var reference = try FFICallbackContextClass.adoptResult(resource, context);
        errdefer reference.deinit();
        CallbackSlot.setCallbackViewOnOwned(&reference, @TypeOf(callable).SemanticType, callable);
        resource.endpoint = try context.engineIn("FFI", "createCallback").call(.{
            .argumentTypes = function.arg_types.items,
            .returnType = function.return_type,
            .threadsafe = function.threadsafe,
        });
        return .{
            .ptr = bun.bindgen.Engine(CallbackPointerSchema).call(.{ .endpoint = resource.endpoint.?.get() }),
            .threadsafe = function.threadsafe,
            .resource = reference,
        };
    }

    pub fn close(this: *FFI) void {
        if (this.closed) return;
        this.closed = true;
        if (this.active_calls == 0) this.closeResources();
    }

    fn closeResources(this: *FFI) void {
        bun.debugAssert(this.active_calls == 0);
        if (this.environment) |environment| {
            this.environment = null;
            var owned = environment;
            owned.deinit();
        }
        if (this.dylib) |*dylib| {
            dylib.close();
            this.dylib = null;
        }

        if (this.shared_state) |state| {
            this.shared_state = null;
            state.deinit();
        }
    }

    fn deinit(this: *FFI) void {
        bun.debugAssert(this.active_calls == 0);
        this.close();
        for (this.functions.values()) |*function| function.deinit();
        this.functions.deinit(this.allocator);
        bun.destroy(this);
    }

    pub fn printCallback(context: anytype, definition: anytype) bun.bindgen.CallError(@TypeOf(context))![]u8 {
        const allocator = bun.default_allocator;

        var function = try parseSignature(context, allocator, definition, .callback);
        defer function.deinit();

        var arraylist = std.Io.Writer.Allocating.init(allocator);
        defer arraylist.deinit();
        function.printSourceCode(&arraylist.writer) catch return error.OutOfMemory;
        return arraylist.toOwnedSlice();
    }

    pub fn printSymbols(context: anytype, definitions: anytype) bun.bindgen.CallError(@TypeOf(context))!std.ArrayListUnmanaged([]u8) {
        const allocator = bun.default_allocator;

        var symbols = try parseSymbols(context, allocator, definitions);
        defer {
            for (symbols.values()) |*function| function.deinit();
            symbols.deinit(allocator);
        }
        var sources: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (sources.items) |source| allocator.free(source);
            sources.deinit(allocator);
        }
        try sources.ensureTotalCapacityPrecise(allocator, symbols.count());
        for (symbols.values()) |*function| {
            var arraylist = std.Io.Writer.Allocating.init(allocator);
            defer arraylist.deinit();
            function.printSourceCode(&arraylist.writer) catch return error.OutOfMemory;
            sources.appendAssumeCapacity(try arraylist.toOwnedSlice());
        }
        return sources;
    }

    pub fn open(context: anytype, name: []const u8, definitions: anytype) bun.bindgen.CallError(@TypeOf(context))!FFIRef {
        if (name.len == 0) return context.fail(.empty_file_path, {});
        var symbols = try parseSymbols(context, bun.default_allocator, definitions);
        defer {
            for (symbols.values()) |*function| function.deinit();
            symbols.deinit(bun.default_allocator);
        }
        if (symbols.count() == 0) return context.fail(.no_symbols, {});

        var dylib: ?DynLib = brk: {
            break :brk DynLib.open(name) catch {
                const backup_name = Fs.FileSystem.instance.abs(&[1]string{name});
                break :brk DynLib.open(backup_name) catch {
                    const dlerror_msg = try getDlError(bun.default_allocator);
                    defer bun.default_allocator.free(dlerror_msg);
                    const msg = try std.fmt.allocPrint(
                        bun.default_allocator,
                        "Failed to open library \"{s}\": {s}",
                        .{ name, dlerror_msg },
                    );
                    defer bun.default_allocator.free(msg);
                    return context.fail(.library_open_failed, try bun.bindgen.SystemError.init(.{
                        .errno = 0,
                        .code = "ERR_DLOPEN_FAILED",
                        .message = msg,
                        .syscall = "dlopen",
                    }));
                };
            };
        };
        defer if (dylib) |*library| library.close();

        for (symbols.values()) |*function| {
            const function_name = function.base_name.?;
            if (function.symbol_from_dynamic_library == null) {
                function.symbol_from_dynamic_library = dylib.?.lookup(Function.Symbol, function_name) orelse
                    return failMessage(context, .symbol_not_found, "Symbol \"{s}\" not found in \"{s}\"", .{ function_name, name });
            }
        }

        const lib = try bun.default_allocator.create(FFI);
        lib.* = .{
            .allocator = bun.default_allocator,
            .dylib = dylib,
            .functions = symbols,
        };
        dylib = null;
        symbols = .empty;
        lib.prepare(context) catch |err| {
            lib.deref();
            return err;
        };
        return try lib.toResult(context);
    }

    pub fn linkSymbols(context: anytype, definitions: anytype) bun.bindgen.CallError(@TypeOf(context))!FFIRef {
        const allocator = bun.default_allocator;

        var symbols = try parseSymbols(context, allocator, definitions);
        defer {
            for (symbols.values()) |*function| function.deinit();
            symbols.deinit(allocator);
        }
        if (symbols.count() == 0) return context.fail(.no_symbols, {});

        for (symbols.values()) |*function| {
            const function_name = function.base_name.?;
            if (function.symbol_from_dynamic_library == null) {
                return failMessage(context, .missing_symbol_pointer, "Symbol \"{s}\" is missing a \"ptr\" field. When using linkSymbols() or CFunction(), you must provide a \"ptr\" field with the memory address of the native function.", .{function_name});
            }
        }

        const lib = try allocator.create(FFI);
        lib.* = .{
            .allocator = allocator,
            .functions = symbols,
        };
        symbols = .empty;
        lib.prepare(context) catch |err| {
            lib.deref();
            return err;
        };
        return try lib.toResult(context);
    }
    fn failMessage(
        context: anytype,
        comptime tag: anytype,
        comptime format: []const u8,
        args: anytype,
    ) bun.bindgen.CallError(@TypeOf(context)) {
        const message = std.fmt.allocPrint(bun.default_allocator, format, args) catch return error.OutOfMemory;
        defer bun.default_allocator.free(message);
        const owned = bun.bindgen.DOMString.fromUTF8(message) catch return error.OutOfMemory;
        return context.fail(tag, owned);
    }

    const SignatureKind = enum { symbol, callback };

    fn parseSignature(
        context: anytype,
        allocator: std.mem.Allocator,
        definition: anytype,
        comptime kind: SignatureKind,
    ) bun.bindgen.CallError(@TypeOf(context))!Function {
        var function: Function = .{
            .allocator = allocator,
            .return_type = definition.returns orelse .void_type,
            .threadsafe = definition.threadsafe orelse false,
        };
        errdefer function.deinit();
        if (function.return_type == .napi_env) return context.fail(.return_napi_env, {});
        if (function.return_type == .buffer) return context.fail(.return_buffer, {});
        if (kind == .symbol and function.threadsafe) return context.fail(.threadsafe_function, {});
        if (function.threadsafe and function.return_type != .void_type) return context.fail(.threadsafe_return, {});
        if (definition.args) |*args| {
            try function.arg_types.ensureTotalCapacityPrecise(allocator, args.len());
            for (0..args.len()) |index| {
                const type_ = args.at(index).?;
                if (type_ == .void_type) return context.fail(.void_argument, {});
                if (kind == .callback and type_ == .buffer) return context.fail(.callback_buffer, {});
                if (function.threadsafe and (type_ == .buffer or type_ == .napi_env or type_ == .napi_value))
                    return context.fail(.threadsafe_argument, {});
                function.arg_types.appendAssumeCapacity(type_);
            }
        }
        if (definition.ptr) |pointer| {
            switch (pointer) {
                .address => |address| if (address != 0) {
                    function.symbol_from_dynamic_library = @ptrFromInt(address);
                },
                .ignored => {},
            }
        }
        return function;
    }

    fn parseSymbols(
        context: anytype,
        allocator: Allocator,
        definitions: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.StringArrayHashMap(Function) {
        var symbols: bun.StringArrayHashMap(Function) = .empty;
        errdefer {
            for (symbols.values()) |*function| function.deinit();
            symbols.deinit(allocator);
        }
        try symbols.ensureTotalCapacity(allocator, definitions.len());

        for (0..definitions.len()) |index| {
            const entry = definitions.at(index).?;
            const name = try entry.key.toUTF8(allocator);
            defer name.deinit();
            if (name.length() == 0 or std.mem.indexOfScalar(u8, name.slice(), 0) != null)
                return context.fail(.invalid_symbol_name, {});
            if (symbols.contains(name.slice()))
                return context.fail(.duplicate_symbol_name, {});

            const definition = switch (entry.value) {
                .definition => |definition| definition,
                .invalid => {
                    const message = try std.fmt.allocPrint(allocator, "Expected an object for key \"{s}\"", .{name.slice()});
                    defer allocator.free(message);
                    return context.fail(.invalid_symbol_definition, try bun.bindgen.DOMString.fromUTF8(message));
                },
            };
            var function = try parseSignature(context, allocator, &definition, .symbol);
            errdefer function.deinit();
            function.base_name = try allocator.dupeSentinel(u8, name.slice(), 0);
            symbols.putAssumeCapacity(bun.asByteSlice(function.base_name.?), function);
        }

        return symbols;
    }

    pub const Function = struct {
        const Symbol = bun.bindgen.EngineArgumentType(FFIBindings.engineShim("prepareFunction"), "symbol");

        symbol_from_dynamic_library: ?Symbol = null,
        base_name: ?[:0]const u8 = null,
        native_data: ?FFIFunctionData = null,

        return_type: ABIType = .void_type,
        arg_types: std.ArrayListUnmanaged(ABIType) = .empty,
        threadsafe: bool = false,
        allocator: Allocator,

        pub fn deinit(val: *Function) void {
            if (val.native_data) |*data| data.deinit();
            val.native_data = null;
            if (val.base_name) |base_name| {
                val.allocator.free(base_name);
                val.base_name = null;
            }

            val.arg_types.clearAndFree(val.allocator);
        }

        pub fn printSourceCode(
            this: *Function,
            writer: anytype,
        ) !void {
            try writer.writeAll("#include <stdint.h>\n#include <stdbool.h>\n");
            if (this.needsNapiEnv()) try writer.writeAll("#include <node_api.h>\n");
            try writer.writeAll("\ntypedef ");
            try writer.writeAll(abiTypeName(this.return_type));
            try writer.writeAll(" (*BunForeignFunction)(");
            if (this.arg_types.items.len == 0) try writer.writeAll("void");
            for (this.arg_types.items, 0..) |arg, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.writeAll(abiTypeName(arg));
                try writer.print(" arg{d}", .{i});
            }
            try writer.writeAll(");\n");
        }

        fn needsNapiEnv(this: *const FFI.Function) bool {
            for (this.arg_types.items) |arg| {
                if (arg == .napi_env or arg == .napi_value) {
                    return true;
                }
            }

            return this.return_type == .napi_value;
        }
    };

    pub const ABIType = FFIABIType;

    fn abiTypeName(type_: ABIType) []const u8 {
        return switch (type_) {
            .buffer, .function_pointer, .c_string, .pointer => "void*",
            .boolean => "bool",
            .int8 => "int8_t",
            .uint8 => "uint8_t",
            .int16 => "int16_t",
            .uint16 => "uint16_t",
            .int32 => "int32_t",
            .uint32 => "uint32_t",
            .int64_fast, .int64 => "int64_t",
            .uint64_fast, .uint64 => "uint64_t",
            .double_type => "double",
            .float_type => "float",
            .char_type => "char",
            .void_type => "void",
            .napi_env => "napi_env",
            .napi_value => "napi_value",
        };
    }
};

const CompilerRT = struct {
    var compiler_rt_dir: [:0]const u8 = "";
    const compiler_rt_sources = struct {
        pub const @"stdbool.h" = @embedFile("./ffi-stdbool.h");
        pub const @"stdarg.h" = @embedFile("./ffi-stdarg.h");
        pub const @"stdnoreturn.h" = @embedFile("./ffi-stdnoreturn.h");
        pub const @"stdalign.h" = @embedFile("./ffi-stdalign.h");
        pub const @"tgmath.h" = @embedFile("./ffi-tgmath.h");
        pub const @"stddef.h" = @embedFile("./ffi-stddef.h");
        pub const @"varargs.h" = "// empty";
    };

    fn createCompilerRTDir(io: std.Io) void {
        const tmpdir = Fs.FileSystem.instance.tmpdir() catch return;
        var bunCC = bun.MakePath.makeOpenPath(io, tmpdir, "bun-cc", .{}) catch return;
        defer bunCC.close(io);

        inline for (comptime std.meta.declarations(compiler_rt_sources)) |decl| {
            const source = @field(compiler_rt_sources, decl);
            bunCC.writeFile(io, .{
                .sub_path = decl,
                .data = source,
            }) catch {};
        }
        var path_buf: [bun.MAX_PATH_BYTES]u8 = undefined;
        compiler_rt_dir = bun.handleOom(bun.default_allocator.dupeSentinel(u8, bun.getFdPath(.fromStdDir(bunCC), &path_buf) catch return, 0));
    }
    var create_compiler_rt_dir_once = bun.once(createCompilerRTDir);

    pub fn dir(io: std.Io) ?[:0]const u8 {
        create_compiler_rt_dir_once.call(io, .{io});
        if (compiler_rt_dir.len == 0) return null;
        return compiler_rt_dir;
    }

    noinline fn memset(
        dest: ?*anyopaque,
        c: c_int,
        byte_count: usize,
    ) callconv(.c) ?*anyopaque {
        if (byte_count != 0) {
            const bytes: [*]u8 = @ptrCast(dest.?);
            @memset(bytes[0..byte_count], @as(u8, @truncate(@as(c_uint, @bitCast(c)))));
        }
        return dest;
    }

    noinline fn memcpy(
        noalias dest: ?*anyopaque,
        noalias source: ?*const anyopaque,
        byte_count: usize,
    ) callconv(.c) ?*anyopaque {
        if (byte_count != 0) {
            const destination: [*]u8 = @ptrCast(dest.?);
            const input: [*]const u8 = @ptrCast(source.?);
            @memcpy(destination[0..byte_count], input[0..byte_count]);
        }
        return dest;
    }

    pub fn define(state: *TCC.State) TCC.Error!void {
        if (comptime Environment.isX64) {
            state.defineSymbol("NEEDS_COMPILER_RT_FUNCTIONS", "1");
            try state.compileString(@embedFile("libtcc1.c"));
        }
    }

    pub fn inject(state: *TCC.State) TCC.Error!void {
        try state.addSymbol("memset", &memset);
        try state.addSymbol("memcpy", &memcpy);
    }
};

pub const ForeignFunctionData = opaque {};
pub const EnvironmentData = opaque {};

pub const ForeignFunction = struct {
    bindgen_state: bun.bindgen.ClassState = .{},
    library: bun.bindgen.RefNative(FFI, .vm),
    index: usize,

    pub fn destroy(this: *ForeignFunction) void {
        this.library.deinit();
        bun.destroy(this);
    }

    fn function(this: *const ForeignFunction) *FFI.Function {
        return &this.library.get().functions.values()[this.index];
    }
};

fn adoptForeignFunction(
    context: bun.bindgen.CallContext(AdoptForeignFunctionSchema),
    args: bun.bindgen.Args(AdoptForeignFunctionSchema),
) bun.JSError!bun.bindgen.Return(AdoptForeignFunctionSchema) {
    const library = args.library.get(FFI.JSBinding).ffi.get();
    if (args.index >= library.functions.count()) @panic("foreign function factory received an invalid symbol index");
    const state = try bun.default_allocator.create(ForeignFunction);
    state.* = .{ .library = .init(library), .index = args.index };
    return ForeignFunctionClass.adoptResult(state, context);
}

fn functionSignature(
    _: bun.bindgen.CallContext(FunctionSignatureSchema),
    args: bun.bindgen.Args(FunctionSignatureSchema),
) bun.JSError!bun.bindgen.Return(FunctionSignatureSchema) {
    const function = args.function.get(ForeignFunction).function();
    const Result = bun.bindgen.Return(FunctionSignatureSchema);
    const Arguments = @FieldType(Result, "argumentTypes");
    const types = try bun.default_allocator.alloc(Arguments.Element, function.arg_types.items.len);
    defer bun.default_allocator.free(types);
    @memcpy(types, function.arg_types.items);
    var name = try bun.bindgen.DOMString.fromUTF8(function.base_name.?);
    errdefer name.deinit();
    return .{
        .name = name,
        .argumentTypes = try Arguments.fromOwnedSlice(types),
        .returnType = function.return_type,
        .ptr = @intFromPtr(function.symbol_from_dynamic_library.?),
    };
}

fn beginForeignCall(args: bun.bindgen.Args(BeginForeignCallSchema)) ?*ForeignFunctionData {
    const library = args.function.library.get();
    if (library.closed) return null;
    library.ref();
    library.active_calls += 1;
    return args.function.function().native_data.?.get();
}

fn endForeignCall(args: bun.bindgen.Args(EndForeignCallSchema)) void {
    const library = args.function.library.get();
    bun.debugAssert(library.active_calls > 0);
    library.active_calls -= 1;
    if (library.closed and library.active_calls == 0) library.closeResources();
    library.deref();
}

fn foreignEnvironment(args: bun.bindgen.Args(ForeignEnvironmentSchema)) ?*EnvironmentData {
    const environment = args.function.library.get().environment orelse return null;
    return environment.get();
}

pub const CallbackEndpointData = opaque {};

pub const FFICallbackContext = struct {
    bindgen_state: bun.bindgen.ClassState = .{},
    endpoint: ?CallbackEndpoint = null,

    pub fn destroy(this: *@This()) void {
        this.close();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const @This(), _: bun.bindgen.MemoryUsageContext(.vm)) usize {
        const endpoint = this.endpoint orelse return @sizeOf(@This());
        return @sizeOf(@This()) + bun.bindgen.Engine(CallbackMemoryUsageSchema).call(.{ .endpoint = endpoint.get() });
    }

    pub fn bindClose(
        this: *@This(),
        _: bun.bindgen.CallContext(FFICallbackContextCloseSchema),
        _: bun.bindgen.Args(FFICallbackContextCloseSchema),
    ) bun.JSError!void {
        if (this.endpoint) |endpoint| bun.bindgen.Engine(CloseCallbackSchema).call(.{
            .endpoint = endpoint.get(),
        });
    }

    pub fn bindPublish(
        this: *@This(),
        context: bun.bindgen.CallContext(FFICallbackContextPublishSchema),
        args: bun.bindgen.Args(FFICallbackContextPublishSchema),
    ) bun.JSError!void {
        if (this.endpoint) |endpoint| context.engineIn("FFI", "publishCallback").call(.{
            .endpoint = endpoint.get(),
            .context = args.bindingThis.operand(context),
        });
    }

    fn close(this: *@This()) void {
        var endpoint = this.endpoint orelse return;
        this.endpoint = null;
        endpoint.deinit();
    }
};

fn invokeCallback(
    context: bun.bindgen.CallContext(InvokeCallbackSchema),
    args: bun.bindgen.Args(InvokeCallbackSchema),
) bun.JSError!bun.bindgen.Return(InvokeCallbackSchema) {
    const callback_view = (try CallbackSlot.view(args.context)) orelse return .{ .void_type = false };
    const PassingArgs = bun.bindgen.Args(NativeCallbackType);
    const Value = @typeInfo(@FieldType(PassingArgs, "arguments")).pointer.child;
    const values = try bun.default_allocator.alloc(Value, args.arguments.len());
    defer bun.default_allocator.free(values);
    for (values, 0..) |*value, index| {
        value.* = switch (args.arguments.at(index).?) {
            .napi_value => |payload| .{ .napi_value = payload.operand(context) },
            inline else => |payload, tag| @unionInit(Value, @tagName(tag), payload),
        };
    }
    return callback_view.call(.{ .arguments = values });
}

const FFIBindings = bun.bindgen.Module("FFI");
const CompileSchema = FFIBindings.function("compile");
const CallbackSchema = FFIBindings.function("callback");
const NativeCallbackType = bun.bindgen.CallbackSchema("FFINativeCallback");
const CallbackPointerSchema = FFIBindings.engineShim("callbackPointer");
const CallbackMemoryUsageSchema = FFIBindings.engineShim("callbackMemoryUsage");
const CloseCallbackSchema = FFIBindings.engineShim("closeCallback");
const CallbackEndpoint = bun.bindgen.Return(FFIBindings.engineShim("createCallback"));
const InvokeCallbackSchema = FFIBindings.nativeExport("invokeCallback");
const InvokeCallbackBinding = bun.bindgen.Fn(InvokeCallbackSchema, invokeCallback);
const FFIClassSchema = FFIBindings.class("FFI");
const FFIClass = bun.bindgen.Class(FFIClassSchema, FFI.JSBinding);
const FFIRef = bun.bindgen.ClassRef(FFIClassSchema);
const FFICloseSchema = FFIClassSchema.member("close");
const FFISymbolsSchema = FFIClassSchema.member("symbols");
const ForeignFunctionClassSchema = FFIBindings.class("ForeignFunction");
const ForeignFunctionClass = bun.bindgen.Class(ForeignFunctionClassSchema, ForeignFunction);
const AdoptForeignFunctionSchema = FFIBindings.nativeExport("adoptForeignFunction");
const AdoptForeignFunctionBinding = bun.bindgen.Fn(AdoptForeignFunctionSchema, adoptForeignFunction);
const FunctionSignatureSchema = FFIBindings.function("functionSignature");
const FunctionSignatureBinding = bun.bindgen.Fn(FunctionSignatureSchema, functionSignature);
const PrepareFunctionSchema = FFIBindings.engineShim("prepareFunction");
const FFIFunctionData = bun.bindgen.Return(PrepareFunctionSchema);
const FFIEnvironment = bun.bindgen.Return(FFIBindings.engineShim("createEnvironment"));
const BeginForeignCallSchema = FFIBindings.nativeExport("beginForeignCall");
const EndForeignCallSchema = FFIBindings.nativeExport("endForeignCall");
const ForeignEnvironmentSchema = FFIBindings.nativeExport("foreignEnvironment");
const BeginForeignCallBinding = bun.bindgen.Fn(BeginForeignCallSchema, beginForeignCall);
const EndForeignCallBinding = bun.bindgen.Fn(EndForeignCallSchema, endForeignCall);
const ForeignEnvironmentBinding = bun.bindgen.Fn(ForeignEnvironmentSchema, foreignEnvironment);
const FFICallbackContextClassSchema = FFIBindings.class("FFICallbackContext");
const FFICallbackContextClass = bun.bindgen.Class(FFICallbackContextClassSchema, FFICallbackContext);
const FFICallbackContextCloseSchema = FFICallbackContextClassSchema.member("close");
const FFICallbackContextPublishSchema = FFICallbackContextClassSchema.member("publish");
const CallbackSlot = FFICallbackContextClass.CachedSlot("callbackValue");
const FFIABIType = @typeInfo(bun.bindgen.EngineArgumentType(PrepareFunctionSchema, "argumentTypes")).pointer.child;

comptime {
    _ = FFIClass;
    _ = FFICallbackContextClass;
    _ = ForeignFunctionClass;
    _ = AdoptForeignFunctionBinding;
    _ = FunctionSignatureBinding;
    _ = BeginForeignCallBinding;
    _ = EndForeignCallBinding;
    _ = ForeignEnvironmentBinding;
    _ = InvokeCallbackBinding;
}

const string = []const u8;

const TCC = if (Environment.enable_tinycc) @import("../../tcc_sys/tcc.zig") else struct {
    pub const State = struct {
        pub fn deinit(_: *State) void {}
    };
};

const Fs = @import("../../resolver/fs.zig");
const options = @import("../../bundler/options.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const strings = bun.strings;
const DynLib = if (Environment.isWindows) WindowsDynLib else PosixDynLib;

const PosixDynLib = struct {
    const LibraryHandle = opaque {};
    handle: *LibraryHandle,

    fn open(path: []const u8) !PosixDynLib {
        const library = try std.DynLib.open(path);
        return .{ .handle = @ptrCast(library.inner.handle) };
    }

    fn close(this: *PosixDynLib) void {
        var library: std.DynLib = .{ .inner = .{ .handle = @ptrCast(this.handle) } };
        library.close();
        this.* = undefined;
    }

    fn lookup(this: *PosixDynLib, comptime T: type, name: [:0]const u8) ?T {
        var library: std.DynLib = .{ .inner = .{ .handle = @ptrCast(this.handle) } };
        return library.lookup(T, name);
    }
};

const WindowsDynLib = struct {
    const libuv = bun.windows.libuv;

    inner: libuv.uv_lib_t,

    fn open(path: []const u8) !WindowsDynLib {
        const path_z = try bun.default_allocator.dupeSentinel(u8, path, 0);
        defer bun.default_allocator.free(path_z);
        var result: WindowsDynLib = undefined;
        if (libuv.uv_dlopen(path_z.ptr, &result.inner) != 0) return error.OpenFailed;
        return result;
    }

    fn close(this: *DynLib) void {
        libuv.uv_dlclose(&this.inner);
    }

    fn lookup(this: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        var pointer: ?*anyopaque = null;
        if (libuv.uv_dlsym(&this.inner, name.ptr, &pointer) != 0) return null;
        return @ptrCast(pointer orelse return null);
    }
};
