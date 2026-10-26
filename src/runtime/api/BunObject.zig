fn loadOrigin() bun.OOM!bun.bindgen.DOMString {
    return bun.bindgen.DOMString.fromUTF8(VirtualMachine.get().origin.origin);
}

fn loadCwd() bun.OOM!bun.bindgen.Return(LazyCwdSchema) {
    return bun.bindgen.DOMString.fromUTF8(VirtualMachine.get().transpiler.fs.top_level_dir);
}

fn loadEmbeddedFiles(context: anytype) bun.JSError!bun.bindgen.Return(LazyEmbeddedFilesSchema) {
    const globalThis = context.viewToken().globalObject();
    var empty_files: [0]bun.StandaloneModuleGraph.File = .{};
    const files = if (globalThis.bunVM().standalone_module_graph) |graph| graph.files.values() else empty_files[0..];
    var indices = try std.array_list.Managed(u32).initCapacity(default_allocator, files.len);
    defer indices.deinit();
    for (files, 0..) |*file, index| {
        if (file.appearsInEmbeddedFilesArray()) indices.appendAssumeCapacity(@intCast(index));
    }
    std.mem.sort(u32, indices.items, files, bun.StandaloneModuleGraph.File.lessThanByIndex);

    const ResultType = bun.bindgen.Return(LazyEmbeddedFilesSchema);
    var result = try ResultType.Builder.init(indices.items.len);
    errdefer result.deinit();
    for (indices.items) |index| {
        var value = try jsc.API.StandaloneGraphEngine.fileBlob(&files[index]);
        defer value.deinit();
        const blob = try bun.webcore.Blob.new(&value);
        result.appendOwned(try blob.toBindingRef(context));
    }
    return result.finish();
}

pub fn shellEscape(
    context: bun.bindgen.CallContext(ShellEscapeSchema),
    args: bun.bindgen.Args(ShellEscapeSchema),
) bun.bindgen.CallError(ShellEscapeSchema)!bun.bindgen.DOMString {
    var input = args.input.toOwned();
    defer input.deinit();
    const bunstr = input.takeBunString();
    defer bunstr.deref();

    var outbuf = std.array_list.Managed(u8).init(bun.default_allocator);
    defer outbuf.deinit();

    if (bun.shell.needsEscapeBunstr(bunstr)) {
        const result = try bun.shell.escapeBunStr(bunstr, &outbuf, true);
        if (!result) {
            const message = try std.fmt.allocPrint(
                bun.default_allocator,
                "String has invalid utf-16: {s}",
                .{bunstr.byteSlice()},
            );
            defer bun.default_allocator.free(message);
            return context.fail(.invalid_utf16, try bun.bindgen.DOMString.fromUTF8(message));
        }
        return bun.bindgen.DOMString.fromUTF8(outbuf.items);
    }

    return bun.bindgen.DOMString.fromBunString(bunstr.dupeRef());
}

pub fn deepEquals(
    context: bun.bindgen.CallContext(DeepEqualsSchema),
    args: bun.bindgen.Args(DeepEqualsSchema),
) bun.JSError!bool {
    const strict = (args.strict orelse null) orelse false;
    return if (strict)
        try context.engineIn("js_value_inspection", "jsValueStrictDeepEquals").call(.{ .input = .{
            .left = args.left.operand(context).asEngine(),
            .right = args.right.operand(context).asEngine(),
        } })
    else
        try context.engineIn("js_value_inspection", "jsValueDeepEquals").call(.{ .input = .{
            .left = args.left.operand(context),
            .right = args.right.operand(context),
        } });
}

pub fn braces(
    context: bun.bindgen.CallContext(BracesSchema),
    args: bun.bindgen.Args(BracesSchema),
) bun.bindgen.CallError(BracesSchema)!bun.bindgen.Return(BracesSchema) {
    var owned_input = args.input.toOwned();
    defer owned_input.deinit();
    const brace_str = if (owned_input.impl) |impl| bun.String.init(impl) else bun.String.empty;
    const opts = args.options orelse @as(@TypeOf(args.options.?), .{ .tokenize = false, .parse = false });
    const brace_slice = try brace_str.toUTF8(bun.default_allocator);
    defer brace_slice.deinit();

    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();

    var lexer_output = lexer_output: {
        if (bun.strings.isAllASCII(brace_slice.slice())) {
            break :lexer_output Braces.Lexer.tokenize(arena.allocator(), brace_slice.slice()) catch |err| {
                return context.fail(.processing_failed, try bun.bindgen.DOMString.fromUTF8(@errorName(err)));
            };
        }

        break :lexer_output Braces.NewLexer(.wtf8).tokenize(arena.allocator(), brace_slice.slice()) catch |err| {
            return context.fail(.processing_failed, try bun.bindgen.DOMString.fromUTF8(@errorName(err)));
        };
    };

    const expansion_count = Braces.calculateExpandedAmount(lexer_output.tokens.items[0..]);

    if (opts.tokenize) {
        const str = try std.fmt.allocPrint(bun.default_allocator, "{f}", .{std.json.fmt(lexer_output.tokens.items[0..], .{})});
        defer bun.default_allocator.free(str);
        return .{ .text = try bun.bindgen.DOMString.fromUTF8(str) };
    }
    if (opts.parse) {
        var parser = Braces.Parser.init(lexer_output.tokens.items[0..], arena.allocator());
        const ast_node = parser.parse() catch |err| {
            return context.fail(.processing_failed, try bun.bindgen.DOMString.fromUTF8(@errorName(err)));
        };
        const str = try std.fmt.allocPrint(bun.default_allocator, "{f}", .{std.json.fmt(ast_node, .{})});
        defer bun.default_allocator.free(str);
        return .{ .text = try bun.bindgen.DOMString.fromUTF8(str) };
    }

    if (expansion_count == 0) {
        return .{ .values = try @FieldType(bun.bindgen.Return(BracesSchema), "values").fromBunStrings(&.{brace_str}) };
    }

    var expanded_strings = try arena.allocator().alloc(std.array_list.Managed(u8), expansion_count);

    for (0..expansion_count) |i| {
        expanded_strings[i] = std.array_list.Managed(u8).init(arena.allocator());
    }

    Braces.expand(
        arena.allocator(),
        lexer_output.tokens.items[0..],
        expanded_strings,
        lexer_output.contains_nested,
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.UnexpectedToken => return context.fail(
            .processing_failed,
            try bun.bindgen.DOMString.fromUTF8("Unexpected token while expanding braces"),
        ),
    };

    var out_strings = try arena.allocator().alloc(bun.String, expansion_count);
    for (0..expansion_count) |i| {
        out_strings[i] = bun.String.cloneUTF8(expanded_strings[i].items[0..]);
    }
    defer for (out_strings) |str| str.deref();

    return .{ .values = try @FieldType(bun.bindgen.Return(BracesSchema), "values").fromBunStrings(out_strings) };
}

pub fn which(
    context: bun.bindgen.CallContext(WhichSchema),
    args: bun.bindgen.Args(WhichSchema),
) bun.bindgen.CallError(WhichSchema)!?bun.bindgen.DOMString {
    const globalThis = context.viewToken().globalObject();
    const allocator = bun.default_allocator;
    const command = (args.command orelse return null) orelse return null;

    var path_str: bun.String.Slice = bun.String.Slice.empty;
    var bin_str = try command.toUTF8(allocator);
    var cwd_str: bun.String.Slice = bun.String.Slice.empty;
    defer {
        path_str.deinit();
        bin_str.deinit();
        cwd_str.deinit();
    }

    if (bin_str.length() >= bun.MAX_PATH_BYTES) {
        return context.fail(.command_too_long, {});
    }

    if (bin_str.length() == 0) {
        return null;
    }

    const vm = globalThis.bunVM();
    path_str = try bun.String.Slice.initDupe(
        allocator,
        vm.transpiler.env.get("PATH") orelse "",
    );
    cwd_str = try bun.String.Slice.initDupe(
        allocator,
        vm.transpiler.fs.top_level_dir,
    );

    if (args.options) |options_input| {
        const converted = try options_input.convert(context);
        switch (converted.value) {
            .options => |which_opts| {
                if (which_opts.path) |value| {
                    const path = switch (value) {
                        .nulled => bun.String.Slice.empty,
                        .string => |text| try text.toUTF8(allocator),
                    };
                    path_str.deinit();
                    path_str = path;
                }
                if (which_opts.cwd) |value| {
                    const cwd = switch (value) {
                        .nulled => bun.String.Slice.empty,
                        .string => |text| try text.toUTF8(allocator),
                    };
                    cwd_str.deinit();
                    cwd_str = cwd;
                }
            },
            .ignored => {},
        }
    }

    const path_buf = bun.path_buffer_pool.get();
    defer bun.path_buffer_pool.put(path_buf);
    if (Which.which(
        path_buf,
        path_str.slice(),
        cwd_str.slice(),
        bin_str.slice(),
    )) |bin_path| {
        return @as(?bun.bindgen.DOMString, try bun.bindgen.DOMString.fromUTF8(bin_path));
    }

    return null;
}

fn applyConsoleFormatOptions(format_options: *jsc.ConsoleObject.FormatOptions, inspect_options: anytype) void {
    if (inspect_options.depth) |depth| format_options.max_depth = depth;
    applyConsoleStyleOptions(format_options, inspect_options);
}

