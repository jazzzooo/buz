pub const Set = struct {
    js: JavaScript,
    fs: Fs,
    json: Json,

    pub fn init(allocator: std.mem.Allocator) Set {
        return Set{
            .js = JavaScript.init(allocator),
            .fs = Fs{
                .shared_buffer = MutableString.initEmpty(allocator),
                .macro_shared_buffer = MutableString.initEmpty(allocator),
            },
            .json = Json{},
        };
    }
};
const debug = Output.scoped(.fs, .visible);
pub const Fs = struct {
    pub const Entry = struct {
        contents: string,
        fd: FD,
        /// When `contents` comes from a native plugin, this field is populated
        /// with information on how to free it.
        external_free_function: ExternalFreeFunction = .none,

        pub const ExternalFreeFunction = struct {
            pub const PluginSourceContext = opaque {};
            ctx: ?*PluginSourceContext,
            function: ?*const fn (?*anyopaque) callconv(.c) void,

            pub const none: ExternalFreeFunction = .{ .ctx = null, .function = null };

            pub fn call(this: *const @This()) void {
                if (this.function) |func| {
                    func(@ptrCast(this.ctx));
                }
            }
        };

        pub fn deinit(entry: *Entry, allocator: std.mem.Allocator) void {
            if (entry.external_free_function.function) |func| {
                func(@ptrCast(entry.external_free_function.ctx));
            } else if (entry.contents.len > 0) {
                allocator.free(entry.contents);
                entry.contents = "";
            }
        }

        pub fn closeFD(entry: *Entry) ?bun.sys.Error {
            if (entry.fd.isValid()) {
                defer entry.fd = .invalid;
                return entry.fd.closeAllowingBadFileDescriptor(@returnAddress());
            }
            return null;
        }
    };

    shared_buffer: MutableString,
    macro_shared_buffer: MutableString,

    use_alternate_source_cache: bool = false,
    stream: bool = false,

    // When we are in a macro, the shared buffer may be in use by the in-progress macro.
    // so we have to dynamically switch it out.
    pub inline fn sharedBuffer(this: *Fs) *MutableString {
        return if (!this.use_alternate_source_cache)
            &this.shared_buffer
        else
            &this.macro_shared_buffer;
    }

    /// When we need to suspend/resume something that has pointers into the shared buffer, we need to
    /// switch out the shared buffer so that it is not in use
    /// The caller must
    pub fn resetSharedBuffer(this: *Fs, buffer: *MutableString) void {
        if (buffer == &this.shared_buffer) {
            this.shared_buffer = MutableString.initEmpty(bun.default_allocator);
        } else if (buffer == &this.macro_shared_buffer) {
            this.macro_shared_buffer = MutableString.initEmpty(bun.default_allocator);
        } else {
            bun.unreachablePanic("resetSharedBuffer: invalid buffer", .{});
        }
    }

    pub fn deinit(c: *Fs) void {
        c.shared_buffer.deinit();
        c.macro_shared_buffer.deinit();
    }

    pub fn readFile(
        c: *Fs,
        io: std.Io,
        _fs: *fs.FileSystem,
        path: string,
        dirname_fd: FD,
        comptime use_shared_buffer: bool,
        _file_handle: ?FD,
    ) !Entry {
        return c.readFileWithAllocator(bun.default_allocator, io, _fs, path, dirname_fd, use_shared_buffer, _file_handle);
    }

    pub fn readFileWithAllocator(
        c: *Fs,
        allocator: std.mem.Allocator,
        io: std.Io,
        _fs: *fs.FileSystem,
        path: string,
        dirname_fd: FD,
        comptime use_shared_buffer: bool,
        _file_handle: ?FD,
    ) !Entry {
        var rfs = _fs.fs;

        var file_handle: std.Io.File = if (_file_handle) |__file| __file.stdFile() else undefined;

        if (_file_handle == null) {
            if (FeatureFlags.store_file_descriptors and dirname_fd.isValid()) {
                file_handle = (bun.sys.openatA(dirname_fd, std.fs.path.basename(path), bun.O.RDONLY, 0).unwrap() catch |err| brk: {
                    switch (err) {
                        error.ENOENT => {
                            const handle = try bun.openFile(path, .{ .mode = .read_only });
                            Output.prettyErrorln(
                                "<r><d>Internal error: directory mismatch for directory \"{s}\", fd {f}<r>. You don't need to do anything, but this indicates a bug.",
                                .{ path, dirname_fd },
                            );
                            break :brk bun.FD.fromStdFile(handle);
                        },
                        else => return err,
                    }
                }).stdFile();
            } else {
                file_handle = try bun.openFile(path, .{ .mode = .read_only });
            }
        } else {
            _ = try bun.sys.lseek(.fromStdFile(file_handle), 0, std.posix.SEEK.SET).unwrap();
        }

        if (comptime !Environment.isWindows) // skip on Windows because NTCreateFile will do it.
            debug("openat({f}, {s}) = {f}", .{ dirname_fd, path, bun.FD.fromStdFile(file_handle) });

        const will_close = rfs.needToCloseFiles() and _file_handle == null;
        defer {
            if (will_close) {
                debug("readFileWithAllocator close({f})", .{bun.fs.printHandle(file_handle.handle)});
                file_handle.close(io);
            }
        }

        const file = if (c.stream)
            rfs.readFileWithHandleAndAllocator(allocator, path, null, file_handle, use_shared_buffer, c.sharedBuffer(), true) catch |err| {
                if (Environment.isDebug) {
                    Output.printError("{s}: readFile error -- {s}", .{ path, @errorName(err) });
                }
                return err;
            }
        else
            rfs.readFileWithHandleAndAllocator(allocator, path, null, file_handle, use_shared_buffer, c.sharedBuffer(), false) catch |err| {
                if (Environment.isDebug) {
                    Output.printError("{s}: readFile error -- {s}", .{ path, @errorName(err) });
                }
                return err;
            };

        return Entry{
            .contents = file.contents,
            .fd = if (FeatureFlags.store_file_descriptors and !will_close) .fromStdFile(file_handle) else bun.invalid_fd,
        };
    }
};

