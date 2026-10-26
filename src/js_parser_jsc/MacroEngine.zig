const BindingEscape = bun.bindgen.Escape(@This());
pub const context_factory: Transpiler.MacroContextFactory = .{ .create = initContext };

fn initContext(transpiler: *Transpiler) bun.OOM!*js_ast.Macro.Context {
    const state = try transpiler.allocator.create(MacroContext);
    state.* = MacroContext.init(transpiler);
    return @ptrCast(&state.header);
}

fn destroyContext(context: *js_ast.Macro.Context) void {
    const state = contextState(context);
    const allocator = state.allocator;
    allocator.destroy(state);
}

fn setJavascriptObject(context: *js_ast.Macro.Context, root: *const bun.bindgen.Root) void {
    contextState(context).javascript_object = root;
}

fn contextState(context: *js_ast.Macro.Context) *MacroContext {
    const header: *js_ast.Macro.Context.Header = @ptrCast(@alignCast(context));
    return @fieldParentPtr("header", header);
}

fn contextStateConst(context: *const js_ast.Macro.Context) *const MacroContext {
    const header: *const js_ast.Macro.Context.Header = @ptrCast(@alignCast(context));
    return @fieldParentPtr("header", header);
}

fn contextGetRemap(context: *const js_ast.Macro.Context, path: string) ?MacroRemapEntry {
    return contextStateConst(context).getRemap(path);
}

fn contextCall(
    opaque_context: *js_ast.Macro.Context,
    allocator: std.mem.Allocator,
    import_record_path: string,
    source_dir: string,
    log: *logger.Log,
    source: *const logger.Source,
    import_range: logger.Range,
    caller: Expr,
    function_name: string,
) anyerror!Expr {
    const context = contextState(opaque_context);
    return context.call(allocator, import_record_path, source_dir, log, source, import_range, caller, function_name);
}

const context_operations: js_ast.Macro.Context.Operations = .{
    .destroy = destroyContext,
    .get_remap = contextGetRemap,
    .set_javascript_object = setJavascriptObject,
    .call = contextCall,
};

const MacroContext = struct {
    header: js_ast.Macro.Context.Header = .{ .operations = &context_operations },
    allocator: std.mem.Allocator,
    resolver: *Resolver,
    io: std.Io,
    env: *DotEnv.Loader,
    remap: MacroRemap,
    javascript_object: ?*const bun.bindgen.Root = null,

    pub fn getRemap(this: MacroContext, path: string) ?MacroRemapEntry {
        if (this.remap.entries.len == 0) return null;
        return this.remap.get(path);
    }

    pub fn init(transpiler: *Transpiler) MacroContext {
        return MacroContext{
            .allocator = transpiler.allocator,
            .resolver = &transpiler.resolver,
            .io = transpiler.io,
            .env = transpiler.env,
            .remap = transpiler.options.macro_remap,
        };
    }

    pub fn call(
        this: *MacroContext,
        allocator: std.mem.Allocator,
        import_record_path: string,
        source_dir: string,
        log: *logger.Log,
        source: *const logger.Source,
        import_range: logger.Range,
        caller: Expr,
        function_name: string,
    ) anyerror!Expr {
        const expr_reset_disabled = Expr.Data.Store.disable_reset;
        const stmt_reset_disabled = Stmt.Data.Store.disable_reset;
        Expr.Data.Store.disable_reset = true;
        Stmt.Data.Store.disable_reset = true;
        defer Expr.Data.Store.disable_reset = expr_reset_disabled;
        defer Stmt.Data.Store.disable_reset = stmt_reset_disabled;
        const import_record_path_without_macro_prefix = if (js_ast.Macro.isMacroPath(import_record_path))
            import_record_path[js_ast.Macro.namespaceWithColon.len..]
        else
            import_record_path;

        bun.assert(!js_ast.Macro.isMacroPath(import_record_path_without_macro_prefix));

        const resolved_specifier = brk: {
            if (jsc.ModuleLoader.HardcodedModule.Alias.get(import_record_path, .bun, .{})) |replacement| {
                break :brk replacement.path;
            }

            const resolve_result = this.resolver.resolve(source_dir, import_record_path_without_macro_prefix, .stmt) catch |err| {
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.ModuleNotFound => {
                        try log.addResolveError(
                            source,
                            import_range,
                            log.msgs.allocator,
                            "Macro \"{s}\" not found",
                            .{import_record_path},
                            .stmt,
                            err,
                        );
                        return error.MacroNotFound;
                    },
                    else => {
                        try log.addRangeErrorFmt(
                            source,
                            import_range,
                            log.msgs.allocator,
                            "{s} resolving macro \"{s}\"",
                            .{ @errorName(err), import_record_path },
                        );
                        return err;
                    },
                }
            };
            break :brk resolve_result.path_pair.primary.text;
        };
        const input_specifier = try this.allocator.dupe(u8, resolved_specifier);
        defer this.allocator.free(input_specifier);

        const vm = try Macro.ensureVM(this.io, this.resolver, log, this.env);
        defer Output.flush();

        const macro_mode = vm.enterMacroMode();
        defer macro_mode.deinit();
        vm.eventLoop().ensureWaker();

        const Wrapper = struct {
            args: std.meta.ArgsTuple(@TypeOf(Macro.loadAndRun)),
            ret: anyerror!Expr,

            pub fn call(self: *@This()) void {
                self.ret = @call(.auto, Macro.loadAndRun, self.args);
            }
        };
        var wrapper = Wrapper{
            .args = .{
                vm,
                input_specifier,
                log,
                allocator,
                function_name,
                caller,
                source,
                import_range,
                this.javascript_object,
            },
            .ret = undefined,
        };

        vm.runWithAPILock(Wrapper, &wrapper, Wrapper.call);
        if (vm.macro_configuration != null and vm.log != log) try vm.log.appendTo(log);
        return try wrapper.ret;
    }
};