fn applyConsoleStyleOptions(format_options: *jsc.ConsoleObject.FormatOptions, inspect_options: anytype) void {
    if (inspect_options.colors) |colors| format_options.enable_colors = colors;
    if (inspect_options.sorted) |sorted| format_options.ordered_properties = sorted;
    if (inspect_options.compact) |compact| format_options.single_line = compact;
}

pub fn inspectTable(
    context: bun.bindgen.CallContext(InspectTableSchema),
    args: bun.bindgen.Args(InspectTableSchema),
) bun.JSError!bun.bindgen.DOMString {
    const value = if (args.value) |value| switch (value) {
        .object => |object| object,
        .invalid => return bun.bindgen.DOMString.empty(),
    } else return bun.bindgen.DOMString.empty();

    var formatOptions = jsc.ConsoleObject.FormatOptions{
        .enable_colors = false,
        .add_newline = false,
        .flush = false,
        .max_depth = 5,
        .quote_strings = true,
        .ordered_properties = false,
        .single_line = true,
    };
    if (args.properties_or_options) |input| switch (input) {
        .properties => |properties| {
            if (args.options) |inspect_options| applyConsoleFormatOptions(&formatOptions, inspect_options);
            return jsc.ConsoleObject.formatTableForBinding(context, value, properties, formatOptions);
        },
        .options => |inspect_options| applyConsoleFormatOptions(&formatOptions, inspect_options),
    };
    if (args.options) |inspect_options| applyConsoleFormatOptions(&formatOptions, inspect_options);
    return jsc.ConsoleObject.formatTableForBinding(context, value, null, formatOptions);
}

pub fn inspect(
    context: bun.bindgen.CallContext(InspectSchema),
    args: bun.bindgen.Args(InspectSchema),
) bun.JSError!bun.bindgen.DOMString {
    const value = args.value orelse return bun.bindgen.DOMString.empty();

    var formatOptions = jsc.ConsoleObject.FormatOptions{
        .enable_colors = false,
        .add_newline = false,
        .flush = false,
        .max_depth = 8,
        .quote_strings = true,
        .ordered_properties = false,
    };
    if (args.options) |input| switch (input) {
        .options => |inspect_options| {
            if (inspect_options.depth) |depth| switch (depth) {
                .number => |number| formatOptions.max_depth = number,
                .ignored => {},
            };
            applyConsoleStyleOptions(&formatOptions, inspect_options);
        },
        .ignored => if (args.colors) |colors| {
            formatOptions.enable_colors = colors;
        },
    };

    return jsc.ConsoleObject.formatValueForBinding(context, value, formatOptions);
}

fn bindInspectValueForErrorMessage(
    context: bun.bindgen.CallContext(InspectValueForErrorMessageSchema),
    args: bun.bindgen.Args(InspectValueForErrorMessageSchema),
) bun.JSError!bun.bindgen.Return(InspectValueForErrorMessageSchema) {
    return jsc.ConsoleObject.formatValueForErrorBinding(context, args.value);
}

fn bindInspectSingleLine(
    context: bun.bindgen.CallContext(InspectSingleLineSchema),
    args: bun.bindgen.Args(InspectSingleLineSchema),
) bun.JSError!bun.bindgen.Return(InspectSingleLineSchema) {
    return jsc.ConsoleObject.formatValueForBinding(
        context,
        args.value,
        .{
            .enable_colors = false,
            .add_newline = false,
            .flush = false,
            .max_depth = std.math.maxInt(u16),
            .quote_strings = true,
            .ordered_properties = false,
            .single_line = true,
        },
    );
}

pub fn openInEditor(
    context: bun.bindgen.CallContext(OpenInEditorSchema),
    args: bun.bindgen.Args(OpenInEditorSchema),
) bun.bindgen.CallError(OpenInEditorSchema)!void {
    const globalThis = context.viewToken().globalObject();
    var arena = bun.ArenaAllocator.init(default_allocator);
    defer arena.deinit();
    var path_slice = bun.String.Slice.empty;
    defer path_slice.deinit();
    var path: string = "";
    var line: ?string = null;
    var column: ?string = null;

    if (args.path) |file_path| {
        path_slice = try file_path.toUTF8(arena.allocator());
        path = path_slice.slice();
    }

    if (args.options) |editor_options| {
        if (editor_options.editor) |editor_name| {
            const sliced = try editor_name.toUTF8(arena.allocator());
            defer sliced.deinit();
            if (sliced.length() > 0 and !try select(globalThis, sliced.slice())) {
                return openInEditorFailure(context, "Could not find editor \"{s}\"", .{sliced.slice()});
            }
        }

        if (editor_options.line) |line_value| {
            if (line_value.length() > 0) line = try line_value.toOwnedSlice(arena.allocator());
        }

        if (editor_options.column) |column_value| {
            if (column_value.length() > 0) column = try column_value.toOwnedSlice(arena.allocator());
        }
    }

    if (path.len == 0) {
        return openInEditorFailure(context, "No file path specified", .{});
    }

    open(globalThis, path, line, column) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EditorNotFound => return openInEditorFailure(context, "Failed to auto-detect editor", .{}),
        else => return openInEditorFailure(context, "Opening editor failed {s}", .{@errorName(err)}),
    };
}

fn select(globalThis: *bun.jsc.JSGlobalObject, name: []const u8) bun.OOM!bool {
    const vm = globalThis.bunVM();
    const current = &vm.rareData().editor_context;
    if (bun.strings.eqlLong(current.name(), name, true)) return true;

    var candidate: Open.EditorContext = .{};
    errdefer candidate.deinit();
    try candidate.setName(name);
    candidate.detectEditor(vm.transpiler.env);
    if (candidate.editor == null or candidate.editor == .none) {
        candidate.deinit();
        return false;
    }
    current.deinit();
    current.* = candidate;
    return true;
}

fn open(
    globalThis: *bun.jsc.JSGlobalObject,
    path: []const u8,
    line: ?[]const u8,
    column: ?[]const u8,
) !void {
    const vm = globalThis.bunVM();
    const current = &vm.rareData().editor_context;
    current.autoDetectEditor(vm.transpiler.env);
    const editor = current.editor orelse return error.EditorNotFound;
    if (editor == .none) return error.EditorNotFound;
    return editor.open(current.path, path, line, column);
}

fn openInEditorFailure(
    context: bun.bindgen.CallContext(OpenInEditorSchema),
    comptime fmt: []const u8,
    values: anytype,
) bun.bindgen.CallError(OpenInEditorSchema)!void {
    const message = try std.fmt.allocPrint(bun.default_allocator, fmt, values);
    defer bun.default_allocator.free(message);
    return context.fail(.operation_failed, try bun.bindgen.DOMString.fromUTF8(message));
}

pub fn getPublicPathWithAssetPrefix(
    allocator: std.mem.Allocator,
    to: string,
    dir: string,
    origin: URL,
    asset_prefix: string,
    comptime platform: bun.path.Platform,
) bun.OOM![]const u8 {
    const relative_path_owned = if (strings.hasPrefix(to, dir)) null else brk: {
        const relative_path = try switch (platform) {
            .posix => std.fs.path.relativePosix(allocator, "/", dir, to),
            .windows, .nt => std.fs.path.relativeWindows(allocator, dir, null, dir, to),
        };
        break :brk relative_path;
    };
    defer if (relative_path_owned) |path| allocator.free(path);
    const relative_path_native = relative_path_owned orelse strings.withoutTrailingSlash(to[dir.len..]);
    var relative_path_buf: bun.PathBuffer = undefined;
    const relative_path = switch (platform) {
        .posix => relative_path_native,
        .windows, .nt => if (relative_path_owned) |path| brk: {
            std.mem.replaceScalar(u8, path, '\\', '/');
            break :brk path;
        } else bun.path.pathToPosixBuf(u8, relative_path_native, &relative_path_buf),
    };
    if (origin.isAbsolute()) {
        if (strings.hasPrefix(relative_path, "..") or strings.hasPrefix(relative_path, "./")) {
            const absolute_path = if (bun.path.Platform.isAbsolute(platform, to)) null else try switch (platform) {
                .posix => std.fs.path.resolvePosix(allocator, &.{ dir, to }),
                .windows, .nt => std.fs.path.resolveWindows(allocator, &.{ dir, to }),
            };
            defer if (absolute_path) |path| allocator.free(path);
            return std.mem.concat(allocator, u8, &.{ origin.origin, "/abs:", absolute_path orelse to });
        } else {
            return origin.joinAlloc(
                allocator,
                asset_prefix,
                "",
                relative_path,
                "",
                to,
            );
        }
    } else {
        return allocator.dupe(u8, std.mem.trimStart(u8, relative_path, "/"));
    }
}

pub fn sleep(
    context: bun.bindgen.CallContext(SleepSchema),
    args: bun.bindgen.Args(SleepSchema),
) bun.bindgen.CallError(SleepSchema)!void {
    var completion = context.completion();
    return api.Timer.All.sleepFromBinding(
        context,
        args.milliseconds,
        completion.take(),
    );
}