pub const JavaScript = struct {
    pub const Result = js_ast.Result;

    pub fn init(_: std.mem.Allocator) JavaScript {
        return JavaScript{};
    }
    // For now, we're not going to cache JavaScript ASTs.
    // It's probably only relevant when bundling for production.
    pub fn parse(
        _: *const @This(),
        allocator: std.mem.Allocator,
        opts: js_parser.Parser.Options,
        defines: *Define,
        log: *logger.Log,
        source: *const logger.Source,
    ) bun.OOM!?js_ast.Result {
        var temp_log = logger.Log.init(allocator);
        defer temp_log.deinit();
        temp_log.level = log.level;
        var parser = js_parser.Parser.init(opts, &temp_log, source, defines, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try temp_log.appendTo(log);
            return null;
        };

        const result = parser.parse() catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (temp_log.errors == 0) {
                try temp_log.addRangeError(source, parser.lexer.range(), @errorName(err));
            }

            try temp_log.appendTo(log);
            return null;
        };

        try temp_log.appendTo(log);
        return result;
    }

    pub fn scan(
        _: *@This(),
        allocator: std.mem.Allocator,
        scan_pass_result: *js_parser.ScanPassResult,
        opts: js_parser.Parser.Options,
        defines: *Define,
        log: *logger.Log,
        source: *const logger.Source,
    ) anyerror!void {
        if (strings.trim(source.contents, "\n\t\r ").len == 0) {
            return;
        }

        var temp_log = logger.Log.init(allocator);
        defer temp_log.deinit();
        var parser = js_parser.Parser.init(opts, &temp_log, source, defines, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try temp_log.appendTo(log);
            return;
        };
        parser.scanImports(scan_pass_result) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try temp_log.appendTo(log);
            return err;
        };
        try temp_log.appendTo(log);
    }
};