const ImportScope = struct {
    path: string,
    previous: ?*ImportScope,

    threadlocal var active: ?*ImportScope = null;

    fn enter(this: *ImportScope, path: string) bool {
        var current = active;
        while (current) |scope| : (current = scope.previous) {
            if (strings.eql(scope.path, path)) return false;
        }
        this.* = .{ .path = path, .previous = active };
        active = this;
        return true;
    }

    fn exit(this: *ImportScope) void {
        bun.assert(active == this);
        active = this.previous;
    }
};

const Macro = struct {
    vm: *JavaScript.VirtualMachine,
    callback: MacroCallback,

    fn ensureVM(
        io: std.Io,
        resolver: *Resolver,
        log: *logger.Log,
        env: *DotEnv.Loader,
    ) !*JavaScript.VirtualMachine {
        return if (JavaScript.VirtualMachine.isLoaded())
            JavaScript.VirtualMachine.get()
        else brk: {
            jsc.initialize(false);

            break :brk try JavaScript.VirtualMachine.initMacro(.{
                .io = io,
                .pinned_threads = bun.cli.Cli.pinnedThreads(),
                .args = resolver.opts.transform_options,
                .log = log,
                .environment = env,
            });
        };
    }

    fn loadAndRun(
        vm: *JavaScript.VirtualMachine,
        input_specifier: string,
        log: *logger.Log,
        allocator: std.mem.Allocator,
        function_name: string,
        caller: Expr,
        source: *const logger.Source,
        import_range: logger.Range,
        javascript_object: ?*const bun.bindgen.Root,
    ) !Expr {
        var macro = load(vm, input_specifier, function_name, log, source, import_range) catch |err|
            return reportCallFailure(vm, log, source, caller.loc, err);
        defer macro.callback.deinit();
        return Runner.run(&macro, log, allocator, function_name, caller, source, javascript_object) catch |err|
            return reportCallFailure(vm, log, source, caller.loc, err);
    }

    fn reportCallFailure(vm: *JavaScript.VirtualMachine, log: *logger.Log, source: *const logger.Source, loc: logger.Loc, err: anyerror) anyerror {
        if (err != error.JSError) return err;
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(vm.global);
        defer scope.deinit();
        const thrown = scope.takeThrownException(error.JSError) catch |failure| return failure;
        reportFailureValue(&scope, thrown.operand(&scope), log, source, loc) catch |failure| return failure;
        return error.MacroFailed;
    }

    fn reportFailureValue(scope: anytype, value: bun.bindgen.EngineOperand, log: *logger.Log, source: *const logger.Source, loc: logger.Loc) bun.JSError!void {
        var text = scope.engineIn("js_strings", "stringFromJS").call(.{ .value = value }) catch |err| switch (err) {
            error.OutOfMemory, error.JSTerminated => return err,
            error.JSError => {
                _ = try scope.takeThrownException(err);
                try log.addError(source, loc, "Macro failed with a value that could not be formatted");
                return;
            },
        };
        defer text.deinit();
        const utf8 = try text.toUTF8(default_allocator);
        defer utf8.deinit();
        try log.addErrorFmt(source, loc, default_allocator, "Macro failed: {s}", .{utf8.slice()});
    }

    fn load(
        vm: *JavaScript.VirtualMachine,
        input_specifier: string,
        function_name: string,
        log: *logger.Log,
        source: *const logger.Source,
        import_range: logger.Range,
    ) !Macro {
        var import_scope: ImportScope = undefined;
        if (!import_scope.enter(input_specifier)) {
            try log.addRangeErrorFmt(source, import_range, log.msgs.allocator, "Macro \"{s}\" was called before its module finished loading", .{input_specifier});
            return error.MacroLoadError;
        }
        defer import_scope.exit();
        try vm.transpiler.configureDefines();
        var scope: bun.bindgen.FocusedEngineScope = undefined;
        scope.init(vm.global);
        defer scope.deinit();
        var module_name = try bun.bindgen.DOMString.fromUTF8(input_specifier);
        defer module_name.deinit();
        const imported = try scope.engine(LoadAndEvaluateModuleShim).call(.{ .moduleName = module_name.operand() });
        var promise = try imported.toOwned();
        defer promise.deinit();
        if (try scope.waitForPromiseRejection(promise.operand(&scope).asPromise())) |rejected| {
            var failure = rejected;
            defer failure.deinit();
            try reportFailureValue(&scope, failure.operand(&scope), log, source, import_range.loc);
            return error.MacroFailed;
        }
        var export_name = try bun.bindgen.DOMString.fromUTF8(function_name);
        defer export_name.deinit();

        return .{
            .vm = vm,
            .callback = try (try scope.engine(GetMacroExportShim).call(.{ .loadedModule = promise.operand(&scope), .exportName = export_name.operand() })).toOwned(),
        };
    }

    pub const Runner = struct {
        const Visit = struct {
            root: bun.bindgen.Root,
            state: union(enum) {
                converting,
                converted: Expr,
            },
        };
        const VisitMap = std.AutoHashMapUnmanaged(jsc.JSValue, Visit);

        pub const MacroError = error{ MacroFailed, OutOfMemory } || ToJSError || bun.JSError;

        pub const Run = struct {
            caller: Expr,
            function_name: string,
            macro: *const Macro,
            global: *jsc.JSGlobalObject,
            allocator: std.mem.Allocator,
            log: *logger.Log,
            source: *const logger.Source,
            visited: VisitMap = VisitMap{},
            stack_check: bun.StackCheck,
            macro_invocation: *MacroCallback.Invocation,

            pub fn runAsync(
                macro: *const Macro,
                invocation: *MacroCallback.Invocation,
                log: *logger.Log,
                allocator: std.mem.Allocator,
                function_name: string,
                caller: Expr,
                args: *const bun.bindgen.RetainedArguments,
                javascript_object: ?*const bun.bindgen.Root,
                source: *const logger.Source,
            ) MacroError!Expr {
                var inline_arguments: [8]bun.bindgen.AnyOperand = undefined;
                const roots = args.values();
                const argument_count = std.math.add(usize, roots.len, @intFromBool(javascript_object != null)) catch return error.OutOfMemory;
                const arguments: []bun.bindgen.AnyOperand = if (argument_count <= inline_arguments.len)
                    inline_arguments[0..argument_count]
                else
                    try allocator.alloc(bun.bindgen.AnyOperand, argument_count);
                defer if (arguments.ptr != inline_arguments[0..].ptr) allocator.free(arguments);
                for (roots, arguments[0..roots.len]) |*value, *argument| {
                    argument.* = value.operand(invocation);
                }
                if (javascript_object) |value| arguments[roots.len] = value.operand(invocation);
                const result = try invocation.call(.{ .arguments = arguments });

                var runner = Run{
                    .caller = caller,
                    .function_name = function_name,
                    .macro = macro,
                    .allocator = allocator,
                    .global = invocation.viewToken().globalObject(),
                    .log = log,
                    .source = source,
                    .visited = VisitMap{},
                    .stack_check = .init(),
                    .macro_invocation = invocation,
                };

                defer {
                    var visited = runner.visited.valueIterator();
                    while (visited.next()) |entry| entry.root.deinit();
                    runner.visited.deinit(allocator);
                }

                return try runner.run(
                    result,
                );
            }

            pub fn run(
                this: *Run,
                input: bun.bindgen.EngineValueResult,
            ) MacroError!Expr {
                if (!this.stack_check.isSafeToRecurse()) return this.global.throwStackOverflow();
                const value = input.operand(this.macro_invocation).asEngine();
                const tag = (try jsc.ConsoleObject.Formatter.Tag.get(value, this.global)).tag;
                const track_identity = switch (tag) {
                    .Array, .Object, .Private, .Promise => true,
                    else => false,
                };
                if (track_identity) {
                    if (try this.beginVisit(value)) |cached| return cached;
                }
                const result = try switch (tag) {
                    .Error => this.coerce(value, .Error),
                    .Undefined => this.coerce(value, .Undefined),
                    .Null => this.coerce(value, .Null),
                    .Private => this.coerce(value, .Private),
                    .Boolean => this.coerce(value, .Boolean),
                    .Array => this.coerce(value, .Array),
                    .Object => this.coerce(value, .Object),
                    .toJSON, .JSON => this.coerce(value, .JSON),
                    .Integer => this.coerce(value, .Integer),
                    .Double => this.coerce(value, .Double),
                    .String => this.coerce(value, .String),
                    .Promise => this.coerce(value, .Promise),
                    else => brk: {
                        const name = try value.getClassInfoName();
                        defer if (name) |owned| owned.deref();

                        try this.log.addErrorFmt(
                            this.source,
                            this.caller.loc,
                            this.allocator,
                            "cannot coerce {s} ({s}) to Bun's AST. Please return a simpler type",
                            .{ if (name) |owned| owned.byteSlice() else "unknown", @tagName(value.jsType()) },
                        );
                        break :brk error.MacroFailed;
                    },
                };
                if (track_identity) this.visited.getPtr(BindingEscape.rawCallScopedValue(value, value.engineView())).?.state = .{ .converted = result };
                return result;
            }

            fn beginVisit(this: *Run, value: bun.bindgen.EngineOperand) MacroError!?Expr {
                if (this.visited.get(BindingEscape.rawCallScopedValue(value, value.engineView()))) |visited| {
                    switch (visited.state) {
                        .converted => |expr| return expr,
                        .converting => {
                            try this.log.addError(
                                this.source,
                                this.caller.loc,
                                "Cannot convert a circular macro result to Bun's AST",
                            );
                            return error.MacroFailed;
                        },
                    }
                }
                var root = try value.asAny().toRoot();
                errdefer root.deinit();
                try this.visited.put(this.allocator, BindingEscape.rawCallScopedValue(value, value.engineView()), .{ .root = root, .state = .converting });
                return null;
            }

            fn coerceBlob(this: *Run, blob: *jsc.WebCore.Blob) MacroError!Expr {
                return Expr.fromBytes(
                    blob.sharedView(),
                    blob.contentType(),
                    this.allocator,
                    null,
                    this.log,
                    this.caller.loc,
                ) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.MacroFailed,
                };
            }

            pub fn coerce(
                this: *Run,
                value: bun.bindgen.EngineOperand,
                comptime tag: jsc.ConsoleObject.Formatter.Tag,
            ) MacroError!Expr {
                switch (comptime tag) {
                    .Error => {
                        const failure_scope = this.macro_invocation;
                        try reportFailureValue(failure_scope, value, this.log, this.source, this.caller.loc);
                        return error.MacroFailed;
                    },
                    .Undefined => return Expr.init(E.Undefined, E.Undefined{}, this.caller.loc),
                    .Null => return Expr.init(E.Null, E.Null{}, this.caller.loc),
                    .Private => {
                        if (value.jsType() == .DOMWrapper) {
                            if (try jsc.WebCore.Response.Binding.tryCast(BindingEscape.rawCallScopedValue(this.macro_invocation, value.engineView()), this.global)) |response_handle_value| {
                                var response_handle = response_handle_value;
                                defer response_handle.deinit();
                                var promise = try response_handle.get().getBlobWithoutWrapper(this.global);
                                defer promise.deinit();
                                return this.run(promise.operand(this.macro_invocation).asEngine().engineView().toResult());
                            } else if (try jsc.WebCore.Request.Binding.tryCast(BindingEscape.rawCallScopedValue(this.macro_invocation, value.engineView()), this.global)) |request_handle_value| {
                                var request_handle = request_handle_value;
                                defer request_handle.deinit();
                                var promise = try request_handle.get().getBlobWithoutWrapper(this.global);
                                defer promise.deinit();
                                return this.run(promise.operand(this.macro_invocation).asEngine().engineView().toResult());
                            } else if (try jsc.WebCore.Blob.BlobClass.tryCast(BindingEscape.rawCallScopedValue(this.macro_invocation, value.engineView()), this.global)) |handle| {
                                var blob_handle = handle;
                                defer blob_handle.deinit();
                                return this.coerceBlob(blob_handle.get().native());
                            } else if (try jsc.API.BuildArtifact.Binding.tryCast(BindingEscape.rawCallScopedValue(this.macro_invocation, value.engineView()), this.global)) |handle| {
                                var artifact_handle = handle;
                                defer artifact_handle.deinit();
                                return this.coerceBlob(&artifact_handle.get().blob);
                            } else if (bun.api.ResolveMessage.Binding.isInstance(BindingEscape.rawCallScopedValue(this.macro_invocation, value.engineView())) or bun.api.BuildMessage.Binding.isInstance(BindingEscape.rawCallScopedValue(this.macro_invocation, value.engineView()))) {
                                const failure_scope = this.macro_invocation;
                                try reportFailureValue(failure_scope, value, this.log, this.source, this.caller.loc);
                                return error.MacroFailed;
                            }
                        }
                    },

                    .Boolean => {
                        return Expr{ .data = .{ .e_boolean = .{ .value = value.toBoolean() } }, .loc = this.caller.loc };
                    },
                    jsc.ConsoleObject.Formatter.Tag.Array => {
                        var iter = try value.arrayIterator();
                        defer iter.deinit();
                        const scope = this.macro_invocation;

                        // Process all array items
                        var array = try ExprNodeList.initCapacity(this.allocator, iter.len);
                        errdefer array.clearAndFree(this.allocator);
                        const expr = Expr.init(
                            E.Array,
                            E.Array{ .items = ExprNodeList.empty, .was_originally_macro = true },
                            this.caller.loc,
                        );
                        while (try iter.next(scope)) |item_result| {
                            const element = try this.run(item_result);
                            if (!element.isMissing()) try array.append(this.allocator, element);
                        }

                        expr.data.e_array.items = array;
                        return expr;
                    },
                    jsc.ConsoleObject.Formatter.Tag.Object => {
                        const expr = Expr.init(
                            E.Object,
                            E.Object{ .properties = G.Property.List{}, .was_originally_macro = true },
                            this.caller.loc,
                        );
                        const property_scope = this.macro_invocation;
                        var object_root = try value.toRoot();
                        defer object_root.deinit();
                        var object_iter = try jsc.JSPropertyIterator(.{
                            .skip_empty_name = false,
                        }).init(property_scope, &object_root);
                        defer object_iter.deinit();

                        // Build properties list
                        var properties = try G.Property.List.initCapacity(this.allocator, object_iter.len);
                        errdefer properties.clearAndFree(this.allocator);

                        while (try object_iter.next(property_scope)) |entry_value| {
                            var entry = entry_value;
                            const prop = entry.name.takeBunString();
                            defer prop.deref();
                            const object_value = try this.run(entry.value);

                            try properties.append(this.allocator, G.Property{
                                .key = Expr.init(
                                    E.String,
                                    E.String.init(try prop.toOwnedSlice(this.allocator)),
                                    this.caller.loc,
                                ),
                                .value = object_value,
                            });
                        }

                        expr.data.e_object.properties = properties;

                        return expr;
                    },

                    .JSON => {},

                    .Integer => {
                        return Expr.init(E.Number, E.Number{ .value = @as(f64, @floatFromInt(value.toInt32())) }, this.caller.loc);
                    },
                    .Double => {
                        return Expr.init(E.Number, E.Number{ .value = value.asNumber() }, this.caller.loc);
                    },
                    .String => {
                        var bun_str = try value.toBunString();
                        defer bun_str.deref();

                        // encode into utf16 so the printer escapes the string correctly
                        const utf16_bytes = try this.allocator.alloc(u16, bun_str.length());
                        if (bun_str.isUTF16()) {
                            @memcpy(utf16_bytes, bun_str.utf16());
                        } else {
                            for (bun_str.latin1(), utf16_bytes) |unit, *out| out.* = unit;
                        }
                        return Expr.init(E.String, E.String.init(utf16_bytes), this.caller.loc);
                    },
                    .Promise => {
                        const scope = this.macro_invocation;
                        const promise_value = (try scope.engineIn("promises", "jsValueAsPromise").call(.{
                            .value = value,
                        })) orelse @panic("Macro promise classification disagrees with its brand");
                        var promise = try promise_value.toOwned();
                        defer promise.deinit();
                        if (try scope.waitForPromiseRejection(promise.operand(scope).asPromise())) |rejected| {
                            var failure = rejected;
                            defer failure.deinit();
                            try reportFailureValue(scope, failure.operand(scope), this.log, this.source, this.caller.loc);
                            return error.MacroFailed;
                        }
                        const result = (try scope.engineIn("promises", "promiseResult").call(.{ .promise = promise.operand(scope) })) orelse
                            @panic("Settled macro promise has no result");
                        return this.run(result);
                    },
                    else => {},
                }

                try this.log.addErrorFmt(
                    this.source,
                    this.caller.loc,
                    this.allocator,
                    "cannot coerce {s} to Bun's AST. Please return a simpler type",
                    .{@tagName(value.jsType())},
                );
                return error.MacroFailed;
            }
        };

        pub fn run(
            macro: *const Macro,
            log: *logger.Log,
            allocator: std.mem.Allocator,
            function_name: string,
            caller: Expr,
            source: *const logger.Source,
            javascript_object: ?*const bun.bindgen.Root,
        ) MacroError!Expr {
            if (comptime Environment.isDebug) Output.prettyln("<r><d>[macro]<r> call <d><b>{s}<r>", .{function_name});

            var invocation: MacroCallback.Invocation = undefined;
            macro.callback.beginInvocation(&invocation);
            defer invocation.deinit();
            const globalObject = invocation.viewToken().globalObject();

            switch (caller.data) {
                .e_call => |call| {
                    const call_args: []Expr = call.args.slice();
                    var builder = try bun.bindgen.RetainedArguments.Builder.init(allocator, call_args.len);
                    defer builder.deinit();
                    for (call_args) |in| {
                        var value = try ExpressionEngine.toOwnedValue(in, allocator, globalObject);
                        builder.appendOwned(value.takeAnyRoot());
                    }
                    var js_args = builder.finish();
                    defer js_args.deinit();

                    const CallFunction = @TypeOf(Run.runAsync);
                    const CallArgs = std.meta.ArgsTuple(CallFunction);
                    const CallData = struct {
                        pub fn callWrapper(args: CallArgs) MacroError!Expr {
                            return @call(.auto, Run.runAsync, args);
                        }
                    };

                    return CallData.callWrapper(.{
                        macro,
                        &invocation,
                        log,
                        allocator,
                        function_name,
                        caller,
                        &js_args,
                        javascript_object,
                        source,
                    });
                },
                .e_template => {
                    try log.addError(source, caller.loc, "Tagged template macros are not supported");
                    return error.MacroFailed;
                },
                else => {
                    @panic("Unexpected caller type");
                },
            }

            unreachable;
        }
    };
};