pub fn sleepSync(
    context: bun.bindgen.CallContext(SleepSyncSchema),
    args: bun.bindgen.Args(SleepSyncSchema),
) bun.bindgen.CallError(SleepSyncSchema)!void {
    const milliseconds = args.milliseconds;
    if (milliseconds < 0) {
        var message_buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "argument to sleepSync must not be negative, got {d}",
            .{milliseconds},
        ) catch unreachable;
        return context.fail(.negative_milliseconds, try bun.bindgen.DOMString.fromUTF8(message));
    }

    std.Io.sleep(VirtualMachine.get().io, .fromMilliseconds(milliseconds), .awake) catch {};
}

pub fn gc(
    _: bun.bindgen.CallContext(GcSchema),
    args: bun.bindgen.Args(GcSchema),
) bun.JSError!usize {
    return bun.current_runtime.garbageCollect(args.force);
}

fn bindGarbageCollect(
    _: bun.bindgen.CallContext(GarbageCollectSchema),
    args: bun.bindgen.Args(GarbageCollectSchema),
) bun.bindgen.Return(GarbageCollectSchema) {
    return bun.current_runtime.garbageCollect(args.sync);
}

pub fn shrink(
    context: bun.bindgen.CallContext(ShrinkSchema),
    _: bun.bindgen.Args(ShrinkSchema),
) bun.JSError!void {
    bun.current_runtime.shrinkFootprint(context);
}

pub fn resolveString(globalThis: *jsc.JSGlobalObject, specifier: bun.String, from: bun.String, is_esm: bool, comptime is_file_path: bool, is_user_require_resolve: bool) bun.JSError!bun.bindgen.DOMString {
    return bun.bindgen.DOMString.fromBunString(try VirtualMachine.resolveModuleSpecifier(
        globalThis,
        specifier,
        from,
        is_esm,
        is_file_path,
        is_user_require_resolve,
    ));
}

pub fn resolveStringWithPaths(
    globalThis: *jsc.JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    is_esm: bool,
    is_user_require_resolve: bool,
    paths_input: anytype,
) bun.JSError!bun.bindgen.DOMString {
    var fallback_buffer: [4096]u8 = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&fallback_buffer, bun.default_allocator);
    const allocator = fallback.allocator();
    const paths = try allocator.alloc(bun.String, paths_input.len());
    defer allocator.free(paths);
    for (paths, 0..) |*path, index| {
        var owned = paths_input.at(index).?.toOwned();
        path.* = owned.takeBunString();
    }
    defer for (paths) |path| path.deref();
    return bun.bindgen.DOMString.fromBunString(try VirtualMachine.resolveModuleSpecifierWithPaths(
        globalThis,
        specifier,
        source,
        is_esm,
        is_user_require_resolve,
        paths,
    ));
}

pub fn resolveSync(
    context: bun.bindgen.CallContext(ResolveSyncFunctionSchema),
    args: bun.bindgen.Args(ResolveSyncFunctionSchema),
) bun.bindgen.CallError(ResolveSyncFunctionSchema)!bun.bindgen.DOMString {
    const globalThis = context.viewToken().globalObject();
    const specifier_input = args.specifier orelse return context.fail(.missing_specifier, {});
    const from_input = args.from orelse return context.fail(.missing_from, {});
    const is_esm = if (args.isESM) |value| switch (value) {
        .value => |boolean| boolean,
        .invalid => return context.fail(.invalid_esm, {}),
    } else true;

    const converted_specifier = try specifier_input.convert(context);
    const specifier_value = converted_specifier.value orelse return context.fail(.nullish_specifier, {});
    var bound_specifier = specifier_value.toOwned();
    const specifier = bound_specifier.takeBunString();
    defer specifier.deref();

    const converted_from = try from_input.convert(context);
    const from_value = converted_from.value orelse return context.fail(.nullish_from, {});
    var bound_from = from_value.toOwned();
    const from = bound_from.takeBunString();
    defer from.deref();

    return resolveString(globalThis, specifier, from, is_esm, false, false);
}

fn bindResolveSync(
    context: bun.bindgen.CallContext(ResolveSyncSchema),
    args: bun.bindgen.Args(ResolveSyncSchema),
) bun.JSError!bun.bindgen.Return(ResolveSyncSchema) {
    const globalThis = context.viewToken().globalObject();
    var bound_specifier = args.specifier.toOwned();
    defer bound_specifier.deinit();
    const specifier = bound_specifier.takeBunString();
    defer specifier.deref();
    var bound_source = args.source.toOwned();
    defer bound_source.deinit();
    const source = bound_source.takeBunString();
    defer source.deref();

    return resolveString(globalThis, specifier, source, args.isESM, true, args.isUserRequireResolve);
}

fn bindResolveSyncWithPaths(
    context: bun.bindgen.CallContext(ResolveSyncWithPathsSchema),
    args: bun.bindgen.Args(ResolveSyncWithPathsSchema),
) bun.JSError!bun.bindgen.Return(ResolveSyncWithPathsSchema) {
    const globalThis = context.viewToken().globalObject();
    var bound_specifier = args.specifier.toOwned();
    defer bound_specifier.deinit();
    const specifier = bound_specifier.takeBunString();
    defer specifier.deref();
    var bound_source = args.source.toOwned();
    defer bound_source.deinit();
    const source = bound_source.takeBunString();
    defer source.deref();

    return resolveStringWithPaths(globalThis, specifier, source, args.isESM, args.isUserRequireResolve, args.paths);
}

fn bindResolveSyncWithStrings(
    context: bun.bindgen.CallContext(ResolveSyncWithStringsSchema),
    args: bun.bindgen.Args(ResolveSyncWithStringsSchema),
) bun.JSError!bun.bindgen.Return(ResolveSyncWithStringsSchema) {
    const globalThis = context.viewToken().globalObject();
    var bound_specifier = args.specifier.toOwned();
    defer bound_specifier.deinit();
    const specifier = bound_specifier.takeBunString();
    defer specifier.deref();
    var bound_source = args.source.toOwned();
    defer bound_source.deinit();
    const source = bound_source.takeBunString();
    defer source.deref();

    Output.scoped(.importMetaResolve, .visible)("source: {f}, specifier: {f}", .{ source, specifier });
    return resolveString(globalThis, specifier, source, args.isESM, true, false);
}

fn bindResolveSyncWithSource(
    context: bun.bindgen.CallContext(ResolveSyncWithSourceSchema),
    args: bun.bindgen.Args(ResolveSyncWithSourceSchema),
) bun.JSError!bun.bindgen.Return(ResolveSyncWithSourceSchema) {
    const globalThis = context.viewToken().globalObject();
    var bound_specifier = args.specifier.toOwned();
    defer bound_specifier.deinit();
    const specifier = bound_specifier.takeBunString();
    defer specifier.deref();

    var bound_source = args.source.toOwned();
    defer bound_source.deinit();
    const source = bound_source.takeBunString();
    defer source.deref();

    return resolveString(globalThis, specifier, source, args.isESM, true, args.isUserRequireResolve);
}

pub fn indexOfLine(
    context: bun.bindgen.CallContext(IndexOfLineSchema),
    args: bun.bindgen.Args(IndexOfLineSchema),
) bun.JSError!f64 {
    const buffer = args.buffer orelse return -1;
    const lease = switch (buffer) {
        .buffer => |value| value,
        .ignored => return -1,
    };
    const offset: usize = if (args.offset) |offset_input| offset: {
        const forced = try offset_input.convertLast(context);
        try context.lease(forced.proof);
        break :offset @intCast(@max(forced.converted.value, 0));
    } else 0;
    const bytes = lease.unsafePtr("the generated C++ frame owns the byte lease until this synchronous line scan returns");
    const index = std.mem.findScalarPos(u8, bytes, offset, '\n') orelse return -1;
    return @floatFromInt(index);
}

pub const Crypto = @import("../crypto/CryptoEngine.zig");

pub fn nanoseconds(
    _: bun.bindgen.CallContext(NanosecondsSchema),
    _: bun.bindgen.Args(NanosecondsSchema),
) bun.JSError!f64 {
    return @floatFromInt(bun.current_runtime.readOriginTimer());
}

pub fn serve(
    context: bun.bindgen.CallContext(ServeSchema),
    args: bun.bindgen.Args(ServeSchema),
) bun.bindgen.CallError(ServeSchema)!bun.bindgen.Return(ServeSchema) {
    return api.server.serveFromBinding(context, args);
}

fn escapeHTML16(input_slice: []const u16) bun.OOM!bun.bindgen.DOMString {
    assert(input_slice.len > 0);
    const escaped = try strings.escapeHTMLForUTF16Input(bun.default_allocator, input_slice);

    return switch (escaped) {
        .static => |val| bun.bindgen.DOMString.fromLatin1(val),
        .original => bun.bindgen.DOMString.fromUTF16(input_slice),
        .allocated => |escaped_html| allocated: {
            defer bun.default_allocator.free(escaped_html);
            break :allocated bun.bindgen.DOMString.fromUTF16(escaped_html);
        },
    };
}