pub const Json = struct {
    pub fn init(_: std.mem.Allocator) Json {
        return Json{};
    }
    fn parse(_: *@This(), log: *logger.Log, source: *const logger.Source, allocator: std.mem.Allocator, comptime func: anytype, comptime force_utf8: bool) bun.OOM!?js_ast.Expr {
        var temp_log = logger.Log.init(allocator);
        defer temp_log.deinit();
        temp_log.level = log.level;
        const result = func(source, &temp_log, allocator, force_utf8) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try temp_log.appendTo(log);
            return null;
        };
        try temp_log.appendTo(log);
        return result;
    }
    pub fn parseJSON(cache: *@This(), log: *logger.Log, source: *const logger.Source, allocator: std.mem.Allocator, mode: enum { json, jsonc }, comptime force_utf8: bool) bun.OOM!?js_ast.Expr {
        // tsconfig.* and jsconfig.* files are JSON files, but they are not valid JSON files.
        // They are JSON files with comments and trailing commas.
        // Sometimes tooling expects this to work.
        if (mode == .jsonc) {
            return try parse(cache, log, source, allocator, json_parser.parseTSConfig, force_utf8);
        }

        return try parse(cache, log, source, allocator, json_parser.parse, force_utf8);
    }

    pub fn parsePackageJSON(cache: *@This(), log: *logger.Log, source: *const logger.Source, allocator: std.mem.Allocator, comptime force_utf8: bool) bun.OOM!?js_ast.Expr {
        return try parse(cache, log, source, allocator, json_parser.parseTSConfig, force_utf8);
    }

    pub fn parseTSConfig(cache: *@This(), log: *logger.Log, source: *const logger.Source, allocator: std.mem.Allocator) bun.OOM!?js_ast.Expr {
        return try parse(cache, log, source, allocator, json_parser.parseTSConfig, true);
    }
};

test "macro allocation failure propagates through nested expression visitors" {
    const Context = js_ast.Macro.Context;
    const Stub = struct {
        header: Context.Header = .{ .operations = &operations },
        calls: usize = 0,

        const operations: Context.Operations = .{
            .destroy = destroy,
            .get_remap = getRemap,
            .set_javascript_object = setJavascriptObject,
            .call = call,
        };

        fn destroy(_: *Context) void {}
        fn getRemap(_: *const Context, _: string) ?@import("../resolver/package_json.zig").MacroImportReplacementMap {
            return null;
        }
        fn setJavascriptObject(_: *Context, _: *const bun.bindgen.Root) void {}
        fn call(context: *Context, _: std.mem.Allocator, _: string, _: string, _: *logger.Log, _: *const logger.Source, _: logger.Range, _: js_ast.Expr, _: string) anyerror!js_ast.Expr {
            const header: *Context.Header = @ptrCast(@alignCast(context));
            const this: *@This() = @fieldParentPtr("header", header);
            this.calls += 1;
            return error.OutOfMemory;
        }
    };

    for ([_][]const u8{
        "value();",
        "const f = () => value();",
        "function f() { return value(); }",
        "class C { field = value(); }",
        "class C { static { value(); } }",
        "const { [value()]: item } = {};",
        "console.log((1 + value()) * 2);",
        "function f(arg = value()) {}",
        "for (let item = value(); false;) {}",
        "try { value(); } catch {}",
        "try {} finally { value(); }",
        "value`text`;",
    }) |body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var ast_memory: js_ast.ASTMemoryAllocator = undefined;
        var ast_scope = ast_memory.enter(allocator);
        defer ast_scope.exit();
        var log = logger.Log.init(std.testing.allocator);
        defer log.deinit();
        const defines = try Define.init(allocator, null, null, false, false);
        defer defines.deinit();
        var stub: Stub = .{};
        var opts = js_parser.Parser.Options.init(.{}, .js);
        opts.macro_context = @ptrCast(&stub.header);
        const code = try std.fmt.allocPrint(allocator, "import {{ value }} from \"macro:fixture\"; {s}", .{body});
        const source = logger.Source.initPathString("input.js", code);
        const cache: JavaScript = .{};
        try std.testing.expectError(error.OutOfMemory, cache.parse(allocator, opts, defines, &log, &source));
        try std.testing.expectEqual(@as(usize, 1), stub.calls);
        try std.testing.expectEqual(@as(u32, 0), log.errors);
    }
}

const string = []const u8;

const fs = @import("../resolver/fs.zig");
const std = @import("std");
const Define = @import("./defines.zig").Define;

const bun = @import("bun");
const Environment = bun.Environment;
const FD = bun.FD;
const FeatureFlags = bun.FeatureFlags;
const Global = bun.Global;
const MutableString = bun.MutableString;
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const js_ast = bun.ast;
const js_parser = bun.js_parser;
const json_parser = bun.json;
const logger = bun.logger;
const strings = bun.strings;
