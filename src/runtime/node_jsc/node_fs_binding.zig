pub fn WithFS(comptime fs: type, comptime Engine: type) type {
    return struct {
        const AsyncCore = @import("../node/NodeFSAsync.zig");
        const CopyCore = @import("../node/NodeFSCopy.zig");
        const RecursiveReaddirCore = @import("../node/NodeFSRecursiveReaddir.zig");

        pub const AsyncRuntime = AsyncCore.Runtime;
        pub const functionNeedsIo = AsyncCore.functionNeedsIo;

        fn materializeStats(comptime Result: type, stats: *const fs.Return.Fstat) Result {
            const Value = switch (@typeInfo(Result)) {
                .optional => |optional| optional.child,
                else => Result,
            };
            const result: Value = switch (stats.*) {
                .big => .{ .bigint_stats = stats.big.toResult(@FieldType(Value, "bigint_stats")) },
                .small => .{ .stats = stats.small.toResult(@FieldType(Value, "stats")) },
            };
            return result;
        }

        fn materializeOptionalStats(comptime Result: type, value: *const fs.StatOrNotFound) Result {
            return switch (value.*) {
                .stats => |*stats| materializeStats(@typeInfo(Result).optional.child, stats),
                .not_found => null,
            };
        }

        fn materializeStatFs(comptime Result: type, statfs: *const fs.Return.StatFS) Result {
            return switch (statfs.*) {
                .big => .{ .bigint_statfs = statfs.big.toResult(@FieldType(Result, "bigint_statfs")) },
                .small => .{ .statfs = statfs.small.toResult(@FieldType(Result, "statfs")) },
            };
        }

        fn materializeDirents(comptime Sequence: type, values: anytype) bun.OOM!Sequence {
            var result = try Sequence.Builder.init(values.len);
            errdefer result.deinit();
            for (values) |*value| result.appendOwned(try value.toResult(Sequence.Element));
            return result.finish();
        }

        fn materializeBuffers(comptime Sequence: type, values: anytype) bun.OOM!Sequence {
            const Element = Sequence.Element;
            var result = try Sequence.Builder.init(values.len);
            errdefer result.deinit();
            for (values) |*value| {
                result.appendOwned(switch (value.*) {
                    .borrowed => |bytes| try Element.fromSlice(bytes),
                    .owned => |bytes| transferred: {
                        value.* = .empty;
                        break :transferred Element.fromDefaultAllocatedSlice(bytes);
                    },
                });
            }
            return result.finish();
        }

        fn materializeReaddir(comptime Result: type, value: *fs.Return.Readdir) bun.OOM!Result {
            defer value.deinit();
            return switch (value.*) {
                .with_file_types => |items| .{ .dirents = try materializeDirents(@FieldType(Result, "dirents"), items) },
                .buffers => |items| .{ .buffers = try materializeBuffers(@FieldType(Result, "buffers"), items) },
                .files => |items| .{ .files = try @FieldType(Result, "files").fromBunStrings(items) },
            };
        }

        fn materializeStringOrBuffer(comptime Result: type, value: *fs.Return.ReadFile) bun.OOM!Result {
            defer {
                value.deinit();
                value.* = .empty;
            }
            return switch (value.*) {
                inline .string, .threadsafe_string => |*owned_string| result: {
                    if (owned_string.underlying.tag != .Dead) {
                        const owned = owned_string.underlying;
                        owned_string.underlying = bun.String.empty;
                        break :result .{ .string = try bindgen.DOMString.fromBunString(owned) };
                    }
                    break :result .{ .string = try bindgen.DOMString.fromUTF8(owned_string.utf8.slice()) };
                },
                .encoded_slice => |*encoded| .{ .string = try bindgen.DOMString.fromUTF8(encoded.slice()) },
                .buffer => |*buffer| .{
                    .buffer = switch (buffer.*) {
                        .borrowed => |bytes| try bindgen.OwnedBytes.fromSlice(bytes),
                        .owned => |bytes| transferred: {
                            buffer.* = .empty;
                            break :transferred bindgen.OwnedBytes.fromDefaultAllocatedSlice(bytes);
                        },
                    },
                },
                .binding_lease => .{ .buffer = try bindgen.OwnedBytes.fromSlice(value.slice()) },
            };
        }

        fn materializeSuccess(
            comptime FunctionSchema: type,
            value: anytype,
        ) bun.OOM!bindgen.Return(FunctionSchema) {
            const Native = @TypeOf(value.*);
            const Result = bindgen.Return(FunctionSchema);
            if (Native == void) return;
            if (Native == fs.Return.Access) return false; // The schema materializes this marker as null.
            if (Native == bool) return value.*;
            if (Native == fs.Return.Open) return value.uv();
            if (Native == fs.Return.Read or Native == fs.Return.Readv) return value.bytes_read;
            if (Native == fs.Return.Write or Native == fs.Return.Writev) return value.bytes_written;
            if (Native == fs.Return.Fstat) return materializeStats(Result, value);
            if (Native == fs.StatOrNotFound) return materializeOptionalStats(Result, value);
            if (Native == fs.Return.StatFS) return materializeStatFs(Result, value);
            if (Native == fs.Return.Readdir) return materializeReaddir(Result, value);
            if (Native == fs.StringOrUndefined) return switch (value.*) {
                .string => |*owned_string| result: {
                    const owned = owned_string.*;
                    owned_string.* = bun.String.empty;
                    break :result try bindgen.DOMString.fromBunString(owned);
                },
                .none => null,
            };
            if (Native == fs.Return.Mkdtemp) {
                const owned = value.string;
                value.string = bun.String.empty;
                return .{ .string = try bindgen.DOMString.fromBunString(owned) };
            }
            if (Native == fs.Return.ReadFile) return materializeStringOrBuffer(Result, value);
            @compileError("unsupported typed Node.js fs result: " ++ @typeName(Native));
        }

        fn AsyncTask(
            comptime FunctionSchema: type,
            comptime ReturnType: type,
            comptime ArgumentType: type,
            comptime function: NodeFSFunctionEnum,
        ) type {
            return struct {
                completion: Completion.Owned,
                work: Work,
                result_consumed: bool = false,

                const Self = @This();
                const cancelable = ArgumentType != void and @hasField(ArgumentType, "abort");
                const staged_read = function == .read or function == .readv;
                const staged_io = staged_read or function == .writev;
                const Attachment = if (staged_io) ArgumentType.Attachment else if (cancelable) Engine.AbortAttachment else void;
                const WorkArgs = if (staged_io) ArgumentType.Async else ArgumentType;
                const Work = AsyncCore.Work(fs, ReturnType, WorkArgs, function, Self, "work");

                const CompletionOps = struct {
                    pub const materialize = if (Attachment == void) materializeWithoutAttachment else materializeWithAttachment;

                    fn materializeWithoutAttachment(
                        comptime Schema: type,
                        context: bindgen.MaterializationContext(Schema),
                        task: *Self,
                    ) bindgen.MaterializationError(Schema)!bindgen.Return(Schema) {
                        return materializeWithAttachment(Schema, context, {}, task);
                    }

                    fn materializeWithAttachment(
                        comptime Schema: type,
                        context: bindgen.MaterializationContext(Schema),
                        attachment: if (Attachment == void) void else *Attachment,
                        task: *Self,
                    ) bindgen.MaterializationError(Schema)!bindgen.Return(Schema) {
                        if (comptime cancelable) {
                            if (try Engine.abortError(context, attachment)) |abort_error| {
                                var error_value = abort_error;
                                defer error_value.deinit();
                                var reason = try error_value.toRoot();
                                return context.reject(&reason, .{});
                            }
                        }
                        return switch (task.work.result) {
                            .err => |err| failure: {
                                task.result_consumed = true;
                                break :failure context.fail(.system, err);
                            },
                            .out_of_memory => error.OutOfMemory,
                            .result => |*result| result: {
                                if (comptime staged_read) attachment.deliver(&task.work.args, result.bytes_read);
                                task.result_consumed = true;
                                break :result materializeSuccess(Schema, result);
                            },
                        };
                    }

                    pub const destroyPayload = Self.deinit;

                    pub fn destroyAttachment(attachment: *Attachment) void {
                        if (comptime staged_read)
                            attachment.deinit()
                        else if (comptime cancelable)
                            Engine.destroyAbortAttachment(attachment);
                    }
                };

                pub const Completion = bindgen.MaterializedCompletion(
                    FunctionSchema,
                    Self,
                    Attachment,
                    CompletionOps,
                );

                pub fn create(
                    node_fs: *fs.NodeFS,
                    args: WorkArgs,
                    runtime: AsyncCore.Runtime,
                    completion: Completion.Owned,
                ) void {
                    var work = Work.init(args, runtime.io);
                    const task = bun.default_allocator.create(Self) catch {
                        work.deinit(false);
                        var owned_completion = completion;
                        owned_completion.outOfMemory();
                        return;
                    };
                    task.* = .{
                        .completion = completion,
                        .work = work,
                    };
                    task.work.schedule(runtime.background_tasks, node_fs) catch {
                        task.work.deinit(false);
                        task.completion.outOfMemory();
                        bun.destroy(task);
                    };
                }

                pub fn schedule(
                    args: WorkArgs,
                    runtime: AsyncCore.Runtime,
                    completion: Completion.Owned,
                ) void {
                    if (comptime AsyncCore.requiresNodeFSForSchedule(function)) {
                        @compileError("this NodeFS task requires a persistent NodeFS instance while scheduling");
                    }
                    var node_fs: fs.NodeFS = .{};
                    Self.create(&node_fs, args, runtime, completion);
                }

                pub fn finish(task: *Self) void {
                    task.completion.complete(task);
                }

                pub fn cancel(task: *Self) void {
                    task.completion.release();
                    task.work.deinit(false);
                    bun.destroy(task);
                }

                fn deinit(task: *Self) void {
                    task.work.deinit(task.result_consumed);
                    bun.destroy(task);
                }
            };
        }

        fn AsyncCpTask(comptime FunctionSchema: type) type {
            return struct {
                completion: Completion.Owned,
                work: *Work,

                const Self = @This();
                const Work = CopyCore.AsyncTask(Hooks);

                const Hooks = struct {
                    owner: *Self,

                    pub fn onCopy(_: *Hooks, _: anytype, _: anytype) void {}

                    pub fn finish(hooks: *Hooks, _: anytype) void {
                        hooks.owner.completion.complete(hooks.owner);
                    }

                    pub fn cancel(hooks: *Hooks) bool {
                        hooks.owner.completion.release();
                        bun.destroy(hooks.owner);
                        return false;
                    }
                };

                const CompletionOps = struct {
                    pub fn materialize(
                        comptime Schema: type,
                        context: bindgen.MaterializationContext(Schema),
                        task: *Self,
                    ) bindgen.MaterializationError(Schema)!bindgen.Return(Schema) {
                        if (task.work.out_of_memory) return error.OutOfMemory;
                        return switch (task.work.result) {
                            .err => |err| context.fail(.system, try bindgen.SystemError.fromSysError(err)),
                            .result => {},
                        };
                    }

                    pub fn destroyPayload(task: *Self) void {
                        task.work.deinit();
                        bun.destroy(task);
                    }

                };

                pub const Completion = bindgen.MaterializedCompletion(FunctionSchema, Self, void, CompletionOps);

                pub fn create(
                    _: *fs.NodeFS,
                    args: fs.Arguments.Cp,
                    runtime: AsyncCore.Runtime,
                    completion: Completion.Owned,
                ) void {
                    const task = bun.default_allocator.create(Self) catch {
                        args.deinit();
                        var owned_completion = completion;
                        owned_completion.outOfMemory();
                        return;
                    };
                    task.* = .{ .completion = completion, .work = undefined };
                    task.work = Work.init(
                        args.toCopyArguments(),
                        runtime.background_tasks,
                        runtime.io,
                        null,
                        .{ .owner = task },
                    ) catch {
                        task.completion.outOfMemory();
                        bun.destroy(task);
                        return;
                    };
                    task.work.schedule();
                }
            };
        }

        fn AsyncRecursiveReaddirTask(comptime FunctionSchema: type) type {
            return struct {
                completion: Completion.Owned,
                work: Work,

                const Self = @This();
                const Work = RecursiveReaddirCore.Work(fs, Self, "work");

                const CompletionOps = struct {
                    pub fn materialize(
                        comptime Schema: type,
                        context: bindgen.MaterializationContext(Schema),
                        task: *Self,
                    ) bindgen.MaterializationError(Schema)!bindgen.Return(Schema) {
                        if (task.work.out_of_memory.load(.monotonic)) return error.OutOfMemory;
                        if (bun.take(&task.work.pending_err)) |err| {
                            return context.fail(.system, err);
                        }
                        var result = try task.work.takeResult();
                        return materializeSuccess(Schema, &result);
                    }

                    pub fn destroyPayload(task: *Self) void {
                        task.work.deinit();
                        bun.destroy(task);
                    }

                };

                pub const Completion = bindgen.MaterializedCompletion(FunctionSchema, Self, void, CompletionOps);

                pub fn create(
                    args: fs.Arguments.Readdir,
                    runtime: AsyncCore.Runtime,
                    completion: Completion.Owned,
                ) void {
                    var work = Work.init(args, runtime) catch {
                        var owned_completion = completion;
                        owned_completion.outOfMemory();
                        return;
                    };
                    const task = bun.default_allocator.create(Self) catch {
                        work.deinit();
                        var owned_completion = completion;
                        owned_completion.outOfMemory();
                        return;
                    };
                    task.* = .{
                        .completion = completion,
                        .work = work,
                    };
                    task.work.schedule() catch {
                        task.work.deinit();
                        task.completion.outOfMemory();
                        bun.destroy(task);
                    };
                }

                pub fn finish(task: *Self) void {
                    task.completion.complete(task);
                }

                pub fn cancel(task: *Self) void {
                    task.completion.release();
                    task.work.deinit();
                    bun.destroy(task);
                }
            };
        }

        pub const Async = struct {
            pub const access = AsyncTask(NodeJSFSSchema.member("access"), fs.Return.Access, fs.Arguments.Access, .access);
            pub const appendFile = AsyncTask(NodeJSFSSchema.member("appendFile"), fs.Return.AppendFile, fs.Arguments.AppendFile, .appendFile);
            pub const chmod = AsyncTask(NodeJSFSSchema.member("chmod"), fs.Return.Chmod, fs.Arguments.Chmod, .chmod);
            pub const chown = AsyncTask(NodeJSFSSchema.member("chown"), fs.Return.Chown, fs.Arguments.Chown, .chown);
            pub const close = AsyncTask(NodeJSFSSchema.member("close"), fs.Return.Close, fs.Arguments.Close, .close);
            pub const copyFile = AsyncTask(NodeJSFSSchema.member("copyFile"), fs.Return.CopyFile, fs.Arguments.CopyFile, .copyFile);
            pub const cp = AsyncCpTask(NodeJSFSSchema.member("cp"));
            pub const exists = AsyncTask(NodeJSFSSchema.member("exists"), fs.Return.Exists, fs.Arguments.Exists, .exists);
            pub const fchmod = AsyncTask(NodeJSFSSchema.member("fchmod"), fs.Return.Fchmod, fs.Arguments.FChmod, .fchmod);
            pub const fchown = AsyncTask(NodeJSFSSchema.member("fchown"), fs.Return.Fchown, fs.Arguments.Fchown, .fchown);
            pub const fdatasync = AsyncTask(NodeJSFSSchema.member("fdatasync"), fs.Return.Fdatasync, fs.Arguments.FdataSync, .fdatasync);
            pub const fstat = AsyncTask(NodeJSFSSchema.member("fstat"), fs.Return.Fstat, fs.Arguments.Fstat, .fstat);
            pub const fsync = AsyncTask(NodeJSFSSchema.member("fsync"), fs.Return.Fsync, fs.Arguments.Fsync, .fsync);
            pub const ftruncate = AsyncTask(NodeJSFSSchema.member("ftruncate"), fs.Return.Ftruncate, fs.Arguments.FTruncate, .ftruncate);
            pub const futimes = AsyncTask(NodeJSFSSchema.member("futimes"), fs.Return.Futimes, fs.Arguments.Futimes, .futimes);
            pub const lchmod = AsyncTask(NodeJSFSSchema.member("lchmod"), fs.Return.Lchmod, fs.Arguments.LCHmod, .lchmod);
            pub const lchown = AsyncTask(NodeJSFSSchema.member("lchown"), fs.Return.Lchown, fs.Arguments.LChown, .lchown);
            pub const link = AsyncTask(NodeJSFSSchema.member("link"), fs.Return.Link, fs.Arguments.Link, .link);
            pub const lstat = AsyncTask(NodeJSFSSchema.member("lstat"), fs.Return.Stat, fs.Arguments.Stat, .lstat);
            pub const lutimes = AsyncTask(NodeJSFSSchema.member("lutimes"), fs.Return.Lutimes, fs.Arguments.Lutimes, .lutimes);
            pub const mkdir = AsyncTask(NodeJSFSSchema.member("mkdir"), fs.Return.Mkdir, fs.Arguments.Mkdir, .mkdir);
            pub const mkdtemp = AsyncTask(NodeJSFSSchema.member("mkdtemp"), fs.Return.Mkdtemp, fs.Arguments.MkdirTemp, .mkdtemp);
            pub const open = AsyncTask(NodeJSFSSchema.member("open"), fs.Return.Open, fs.Arguments.Open, .open);
            pub const read = AsyncTask(NodeJSFSSchema.member("read"), fs.Return.Read, fs.Arguments.Read, .read);
            pub const readdir = AsyncTask(NodeJSFSSchema.member("readdir"), fs.Return.Readdir, fs.Arguments.Readdir, .readdir);
            pub const readdir_recursive = AsyncRecursiveReaddirTask(NodeJSFSSchema.member("readdir"));
            pub const readFile = AsyncTask(NodeJSFSSchema.member("readFile"), fs.Return.ReadFile, fs.Arguments.ReadFile, .readFile);
            pub const readlink = AsyncTask(NodeJSFSSchema.member("readlink"), fs.Return.Readlink, fs.Arguments.Readlink, .readlink);
            pub const readv = AsyncTask(NodeJSFSSchema.member("readv"), fs.Return.Readv, fs.Arguments.Readv, .readv);
            pub const realpath = AsyncTask(NodeJSFSSchema.member("realpathNative"), fs.Return.Realpath, fs.Arguments.Realpath, .realpath);
            pub const realpathNonNative = AsyncTask(NodeJSFSSchema.member("realpath"), fs.Return.Realpath, fs.Arguments.Realpath, .realpathNonNative);
            pub const rename = AsyncTask(NodeJSFSSchema.member("rename"), fs.Return.Rename, fs.Arguments.Rename, .rename);
            pub const rm = AsyncTask(NodeJSFSSchema.member("rm"), fs.Return.Rm, fs.Arguments.Rm, .rm);
            pub const rmdir = AsyncTask(NodeJSFSSchema.member("rmdir"), fs.Return.Rmdir, fs.Arguments.Rmdir, .rmdir);
            pub const stat = AsyncTask(NodeJSFSSchema.member("stat"), fs.Return.Stat, fs.Arguments.Stat, .stat);
            pub const statfs = AsyncTask(NodeJSFSSchema.member("statfs"), fs.Return.StatFS, fs.Arguments.StatFS, .statfs);
            pub const symlink = AsyncTask(NodeJSFSSchema.member("symlink"), fs.Return.Symlink, fs.Arguments.Symlink, .symlink);
            pub const truncate = AsyncTask(NodeJSFSSchema.member("truncate"), fs.Return.Truncate, fs.Arguments.Truncate, .truncate);
            pub const unlink = AsyncTask(NodeJSFSSchema.member("unlink"), fs.Return.Unlink, fs.Arguments.Unlink, .unlink);
            pub const utimes = AsyncTask(NodeJSFSSchema.member("utimes"), fs.Return.Utimes, fs.Arguments.Utimes, .utimes);
            pub const write = AsyncTask(NodeJSFSSchema.member("write"), fs.Return.Write, fs.Arguments.Write, .write);
            pub const writeFile = AsyncTask(NodeJSFSSchema.member("writeFile"), fs.Return.WriteFile, fs.Arguments.WriteFile, .writeFile);
            pub const writev = AsyncTask(NodeJSFSSchema.member("writev"), fs.Return.Writev, fs.Arguments.Writev, .writev);

            pub fn materializedStat(comptime FunctionSchema: type) type {
                return AsyncTask(FunctionSchema, fs.Return.Stat, fs.Arguments.Stat, .stat);
            }

            pub fn materializedFstat(comptime FunctionSchema: type) type {
                return AsyncTask(FunctionSchema, fs.Return.Fstat, fs.Arguments.Fstat, .fstat);
            }

            pub fn materializedUnlink(comptime FunctionSchema: type) type {
                return AsyncTask(FunctionSchema, fs.Return.Unlink, fs.Arguments.Unlink, .unlink);
            }
        };

        fn NodeFSFunction(comptime method_name: []const u8) type {
            const MethodSchema = NodeJSFSSchema.member(method_name);
            return fn (
                this: *Binding,
                context: bindgen.CallContext(MethodSchema),
                args: bindgen.Args(MethodSchema),
            ) bindgen.CallError(MethodSchema)!bindgen.Return(MethodSchema);
        }

        fn NodeFSAsyncFunction(comptime method_name: []const u8) type {
            const MethodSchema = NodeJSFSSchema.member(method_name);
            return fn (
                this: *Binding,
                context: bindgen.CallContext(MethodSchema),
                args: bindgen.Args(MethodSchema),
            ) bindgen.CallError(MethodSchema)!void;
        }

        const NodeFSFunctionEnum = std.meta.DeclEnum(fs.NodeFS);
        const ReadFileOptions = bindgen.UnionMemberType(
            NodeJSFSSchema.member("readFile").args[1].ArgumentType,
            "options",
        );
        const AbortSignalType = bindgen.DictionaryFieldType(ReadFileOptions, "signal");
        const AbortSignalView = bindgen.ArgumentType(AbortSignalType);

        fn abortSignalView(comptime Arguments: type, method_args: anytype) ?AbortSignalView {
            if (comptime Arguments != fs.Arguments.ReadFile and Arguments != fs.Arguments.WriteFile) return null;
            const options = method_args.options orelse return null;
            return switch (options) {
                .options => |values| values.signal,
                .encoding => null,
            };
        }

        fn typedArgumentsFromBindgen(
            comptime Arguments: type,
            comptime asynchronous: bool,
            context: anytype,
            method_args: anytype,
        ) bun.bindgen.CallError(@TypeOf(context))!Arguments {
            if (comptime Arguments == void) return {};
            if (comptime Arguments == fs.Arguments.Read or Arguments == fs.Arguments.Write) {
                return switch (try Arguments.fromBindgen(method_args)) {
                    .value => |value| value,
                    .validation_error => |validation_error| return failArgumentValidation(context, validation_error),
                };
            }
            var result = try Arguments.fromBindgen(method_args);
            if (comptime !asynchronous and (Arguments == fs.Arguments.ReadFile or Arguments == fs.Arguments.WriteFile)) {
                if (abortSignalView(Arguments, method_args)) |signal| {
                    result.abort = .initSnapshot(Engine.abortSignalAborted(signal));
                }
            }
            return result;
        }

        fn failArgumentValidation(
            context: anytype,
            validation_error: fs.Arguments.ValidationError,
        ) bun.bindgen.CallError(@TypeOf(context)) {
            return switch (validation_error) {
                .invalid_argument_value => |message| context.fail(
                    .invalid_argument_value,
                    try bindgen.ThreadSafeDOMString.fromUTF8(message),
                ),
                .out_of_range => |range| {
                    var message_buffer: [512]u8 = undefined;
                    const message = switch (range.value) {
                        .float => |value| std.fmt.bufPrint(
                            &message_buffer,
                            "{f}",
                            .{bun.fmt.outOfRange(value, range.options)},
                        ) catch unreachable,
                        .signed => |value| std.fmt.bufPrint(
                            &message_buffer,
                            "{f}",
                            .{bun.fmt.outOfRange(value, range.options)},
                        ) catch unreachable,
                        .unsigned => |value| std.fmt.bufPrint(
                            &message_buffer,
                            "{f}",
                            .{bun.fmt.outOfRange(@as(f64, @floatFromInt(value)), range.options)},
                        ) catch unreachable,
                    };
                    return context.fail(.out_of_range, try bindgen.ThreadSafeDOMString.fromUTF8(message));
                },
            };
        }

        /// Returns bindings for a NodeFS function.
        /// Async calls use a thread pool.
        pub fn Bindings(comptime function_name: NodeFSFunctionEnum, comptime method_name: []const u8) type {
            const function = @field(fs.NodeFS, @tagName(function_name));
            const fn_info = @typeInfo(@TypeOf(function)).@"fn";
            if (fn_info.param_types.len != 3) {
                @compileError("Expected fn(NodeFS, Arguments) Return for NodeFS." ++ @tagName(function_name));
            }
            const Arguments = fn_info.param_types[1].?;
            const FunctionResult = fn_info.return_type.?;
            const returns_error = @typeInfo(FunctionResult) == .error_union;
            const MethodSchema = NodeJSFSSchema.member(method_name);
            const has_abort_signal = Arguments == fs.Arguments.ReadFile or Arguments == fs.Arguments.WriteFile;

            const Shared = struct {
                fn invokeSync(
                    node_fs: *fs.NodeFS,
                    context: bindgen.CallContext(MethodSchema),
                    args: Arguments,
                ) bindgen.CallError(MethodSchema)!bindgen.Return(MethodSchema) {
                    var result = if (comptime returns_error)
                        try function(node_fs, args, .sync)
                    else
                        function(node_fs, args, .sync);
                    return switch (result) {
                        .err => |err| context.fail(.system, try bindgen.SystemError.fromSysError(err)),
                        .result => |*value| materializeSuccess(MethodSchema, value),
                    };
                }
            };

            if (Arguments != void and !@hasDecl(Arguments, "fromBindgen")) {
                @compileError("typed Node.js fs arguments must implement fromBindgen: " ++ method_name);
            }
            return struct {
                pub const node_fs_function = function_name;

                pub const SyncInput = struct {
                    node_fs: *fs.NodeFS,
                    args: Arguments,
                };

                pub const StartInput = struct {
                    node_fs: *fs.NodeFS,
                    args: Arguments,
                    signal: if (has_abort_signal) ?AbortSignalView else void,
                };

                pub fn runSync(
                    this: *Binding,
                    context: bindgen.CallContext(MethodSchema),
                    method_args: bindgen.Args(MethodSchema),
                ) bindgen.CallError(MethodSchema)!bindgen.Return(MethodSchema) {
                    var args = try typedArgumentsFromBindgen(Arguments, false, context, method_args);

                    defer if (comptime Arguments != void and @hasDecl(Arguments, "deinit"))
                        args.deinit();

                    if (comptime AsyncCore.functionNeedsIo(function_name, false)) {
                        return runSyncWithIo(bun.current_runtime.io(), context, SyncInput{
                            .node_fs = this.node_fs.get(),
                            .args = args,
                        });
                    }
                    return Shared.invokeSync(this.node_fs.get(), context, args);
                }

                fn runSyncWithIo(
                    io: std.Io,
                    context: bindgen.CallContext(MethodSchema),
                    input: SyncInput,
                ) bindgen.CallError(MethodSchema)!bindgen.Return(MethodSchema) {
                    const previous_io = input.node_fs.runtime_io;
                    input.node_fs.runtime_io = io;
                    defer input.node_fs.runtime_io = previous_io;
                    return Shared.invokeSync(input.node_fs, context, input.args);
                }

                pub fn runAsync(
                    this: *Binding,
                    context: bindgen.CallContext(MethodSchema),
                    method_args: bindgen.Args(MethodSchema),
                ) bindgen.CallError(MethodSchema)!void {
                    var args = try typedArgumentsFromBindgen(Arguments, true, context, method_args);
                    var owns_args = true;

                    defer if (comptime Arguments != void and @hasDecl(Arguments, "deinit")) {
                        if (owns_args) args.deinit();
                    };

                    if (comptime has_abort_signal) check_early_abort: {
                        const signal = abortSignalView(Arguments, method_args) orelse break :check_early_abort;
                        if (try Engine.abortErrorFromView(context, signal)) |abort_error| {
                            var error_value = abort_error;
                            defer error_value.deinit();
                            var reason = try error_value.toRoot();
                            var view = context.completion();
                            view.reject(&reason, .{ .attach_async_stack = true });
                            return;
                        }
                    }

                    owns_args = false;
                    const runtime: AsyncCore.Runtime = .{
                        .background_tasks = bun.current_runtime.backgroundTasks(),
                        .io = if (comptime AsyncCore.functionNeedsIo(function_name, true)) bun.current_runtime.io() else null,
                    };
                    return startAsyncWithRuntime(runtime, context, StartInput{
                        .node_fs = this.node_fs.get(),
                        .args = args,
                        .signal = if (comptime has_abort_signal) abortSignalView(Arguments, method_args) else {},
                    });
                }

                fn startAsyncWithRuntime(
                    runtime: AsyncCore.Runtime,
                    context: bindgen.CallContext(MethodSchema),
                    input: StartInput,
                ) bindgen.CallError(MethodSchema)!void {
                    var args = input.args;
                    var owns_args = true;
                    defer if (comptime Arguments != void and @hasDecl(Arguments, "deinit")) {
                        if (owns_args) args.deinit();
                    };
                    const Task = @field(Async, @tagName(function_name));
                    var view = context.completion();
                    switch (comptime function_name) {
                        .read, .readv, .writev => {
                            var prepared = try args.prepareAsync();
                            owns_args = false;
                            errdefer prepared.args.deinit();
                            const completion = try Task.Completion.take(&view, prepared.attachment);
                            return Task.create(input.node_fs, prepared.args, runtime, completion);
                        },
                        .cp => {
                            const completion = try Task.Completion.take(&view, {});
                            owns_args = false;
                            return Task.create(input.node_fs, args, runtime, completion);
                        },
                        .readdir => if (args.recursive) {
                            const RecursiveTask = Async.readdir_recursive;
                            const completion = try RecursiveTask.Completion.take(&view, {});
                            owns_args = false;
                            return RecursiveTask.create(args, runtime, completion);
                        },
                        else => {},
                    }
                    if (comptime has_abort_signal) {
                        const prepared = try Engine.prepareAbort(context, input.signal);
                        args.abort.deinit();
                        args.abort = prepared.token;
                        const completion = try Task.Completion.take(&view, prepared.attachment);
                        owns_args = false;
                        return Task.create(input.node_fs, args, runtime, completion);
                    } else {
                        const completion = try Task.Completion.take(&view, {});
                        owns_args = false;
                        return Task.create(input.node_fs, args, runtime, completion);
                    }
                }
            };
        }

        fn callAsync(comptime function_name: NodeFSFunctionEnum) NodeFSAsyncFunction(@tagName(function_name)) {
            return Bindings(function_name, @tagName(function_name)).runAsync;
        }

        fn callAsyncAs(comptime function_name: NodeFSFunctionEnum, comptime method_name: []const u8) NodeFSAsyncFunction(method_name) {
            return Bindings(function_name, method_name).runAsync;
        }

        fn callSync(comptime function_name: NodeFSFunctionEnum) NodeFSFunction(@tagName(function_name) ++ "Sync") {
            return Bindings(function_name, @tagName(function_name) ++ "Sync").runSync;
        }

        fn callSyncAs(comptime function_name: NodeFSFunctionEnum, comptime method_name: []const u8) NodeFSFunction(method_name) {
            return Bindings(function_name, method_name).runSync;
        }

        pub const Binding = struct {
            bindgen_state: bindgen.ClassState = .{},
            node_fs: bindgen.OwnedNativeWithDestructor(fs.NodeFS, destroyNodeFS, .any),

            pub const new = bun.TrivialNew(@This());

            pub fn destroy(this: *Binding) void {
                this.node_fs.deinit();
                bun.destroy(this);
            }

            fn destroyNodeFS(node_fs: *fs.NodeFS) void {
                bun.destroy(node_fs);
            }

            pub fn memoryUsage(_: *const Binding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
                return @sizeOf(Binding) + @sizeOf(fs.NodeFS);
            }

            pub fn getDirent(
                _: *Binding,
                context: bindgen.CallContext(NodeJSFSDirentSchema),
                _: bindgen.Args(NodeJSFSDirentSchema),
            ) bun.JSError!bindgen.Return(NodeJSFSDirentSchema) {
                return NodeDirentObject.constructorResult(context);
            }

            pub fn getStats(
                _: *Binding,
                context: bindgen.CallContext(NodeJSFSStatsSchema),
                _: bindgen.Args(NodeJSFSStatsSchema),
            ) bun.JSError!bindgen.Return(NodeJSFSStatsSchema) {
                return NodeStatsObject.constructorResult(context);
            }

            pub const access = callAsync(.access);
            pub const appendFile = callAsync(.appendFile);
            pub const close = callAsync(.close);
            pub const copyFile = callAsync(.copyFile);
            pub const cp = callAsync(.cp);
            pub const exists = callAsync(.exists);
            pub const chown = callAsync(.chown);
            pub const chmod = callAsync(.chmod);
            pub const fchmod = callAsync(.fchmod);
            pub const fchown = callAsync(.fchown);
            pub const fstat = callAsync(.fstat);
            pub const fsync = callAsync(.fsync);
            pub const ftruncate = callAsync(.ftruncate);
            pub const futimes = callAsync(.futimes);
            pub const lchmod = callAsync(.lchmod);
            pub const lchown = callAsync(.lchown);
            pub const link = callAsync(.link);
            pub const lstat = callAsync(.lstat);
            pub const mkdir = callAsync(.mkdir);
            pub const mkdtemp = callAsync(.mkdtemp);
            pub const open = callAsync(.open);
            pub const read = callAsync(.read);
            pub const write = callAsync(.write);
            pub const readdir = callAsync(.readdir);
            pub const readFile = callAsync(.readFile);
            pub const writeFile = callAsync(.writeFile);
            pub const readlink = callAsync(.readlink);
            pub const rm = callAsync(.rm);
            pub const rmdir = callAsync(.rmdir);
            pub const realpath = callAsyncAs(.realpathNonNative, "realpath");
            pub const realpathNative = callAsyncAs(.realpath, "realpathNative");
            pub const rename = callAsync(.rename);
            pub const stat = callAsync(.stat);
            pub const statfs = callAsync(.statfs);
            pub const symlink = callAsync(.symlink);
            pub const truncate = callAsync(.truncate);
            pub const unlink = callAsync(.unlink);
            pub const utimes = callAsync(.utimes);
            pub const lutimes = callAsync(.lutimes);
            pub const accessSync = callSync(.access);
            pub const appendFileSync = callSync(.appendFile);
            pub const closeSync = callSync(.close);
            pub const cpSync = callSync(.cp);
            pub const copyFileSync = callSync(.copyFile);
            pub const existsSync = callSync(.exists);
            pub const chownSync = callSync(.chown);
            pub const chmodSync = callSync(.chmod);
            pub const fchmodSync = callSync(.fchmod);
            pub const fchownSync = callSync(.fchown);
            pub const fstatSync = callSync(.fstat);
            pub const fsyncSync = callSync(.fsync);
            pub const ftruncateSync = callSync(.ftruncate);
            pub const futimesSync = callSync(.futimes);
            pub const lchmodSync = callSync(.lchmod);
            pub const lchownSync = callSync(.lchown);
            pub const linkSync = callSync(.link);
            pub const lstatSync = callSync(.lstat);
            pub const mkdirSync = callSync(.mkdir);
            pub const mkdtempSync = callSync(.mkdtemp);
            pub const openSync = callSync(.open);
            pub const readSync = callSync(.read);
            pub const writeSync = callSync(.write);
            pub const readdirSync = callSync(.readdir);
            pub const readFileSync = callSync(.readFile);
            pub const writeFileSync = callSync(.writeFile);
            pub const readlinkSync = callSync(.readlink);
            pub const realpathSync = callSyncAs(.realpathNonNative, "realpathSync");
            pub const realpathNativeSync = callSyncAs(.realpath, "realpathNativeSync");
            pub const renameSync = callSync(.rename);
            pub const statSync = callSync(.stat);
            pub const statfsSync = callSync(.statfs);
            pub const symlinkSync = callSync(.symlink);
            pub const truncateSync = callSync(.truncate);
            pub const unlinkSync = callSync(.unlink);
            pub const utimesSync = callSync(.utimes);
            pub const lutimesSync = callSync(.lutimes);
            pub const rmSync = callSync(.rm);
            pub const rmdirSync = callSync(.rmdir);
            pub const writev = callAsync(.writev);
            pub const writevSync = callSync(.writev);
            pub const readv = callAsync(.readv);
            pub const readvSync = callSync(.readv);
            pub const fdatasyncSync = callSync(.fdatasync);
            pub const fdatasync = callAsync(.fdatasync);
        };

        pub fn create(
            context: bindgen.CallContext(NodeJSFSCreateSchema),
            _: bindgen.Args(NodeJSFSCreateSchema),
        ) bun.JSError!bindgen.ClassRef(NodeJSFSSchema) {
            const module = Binding.new(.{ .node_fs = .init(bun.new(fs.NodeFS, .{})) });

            return NodeJSFSClass.adoptResult(module, context);
        }

        pub fn createMemfdForTesting(
            context: bun.bindgen.CallContext(CreateMemfdForTestingSchema),
            args: bun.bindgen.Args(CreateMemfdForTestingSchema),
        ) bindgen.CallError(CreateMemfdForTestingSchema)!bindgen.Return(CreateMemfdForTestingSchema) {
            if (comptime !bun.Environment.isLinux) {
                return context.fail(.unavailable, {});
            }

            switch (bun.sys.memfd_create("my_memfd", .non_executable)) {
                .result => |fd| {
                    switch (bun.sys.ftruncate(fd, args.size)) {
                        .result => return fd.cast(),
                        .err => |err| {
                            fd.close();
                            return context.fail(.system, try bindgen.SystemError.fromSysError(err));
                        },
                    }
                },
                .err => |err| return context.fail(.system, try bindgen.SystemError.fromSysError(err)),
            }
        }

        fn mkdirRecursive(
            args: bindgen.Args(MkdirRecursiveSchema),
        ) bun.OOM!bindgen.Return(MkdirRecursiveSchema) {
            const path = try args.path.toUTF8(bun.default_allocator);
            defer path.deinit();
            var node_fs: fs.NodeFS = .{};
            return node_fs.mkdirRecursive(.{
                .path = .{ .string = bun.PathString.init(path.slice()) },
                .recursive = true,
            }) != .err;
        }

        const NodeJSFSClass = bindgen.Class(NodeJSFSSchema, Binding);
        const CreateMemfdForTestingBinding = bun.bindgen.Fn(CreateMemfdForTestingSchema, createMemfdForTesting);

        comptime {
            _ = bindgen.Fn(NodeJSFSCreateSchema, create);
            _ = NodeJSFSClass;
            _ = CreateMemfdForTestingBinding;
            _ = bindgen.Fn(MkdirRecursiveSchema, mkdirRecursive);
        }
    };
}

const std = @import("std");

const bun = @import("bun");
const bindgen = bun.bindgen;

const NodeJSFSBindingModule = bindgen.Module("NodeJSFS");
const NodeJSFSCreateSchema = NodeJSFSBindingModule.function("create");
const NodeJSFSSchema = NodeJSFSBindingModule.class("NodeJSFS");
const NodeJSFSDirentSchema = NodeJSFSSchema.member("Dirent");
const NodeJSFSStatsSchema = NodeJSFSSchema.member("Stats");
const NodeDirentObject = bindgen.PlainObject(bindgen.Module("NodeDirent").class("Dirent"));
const NodeStatsObject = bindgen.PlainObject(bindgen.Module("NodeFSStat").class("Stats"));

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const CreateMemfdForTestingSchema = InternalTestingBindings.function("createMemfd");
const MkdirRecursiveSchema = bindgen.Module("NodeFS").nativeExport("mkdirRecursive");