fn escapeHTML8(input_slice: []const u8) bun.OOM!bun.bindgen.DOMString {
    assert(input_slice.len > 0);
    var stack_allocator_buffer: [256]u8 = undefined;
    var stack_allocator: std.heap.BufferFirstAllocator = .init(&stack_allocator_buffer, bun.default_allocator);
    const allocator = if (input_slice.len <= 32) stack_allocator.allocator() else stack_allocator.fallback_allocator;

    const escaped = try strings.escapeHTMLForLatin1Input(allocator, input_slice);

    switch (escaped) {
        .static => |val| {
            return bun.bindgen.DOMString.fromLatin1(val);
        },
        .original => return bun.bindgen.DOMString.fromLatin1(input_slice),
        .allocated => |escaped_html| {
            defer allocator.free(escaped_html);
            if (comptime Environment.allow_assert) {
                // the output should always be longer than the input
                assert(escaped_html.len > input_slice.len);

                // assert we do not allocate a new string unnecessarily
                assert(
                    !std.mem.eql(
                        u8,
                        input_slice,
                        escaped_html,
                    ),
                );
            }

            return bun.bindgen.DOMString.fromLatin1(escaped_html);
        },
    }
}

fn bindEscapeHTML16(
    _: bun.bindgen.CallContext(EscapeHTMLUTF16Schema),
    args: bun.bindgen.Args(EscapeHTMLUTF16Schema),
) bun.JSError!bun.bindgen.Return(EscapeHTMLUTF16Schema) {
    const data = args.data.unsafePtr("the C++ caller's converted WTF::String owns these UTF-16 units until escapeHTML16 returns");
    return try escapeHTML16(data);
}

fn bindEscapeHTML8(
    _: bun.bindgen.CallContext(EscapeHTMLLatin1Schema),
    args: bun.bindgen.Args(EscapeHTMLLatin1Schema),
) bun.JSError!bun.bindgen.Return(EscapeHTMLLatin1Schema) {
    const data = args.data.unsafePtr("the generated C++ call frame owns this copied Latin-1 buffer until escapeHTML8 returns");
    return try escapeHTML8(data);
}

pub fn allocUnsafe(
    context: bun.bindgen.CallContext(AllocUnsafeSchema),
    args: bun.bindgen.Args(AllocUnsafeSchema),
) bun.JSError!bun.bindgen.Return(AllocUnsafeSchema) {
    return context.engineIn("array_buffers", "createUninitializedUint8Array").call(.{ .length = args.size });
}

pub fn mmapFile(
    context: bun.bindgen.CallContext(MmapSchema),
    args: bun.bindgen.Args(MmapSchema),
) bun.bindgen.CallError(MmapSchema)!bun.bindgen.Return(MmapSchema) {
    if (comptime Environment.isWindows) {
        return context.fail(.unsupported_platform, {});
    }

    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();

    var buf: bun.PathBuffer = undefined;
    const path_input = args.path orelse return context.fail(.invalid_path, {});
    const path_view = switch (path_input) {
        .string => |value| value,
        .invalid => return context.fail(.invalid_path, {}),
    };
    const path_str = try path_view.toUTF8(arena.allocator());
    defer path_str.deinit();
    if (path_str.length() > bun.MAX_PATH_BYTES) return context.fail(.path_too_long, {});
    if (std.mem.indexOfScalar(u8, path_str.slice(), 0) != null) return context.fail(.path_contains_null, {});
    const paths = &[_]string{path_str.slice()};
    const path = bun.path.joinAbsStringBufChecked(bun.fs.FileSystem.instance.top_level_dir, buf[0 .. buf.len - 1], paths, .auto) orelse
        return context.fail(.path_too_long, {});

    buf[path.len] = 0;

    const buf_z: [:0]const u8 = buf[0..path.len :0];

    var flags: std.c.MAP = .{ .TYPE = .SHARED };

    // Conforming applications must specify either MAP_PRIVATE or MAP_SHARED.
    var offset: usize = 0;
    var map_size: ?usize = null;

    if (args.options) |options_input| {
        const converted = try options_input.convert(context);
        switch (converted.value) {
            .options => |opts| {
                if (opts.shared) |shared| flags.TYPE = if (shared) .SHARED else .PRIVATE;

                if (@hasField(std.c.MAP, "SYNC")) {
                    if (opts.sync orelse false) {
                        flags.TYPE = .SHARED_VALIDATE;
                        flags.SYNC = true;
                    }
                }

                if (opts.size) |size_value| {
                    if (size_value < 0) return context.fail(.negative_size, {});
                    map_size = @intCast(size_value);
                }

                if (opts.offset) |offset_value| {
                    if (offset_value < 0) return context.fail(.negative_offset, {});
                    offset = @intCast(offset_value);
                }
            },
            .nulled, .undefined => {},
            .invalid => return context.fail(.invalid_options, {}),
        }
    }

    const map = switch (bun.sys.mmapFile(buf_z, flags, map_size, offset)) {
        .result => |map| map,

        .err => |err| {
            if (err.getErrno() == .NOMEM) return error.OutOfMemory;
            return context.fail(.system, try bun.bindgen.SystemError.fromSysError(err));
        },
    };

    const MappedBytes = struct {
        mapping: bun.sys.FileMapping,

        fn deallocate(_: ?*anyopaque, context_ptr: ?*anyopaque) callconv(.c) void {
            const this: *@This() = @ptrCast(@alignCast(context_ptr orelse
                @panic("mapped bytes deallocator received no context")));
            defer bun.default_allocator.destroy(this);
            this.mapping.deinit();
        }
    };

    const mapped_bytes = bun.default_allocator.create(MappedBytes) catch {
        map.deinit();
        return error.OutOfMemory;
    };
    mapped_bytes.* = .{ .mapping = map };

    const operation = context.engineIn("array_buffers", "uint8ArrayAdoptOwnedBytes");
    const EngineArgs = @TypeOf(operation).Args;
    const Owner = @FieldType(EngineArgs, "owner");
    var engine_args: EngineArgs = .{
        .owner = Owner.initNative(try bun.bindgen.adoptExternalBytesOwner(
            @ptrCast(map.bytes.ptr),
            map.bytes.len,
            @ptrCast(mapped_bytes),
            MappedBytes.deallocate,
        )),
    };
    return try operation.call(&engine_args);
}

pub fn stringWidth(
    context: bun.bindgen.CallContext(StringWidthSchema),
    args: bun.bindgen.Args(StringWidthSchema),
) bun.JSError!usize {
    _ = context;
    if (args.options) |value| switch (value) {
        .options => |width_options| return bun.api.StringEngine.getStringWidth(
            args.input,
            width_options.count_ansi_escape_codes,
            width_options.ambiguous_is_narrow,
        ),
        .ignored => {},
    };
    return bun.api.StringEngine.getStringWidth(args.input, false, true);
}

// This is aliased to Bun.env
pub const EnvironmentVariables = struct {
    fn bindCount(
        _: bun.bindgen.CallContext(EnvironmentVariableCountSchema),
        _: bun.bindgen.Args(EnvironmentVariableCountSchema),
    ) bun.bindgen.Return(EnvironmentVariableCountSchema) {
        return VirtualMachine.get().transpiler.env.map.map.entries.len;
    }

    fn bindKey(
        _: bun.bindgen.CallContext(EnvironmentVariableKeySchema),
        args: bun.bindgen.Args(EnvironmentVariableKeySchema),
    ) bun.JSError!bun.bindgen.Return(EnvironmentVariableKeySchema) {
        const keys = VirtualMachine.get().transpiler.env.map.map.keys();
        if (args.index >= keys.len) return null;
        return try bun.bindgen.DOMString.fromUTF8(keys[args.index]);
    }

    fn bindGet(
        _: bun.bindgen.CallContext(EnvironmentVariableGetSchema),
        args: bun.bindgen.Args(EnvironmentVariableGetSchema),
    ) bun.JSError!bun.bindgen.Return(EnvironmentVariableGetSchema) {
        var name_slice = try args.name.toUTF8(bun.default_allocator);
        defer name_slice.deinit();
        const value = VirtualMachine.get().transpiler.env.get(name_slice.slice()) orelse return null;
        return try bun.bindgen.DOMString.fromUTF8(value);
    }

    fn bindPrepareProxy(
        _: bun.bindgen.CallContext(PrepareProxyEnvironmentVariableSchema),
        args: bun.bindgen.Args(PrepareProxyEnvironmentVariableSchema),
    ) bun.JSError!bun.bindgen.Return(PrepareProxyEnvironmentVariableSchema) {
        var name = try args.name.toUTF8(bun.default_allocator);
        defer name.deinit();
        if (args.value) |input| {
            const value = try input.toUTF8(bun.default_allocator);
            defer value.deinit();
            return .initNative(try VirtualMachine.get().prepareProxyEnvironmentVariable(name.slice(), value.slice()));
        }
        return .initNative(try VirtualMachine.get().prepareProxyEnvironmentVariable(name.slice(), null));
    }

    fn bindFinishProxy(
        args: *bun.bindgen.Args(FinishProxyEnvironmentVariableSchema),
    ) bun.bindgen.Return(FinishProxyEnvironmentVariableSchema) {
        const update = args.update.takeNative();
        bun.assert(update.vm == VirtualMachine.get());
        update.finish(args.commit);
    }
};