const string = []const u8;

const DotEnv = @import("../dotenv/env_loader.zig");
const std = @import("std");
const ExpressionEngine = @import("./ExpressionEngine.zig");

const MacroRemap = @import("../resolver/package_json.zig").MacroMap;
const MacroRemapEntry = @import("../resolver/package_json.zig").MacroImportReplacementMap;

const Resolver = @import("../resolver/resolver.zig").Resolver;
const isPackagePath = @import("../resolver/resolver.zig").isPackagePath;

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const Transpiler = bun.Transpiler;
const default_allocator = bun.default_allocator;
const logger = bun.logger;
const strings = bun.strings;
const Loader = bun.options.Loader;
const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const LoadAndEvaluateModuleShim = ModuleLoaderBindings.engineShim("loadAndEvaluateModule");
const GetMacroExportShim = ModuleLoaderBindings.engineShim("getMacroExport");
const MacroCallback = bun.bindgen.Callback(GetMacroExportShim.ReturnType);

const js_ast = bun.ast;
const E = js_ast.E;
const Expr = js_ast.Expr;
const ExprNodeList = js_ast.ExprNodeList;
const G = js_ast.G;
const S = js_ast.S;
const Stmt = js_ast.Stmt;
const ToJSError = js_ast.ToJSError;

const JavaScript = bun.jsc;
const jsc = bun.jsc;