pub const JSZlib = struct {
    const Library = enum {
        zlib,
        libdeflate,
    };

    const CompressConfig = struct {
        level: ?i32 = null,
        library: Library = .zlib,
    };

    const DecompressConfig = struct {
        options: zlib.Options,
        library: Library = .zlib,
    };

    fn compressionInput(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        input_argument: anytype,
    ) bun.bindgen.CallError(Schema)!bun.api.node.StringOrBuffer {
        const input = input_argument orelse return context.fail(.missing_input, {});
        const forced = try input.convertLast(context);
        try context.lease(forced.proof);
        return bun.api.node.StringOrBuffer.fromBindgen(forced.converted.value, .utf8);
    }

    fn compressConfig(options_argument: anytype) CompressConfig {
        var config: CompressConfig = .{};
        const input = options_argument orelse return config;
        const resolved_options = input orelse return config;
        if (resolved_options.window_bits != null) config.library = .zlib;
        if (resolved_options.library) |library| {
            config.library = switch (library) {
                .zlib => .zlib,
                .libdeflate => .libdeflate,
            };
        }
        config.level = resolved_options.level;
        return config;
    }

    fn decompressConfig(
        options_argument: anytype,
        is_gzip: bool,
    ) DecompressConfig {
        var config: DecompressConfig = .{
            .options = .{
                .gzip = is_gzip,
                .windowBits = if (is_gzip) 31 else -15,
            },
        };
        const input = options_argument orelse return config;
        const resolved_options = input orelse return config;
        if (resolved_options.window_bits) |window_bits| {
            config.options.windowBits = window_bits;
            config.library = .zlib;
        }
        if (resolved_options.level) |level| config.options.level = level;
        if (resolved_options.memory_level) |memory_level| {
            config.options.memLevel = memory_level;
            config.library = .zlib;
        }
        if (resolved_options.strategy) |strategy| {
            config.options.strategy = strategy;
            config.library = .zlib;
        }
        if (resolved_options.library) |library| {
            config.library = switch (library) {
                .zlib => .zlib,
                .libdeflate => .libdeflate,
            };
        }
        return config;
    }

    pub fn gzipSync(
        context: bun.bindgen.CallContext(GzipSyncSchema),
        args: bun.bindgen.Args(GzipSyncSchema),
    ) bun.bindgen.CallError(GzipSyncSchema)!bun.bindgen.OwnedBytes {
        const config = compressConfig(args.options);
        var buffer = try compressionInput(GzipSyncSchema, context, args.input);
        defer buffer.deinit();
        return gzipOrDeflateSync(GzipSyncSchema, context, buffer.slice(), config, true);
    }

    pub fn inflateSync(
        context: bun.bindgen.CallContext(InflateSyncSchema),
        args: bun.bindgen.Args(InflateSyncSchema),
    ) bun.bindgen.CallError(InflateSyncSchema)!bun.bindgen.OwnedBytes {
        const config = decompressConfig(args.options, false);
        var buffer = try compressionInput(InflateSyncSchema, context, args.input);
        defer buffer.deinit();
        return gunzipOrInflateSync(InflateSyncSchema, context, buffer.slice(), config, false);
    }

    pub fn deflateSync(
        context: bun.bindgen.CallContext(DeflateSyncSchema),
        args: bun.bindgen.Args(DeflateSyncSchema),
    ) bun.bindgen.CallError(DeflateSyncSchema)!bun.bindgen.OwnedBytes {
        const config = compressConfig(args.options);
        var buffer = try compressionInput(DeflateSyncSchema, context, args.input);
        defer buffer.deinit();
        return gzipOrDeflateSync(DeflateSyncSchema, context, buffer.slice(), config, false);
    }

    pub fn gunzipSync(
        context: bun.bindgen.CallContext(GunzipSyncSchema),
        args: bun.bindgen.Args(GunzipSyncSchema),
    ) bun.bindgen.CallError(GunzipSyncSchema)!bun.bindgen.OwnedBytes {
        const config = decompressConfig(args.options, true);
        var buffer = try compressionInput(GunzipSyncSchema, context, args.input);
        defer buffer.deinit();
        return gunzipOrInflateSync(GunzipSyncSchema, context, buffer.slice(), config, true);
    }

    fn zlibInitFailure(context: anytype, err: anyerror) bun.bindgen.CallError(@TypeOf(context)) {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        var message_buffer: [160]u8 = undefined;
        const message = if (err == error.InvalidArgument)
            "Zlib error: Invalid argument"
        else
            std.fmt.bufPrint(&message_buffer, "Zlib error: {s}", .{@errorName(err)}) catch unreachable;
        return context.fail(.operation_failed, try bun.bindgen.DOMString.fromUTF8(message));
    }

    fn gunzipOrInflateSync(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        compressed: []const u8,
        config: DecompressConfig,
        is_gzip: bool,
    ) bun.bindgen.CallError(Schema)!bun.bindgen.OwnedBytes {
        const allocator = bun.default_allocator;

        var list = brk: {
            if (is_gzip and compressed.len > 64) {
                //   0   1   2   3   4   5   6   7
                //  +---+---+---+---+---+---+---+---+
                //  |     CRC32     |     ISIZE     |
                //  +---+---+---+---+---+---+---+---+
                const estimated_size: u32 = @bitCast(compressed[compressed.len - 4 ..][0..4].*);
                // If it's > 256 MB, let's rely on dynamic allocation to minimize the risk of OOM.
                if (estimated_size > 0 and estimated_size < 256 * 1024 * 1024) {
                    break :brk try std.ArrayListUnmanaged(u8).initCapacity(allocator, @max(estimated_size, 64));
                }
            }

            break :brk try std.ArrayListUnmanaged(u8).initCapacity(allocator, if (compressed.len > 512) compressed.len else 32);
        };
        errdefer list.deinit(allocator);

        switch (config.library) {
            .zlib => {
                var reader = zlib.ZlibReaderArrayList.initWithOptions(compressed, &list, allocator, .{
                    .windowBits = config.options.windowBits,
                    .level = config.options.level,
                }) catch |err| return zlibInitFailure(context, err);
                defer reader.deinit();

                reader.readAll(true) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return context.fail(.operation_failed, try bun.bindgen.DOMString.fromUTF8(reader.errorMessage() orelse "Zlib returned an error"));
                };
            },
            .libdeflate => {
                var decompressor: *bun.libdeflate.Decompressor = bun.libdeflate.Decompressor.alloc() orelse {
                    return error.OutOfMemory;
                };
                defer decompressor.deinit();
                while (true) {
                    const result = decompressor.decompress(compressed, list.allocatedSlice(), if (is_gzip) .gzip else .deflate);

                    list.items.len = result.written;

                    if (result.status == .insufficient_space) {
                        if (list.capacity > 1024 * 1024 * 1024) {
                            return error.OutOfMemory;
                        }

                        list.ensureTotalCapacity(allocator, list.capacity * 2) catch {
                            return error.OutOfMemory;
                        };
                        continue;
                    }

                    if (result.status == .success) break;

                    var message_buffer: [160]u8 = undefined;
                    const message = std.fmt.bufPrint(&message_buffer, "libdeflate returned an error: {s}", .{@tagName(result.status)}) catch unreachable;
                    return context.fail(.operation_failed, try bun.bindgen.DOMString.fromUTF8(message));
                }
            },
        }
        return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(try list.toOwnedSlice(allocator));
    }

    fn gzipOrDeflateSync(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        input: []const u8,
        config: CompressConfig,
        is_gzip: bool,
    ) bun.bindgen.CallError(Schema)!bun.bindgen.OwnedBytes {
        const allocator = bun.default_allocator;

        switch (config.library) {
            .zlib => {
                var list = try std.ArrayListUnmanaged(u8).initCapacity(
                    allocator,
                    if (input.len > 512) input.len else 32,
                );
                errdefer list.deinit(allocator);

                var reader = zlib.ZlibCompressorArrayList.init(input, &list, allocator, .{
                    .windowBits = 15,
                    .gzip = is_gzip,
                    .level = config.level orelse 6,
                }) catch |err| return zlibInitFailure(context, err);
                defer reader.deinit();

                reader.readAll() catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    return context.fail(.operation_failed, try bun.bindgen.DOMString.fromUTF8(reader.errorMessage() orelse "Zlib returned an error"));
                };
                return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(try list.toOwnedSlice(allocator));
            },
            .libdeflate => {
                var compressor: *bun.libdeflate.Compressor = bun.libdeflate.Compressor.alloc(config.level orelse 6) orelse {
                    return error.OutOfMemory;
                };
                const encoding: bun.libdeflate.Encoding = if (is_gzip) .gzip else .deflate;
                defer compressor.deinit();

                var list = try std.ArrayListUnmanaged(u8).initCapacity(
                    allocator,
                    compressor.maxBytesNeeded(input, encoding),
                );
                errdefer list.deinit(allocator);

                const result = compressor.compress(input, list.allocatedSlice(), encoding);
                list.items.len = result.written;
                if (result.status != .success) {
                    var message_buffer: [160]u8 = undefined;
                    const message = std.fmt.bufPrint(&message_buffer, "libdeflate error: {s}", .{@tagName(result.status)}) catch unreachable;
                    return context.fail(.operation_failed, try bun.bindgen.DOMString.fromUTF8(message));
                }
                return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(try list.toOwnedSlice(allocator));
            },
        }
    }
};

pub const JSZstd = struct {
    fn level(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        options_argument: anytype,
    ) bun.bindgen.CallError(Schema)!i32 {
        const input = options_argument orelse return 3;
        const resolved_options = input orelse return 3;
        if (comptime @hasField(@TypeOf(resolved_options), "level")) {
            if (resolved_options.level) |value| {
                if (value < 1 or value > 22) return context.fail(.invalid_level, {});
                return value;
            }
        }
        return 3;
    }

    pub fn compressSync(
        context: bun.bindgen.CallContext(ZstdCompressSyncSchema),
        args: bun.bindgen.Args(ZstdCompressSyncSchema),
    ) bun.bindgen.CallError(ZstdCompressSyncSchema)!bun.bindgen.OwnedBytes {
        const compression_level = try level(ZstdCompressSyncSchema, context, args.options);
        var buffer = try JSZlib.compressionInput(ZstdCompressSyncSchema, context, args.input);
        defer buffer.deinit();

        return switch (try compressOwned(buffer.slice(), compression_level)) {
            .success => |output| output,
            .err => |message| context.fail(.operation_failed, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message)),
        };
    }

    const CompressionResult = union(enum) {
        success: bun.bindgen.OwnedBytes,
        err: []const u8,
    };

    fn compressOwned(input: []const u8, compression_level: i32) bun.OOM!CompressionResult {
        const allocator = bun.default_allocator;
        var output = try allocator.alloc(u8, bun.zstd.compressBound(input.len));
        defer allocator.free(output);
        const compressed_size = switch (bun.zstd.compress(output, input, compression_level)) {
            .success => |size| size,
            .out_of_memory => return error.OutOfMemory,
            .err => |message| return .{ .err = message },
        };
        if (compressed_size < output.len) output = try allocator.realloc(output, compressed_size);
        const owned = bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(output);
        output = &.{};
        return .{ .success = owned };
    }

    pub fn decompressSync(
        context: bun.bindgen.CallContext(ZstdDecompressSyncSchema),
        args: bun.bindgen.Args(ZstdDecompressSyncSchema),
    ) bun.bindgen.CallError(ZstdDecompressSyncSchema)!bun.bindgen.OwnedBytes {
        _ = try level(ZstdDecompressSyncSchema, context, args.options);
        var buffer = try JSZlib.compressionInput(ZstdDecompressSyncSchema, context, args.input);
        defer buffer.deinit();

        const allocator = bun.default_allocator;
        const output = bun.zstd.decompressAlloc(allocator, buffer.slice()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const message = try std.fmt.allocPrint(allocator, "Decompression failed: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return context.fail(.operation_failed, try bun.bindgen.ThreadSafeDOMString.fromUTF8(message));
        };
        return bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(output);
    }

    const AsyncInput = union(enum) {
        bytes: bun.bindgen.OwnedBytes,
        string: bun.bindgen.ThreadSafeDOMString,

        fn deinit(input: *AsyncInput) void {
            switch (input.*) {
                inline else => |*value| value.deinit(),
            }
        }
    };

    fn asyncInput(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        input_argument: anytype,
    ) bun.bindgen.CallError(Schema)!AsyncInput {
        const input = input_argument orelse return context.fail(.missing_input, {});
        const converted = try input.convert(context);
        return switch (converted.value) {
            .buffer => |bytes| .{ .bytes = try bytes.toOwned() },
            .string => |text| .{ .string = try text.toOwned() },
        };
    }

    const Mode = enum { compress, decompress };

    fn ZstdJob(comptime Schema: type, comptime mode: Mode) type {
        return struct {
            input: AsyncInput,
            level: if (mode == .compress) i32 else void,
            completion: bun.bindgen.OwnedCompletion(Schema),
            task: bun.BackgroundTaskGroup.Task = .{ .callback = &run, .on_cancel = &cancel },

            const Self = @This();

            pub fn schedule(this: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
                bun.BackgroundWork.schedule(background_tasks, &this.task) catch {
                    this.completion.fail(.concurrency_unavailable, {});
                    this.deinit();
                };
            }

            fn run(task: *bun.BackgroundTaskGroup.Task) void {
                const this: *Self = @fieldParentPtr("task", task);
                defer this.deinit();
                switch (this.input) {
                    .bytes => |*bytes| this.process(bytes.slice()),
                    .string => |*text| {
                        var utf8 = text.toUTF8(bun.default_allocator) catch {
                            this.completion.outOfMemory();
                            return;
                        };
                        defer utf8.deinit();
                        this.process(utf8.slice());
                    },
                }
            }

            fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
                const this: *Self = @fieldParentPtr("task", task);
                this.completion.release();
                this.deinit();
            }

            fn process(this: *Self, input: []const u8) void {
                const output = switch (mode) {
                    .compress => compress: {
                        const result = compressOwned(input, this.level) catch {
                            this.completion.outOfMemory();
                            return;
                        };
                        break :compress switch (result) {
                            .success => |owned| owned,
                            .err => |message| {
                                const owned_message = bun.bindgen.ThreadSafeDOMString.fromUTF8(message) catch {
                                    this.completion.outOfMemory();
                                    return;
                                };
                                this.completion.fail(.operation_failed, owned_message);
                                return;
                            },
                        };
                    },
                    .decompress => bun.bindgen.OwnedBytes.fromDefaultAllocatedSlice(bun.zstd.decompressAlloc(bun.default_allocator, input) catch |err| {
                        switch (err) {
                            error.OutOfMemory => this.completion.outOfMemory(),
                            else => this.completion.fail(.decompression_failed, {}),
                        }
                        return;
                    }),
                };
                this.completion.resolve(output);
            }

            fn deinit(this: *Self) void {
                this.input.deinit();
                bun.default_allocator.destroy(this);
            }
        };
    }

    fn start(
        comptime Schema: type,
        context: bun.bindgen.CallContext(Schema),
        input: AsyncInput,
        comptime mode: Mode,
        compression_level: if (mode == .compress) i32 else void,
    ) void {
        var completion = context.completion();
        const Job = ZstdJob(Schema, mode);
        const job = bun.default_allocator.create(Job) catch {
            var owned_input = input;
            owned_input.deinit();
            completion.outOfMemory();
            return;
        };
        job.* = .{
            .input = input,
            .level = compression_level,
            .completion = completion.take(),
        };
        job.schedule(bun.current_runtime.backgroundTasks());
    }

    pub fn compress(
        context: bun.bindgen.CallContext(ZstdCompressSchema),
        args: bun.bindgen.Args(ZstdCompressSchema),
    ) bun.bindgen.CallError(ZstdCompressSchema)!void {
        const compression_level = try level(ZstdCompressSchema, context, args.options);
        const input = try asyncInput(ZstdCompressSchema, context, args.input);
        start(ZstdCompressSchema, context, input, .compress, compression_level);
    }

    pub fn decompress(
        context: bun.bindgen.CallContext(ZstdDecompressSchema),
        args: bun.bindgen.Args(ZstdDecompressSchema),
    ) bun.bindgen.CallError(ZstdDecompressSchema)!void {
        _ = try level(ZstdDecompressSchema, context, args.options);
        const input = try asyncInput(ZstdDecompressSchema, context, args.input);
        start(ZstdDecompressSchema, context, input, .decompress, {});
    }
};

const string = []const u8;

const Braces = @import("../../shell_parser/braces.zig");
const Open = @import("../../cli/open.zig");
const Which = @import("../../which/which.zig");
const options = @import("../../bundler/options.zig");
const std = @import("std");
const zlib = @import("../../zlib/zlib.zig");
const URL = @import("../../url/url.zig").URL;
const conv = std.builtin.CallingConvention.Unspecified;

const bun = @import("bun");
const Environment = bun.Environment;
const MutableString = bun.MutableString;
const Output = bun.Output;
const assert = bun.assert;
const default_allocator = bun.default_allocator;
const strings = bun.strings;
const BunObjectBindings = bun.bindgen.Module("BunObject");
const ConsoleObjectBindings = bun.bindgen.Module("ConsoleObject");
const BracesSchema = BunObjectBindings.function("braces");
const BracesBinding = bun.bindgen.Fn(BracesSchema, braces);
const GcSchema = BunObjectBindings.function("gc");
const GcBinding = bun.bindgen.Fn(GcSchema, gc);
const NanosecondsSchema = BunObjectBindings.function("nanoseconds");
const NanosecondsBinding = bun.bindgen.Fn(NanosecondsSchema, nanoseconds);
const InspectSchema = BunObjectBindings.function("inspect");
const InspectBinding = bun.bindgen.Fn(InspectSchema, inspect);
const InspectTableSchema = BunObjectBindings.function("inspectTable");
const InspectTableBinding = bun.bindgen.Fn(InspectTableSchema, inspectTable);
const AllocUnsafeSchema = BunObjectBindings.function("allocUnsafe");
const AllocUnsafeBinding = bun.bindgen.Fn(AllocUnsafeSchema, allocUnsafe);
const IndexOfLineSchema = BunObjectBindings.function("indexOfLine");
const IndexOfLineBinding = bun.bindgen.Fn(IndexOfLineSchema, indexOfLine);
const ShellEscapeSchema = BunObjectBindings.function("shellEscape");
const ShellEscapeBinding = bun.bindgen.Fn(ShellEscapeSchema, shellEscape);
const DeepEqualsSchema = BunObjectBindings.function("deepEquals");
const DeepEqualsBinding = bun.bindgen.Fn(DeepEqualsSchema, deepEquals);
const ShrinkSchema = BunObjectBindings.function("shrink");
const ShrinkBinding = bun.bindgen.Fn(ShrinkSchema, shrink);
const SleepSchema = BunObjectBindings.function("sleep");
const SleepBinding = bun.bindgen.Fn(SleepSchema, sleep);
const SleepSyncSchema = BunObjectBindings.function("sleepSync");
const SleepSyncBinding = bun.bindgen.Fn(SleepSyncSchema, sleepSync);
const StringWidthSchema = BunObjectBindings.function("stringWidth");
const StringWidthBinding = bun.bindgen.Fn(StringWidthSchema, stringWidth);
const WhichSchema = BunObjectBindings.function("which");
const WhichBinding = bun.bindgen.Fn(WhichSchema, which);
const MmapSchema = BunObjectBindings.function("mmap");
const MmapBinding = bun.bindgen.Fn(MmapSchema, mmapFile);
const OpenInEditorSchema = BunObjectBindings.function("openInEditor");
const OpenInEditorBinding = bun.bindgen.Fn(OpenInEditorSchema, openInEditor);
const DeflateSyncSchema = BunObjectBindings.function("deflateSync");
const DeflateSyncBinding = bun.bindgen.Fn(DeflateSyncSchema, JSZlib.deflateSync);
const GunzipSyncSchema = BunObjectBindings.function("gunzipSync");
const GunzipSyncBinding = bun.bindgen.Fn(GunzipSyncSchema, JSZlib.gunzipSync);
const GzipSyncSchema = BunObjectBindings.function("gzipSync");
const GzipSyncBinding = bun.bindgen.Fn(GzipSyncSchema, JSZlib.gzipSync);
const InflateSyncSchema = BunObjectBindings.function("inflateSync");
const InflateSyncBinding = bun.bindgen.Fn(InflateSyncSchema, JSZlib.inflateSync);
const ZstdCompressSyncSchema = BunObjectBindings.function("zstdCompressSync");
const ZstdCompressSyncBinding = bun.bindgen.Fn(ZstdCompressSyncSchema, JSZstd.compressSync);
const ZstdDecompressSyncSchema = BunObjectBindings.function("zstdDecompressSync");
const ZstdDecompressSyncBinding = bun.bindgen.Fn(ZstdDecompressSyncSchema, JSZstd.decompressSync);
const ZstdCompressSchema = BunObjectBindings.function("zstdCompress");
const ZstdCompressBinding = bun.bindgen.Fn(ZstdCompressSchema, JSZstd.compress);
const ZstdDecompressSchema = BunObjectBindings.function("zstdDecompress");
const ZstdDecompressBinding = bun.bindgen.Fn(ZstdDecompressSchema, JSZstd.decompress);
const ResolveSyncFunctionSchema = BunObjectBindings.function("resolveSync");
const ResolveSyncFunctionBinding = bun.bindgen.Fn(ResolveSyncFunctionSchema, resolveSync);
const ServeSchema = BunObjectBindings.function("serve");
const ServeBinding = bun.bindgen.Fn(ServeSchema, serve);
const ConnectSchema = BunObjectBindings.function("connect");
const ConnectBinding = bun.bindgen.Fn(ConnectSchema, bindConnect);
const ListenSchema = BunObjectBindings.function("listen");
const ListenBinding = bun.bindgen.Fn(ListenSchema, bindListen);
const ShaSchema = BunObjectBindings.function("sha");
const ShaBinding = bun.bindgen.Fn(ShaSchema, bindSha);
const SpawnSchema = BunObjectBindings.function("spawn");
const SpawnBinding = bun.bindgen.Fn(SpawnSchema, bindSpawn);
const SpawnSyncSchema = BunObjectBindings.function("spawnSync");
const SpawnSyncBinding = bun.bindgen.Fn(SpawnSyncSchema, bindSpawnSync);
const UdpSocketNativeSchema = BunObjectBindings.function("udpSocketNative");
const UdpSocketNativeBinding = bun.bindgen.Fn(UdpSocketNativeSchema, bindUdpSocketNative);
const EnvironmentVariableCountSchema = BunObjectBindings.nativeExport("environmentVariableCount");
const EnvironmentVariableKeySchema = BunObjectBindings.nativeExport("environmentVariableKey");
const EnvironmentVariableGetSchema = BunObjectBindings.nativeExport("environmentVariableGet");
const PrepareProxyEnvironmentVariableSchema = BunObjectBindings.nativeExport("prepareProxyEnvironmentVariable");
const FinishProxyEnvironmentVariableSchema = BunObjectBindings.nativeExport("finishProxyEnvironmentVariable");
const ResolveSyncSchema = BunObjectBindings.nativeExport("resolveSync");
const ResolveSyncWithPathsSchema = BunObjectBindings.nativeExport("resolveSyncWithPaths");
const ResolveSyncWithSourceSchema = BunObjectBindings.nativeExport("resolveSyncWithSource");
const ResolveSyncWithStringsSchema = BunObjectBindings.nativeExport("resolveSyncWithStrings");
const LazyArgvSchema = BunObjectBindings.nativeExport("lazyargv");
const LazyCwdSchema = BunObjectBindings.nativeExport("lazycwd");
const LazyEmbeddedFilesSchema = BunObjectBindings.nativeExport("lazyembeddedFiles");
const LazyEnableANSIColorsSchema = BunObjectBindings.nativeExport("lazyenableANSIColors");
const LazyOriginSchema = BunObjectBindings.nativeExport("lazyorigin");
const LazyS3Schema = BunObjectBindings.nativeExport("lazys3");
const LazyValkeySchema = BunObjectBindings.nativeExport("lazyvalkey");
const MainGetSchema = BunObjectBindings.function("mainGet");
const MainSetSchema = BunObjectBindings.function("mainSet");
const BunStdinCreateSchema = BunObjectBindings.nativeExport("bunStdinCreate");
const BunStderrCreateSchema = BunObjectBindings.nativeExport("bunStderrCreate");
const BunStdoutCreateSchema = BunObjectBindings.nativeExport("bunStdoutCreate");
const EscapeHTMLLatin1Schema = BunObjectBindings.nativeExport("escapeHTMLLatin1");
const EscapeHTMLUTF16Schema = BunObjectBindings.nativeExport("escapeHTMLUTF16");
const InspectSingleLineSchema = ConsoleObjectBindings.nativeExport("inspectSingleLine");
const InspectValueForErrorMessageSchema = ConsoleObjectBindings.nativeExport("inspectValueForErrorMessage");
const GarbageCollectionBindings = bun.bindgen.Module("garbage_collection");
const GarbageCollectSchema = GarbageCollectionBindings.nativeExport("garbageCollect");
const BunStdinCreateBinding = bun.bindgen.Fn(BunStdinCreateSchema, bindBunStdinCreate);
const BunStderrCreateBinding = bun.bindgen.Fn(BunStderrCreateSchema, bindBunStderrCreate);
const BunStdoutCreateBinding = bun.bindgen.Fn(BunStdoutCreateSchema, bindBunStdoutCreate);
const EscapeHTMLLatin1Binding = bun.bindgen.Fn(EscapeHTMLLatin1Schema, bindEscapeHTML8);
const EscapeHTMLUTF16Binding = bun.bindgen.Fn(EscapeHTMLUTF16Schema, bindEscapeHTML16);
const InspectSingleLineBinding = bun.bindgen.Fn(InspectSingleLineSchema, bindInspectSingleLine);
const InspectValueForErrorMessageBinding = bun.bindgen.Fn(InspectValueForErrorMessageSchema, bindInspectValueForErrorMessage);
const GarbageCollectBinding = bun.bindgen.Fn(GarbageCollectSchema, bindGarbageCollect);
const EnvironmentVariableCountBinding = bun.bindgen.Fn(EnvironmentVariableCountSchema, EnvironmentVariables.bindCount);
const EnvironmentVariableKeyBinding = bun.bindgen.Fn(EnvironmentVariableKeySchema, EnvironmentVariables.bindKey);
const EnvironmentVariableGetBinding = bun.bindgen.Fn(EnvironmentVariableGetSchema, EnvironmentVariables.bindGet);
const PrepareProxyEnvironmentVariableBinding = bun.bindgen.Fn(PrepareProxyEnvironmentVariableSchema, EnvironmentVariables.bindPrepareProxy);
const FinishProxyEnvironmentVariableBinding = bun.bindgen.Fn(FinishProxyEnvironmentVariableSchema, EnvironmentVariables.bindFinishProxy);
const ResolveSyncBinding = bun.bindgen.Fn(ResolveSyncSchema, bindResolveSync);
const ResolveSyncWithPathsBinding = bun.bindgen.Fn(ResolveSyncWithPathsSchema, bindResolveSyncWithPaths);
const ResolveSyncWithSourceBinding = bun.bindgen.Fn(ResolveSyncWithSourceSchema, bindResolveSyncWithSource);
const ResolveSyncWithStringsBinding = bun.bindgen.Fn(ResolveSyncWithStringsSchema, bindResolveSyncWithStrings);
const LazyArgvBinding = bun.bindgen.Fn(LazyArgvSchema, bindLazyArgv);
const LazyCwdBinding = bun.bindgen.Fn(LazyCwdSchema, bindLazyCwd);
const LazyEmbeddedFilesBinding = bun.bindgen.Fn(LazyEmbeddedFilesSchema, bindLazyEmbeddedFiles);
const LazyEnableANSIColorsBinding = bun.bindgen.Fn(LazyEnableANSIColorsSchema, bindLazyEnableANSIColors);
const LazyOriginBinding = bun.bindgen.Fn(LazyOriginSchema, bindLazyOrigin);
const LazyS3Binding = bun.bindgen.Fn(LazyS3Schema, bindLazyS3);
const LazyValkeyBinding = bun.bindgen.Fn(LazyValkeySchema, bindLazyValkey);
const MainGetBinding = bun.bindgen.Fn(MainGetSchema, bindMainGet);
const MainSetBinding = bun.bindgen.Fn(MainSetSchema, bindMainSet);

fn bindConnect(
    context: bun.bindgen.CallContext(ConnectSchema),
    args: bun.bindgen.Args(ConnectSchema),
) bun.bindgen.CallError(ConnectSchema)!void {
    try api.Listener.connectForBinding(context, &args.options);
}

fn bindListen(
    context: bun.bindgen.CallContext(ListenSchema),
    args: bun.bindgen.Args(ListenSchema),
) bun.bindgen.CallError(ListenSchema)!bun.bindgen.Return(ListenSchema) {
    return try api.Listener.listenForBinding(context, &args.options);
}

fn bindSha(
    context: bun.bindgen.CallContext(ShaSchema),
    args: bun.bindgen.Args(ShaSchema),
) bun.bindgen.CallError(ShaSchema)!bun.bindgen.Return(ShaSchema) {
    const input = args.input orelse
        return context.fail(.missing_input, {});
    return Crypto.SHA512_256.hashBound(context, input, args.output);
}

fn bindSpawn(
    context: bun.bindgen.CallContext(SpawnSchema),
    args: bun.bindgen.Args(SpawnSchema),
) bun.bindgen.CallError(SpawnSchema)!bun.bindgen.Return(SpawnSchema) {
    return try api.Subprocess.spawn(context, args);
}

fn bindSpawnSync(
    context: bun.bindgen.CallContext(SpawnSyncSchema),
    args: bun.bindgen.Args(SpawnSyncSchema),
) bun.bindgen.CallError(SpawnSyncSchema)!bun.bindgen.Return(SpawnSyncSchema) {
    return try api.Subprocess.spawnSync(context, args);
}

fn bindUdpSocketNative(
    context: bun.bindgen.CallContext(UdpSocketNativeSchema),
    args: bun.bindgen.Args(UdpSocketNativeSchema),
) bun.bindgen.CallError(UdpSocketNativeSchema)!bun.bindgen.Return(UdpSocketNativeSchema) {
    return api.UDPSocket.createForBinding(context, &args.options);
}

fn bindLazyArgv(
    context: bun.bindgen.CallContext(LazyArgvSchema),
    _: bun.bindgen.Args(LazyArgvSchema),
) bun.JSError!bun.bindgen.Return(LazyArgvSchema) {
    return bun.current_runtime.createProcessArgv(context);
}

fn bindLazyCwd(
    _: bun.bindgen.CallContext(LazyCwdSchema),
    _: bun.bindgen.Args(LazyCwdSchema),
) bun.JSError!bun.bindgen.Return(LazyCwdSchema) {
    return loadCwd();
}

fn bindLazyEmbeddedFiles(
    context: bun.bindgen.CallContext(LazyEmbeddedFilesSchema),
    _: bun.bindgen.Args(LazyEmbeddedFilesSchema),
) bun.JSError!bun.bindgen.Return(LazyEmbeddedFilesSchema) {
    return loadEmbeddedFiles(context);
}

fn bindLazyEnableANSIColors(
    _: bun.bindgen.CallContext(LazyEnableANSIColorsSchema),
    _: bun.bindgen.Args(LazyEnableANSIColorsSchema),
) bun.bindgen.Return(LazyEnableANSIColorsSchema) {
    return Output.enable_ansi_colors_stdout or Output.enable_ansi_colors_stderr;
}

fn bindLazyOrigin(
    _: bun.bindgen.CallContext(LazyOriginSchema),
    _: bun.bindgen.Args(LazyOriginSchema),
) bun.JSError!bun.bindgen.Return(LazyOriginSchema) {
    return loadOrigin();
}

fn bindLazyS3(
    context: bun.bindgen.CallContext(LazyS3Schema),
    _: bun.bindgen.Args(LazyS3Schema),
) bun.JSError!bun.bindgen.Return(LazyS3Schema) {
    return WebCore.S3Client.default(context);
}

fn bindLazyValkey(
    context: bun.bindgen.CallContext(LazyValkeySchema),
    _: bun.bindgen.Args(LazyValkeySchema),
) bun.bindgen.CallError(LazyValkeySchema)!bun.bindgen.Return(LazyValkeySchema) {
    return api.Valkey.default(context);
}

fn bindMainGet(
    context: bun.bindgen.CallContext(MainGetSchema),
    args: bun.bindgen.Args(MainGetSchema),
) bun.JSError!bun.bindgen.Return(MainGetSchema) {
    _ = args;
    return jsc.ModuleRunMainOperations.MainEntry.get(context);
}

fn bindMainSet(
    _: bun.bindgen.CallContext(MainSetSchema),
    args: bun.bindgen.Args(MainSetSchema),
) bun.JSError!bun.bindgen.Return(MainSetSchema) {
    return jsc.ModuleRunMainOperations.MainEntry.set(args);
}

fn bindBunStdinCreate(
    context: bun.bindgen.CallContext(BunStdinCreateSchema),
    _: bun.bindgen.Args(BunStdinCreateSchema),
) bun.JSError!bun.bindgen.Return(BunStdinCreateSchema) {
    return createStdioBlob(context, .stdin);
}

fn bindBunStderrCreate(
    context: bun.bindgen.CallContext(BunStderrCreateSchema),
    _: bun.bindgen.Args(BunStderrCreateSchema),
) bun.JSError!bun.bindgen.Return(BunStderrCreateSchema) {
    return createStdioBlob(context, .stderr);
}

fn bindBunStdoutCreate(
    context: bun.bindgen.CallContext(BunStdoutCreateSchema),
    _: bun.bindgen.Args(BunStdoutCreateSchema),
) bun.JSError!bun.bindgen.Return(BunStdoutCreateSchema) {
    return createStdioBlob(context, .stdout);
}

const StdioBlob = enum { stdin, stderr, stdout };

fn createStdioBlob(context: anytype, comptime stream: StdioBlob) bun.JSError!bun.bindgen.Return(@TypeOf(context)) {
    const rare_data = VirtualMachine.get().rareData();
    const store = try rare_data.stdio(switch (stream) {
        .stdin => .std_in,
        .stderr => .std_err,
        .stdout => .std_out,
    });
    store.ref();
    var value = try bun.webcore.Blob.initWithStore(store);
    defer value.deinit();
    const blob = try bun.webcore.Blob.new(&value);
    return blob.toBindingRef(context);
}

comptime {
    @setEvalBranchQuota(100_000);
    _ = BracesBinding;
    _ = GcBinding;
    _ = NanosecondsBinding;
    _ = InspectBinding;
    _ = InspectTableBinding;
    _ = AllocUnsafeBinding;
    _ = IndexOfLineBinding;
    _ = ShellEscapeBinding;
    _ = DeepEqualsBinding;
    _ = ShrinkBinding;
    _ = SleepBinding;
    _ = SleepSyncBinding;
    _ = StringWidthBinding;
    _ = WhichBinding;
    _ = MmapBinding;
    _ = OpenInEditorBinding;
    _ = DeflateSyncBinding;
    _ = GunzipSyncBinding;
    _ = GzipSyncBinding;
    _ = InflateSyncBinding;
    _ = ZstdCompressSyncBinding;
    _ = ZstdDecompressSyncBinding;
    _ = ZstdCompressBinding;
    _ = ZstdDecompressBinding;
    _ = ResolveSyncFunctionBinding;
    _ = ServeBinding;
    _ = ConnectBinding;
    _ = ListenBinding;
    _ = ShaBinding;
    _ = SpawnBinding;
    _ = SpawnSyncBinding;
    _ = UdpSocketNativeBinding;
    _ = BunStdinCreateBinding;
    _ = BunStderrCreateBinding;
    _ = BunStdoutCreateBinding;
    _ = EscapeHTMLLatin1Binding;
    _ = EscapeHTMLUTF16Binding;
    _ = InspectSingleLineBinding;
    _ = InspectValueForErrorMessageBinding;
    _ = GarbageCollectBinding;
    _ = EnvironmentVariableCountBinding;
    _ = EnvironmentVariableKeyBinding;
    _ = EnvironmentVariableGetBinding;
    _ = PrepareProxyEnvironmentVariableBinding;
    _ = FinishProxyEnvironmentVariableBinding;
    _ = ResolveSyncBinding;
    _ = ResolveSyncWithPathsBinding;
    _ = ResolveSyncWithSourceBinding;
    _ = ResolveSyncWithStringsBinding;
    _ = LazyArgvBinding;
    _ = LazyCwdBinding;
    _ = LazyEmbeddedFilesBinding;
    _ = LazyEnableANSIColorsBinding;
    _ = LazyOriginBinding;
    _ = LazyS3Binding;
    _ = LazyValkeyBinding;
    _ = MainGetBinding;
    _ = MainSetBinding;
}

const api = bun.api;
const node = bun.api.node;

const jsc = bun.jsc;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const VirtualMachine = jsc.VirtualMachine;
const WebCore = bun.jsc.WebCore;

const JSBundler = bun.jsc.API.JSBundler;
