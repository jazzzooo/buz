//! This is the shared global state for a single JS instance execution.
//!
//! Today, Bun is one VM per thread, so the name "VirtualMachine" sort of makes
//! sense. If that changes, this should be renamed `ScriptExecutionContext`.

const BindingEscape = bun.bindgen.Escape(@This());
const VirtualMachine = @This();

var is_bun_test = false;

pub fn setSyntheticAllocationLimit(limit: usize) void {
    _ = bun.JavaScriptLimits.setSyntheticAllocationLimit(limit);
    bun.bindgen.Engine(SetStringAllocationLimitShim).call(.{ .value = limit });
}

pub fn setIsBunTest(enabled: bool) void {
    is_bun_test = enabled;
    bun.bindgen.Engine(SetBunTestModeShim).call(.{ .enabled = enabled });
}

global: *JSGlobalObject,
allocator: std.mem.Allocator,
io: std.Io,
pinned_threads: *bun.PinnedThreadDomain,
background_tasks: bun.BackgroundTaskGroup,
background_tasks_deinitialized: bool = false,
pending_work: @import("./WorkTask.zig").Pending = .{},
transpiler: Transpiler,
bun_watcher: ImportWatcher = .none,
console: *ConsoleObject,
log: *logger.Log,
owns_log: bool = false,
macro_configuration: ?*Config.OwnedMacroConfiguration = null,
main: []const u8 = "",
main_is_html_entrypoint: bool = false,
main_resolved_path: bun.String = bun.String.empty,
main_hash: u32 = 0,
/// Set if code overrides Bun.main to a custom value, and then reset when the VM loads a new file
/// (e.g. when bun:test starts testing a new file)
overridden_main: bun.bindgen.Root.Optional = .empty,
entry_point: ServerEntryPoint = undefined,
origin: URL = URL{},
node_fs: ?*bun.api.node.fs.NodeFS = null,
timer: bun.api.Timer.All,
event_loop_handle: ?*jsc.PlatformEventLoop = null,
pending_unref_counter: i32 = 0,
preload: []const []const u8 = &.{},
unhandled_pending_rejection_to_capture: ?*UnhandledRejectionCapture = null,
standalone_module_graph: ?*bun.StandaloneModuleGraph = null,
smol: bool = false,
dns_result_order: DNSResolver.Order = .verbatim,
cpu_profiler_config: ?CPUProfilerConfig = null,
heap_profiler_config: ?HeapProfilerConfig = null,
counters: Counters = .{},

hot_reload: bun.cli.Command.HotReload = .none,
jsc_vm: *VM = undefined,

/// hide bun:wrap from stack traces
/// bun:wrap is very noisy
hide_bun_stackframes: bool = true,

is_printing_plugin: bool = false,
is_shutting_down: bool = false,
plugin_runner: ?PluginRunner = null,
is_main_thread: bool = false,
exit_handler: ExitHandler = .{},

default_tls_reject_unauthorized: ?bool = null,
default_verbose_fetch: ?bun.http.HTTPVerboseLevel = null,

/// Do not access this field directly!
///
/// It exists in the VirtualMachine struct so that we don't accidentally
/// make a stack copy of it only use it through source_mappings.
///
/// This proposal could let us safely move it back https://github.com/ziglang/zig/issues/7769
saved_source_map_table: SavedSourceMap.HashTable = undefined,
source_mappings: SavedSourceMap = undefined,

arena: *Arena = undefined,
has_loaded: bool = false,

had_errors: bool = false,

macro_mode: bool = false,
no_macros: bool = false,
auto_killer: ProcessAutoKiller = .{ .enabled = false },

has_any_macro_remappings: bool = false,
/// TODO: Audit VM initialization so development-server instances enable origin-aware stack formatting.
is_from_devserver: bool = false,
has_enabled_macro_mode: bool = false,

/// Used by bun:test to set global hooks for beforeAll, beforeEach, etc.
is_in_preload: bool = false,
has_patched_run_main: bool = false,

transpiler_store: ModuleLoader.RuntimeTranspilerStore,

pending_file_poll_frees: ?*bun.Async.FilePoll.Store = null,

remap_stack_frames_mutex: std.Io.Mutex = .init,

/// The arguments used to launch the process _after_ the script name and bun and any flags applied to Bun
///     "bun run foo --bar"
///          ["--bar"]
///     "bun run foo baz --bar"
///          ["baz", "--bar"]
///     "bun run foo
///          []
///     "bun foo --bar"
///          ["--bar"]
///     "bun foo baz --bar"
///          ["baz", "--bar"]
///     "bun foo
///          []
argv: []const []const u8 = &[_][]const u8{},

origin_timer: SystemTimer = undefined,
origin_timestamp: u64 = 0,
/// For fake timers: override performance.now() with a specific value (in nanoseconds)
/// When null, use the real timer. When set, return this value instead.
overridden_performance_now: ?u64 = null,
macro_event_loop: EventLoop = EventLoop{},
regular_event_loop: EventLoop = EventLoop{},
event_loop: *EventLoop = undefined,

ref_strings: jsc.RefString.Map = undefined,
ref_strings_mutex: std.Io.Mutex = undefined,

active_tasks: usize = 0,

rare_data: ?*jsc.RareData = null,
/// Owned storage for proxy env vars set via process.env at runtime. Not
/// in RareData because lazy RareData creation races with worker spawn
/// (worker thread needs to lock parent.proxy_env_storage.lock atomically
/// with observing the env map; a null-check on rare_data can't be both
/// lock-free and correct). ~56 bytes — negligible on VirtualMachine.
proxy_env_storage: jsc.RareData.ProxyEnvStorage = .{},
is_us_loop_entered: bool = false,
pending_entry_promise: ?EntryPointPromise = null,
/// hot_reload_counter value at which we last surfaced a rejected
/// pending_entry_promise. We can't use the promise's handled flag as the
/// "already reported" sentinel any more: the C++ module loader marks every
/// pipeline promise handled before it ever reaches us. Using a generation
/// counter (rather than the promise pointer) avoids false negatives when
/// GC reuses the previous promise's allocation for the next reload's.
pending_entry_promise_reported_at: u32 = std.math.maxInt(u32),
/// A watcher event arrived while pending_entry_promise was still pending
/// — i.e. while a previous hot-reload's loadAndEvaluateModule chain was
/// still in flight on the microtask queue. Starting a second clearAll +
/// load now would let the two chains interleave through one registry and
/// produce duplicate or partial-graph evaluations, so defer the new reload
/// until the in-flight promise settles. The main loop's per-tick
/// reportExceptionInHotReloadedModuleIfNeeded picks this up.
hot_reload_deferred: bool = false,
entry_point_result: struct {
    value: bun.bindgen.EngineRoot.Optional = .empty,
    cjs_set_value: bool = false,
} = .{},

auto_install_dependencies: bool = false,

onUnhandledRejection: *const OnUnhandledRejection = defaultOnUnhandledRejection,
onUnhandledRejectionCtx: ?*anyopaque = null,
onUnhandledRejectionExceptionList: ?*ExceptionList = null,
unhandled_error_counter: usize = 0,
reported_unhandled_rejection: bool = false,
is_handling_uncaught_exception: bool = false,
exit_on_uncaught_exception: bool = false,

modules: ModuleLoader.AsyncModule.Queue = .{},
aggressive_garbage_collection: GCLevel = GCLevel.none,

module_loader: ModuleLoader = .{},

gc_controller: jsc.GarbageCollectionController = .{},
worker: ?*jsc.WebWorker = null,
worker_children: jsc.WebWorker.Children = .{},
ipc: ?IPCInstanceUnion = null,
hot_reload_counter: u32 = 0,

debugger: ?jsc.Debugger = null,
has_terminated: bool = false,

body_value_hive_allocator: webcore.Body.Value.HiveAllocator = undefined,

is_inside_deferred_task_queue: bool = false,
/// When true, drainMicrotasksWithGlobal is suppressed. Used by SpawnSyncEventLoop
/// to prevent the isolated event loop from draining the shared JSC microtask queue
/// (which would execute user JavaScript during spawnSync).
suppress_microtask_drain: bool = false,

// defaults off. .on("message") will set it to true unless overridden
// process.channel.unref() will set it to false and mark it overridden
// on disconnect it will be disabled
channel_ref: bun.Async.KeepAlive = .{},
// if process.channel.ref() or unref() has been called, this is set to true
channel_ref_overridden: bool = false,
// if one disconnect event listener should be ignored
channel_ref_should_ignore_one_disconnect_event_listener: bool = false,

/// A set of extensions that exist in the require.extensions map. Keys
/// contain the leading '.'. Values are either built-in loaders or rooted
/// custom loader functions.
///
/// `.keys() == transpiler.resolver.opts.extra_cjs_extensions`, so
/// mutations in this map must update the resolver.
commonjs_custom_extensions: bun.StringArrayHashMap(ModuleLoader.CommonJSExtension) = .empty,
/// Property mutation frames own pending updates; shutdown cancels their payloads
/// through this non-owning list. Reservations keep nested commits allocation-free.
commonjs_extension_updates: ?*ModuleLoader.CommonJSExtensionUpdate = null,
commonjs_extension_reservations: usize = 0,
/// Incremented when the `require.extensions` for a built-in extension is mutated.
/// An example is mutating `require.extensions['.js']` to intercept all '.js' files.
/// The value is decremented when defaults are restored.
has_mutated_built_in_extensions: u32 = 0,

initial_script_execution_context_identifier: i32,

/// `bun test --isolate`: bumped each time a fresh global is swapped in.
/// Native callbacks compare against this and self-cancel on mismatch so
/// stale handles from a prior test file never call into the new global.
test_isolation_generation: u32 = 0,
/// When true, listening sockets and subprocesses are tracked so they can
/// be force-closed between test files. Set by `bun test --isolate`.
test_isolation_enabled: bool = false,

pub const ProcessAutoKiller = @import("./ProcessAutoKiller.zig");
pub const OnUnhandledRejection = fn (*VirtualMachine, globalObject: *JSGlobalObject, JSValue) void;

pub fn allowAddons(this: *VirtualMachine) bool {
    return if (this.transpiler.options.transform_options.allow_addons) |allow_addons| allow_addons else true;
}
pub fn allowRejectionHandledWarning(this: *VirtualMachine) bool {
    return this.unhandledRejectionsMode() != .bun;
}
pub fn unhandledRejectionsMode(this: *VirtualMachine) api.UnhandledRejections {
    return this.transpiler.options.transform_options.unhandled_rejections orelse .bun;
}

pub fn prepareProxyEnvironmentVariable(this: *VirtualMachine, name: []const u8, value: ?[]const u8) bun.OOM!*ProxyEnvironmentUpdate {
    const storage = &this.proxy_env_storage;
    storage.lock.lockUncancelable(this.io);
    defer storage.lock.unlock(this.io);

    const slot = storage.slot(name) orelse unreachable;
    const new_value = if (value) |bytes| try jsc.RareData.RefCountedEnvValue.create(bytes) else null;
    errdefer if (new_value) |owned| owned.deref();
    const update = try bun.default_allocator.create(ProxyEnvironmentUpdate);
    errdefer bun.default_allocator.destroy(update);
    // The engine commits an ordinary data-property operation without invoking JS
    // between preparation and finish, so this capacity remains available.
    if (value != null) try this.transpiler.env.map.ensureUnusedCapacity(1);
    update.* = .{ .vm = this, .slot = slot, .replacement = new_value };
    return update;
}

pub const ProxyEnvironmentUpdate = struct {
    vm: *VirtualMachine,
    slot: jsc.RareData.ProxyEnvStorage.Slot,
    replacement: ?*jsc.RareData.RefCountedEnvValue,

    pub fn finish(update: *ProxyEnvironmentUpdate, commit: bool) void {
        const vm = update.vm;
        const storage = &vm.proxy_env_storage;
        storage.lock.lockUncancelable(vm.io);
        defer storage.lock.unlock(vm.io);
        if (commit) {
            if (update.replacement) |value| {
                vm.transpiler.env.map.putAssumeCapacity(update.slot.key, value.bytes);
            } else {
                vm.transpiler.env.map.remove(update.slot.key);
            }
            const old_value = update.slot.ptr.*;
            update.slot.ptr.* = update.replacement;
            update.replacement = old_value;
        }
        if (update.replacement) |value| value.deref();
        bun.default_allocator.destroy(update);
    }
};

pub fn initRequestBodyValue(this: *VirtualMachine, body: jsc.WebCore.Body.Value) !*Body.Value.HiveRef {
    return .init(body, &this.body_value_hive_allocator);
}

/// Whether this VM should be destroyed after it exits, even if it is the main thread's VM.
/// Worker VMs are always destroyed on exit, regardless of this setting. Setting this to
/// true may expose bugs that would otherwise only occur using Workers. Controlled by
pub fn shouldDestructMainThreadOnExit(_: *const VirtualMachine) bool {
    return bun.feature_flag.BUN_DESTRUCT_VM_ON_EXIT.get();
}

pub threadlocal var is_bundler_thread_for_bytecode_cache: bool = false;

pub fn uwsLoop(this: *const VirtualMachine) *uws.Loop {
    if (comptime Environment.isPosix) {
        if (Environment.allow_assert) {
            return this.event_loop_handle orelse @panic("uws event_loop_handle is null");
        }
        return this.event_loop_handle.?;
    }

    return uws.Loop.get();
}

pub fn uvLoop(this: *const VirtualMachine) *bun.Async.Loop {
    if (Environment.allow_assert) {
        return this.event_loop_handle orelse @panic("libuv event_loop_handle is null");
    }
    return this.event_loop_handle.?;
}

pub fn isMainThread(this: *const VirtualMachine) bool {
    return this.worker == null;
}

pub fn isInspectorEnabled(this: *const VirtualMachine) bool {
    return this.debugger != null;
}

pub fn isShuttingDown(this: *const VirtualMachine) bool {
    return this.is_shutting_down;
}

pub fn getTLSRejectUnauthorized(this: *const VirtualMachine) bool {
    return this.default_tls_reject_unauthorized orelse this.transpiler.env.getTLSRejectUnauthorized();
}

pub fn onSubprocessSpawn(this: *VirtualMachine, process: *bun.spawn.Process) void {
    this.auto_killer.onSubprocessSpawn(process);
}

pub fn onSubprocessExit(this: *VirtualMachine, process: *bun.spawn.Process) void {
    this.auto_killer.onSubprocessExit(process);
}

pub fn getVerboseFetch(this: *VirtualMachine) bun.http.HTTPVerboseLevel {
    return this.default_verbose_fetch orelse {
        if (this.transpiler.env.get("BUN_CONFIG_VERBOSE_FETCH")) |verbose_fetch| {
            if (strings.eqlComptime(verbose_fetch, "true") or strings.eqlComptime(verbose_fetch, "1")) {
                this.default_verbose_fetch = .headers;
                return .headers;
            } else if (strings.eqlComptime(verbose_fetch, "curl")) {
                this.default_verbose_fetch = .curl;
                return .curl;
            }
        }
        this.default_verbose_fetch = .none;
        return .none;
    };
}

pub const VMHolder = struct {
    pub threadlocal var vm: ?*VirtualMachine = null;
    pub threadlocal var cached_global_object: ?*JSGlobalObject = null;
    pub var main_thread_vm: ?*VirtualMachine = null;

    pub fn setDefaultGlobalObject(global: *JSGlobalObject) void {
        if (vm) |vm_instance| {
            vm_instance.global = global;

            // Ensure this is always set when it should be.
            if (vm_instance.is_main_thread) {
                VMHolder.main_thread_vm = vm_instance;
            }
        }

        cached_global_object = global;
    }

    pub fn getDefaultGlobalObject() ?*JSGlobalObject {
        if (cached_global_object) |global| return global;
        const vm_instance = vm orelse return null;
        cached_global_object = vm_instance.global;
        return vm_instance.global;
    }
};

pub inline fn get() *VirtualMachine {
    return getOrNull().?;
}

pub inline fn getOrNull() ?*VirtualMachine {
    return VMHolder.vm;
}

pub fn getMainThreadVM() ?*VirtualMachine {
    return VMHolder.main_thread_vm;
}

pub fn mimeType(this: *VirtualMachine, str: []const u8) ?bun.http.MimeType {
    return this.rareData().mimeTypeFromString(this.allocator, str);
}

pub fn onAfterEventLoop(this: *VirtualMachine) void {
    this.drainNativeFinalizers();
    if (bun.take(&this.pending_file_poll_frees)) |store| {
        store.processDeferredFrees();
    }
}

pub fn drainNativeFinalizers(this: *VirtualMachine) void {
    if (this.rare_data) |rare| rare.drainNativeFinalizers();
}

pub fn isEventLoopAliveExcludingImmediates(vm: *const VirtualMachine) bool {
    return vm.unhandled_error_counter == 0 and
        (vm.event_loop_handle.?.isActive() or
            vm.active_tasks > 0 or
            vm.event_loop.tasks.count > 0 or
            !vm.event_loop.concurrent_tasks.isEmpty() or
            vm.event_loop.hasPendingRefs());
}

pub fn isEventLoopAlive(vm: *const VirtualMachine) bool {
    return vm.isEventLoopAliveExcludingImmediates() or
        // We need to keep running in this case so that immediate tasks get run. But immediates
        // intentionally don't make the event loop _active_ so we need to check for them
        // separately.
        vm.event_loop.immediate_tasks.items.len > 0 or
        vm.event_loop.next_immediate_tasks.items.len > 0;
}

pub fn wakeup(this: *VirtualMachine) void {
    this.eventLoop().wakeup();
}

const SourceMapHandlerGetter = struct {
    vm: *VirtualMachine,
    printer: *js_printer.BufferPrinter,

    pub fn get(this: *SourceMapHandlerGetter) js_printer.SourceMapHandler {
        if (this.vm.debugger == null or this.vm.debugger.?.mode == .connect) {
            return SavedSourceMap.SourceMapHandler.init(&this.vm.source_mappings);
        }

        return js_printer.SourceMapHandler.For(SourceMapHandlerGetter, onChunk).init(this);
    }

    /// When the inspector is enabled, we want to generate an inline sourcemap.
    /// And, for now, we also store it in source_mappings like normal
    /// This is hideously expensive memory-wise...
    pub fn onChunk(this: *SourceMapHandlerGetter, chunk: SourceMap.Chunk, source: *const logger.Source) anyerror!void {
        var temp_json_buffer = bun.MutableString.initEmpty(bun.default_allocator);
        defer temp_json_buffer.deinit();
        try chunk.printSourceMapContentsFromInternal(source, &temp_json_buffer, true, true);
        const source_map_url_prefix_start = "//# sourceMappingURL=data:application/json;base64,";
        // TODO: do we need to %-encode the path?
        const source_url_len = source.path.text.len;
        const source_mapping_url = "\n//# sourceURL=";
        const prefix_len = source_map_url_prefix_start.len + source_mapping_url.len + source_url_len;

        try this.vm.source_mappings.putMappings(source, chunk.buffer);
        const encode_len = bun.base64.encodeLen(temp_json_buffer.list.items);
        try this.printer.ctx.buffer.growIfNeeded(encode_len + prefix_len + 2);
        this.printer.ctx.buffer.appendAssumeCapacity("\n" ++ source_map_url_prefix_start);
        _ = bun.base64.encode(this.printer.ctx.buffer.list.items.ptr[this.printer.ctx.buffer.len()..this.printer.ctx.buffer.list.capacity], temp_json_buffer.list.items);
        this.printer.ctx.buffer.list.items.len += encode_len;
        this.printer.ctx.buffer.appendAssumeCapacity(source_mapping_url);
        // TODO: do we need to %-encode the path?
        this.printer.ctx.buffer.appendAssumeCapacity(source.path.text);
        try this.printer.ctx.buffer.append("\n");
    }
};

pub inline fn sourceMapHandler(this: *VirtualMachine, printer: *js_printer.BufferPrinter) SourceMapHandlerGetter {
    return SourceMapHandlerGetter{
        .vm = this,
        .printer = printer,
    };
}

pub const GCLevel = enum(u3) {
    none = 0,
    mild = 1,
    aggressive = 2,
};

pub threadlocal var is_main_thread_vm: bool = false;

pub const UnhandledRejectionScope = struct {
    ctx: ?*anyopaque = null,
    onUnhandledRejection: *const OnUnhandledRejection = undefined,
    count: usize = 0,

    pub fn apply(this: *UnhandledRejectionScope, vm: *jsc.VirtualMachine) void {
        vm.onUnhandledRejection = this.onUnhandledRejection;
        vm.onUnhandledRejectionCtx = this.ctx;
        vm.unhandled_error_counter = this.count;
    }
};

pub const UnhandledRejectionCapture = struct {
    root: bun.bindgen.EngineRoot.Optional = .empty,
    failure: ?bun.JSError = null,

    pub fn capture(this: *UnhandledRejectionCapture, global: *JSGlobalObject, value: JSValue) void {
        if (this.failure != null) return;
        BindingEscape.setOptionalEngineValue(global, &this.root, value) catch |err| {
            this.failure = err;
        };
    }

    pub fn deinit(this: *UnhandledRejectionCapture) void {
        this.root.deinit();
    }
};

pub fn onQuietUnhandledRejectionHandlerCaptureValue(this: *VirtualMachine, global: *JSGlobalObject, value: JSValue) void {
    this.unhandled_error_counter += 1;
    value.ensureStillAlive();
    if (this.unhandled_pending_rejection_to_capture) |capture| {
        capture.capture(global, value);
    }
}

pub fn unhandledRejectionScope(this: *VirtualMachine) UnhandledRejectionScope {
    return .{
        .onUnhandledRejection = this.onUnhandledRejection,
        .ctx = this.onUnhandledRejectionCtx,
        .count = this.unhandled_error_counter,
    };
}

fn ensureSourceCodePrinter(this: *VirtualMachine) void {
    if (source_code_printer == null) {
        const allocator = if (bun.heap_breakdown.enabled) bun.heap_breakdown.namedAllocator("SourceCode") else this.allocator;
        const writer = js_printer.BufferWriter.init(allocator);
        source_code_printer = allocator.create(js_printer.BufferPrinter) catch unreachable;
        source_code_printer.?.* = js_printer.BufferPrinter.init(writer);
    }
}

pub fn loadExtraEnvAndSourceCodePrinter(this: *VirtualMachine) void {
    var map = this.transpiler.env.map;

    ensureSourceCodePrinter(this);

    if (map.get("BUN_SHOW_BUN_STACKFRAMES") != null) {
        this.hide_bun_stackframes = false;
    }

    if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_ASYNC_TRANSPILER.get()) {
        this.transpiler_store.enabled = false;
    }

    if (map.map.fetchSwapRemove("NODE_CHANNEL_FD")) |kv| {
        const fd_s = kv.value.value;
        const mode = if (map.map.fetchSwapRemove("NODE_CHANNEL_SERIALIZATION_MODE")) |mode_kv|
            IPC.Mode.fromString(mode_kv.value.value) orelse .json
        else
            .json;

        IPC.log("IPC environment variables: NODE_CHANNEL_FD={s}, NODE_CHANNEL_SERIALIZATION_MODE={s}", .{ fd_s, @tagName(mode) });
        if (std.fmt.parseInt(u31, fd_s, 10)) |fd| {
            this.initIPCInstance(.fromUV(fd), mode);
        } else |_| {
            Output.warn("Failed to parse IPC channel number '{s}'", .{fd_s});
        }
    }

    // Node.js checks if this are set to "1" and no other value
    if (map.get("NODE_PRESERVE_SYMLINKS")) |value| {
        this.transpiler.resolver.opts.preserve_symlinks = bun.strings.eqlComptime(value, "1");
    }

    if (map.get("BUN_GARBAGE_COLLECTOR_LEVEL")) |gc_level| {
        // Reuse this flag for other things to avoid unnecessary hashtable
        // lookups on start for obscure flags which we do not want others to
        // depend on.
        if (map.get("BUN_FEATURE_FLAG_FORCE_WAITER_THREAD") != null) {
            bun.spawn.process.WaiterThread.setShouldUseWaiterThread();
        }

        // Only allowed for testing
        if (map.get("BUN_FEATURE_FLAG_INTERNAL_FOR_TESTING") != null) {
            ModuleLoader.is_allowed_to_use_internal_testing_apis = true;
        }

        if (strings.eqlComptime(gc_level, "1")) {
            this.aggressive_garbage_collection = .mild;
        } else if (strings.eqlComptime(gc_level, "2")) {
            this.aggressive_garbage_collection = .aggressive;
        }

        if (map.get("BUN_FEATURE_FLAG_SYNTHETIC_MEMORY_LIMIT")) |value| {
            if (std.fmt.parseInt(usize, value, 10)) |limit| {
                setSyntheticAllocationLimit(limit);
            } else |_| {
                Output.panic("BUN_FEATURE_FLAG_SYNTHETIC_MEMORY_LIMIT must be a positive integer", .{});
            }
        }
    }
}

fn isErrorLike(globalObject: *JSGlobalObject, reason: JSValue) bun.JSError!bool {
    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    engine_scope.init(globalObject);
    defer engine_scope.deinit();
    return engine_scope.engine(PromiseIsErrorLikeShim).call(.{ .reason = BindingEscape.borrowEngineValue(&engine_scope, reason) });
}

fn noSideEffectsToString(global_object: *JSGlobalObject, reason: JSValue) bun.JSError!bun.bindgen.DOMString {
    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    engine_scope.init(global_object);
    defer engine_scope.deinit();
    return engine_scope.engine(NoSideEffectsToStringShim).call(.{ .reason = BindingEscape.borrowEngineValue(&engine_scope, reason) });
}

fn emitUnhandledRejectionWarning(global_object: *JSGlobalObject, reason: JSValue) bun.JSError!void {
    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    engine_scope.init(global_object);
    defer engine_scope.deinit();
    return engine_scope.engine(EmitUnhandledRejectionWarningShim).call(.{ .reason = BindingEscape.borrowEngineValue(&engine_scope, reason) });
}

fn processHandleUnhandledRejection(context: anytype, reason: anytype, promise: ?bun.bindgen.PromiseResult) bun.JSError!bool {
    return context.engineIn("ProcessHost", "processHandleUnhandledRejection").call(.{
        .reason = reason.operand(context).asEngine(),
        .promise = if (promise) |present| present.operand(context) else null,
    });
}

fn wrapUnhandledRejectionErrorForUncaughtException(globalObject: *JSGlobalObject, reason: JSValue) bun.JSError!JSValue {
    if (try isErrorLike(globalObject, reason)) return reason;
    var reason_string = try noSideEffectsToString(globalObject, reason);
    defer reason_string.deinit();
    const msg_1 = "This error originated either by throwing inside of an async function without a catch block, " ++
        "or by rejecting a promise which was not handled with .catch(). The promise rejected with the reason \"";
    return globalObject.createNodeError(.ERR_UNHANDLED_REJECTION, msg_1 ++ "{f}\".", .{reason_string});
}

pub fn unhandledRejection(this: *jsc.VirtualMachine, context: anytype, reason_value: bun.bindgen.EngineValueResult, promise: ?bun.bindgen.PromiseResult) void {
    const globalObject = context.viewToken().globalObject();
    const reason = BindingEscape.borrowResultValue(context, &reason_value);
    if (this.isShuttingDown()) {
        Output.debugWarn("unhandledRejection during shutdown.", .{});
        return;
    }

    if (is_bun_test) {
        this.unhandled_error_counter += 1;
        this.onUnhandledRejection(this, globalObject, reason);
        return;
    }

    switch (this.unhandledRejectionsMode()) {
        .bun => {
            if (processHandleUnhandledRejection(context, reason_value, promise) catch return) return;
            // continue to default handler
        },
        .none => {
            defer this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                error.JSTerminated => {}, // we are returning anyway
            };
            if (processHandleUnhandledRejection(context, reason_value, promise) catch return) return;
            return; // ignore the unhandled rejection
        },
        .warn => {
            defer this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                error.JSTerminated => {}, // we are returning anyway
            };
            _ = processHandleUnhandledRejection(context, reason_value, promise) catch return;
            emitUnhandledRejectionWarning(globalObject, reason) catch |err| {
                @import("./Task.zig").reportErrorOrTerminate(globalObject, err) catch return;
            };
            return;
        },
        .warn_with_error_code => {
            defer this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                error.JSTerminated => {}, // we are returning anyway
            };
            if (processHandleUnhandledRejection(context, reason_value, promise) catch return) return;
            emitUnhandledRejectionWarning(globalObject, reason) catch |err| {
                @import("./Task.zig").reportErrorOrTerminate(globalObject, err) catch return;
            };
            this.exit_handler.exit_code = 1;
            return;
        },
        .strict => {
            defer this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                error.JSTerminated => {}, // we are returning anyway
            };
            const wrapped_reason = wrapUnhandledRejectionErrorForUncaughtException(globalObject, reason) catch |err| {
                @import("./Task.zig").reportErrorOrTerminate(globalObject, err) catch {};
                return;
            };
            _ = this.uncaughtException(globalObject, wrapped_reason, true);
            if (processHandleUnhandledRejection(context, reason_value, promise) catch return) return;
            emitUnhandledRejectionWarning(globalObject, reason) catch |err| {
                @import("./Task.zig").reportErrorOrTerminate(globalObject, err) catch return;
            };
            return;
        },
        .throw => {
            if (processHandleUnhandledRejection(context, reason_value, promise) catch return) {
                this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                    error.JSTerminated => {}, // we are returning anyway
                };
                return;
            }
            const wrapped_reason = wrapUnhandledRejectionErrorForUncaughtException(globalObject, reason) catch |err| {
                @import("./Task.zig").reportErrorOrTerminate(globalObject, err) catch {};
                return;
            };
            if (this.uncaughtException(globalObject, wrapped_reason, true)) {
                this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                    error.JSTerminated => {}, // we are returning anyway
                };
                return;
            }
            // continue to default handler
            this.eventLoop().drainMicrotasks() catch |e| switch (e) {
                error.JSTerminated => return,
            };
        },
    }
    this.unhandled_error_counter += 1;
    this.onUnhandledRejection(this, globalObject, reason);
    return;
}

pub fn uncaughtException(this: *jsc.VirtualMachine, globalObject: *JSGlobalObject, err: JSValue, is_rejection: bool) bool {
    if (this.isShuttingDown()) {
        return true;
    }

    if (is_bun_test) {
        this.unhandled_error_counter += 1;
        this.onUnhandledRejection(this, globalObject, err);
        return true;
    }

    if (this.is_handling_uncaught_exception) {
        this.runErrorHandler(err, null);
        this.exitProcess(7);
        @panic("Uncaught exception while handling uncaught exception");
    }
    if (this.exit_on_uncaught_exception) {
        this.runErrorHandler(err, null);
        this.exitProcess(1);
        @panic("made it past Bun__Process__exit");
    }
    this.is_handling_uncaught_exception = true;
    defer this.is_handling_uncaught_exception = false;
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(globalObject);
    defer scope.deinit();
    const error_result = scope.engineIn("errors", "jsValueToError").call(.{ .value = BindingEscape.borrowEngineValue(&scope, err) });
    const handled = scope.engine(ProcessHandleUncaughtExceptionShim).call(.{
        .exception = if (error_result) |result| result.operand(&scope) else BindingEscape.borrowEngineValue(&scope, err),
        .isRejection = is_rejection,
    }) catch true;
    if (!handled) {
        // TODO maybe we want a separate code path for uncaught exceptions
        this.unhandled_error_counter += 1;
        this.exit_handler.exit_code = 1;
        this.onUnhandledRejection(this, globalObject, err);
    }
    return handled;
}

pub fn reportExceptionInHotReloadedModuleIfNeeded(this: *jsc.VirtualMachine) void {
    defer this.addMainToWatcherIfNeeded();
    var promise = if (this.pending_entry_promise) |*pending| pending.clone() else return;
    defer promise.deinit();
    switch (this.entryPointPromiseStatus(&promise)) {
        .pending => return,
        .rejected => if (this.pending_entry_promise_reported_at != this.hot_reload_counter) {
            this.pending_entry_promise_reported_at = this.hot_reload_counter;
            this.reportUnhandledEntryPoint(&promise) catch |err| this.global.reportUncaughtExceptionFromError(err);
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(this.global);
            defer scope.deinit();
            scope.engineIn("promises", "promiseSetHandled").call(.{ .promise = promise.operand(&scope) });
        },
        .fulfilled => {},
    }

    if (this.hot_reload_deferred) {
        this.reload(null);
    }
}

pub fn addMainToWatcherIfNeeded(this: *jsc.VirtualMachine) void {
    if (this.isWatcherEnabled()) {
        const main = this.main;
        if (main.len == 0) return;
        _ = this.bun_watcher.addFileByPathSlow(main, this.transpiler.options.loader(std.fs.path.extension(main)), null);
    }
}

pub fn defaultOnUnhandledRejection(this: *jsc.VirtualMachine, _: *JSGlobalObject, value: JSValue) void {
    this.runErrorHandler(value, this.onUnhandledRejectionExceptionList);
    this.reported_unhandled_rejection = true;
}

pub fn useDefaultUnhandledRejectionHandler(this: *VirtualMachine) void {
    this.onUnhandledRejection = defaultOnUnhandledRejection;
}

pub fn hasReportedUnhandledRejection(this: *const VirtualMachine) bool {
    return this.reported_unhandled_rejection;
}

pub inline fn packageManager(this: *VirtualMachine) *PackageManager {
    return this.transpiler.resolver.package_manager orelse @panic("package manager accessed before successful initialization");
}

pub fn garbageCollect(this: *const VirtualMachine, sync: bool) usize {
    @branchHint(.cold);
    defer Global.mimalloc_cleanup(false);
    const heap_size = if (sync) this.global.vm().runGC(true) else blk: {
        this.global.vm().collectAsync();
        break :blk this.global.vm().heapSize();
    };
    // Sweep only queues native destruction; teardown runs after the engine call returns.
    if (this.rare_data) |rare| rare.drainNativeFinalizers();
    if (sync) jsc.wtf.releaseFastMallocFreeMemory();
    return heap_size;
}

pub inline fn autoGarbageCollect(this: *const VirtualMachine) void {
    if (this.aggressive_garbage_collection != .none) {
        _ = this.garbageCollect(this.aggressive_garbage_collection == .aggressive);
    }
}

pub fn reload(this: *VirtualMachine, _: ?*HotReloader.Task) void {
    // The C++ module loader is async: reloadEntryPoint() returns while the
    // fetch/link/evaluate chain is still draining via microtasks. Kicking
    // off another clearAll() before that chain settles lets the two loads
    // race through one registry. Defer instead; the main loop reschedules
    // via reportExceptionInHotReloadedModuleIfNeeded once the in-flight
    // promise resolves or rejects.
    //
    // Also defer when the previous promise has rejected but its error
    // hasn't been printed yet: reloadEntryPoint() re-transpiles and
    // overwrites source_mappings[path] in place, so a watcher event that
    // slips in between the rejection microtask and the report would remap
    // that error against the wrong sourcemap.
    if (this.pending_entry_promise) |*p| {
        switch (this.entryPointPromiseStatus(p)) {
            .pending => {
                this.hot_reload_deferred = true;
                return;
            },
            .rejected => if (this.pending_entry_promise_reported_at != this.hot_reload_counter) {
                this.hot_reload_deferred = true;
                return;
            },
            .fulfilled => {},
        }
    }
    this.hot_reload_deferred = false;

    Output.debug("Reloading...", .{});
    const should_clear_terminal = !this.transpiler.env.hasSetNoClearTerminalOnReload(!Output.enable_ansi_colors_stdout);
    if (this.hot_reload == .watch) {
        Output.flush();
        bun.reloadProcess(
            bun.default_allocator,
            should_clear_terminal,
            false,
        );
    }

    if (should_clear_terminal) {
        Output.flush();
        Output.disableBuffering();
        Output.resetTerminalAll();
        Output.enableBuffering();
    }

    jsc.API.cron.CronJob.clearAllForVM(this, .reload);
    this.global.reload() catch |err| {
        this.reportReloadFailure(err);
        return;
    };
    this.hot_reload_counter += 1;
    this.clearPendingEntryPromise();
    // reloadEntryPoint() stores into pending_entry_promise on every return path.
    var promise = this.reloadEntryPoint(this.main) catch |err| {
        this.reportReloadFailure(err);
        return;
    };
    promise.deinit();
}

fn reportReloadFailure(this: *VirtualMachine, err: anyerror) void {
    const failure: bun.JSError = switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.JSError => error.JSError,
        error.JSTerminated => error.JSTerminated,
        else => this.global.throwError(err, "while reloading"),
    };
    this.global.reportUncaughtExceptionFromError(failure);
}

pub inline fn nodeFS(this: *VirtualMachine) *Node.fs.NodeFS {
    return this.node_fs orelse brk: {
        this.node_fs = bun.default_allocator.create(Node.fs.NodeFS) catch unreachable;
        this.node_fs.?.* = Node.fs.NodeFS{
            .runtime_io = this.io,
        };
        break :brk this.node_fs.?;
    };
}

pub inline fn rareData(this: *VirtualMachine) *jsc.RareData {
    return bun.handleOom(this.tryRareData());
}

pub fn tryRareData(this: *VirtualMachine) bun.OOM!*jsc.RareData {
    return this.rare_data orelse brk: {
        this.rare_data = try this.allocator.create(jsc.RareData);
        this.rare_data.?.* = .{
            .io = this.io,
            .ssl_ctx_cache = .init(this.io),
        };
        this.rare_data.?.native_finalizer_queue.init(this);
        // LSAN needs an explicit root for native sockets reachable through
        // RareData because it does not scan this allocator's pages.
        bun.asan.registerRootRegion(this.rare_data.?, @sizeOf(jsc.RareData));
        break :brk this.rare_data.?;
    };
}

pub inline fn eventLoop(this: *VirtualMachine) *EventLoop {
    return this.event_loop;
}

pub fn runtimeLoopHandle(this: *VirtualMachine) bun.RuntimeLoopHandle {
    return jsc.EventLoopHandle.init(this).runtimeLoopHandle();
}

pub fn parentEventLoop(this: *VirtualMachine) bun.ParentEventLoop {
    return jsc.EventLoopHandle.init(this).parentEventLoop();
}

pub fn onBeforeExit(this: *VirtualMachine) void {
    this.exit_handler.dispatchOnBeforeExit();
    var dispatch = false;
    while (true) {
        while (this.isEventLoopAlive()) : (dispatch = true) {
            this.tick();
            this.eventLoop().autoTickActive();
        }

        if (dispatch) {
            this.exit_handler.dispatchOnBeforeExit();
            dispatch = false;

            if (this.isEventLoopAlive()) continue;
        }

        break;
    }
}

pub fn scriptExecutionStatus(this: *const VirtualMachine) jsc.ScriptExecutionStatus {
    if (this.is_shutting_down) {
        return .stopped;
    }

    if (this.worker) |worker| {
        if (worker.hasRequestedTerminate()) {
            return .stopped;
        }
    }

    return .running;
}

pub fn onExit(this: *VirtualMachine) void {
    // Write CPU profile if profiling was enabled - do this FIRST before any shutdown begins
    // Grab the config and null it out to make this idempotent
    if (this.cpu_profiler_config) |config| {
        this.cpu_profiler_config = null;
        CPUProfiler.stopAndWriteProfile(this.io, this.jsc_vm, config) catch |err| {
            Output.err(err, "Failed to write CPU profile", .{});
        };
    }

    // Write heap profile if profiling was enabled - do this after CPU profile but before shutdown
    // Grab the config and null it out to make this idempotent
    if (this.heap_profiler_config) |config| {
        this.heap_profiler_config = null;
        HeapProfiler.generateAndWriteProfile(this.io, this.global, config) catch |err| {
            Output.err(err, "Failed to write heap profile", .{});
        };
    }

    this.exit_handler.dispatchOnExit();
    this.is_shutting_down = true;
    bun.bindgen.Engine(ShutdownWebViewTransportsShim).call(.{ .vm = @ptrCast(this.jsc_vm) });
    this.transpiler.resolver.watcher = null;
    this.bun_watcher.deinit();
    this.module_loader.deinitCommonJSExtensions(this);

    const rare_data = this.rare_data orelse return;
    rare_data.closeNativeCompletions();
    rare_data.closeDNSResolvers();
    rare_data.drainNativeFinalizers();
    defer rare_data.cleanup_hooks.clearAndFree(bun.default_allocator);
    // Make sure we run new cleanup hooks introduced by running cleanup hooks
    while (rare_data.cleanup_hooks.items.len > 0) {
        var hooks = rare_data.cleanup_hooks;
        defer hooks.deinit(bun.default_allocator);
        rare_data.cleanup_hooks = .empty;
        for (hooks.items) |hook| {
            hook.execute();
        }
    }
}

pub fn exitProcess(this: *VirtualMachine, code: u8) void {
    this.exit_handler.exit_code = code;
    if (this.worker) |worker| {
        worker.exit();
        return;
    }
    this.onExit();
    bun.Global.exitWithoutCleanup(this.exit_handler.exit_code);
}

pub fn globalExit(this: *VirtualMachine) noreturn {
    bun.assert(this.isShuttingDown());
    // FIXME: we should be doing this, but we're not, but unfortunately doing it
    //        causes like 50+ tests to break
    // this.eventLoop().tick();

    jsc.Debugger.stopAndJoin(this);
    const exit_code = this.exit_handler.exit_code;
    if (this.shouldDestructMainThreadOnExit() and !this.destructOnExit()) {
        bun.Global.exitWithoutCleanup(exit_code);
    }
    bun.Global.exit(exit_code);
}

pub fn destructOnExit(this: *VirtualMachine) bool {
    bun.assert(this.isShuttingDown());
    if (this.stopChildThreads(10_000) == .timed_out) {
        Output.errGeneric("Timed out while stopping worker threads", .{});
        return false;
    }
    {
        const api_lock = this.jsc_vm.getAPILock();
        defer api_lock.release();
        this.prepareForJSCDestruction();
    }
    if (!bun.bindgen.Engine(GlobalObjectDestructOnExitShim).call(.{ .globalObject = @ptrCast(this.global) })) return false;
    // Finalization can close sockets after the native groups have drained.
    uws.Loop.get().drainClosedSockets();
    this.transpiler.deinit();
    this.gc_controller.deinit();
    this.deinit();
    return true;
}

pub fn nextAsyncTaskID(this: *VirtualMachine) u64 {
    var debugger: *jsc.Debugger = &(this.debugger orelse return 0);
    debugger.next_debugger_id +%= 1;
    return debugger.next_debugger_id;
}

pub fn hotMap(this: *VirtualMachine) ?*jsc.RareData.HotMap {
    if (this.hot_reload != .hot) {
        return null;
    }

    return this.rareData().hotMap(this.allocator);
}

pub inline fn enqueueTask(this: *VirtualMachine, task: jsc.Task) void {
    this.eventLoop().enqueueTask(task);
}

pub inline fn enqueueImmediateTask(this: *VirtualMachine, task: *bun.api.Timer.ImmediateObject) void {
    this.eventLoop().enqueueImmediateTask(task);
}

pub inline fn enqueueTaskConcurrent(this: *VirtualMachine, task: *jsc.ConcurrentTask) void {
    this.eventLoop().enqueueTaskConcurrent(task);
}

pub fn tick(this: *VirtualMachine) void {
    this.eventLoop().tick();
}

pub fn waitFor(this: *VirtualMachine, cond: *bool) void {
    while (!cond.*) {
        this.eventLoop().tick();

        if (!cond.*) {
            this.eventLoop().autoTick();
        }
    }
}

pub fn waitForTasks(this: *VirtualMachine) void {
    while (this.isEventLoopAlive()) {
        this.eventLoop().tick();

        if (this.isEventLoopAlive()) {
            this.eventLoop().autoTick();
        }
    }
}

const MacroModeScope = struct {
    vm: *VirtualMachine,
    target: options.Target,
    use_alternate_source_cache: bool,
    macro_mode: bool,
    event_loop: *EventLoop,
    transpiler_store_enabled: bool,

    pub fn deinit(scope: *const MacroModeScope) void {
        const vm = scope.vm;
        vm.transpiler.options.target = scope.target;
        vm.transpiler.resolver.caches.fs.use_alternate_source_cache = scope.use_alternate_source_cache;
        vm.macro_mode = scope.macro_mode;
        vm.event_loop = scope.event_loop;
        vm.transpiler_store.enabled = scope.transpiler_store_enabled;
    }
};

pub fn enterMacroMode(this: *VirtualMachine) MacroModeScope {
    const scope: MacroModeScope = .{
        .vm = this,
        .target = this.transpiler.options.target,
        .use_alternate_source_cache = this.transpiler.resolver.caches.fs.use_alternate_source_cache,
        .macro_mode = this.macro_mode,
        .event_loop = this.event_loop,
        .transpiler_store_enabled = this.transpiler_store.enabled,
    };
    if (!this.has_enabled_macro_mode) {
        this.has_enabled_macro_mode = true;
        this.macro_event_loop.tasks = .{};
        this.macro_event_loop.global = this.global;
        this.macro_event_loop.virtual_machine = this;
        this.macro_event_loop.concurrent_tasks = .{};
        ensureSourceCodePrinter(this);
    }

    this.transpiler.options.target = .bun_macro;
    this.transpiler.resolver.caches.fs.use_alternate_source_cache = true;
    this.macro_mode = true;
    this.event_loop = &this.macro_event_loop;
    bun.analytics.Features.macros += 1;
    this.transpiler_store.enabled = false;
    return scope;
}

pub fn isWatcherEnabled(this: *VirtualMachine) bool {
    return this.bun_watcher != .none;
}

/// Instead of storing timestamp as a i128, we store it as a u64.
/// We subtract the timestamp from Jan 1, 2000 (Y2K)
pub const origin_relative_epoch = 946684800 * std.time.ns_per_s;
fn getOriginTimestamp() u64 {
    const now = @max(bun.timespec.realNow().nsSigned(), origin_relative_epoch);
    return @intCast(now - origin_relative_epoch);
}

pub inline fn isLoaded() bool {
    return VMHolder.vm != null;
}
pub fn initWithModuleGraph(
    opts: Options,
) !*VirtualMachine {
    _ = try uws.Loop.ensure();
    const allocator = opts.allocator;
    VMHolder.vm = try allocator.create(VirtualMachine);
    const console = try allocator.create(ConsoleObject);
    console.init(Output.rawErrorWriter(), Output.rawWriter());
    const log = opts.log.?;
    const transpiler = try Transpiler.init(
        allocator,
        opts.io,
        log,
        opts.args,
        transpiler_engine_capabilities,
        null,
    );
    var vm = VMHolder.vm.?;

    vm.* = VirtualMachine{
        .global = undefined,
        .transpiler_store = RuntimeTranspilerStore.init(),
        .allocator = allocator,
        .io = opts.io,
        .pinned_threads = opts.pinned_threads,
        .background_tasks = .init(opts.pinned_threads.backgroundExecutor()),
        .entry_point = ServerEntryPoint{},
        .transpiler = transpiler,
        .console = console,
        .log = log,
        .timer = bun.api.Timer.All.init(opts.io),
        .origin = transpiler.options.origin,
        .saved_source_map_table = SavedSourceMap.HashTable.init(bun.default_allocator),
        .source_mappings = undefined,
        .origin_timer = SystemTimer.start() catch unreachable,
        .origin_timestamp = getOriginTimestamp(),
        .ref_strings = jsc.RefString.Map.init(allocator),
        .ref_strings_mutex = .init,
        .standalone_module_graph = opts.graph.?,
        .initial_script_execution_context_identifier = if (opts.is_main_thread) 1 else std.math.maxInt(i32),
    };
    errdefer vm.background_tasks.deinit();
    vm.source_mappings.init(vm.io, &vm.saved_source_map_table);
    vm.regular_event_loop.virtual_machine = vm;
    vm.regular_event_loop.concurrent_tasks = .{};
    vm.event_loop = &vm.regular_event_loop;
    vm.transpiler.resolver.package_manager_event_loop = PackageManagerEngine.forEventLoop(vm.event_loop);

    vm.transpiler.resolver.store_fd = false;
    vm.transpiler.resolver.prefer_module_field = false;

    vm.transpiler.resolver.onWakePackageManager = vm.modules.initWakeHandler();
    errdefer vm.modules.close();

    // Emitting "@__PURE__" comments at runtime is a waste of memory and time.
    vm.transpiler.options.emit_dce_annotations = false;

    vm.transpiler.resolver.standalone_module_graph = opts.graph.?;

    // Avoid reading from tsconfig.json & package.json when we're in standalone mode
    vm.transpiler.configureLinkerWithAutoJSX(false);

    vm.transpiler.clearMacroContext();
    if (opts.is_main_thread) {
        VMHolder.main_thread_vm = vm;
        vm.is_main_thread = true;
    }
    bun.RuntimeConfig.is_smol_mode = opts.smol;
    vm.global = JSGlobalObject.create(
        vm,
        vm.initial_script_execution_context_identifier,
        false,
        false,
        null,
    );
    vm.regular_event_loop.global = vm.global;
    vm.jsc_vm = vm.global.vm();
    jsc.setLoopVM(uws.Loop.get(), vm.jsc_vm);
    bun.ParentDeathWatchdog.installOnEventLoop(vm.runtimeLoopHandle());

    if (opts.debugger) |debugger| vm.configureDebugger(debugger);
    vm.body_value_hive_allocator = Body.Value.HiveAllocator.init(bun.typedAllocator(jsc.WebCore.Body.Value));

    return vm;
}

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pinned_threads: *bun.PinnedThreadDomain,
    args: api.TransformOptions,
    log: ?*logger.Log = null,
    env_loader: ?*DotEnv.Loader = null,
    store_fd: bool = false,
    smol: bool = false,
    dns_result_order: DNSResolver.Order = .verbatim,

    // --print needs the result from evaluating the main module
    eval: bool = false,

    graph: ?*bun.StandaloneModuleGraph = null,
    // null also disables inspector settings inherited from the environment.
    debugger: ?bun.cli.Command.Debugger = .{ .unspecified = {} },
    is_main_thread: bool = false,
};

pub fn initMacro(opts: struct {
    io: std.Io,
    pinned_threads: *bun.PinnedThreadDomain,
    args: api.TransformOptions,
    log: *logger.Log,
    environment: *const DotEnv.Loader,
}) !*VirtualMachine {
    const configuration = try Config.OwnedMacroConfiguration.create(opts.args, opts.environment, opts.log.level);
    errdefer configuration.destroy();
    const vm = init(.{
        .allocator = bun.default_allocator,
        .io = opts.io,
        .pinned_threads = opts.pinned_threads,
        .args = configuration.args,
        .log = &configuration.log,
        .env_loader = &configuration.environment.loader,
    }) catch |err| {
        try configuration.log.appendTo(opts.log);
        return err;
    };
    vm.macro_configuration = configuration;
    return vm;
}

pub fn init(opts: Options) !*VirtualMachine {
    _ = try uws.Loop.ensure();
    const allocator = opts.allocator;
    var log: *logger.Log = undefined;
    if (opts.log) |__log| {
        log = __log;
    } else {
        log = try allocator.create(logger.Log);
        log.* = logger.Log.init(allocator);
    }
    errdefer if (opts.log == null) {
        log.deinit();
        allocator.destroy(log);
    };

    const vm = try allocator.create(VirtualMachine);
    errdefer allocator.destroy(vm);
    const console = try allocator.create(ConsoleObject);
    errdefer allocator.destroy(console);
    console.init(Output.rawErrorWriter(), Output.rawWriter());
    const transpiler = try Transpiler.init(
        allocator,
        opts.io,
        log,
        try Config.configureTransformOptionsForBunVM(allocator, opts.args),
        transpiler_engine_capabilities,
        opts.env_loader,
    );
    vm.* = VirtualMachine{
        .global = undefined,
        .transpiler_store = RuntimeTranspilerStore.init(),
        .allocator = allocator,
        .io = opts.io,
        .pinned_threads = opts.pinned_threads,
        .background_tasks = .init(opts.pinned_threads.backgroundExecutor()),
        .entry_point = ServerEntryPoint{},
        .transpiler = transpiler,
        .console = console,
        .log = log,
        .owns_log = opts.log == null,

        .timer = bun.api.Timer.All.init(opts.io),

        .origin = transpiler.options.origin,

        .saved_source_map_table = SavedSourceMap.HashTable.init(bun.default_allocator),
        .source_mappings = undefined,
        .origin_timer = SystemTimer.start() catch unreachable,
        .origin_timestamp = getOriginTimestamp(),
        .ref_strings = jsc.RefString.Map.init(allocator),
        .ref_strings_mutex = .init,
        .initial_script_execution_context_identifier = if (opts.is_main_thread) 1 else std.math.maxInt(i32),
    };
    VMHolder.vm = vm;
    if (opts.is_main_thread) VMHolder.main_thread_vm = vm;
    errdefer vm.background_tasks.deinit();
    vm.source_mappings.init(vm.io, &vm.saved_source_map_table);
    vm.regular_event_loop.virtual_machine = vm;
    vm.regular_event_loop.concurrent_tasks = .{};
    vm.event_loop = &vm.regular_event_loop;
    vm.transpiler.resolver.package_manager_event_loop = PackageManagerEngine.forEventLoop(vm.event_loop);

    // Emitting "@__PURE__" comments at runtime is a waste of memory and time.
    vm.transpiler.options.emit_dce_annotations = false;

    vm.transpiler.resolver.store_fd = opts.store_fd;
    vm.transpiler.resolver.prefer_module_field = false;
    vm.transpiler.resolver.opts.preserve_symlinks = opts.args.preserve_symlinks orelse false;

    vm.transpiler.resolver.onWakePackageManager = vm.modules.initWakeHandler();
    errdefer vm.modules.close();

    vm.transpiler.configureLinker();

    vm.transpiler.clearMacroContext();

    vm.global = JSGlobalObject.create(
        vm,
        vm.initial_script_execution_context_identifier,
        opts.smol,
        opts.eval,
        null,
    );
    vm.regular_event_loop.global = vm.global;
    vm.jsc_vm = vm.global.vm();
    jsc.setLoopVM(uws.Loop.get(), vm.jsc_vm);
    vm.smol = opts.smol;
    vm.dns_result_order = opts.dns_result_order;
    if (opts.is_main_thread) bun.ParentDeathWatchdog.installOnEventLoop(vm.runtimeLoopHandle());

    if (opts.smol)
        bun.RuntimeConfig.is_smol_mode = opts.smol;

    if (opts.debugger) |debugger| vm.configureDebugger(debugger);
    vm.body_value_hive_allocator = Body.Value.HiveAllocator.init(bun.typedAllocator(jsc.WebCore.Body.Value));

    return vm;
}

fn configureDebugger(this: *VirtualMachine, cli_flag: bun.cli.Command.Debugger) void {
    if (bun.env_var.HYPERFINE_RANDOMIZED_ENVIRONMENT_OFFSET.get() != null) {
        return;
    }

    const unix = bun.env_var.BUN_INSPECT.get();
    const connect_to = bun.env_var.BUN_INSPECT_CONNECT_TO.get();

    const set_breakpoint_on_first_line = unix.len > 0 and strings.endsWith(unix, "?break=1"); // If we should set a breakpoint on the first line
    const wait_for_debugger = unix.len > 0 and strings.endsWith(unix, "?wait=1"); // If we should wait for the debugger to connect before starting the event loop

    const wait_for_connection: jsc.Debugger.Wait = if (set_breakpoint_on_first_line or wait_for_debugger) .forever else .off;

    switch (cli_flag) {
        .unspecified => {
            if (unix.len > 0) {
                this.debugger = .{
                    .path_or_port = null,
                    .from_environment_variable = unix,
                    .wait_for_connection = wait_for_connection,
                    .set_breakpoint_on_first_line = set_breakpoint_on_first_line,
                };
            } else if (connect_to.len > 0) {
                // This works in the vscode debug terminal because that relies on unix or notify being set, which they
                // are in the debug terminal. This branch doesn't reach
                this.debugger = .{
                    .path_or_port = null,
                    .from_environment_variable = connect_to,
                    .wait_for_connection = .off,
                    .set_breakpoint_on_first_line = false,
                    .mode = .connect,
                };
            }
        },
        .enable => {
            this.debugger = .{
                .path_or_port = cli_flag.enable.path_or_port,
                .from_environment_variable = unix,
                .wait_for_connection = if (cli_flag.enable.wait_for_connection) .forever else wait_for_connection,
                .set_breakpoint_on_first_line = set_breakpoint_on_first_line or cli_flag.enable.set_breakpoint_on_first_line,
            };
        },
    }

    if (this.isInspectorEnabled()) {
        // The runtime transpiler cache does not store inline source maps needed
        // by the debugger frontend. Disable it so the printer always runs and
        // generates the inline sourceMappingURL for the inspector.
        bun.js_parser.RuntimeTranspilerCache.is_disabled = true;

        if (this.debugger.?.mode != .connect) {
            this.transpiler.options.minify_identifiers = false;
            this.transpiler.options.minify_syntax = false;
            this.transpiler.options.minify_whitespace = false;
            this.transpiler.options.debugger = true;
        }
    }
}

pub fn initWorker(
    worker: *jsc.WebWorker,
    opts: Options,
) anyerror!*VirtualMachine {
    _ = try uws.Loop.ensure();
    var log: *logger.Log = undefined;
    const allocator = opts.allocator;
    if (opts.log) |__log| {
        log = __log;
    } else {
        log = try allocator.create(logger.Log);
        log.* = logger.Log.init(allocator);
    }

    VMHolder.vm = try allocator.create(VirtualMachine);
    const console = try allocator.create(ConsoleObject);
    console.init(Output.rawErrorWriter(), Output.rawWriter());
    const transpiler = try Transpiler.init(
        allocator,
        opts.io,
        log,
        try Config.configureTransformOptionsForBunVM(allocator, opts.args),
        transpiler_engine_capabilities,
        opts.env_loader,
    );
    var vm = VMHolder.vm.?;

    vm.* = VirtualMachine{
        .global = undefined,
        .allocator = allocator,
        .io = opts.io,
        .pinned_threads = opts.pinned_threads,
        .background_tasks = .init(opts.pinned_threads.backgroundExecutor()),
        .transpiler_store = RuntimeTranspilerStore.init(),
        .entry_point = ServerEntryPoint{},
        .transpiler = transpiler,
        .console = console,
        .log = log,

        .timer = bun.api.Timer.All.init(opts.io),
        .origin = transpiler.options.origin,

        .saved_source_map_table = SavedSourceMap.HashTable.init(bun.default_allocator),
        .source_mappings = undefined,
        .origin_timer = SystemTimer.start() catch unreachable,
        .origin_timestamp = getOriginTimestamp(),
        .ref_strings = jsc.RefString.Map.init(allocator),
        .ref_strings_mutex = .init,
        .standalone_module_graph = worker.parent.standalone_module_graph,
        .worker = worker,
        .initial_script_execution_context_identifier = @as(i32, @intCast(worker.execution_context_id)),
    };
    errdefer vm.background_tasks.deinit();
    vm.source_mappings.init(vm.io, &vm.saved_source_map_table);
    // Emitting "@__PURE__" comments at runtime is a waste of memory and time.
    vm.transpiler.options.emit_dce_annotations = false;

    vm.regular_event_loop.virtual_machine = vm;
    vm.regular_event_loop.concurrent_tasks = .{};
    vm.event_loop = &vm.regular_event_loop;
    vm.transpiler.resolver.package_manager_event_loop = PackageManagerEngine.forEventLoop(vm.event_loop);
    vm.hot_reload = worker.parent.hot_reload;
    vm.transpiler.resolver.store_fd = opts.store_fd;
    vm.transpiler.resolver.prefer_module_field = false;
    vm.transpiler.resolver.onWakePackageManager = vm.modules.initWakeHandler();
    errdefer vm.modules.close();
    vm.transpiler.resolver.standalone_module_graph = opts.graph;

    if (opts.graph == null) {
        vm.transpiler.configureLinker();
    } else {
        vm.transpiler.configureLinkerWithAutoJSX(false);
    }

    vm.smol = opts.smol;
    vm.transpiler.clearMacroContext();

    vm.global = JSGlobalObject.create(
        vm,
        vm.initial_script_execution_context_identifier,
        worker.mini,
        opts.eval,
        worker.cpp_worker,
    );
    vm.regular_event_loop.global = vm.global;
    vm.jsc_vm = vm.global.vm();
    jsc.setLoopVM(uws.Loop.get(), vm.jsc_vm);
    vm.transpiler.setAllocator(allocator);
    vm.body_value_hive_allocator = Body.Value.HiveAllocator.init(bun.typedAllocator(jsc.WebCore.Body.Value));

    return vm;
}

pub fn initBake(opts: Options) anyerror!*VirtualMachine {
    _ = try uws.Loop.ensure();
    const allocator = opts.allocator;
    var log: *logger.Log = undefined;
    if (opts.log) |__log| {
        log = __log;
    } else {
        log = try allocator.create(logger.Log);
        log.* = logger.Log.init(allocator);
    }

    VMHolder.vm = try allocator.create(VirtualMachine);
    const console = try allocator.create(ConsoleObject);
    console.init(Output.rawErrorWriter(), Output.rawWriter());
    const transpiler = try Transpiler.init(
        allocator,
        opts.io,
        log,
        try Config.configureTransformOptionsForBunVM(allocator, opts.args),
        transpiler_engine_capabilities,
        opts.env_loader,
    );
    var vm = VMHolder.vm.?;

    vm.* = VirtualMachine{
        .global = undefined,
        .transpiler_store = RuntimeTranspilerStore.init(),
        .allocator = allocator,
        .io = opts.io,
        .pinned_threads = opts.pinned_threads,
        .background_tasks = .init(opts.pinned_threads.backgroundExecutor()),
        .entry_point = ServerEntryPoint{},
        .transpiler = transpiler,
        .console = console,
        .log = log,
        .timer = bun.api.Timer.All.init(opts.io),
        .origin = transpiler.options.origin,
        .saved_source_map_table = SavedSourceMap.HashTable.init(bun.default_allocator),
        .source_mappings = undefined,
        .origin_timer = SystemTimer.start() catch unreachable,
        .origin_timestamp = getOriginTimestamp(),
        .ref_strings = jsc.RefString.Map.init(allocator),
        .ref_strings_mutex = .init,
        .initial_script_execution_context_identifier = if (opts.is_main_thread) 1 else std.math.maxInt(i32),
    };
    errdefer vm.background_tasks.deinit();
    vm.source_mappings.init(vm.io, &vm.saved_source_map_table);
    vm.regular_event_loop.virtual_machine = vm;
    vm.regular_event_loop.concurrent_tasks = .{};
    vm.event_loop = &vm.regular_event_loop;
    vm.transpiler.resolver.package_manager_event_loop = PackageManagerEngine.forEventLoop(vm.event_loop);
    if (comptime bun.Environment.isWindows) {
        vm.eventLoop().ensureWaker();
        vm.global = @ptrCast(bun.bindgen.Engine(CreateBakeProductionGlobalShim).call(.{}));
        vm.jsc_vm = vm.global.vm();
        jsc.setLoopVM(uws.Loop.get(), vm.jsc_vm);
    } else {
        vm.global = @ptrCast(bun.bindgen.Engine(CreateBakeProductionGlobalShim).call(.{}));
        vm.jsc_vm = vm.global.vm();
        vm.eventLoop().ensureWaker();
    }

    vm.transpiler.resolver.store_fd = opts.store_fd;
    vm.transpiler.resolver.prefer_module_field = false;

    vm.transpiler.resolver.onWakePackageManager = vm.modules.initWakeHandler();
    errdefer vm.modules.close();

    vm.transpiler.configureLinker();

    vm.transpiler.clearMacroContext();

    vm.smol = opts.smol;

    if (opts.smol)
        bun.RuntimeConfig.is_smol_mode = opts.smol;

    if (opts.debugger) |debugger| vm.configureDebugger(debugger);
    vm.body_value_hive_allocator = Body.Value.HiveAllocator.init(bun.typedAllocator(jsc.WebCore.Body.Value));

    return vm;
}

pub threadlocal var source_code_printer: ?*js_printer.BufferPrinter = null;

pub fn clearRefString(_: *anyopaque, ref_string: *jsc.RefString) void {
    _ = VirtualMachine.get().ref_strings.remove(ref_string.hash);
}

pub fn refCountedResolvedSource(this: *VirtualMachine, code: []const u8, specifier: bun.String, source_url: []const u8, hash_: ?u32, comptime add_double_ref: bool) ResolvedSource {
    // refCountedString will panic if the code is empty
    if (code.len == 0) {
        return ResolvedSource{
            .source_code = bun.String.empty,
            .source_url = specifier.createIfDifferent(source_url),
            .source_code_needs_deref = false,
        };
    }
    const source = this.refCountedString(code, hash_, !add_double_ref);
    if (add_double_ref) {
        source.ref();
        source.ref();
    }

    return ResolvedSource{
        .source_code = bun.String.init(source.impl),
        .source_url = specifier.createIfDifferent(source_url),
        .source_code_needs_deref = true,
    };
}

pub fn refCountedString(this: *VirtualMachine, input_: []const u8, hash_: ?u32, comptime dupe: bool) *jsc.RefString {
    bun.assert(input_.len > 0);
    const hash = hash_ orelse jsc.RefString.computeHash(input_);
    this.ref_strings_mutex.lockUncancelable(this.io);
    defer this.ref_strings_mutex.unlock(this.io);

    const entry = this.ref_strings.getOrPut(hash) catch unreachable;
    if (!entry.found_existing) {
        const input = if (comptime dupe)
            (this.allocator.dupe(u8, input_) catch unreachable)
        else
            input_;

        const ref = this.allocator.create(jsc.RefString) catch unreachable;
        ref.* = jsc.RefString{
            .allocator = this.allocator,
            .ptr = input.ptr,
            .len = input.len,
            .impl = bun.String.createExternal(.latin1, *jsc.RefString, input, ref, &freeRefString).value.WTFStringImpl,
            .hash = hash,
            .ctx = this,
            .onBeforeDeinit = VirtualMachine.clearRefString,
        };
        entry.value_ptr.* = ref;
    } else {
        entry.value_ptr.*.ref();
    }
    return entry.value_ptr.*;
}

fn freeRefString(str: *jsc.RefString, _: *u8, _: usize) void {
    str.deinit();
}

fn fetchDiagnosticSource(jsc_vm: *VirtualMachine, source_url: *const bun.bindgen.DOMString, log: *logger.Log) anyerror!ResolvedSource {
    var retained = source_url.clone();
    const specifier = retained.takeBunString();
    defer specifier.deref();
    bun.assert(VirtualMachine.isLoaded());

    if (try ModuleLoader.fetchBuiltinModule(jsc_vm, specifier)) |builtin| {
        return builtin;
    }

    const specifier_clone = try specifier.toUTF8(bun.default_allocator);
    defer specifier_clone.deinit();

    var virtual_source_to_use: ?logger.Source = null;
    var blob_to_deinit: ?jsc.WebCore.Blob = null;
    defer if (blob_to_deinit) |*blob| blob.deinit();
    const lr = ModuleLoader.getLoaderAndVirtualSource(specifier_clone.slice(), jsc_vm, &virtual_source_to_use, &blob_to_deinit, null) catch |err| switch (err) {
        error.BlobNotFound => return error.ModuleNotFound,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const module_type: options.ModuleType = if (lr.package_json) |pkg| pkg.module_type else .unknown;

    errdefer jsc_vm.module_loader.resetArena(jsc_vm);

    return try ModuleLoader.transpileSourceCode(
        jsc_vm,
        lr.specifier,
        "",
        specifier,
        lr.path,
        lr.loader orelse if (lr.is_main) .js else .file,
        module_type,
        log,
        lr.virtual_source,
        null,
        VirtualMachine.source_code_printer.?,
        jsc_vm.global,
        .print_source,
    );
}

pub const ResolveFunctionResult = struct {
    result: ?Resolver.Result,
    path: string,
    query_string: []const u8 = "",
};

fn normalizeSpecifierForResolution(specifier_: []const u8, query_string: *[]const u8) []const u8 {
    var specifier = specifier_;

    if (strings.indexOfChar(specifier, '?')) |i| {
        query_string.* = specifier[i..];
        specifier = specifier[0..i];
    }

    return specifier;
}

const specifier_cache_resolver_bufs = bun.ThreadlocalBuffers(struct { buf: bun.PathBuffer = undefined });
fn _resolve(
    jsc_vm: *VirtualMachine,
    ret: *ResolveFunctionResult,
    specifier: string,
    source: string,
    is_esm: bool,
    comptime is_a_file_path: bool,
) !void {
    if (strings.eqlComptime(std.fs.path.basename(specifier), Runtime.Runtime.Imports.alt_name)) {
        ret.path = Runtime.Runtime.Imports.Name;
        return;
    } else if (strings.eqlComptime(specifier, main_file_name) and jsc_vm.entry_point.generated) {
        ret.result = null;
        ret.path = main_file_name;
        return;
    } else if (strings.hasPrefixComptime(specifier, js_ast.Macro.namespaceWithColon)) {
        ret.result = null;
        ret.path = specifier;
        return;
    } else if (strings.hasPrefixComptime(specifier, node_fallbacks.import_path)) {
        ret.result = null;
        ret.path = specifier;
        return;
    } else if (jsc.ModuleLoader.HardcodedModule.Alias.get(specifier, .bun, .{})) |result| {
        ret.result = null;
        ret.path = result.path;
        return;
    } else if (jsc_vm.module_loader.eval_source != null and
        (strings.endsWithComptime(specifier, bun.pathLiteral("/[eval]")) or
            strings.endsWithComptime(specifier, bun.pathLiteral("/[stdin]"))))
    {
        ret.result = null;
        ret.path = specifier;
        return;
    } else if (strings.hasPrefixComptime(specifier, "blob:")) {
        ret.result = null;
        if (jsc.WebCore.ObjectURLRegistry.singleton().has(jsc_vm.io, specifier["blob:".len..])) {
            ret.path = specifier;
            return;
        } else {
            return error.ModuleNotFound;
        }
    }

    const is_special_source = strings.eqlComptime(source, main_file_name) or js_ast.Macro.isMacroPath(source);
    var query_string: []const u8 = "";
    const normalized_specifier = normalizeSpecifierForResolution(specifier, &query_string);
    const source_to_use = if (!is_special_source)
        if (is_a_file_path)
            std.fs.path.dirname(source) orelse "."
        else
            source
    else
        jsc_vm.transpiler.fs.top_level_dir;

    const result: Resolver.Result = try brk: {
        // TODO: We only want to retry on not found only when the directories we searched for were cached.
        // This fixes an issue where new files created in cached directories were not picked up.
        // See https://github.com/oven-sh/bun/issues/3216
        //
        // This cache-bust is disabled when the filesystem is not being used to resolve.
        var retry_on_not_found = std.fs.path.isAbsolute(source_to_use);
        while (true) {
            break :brk switch (jsc_vm.transpiler.resolver.resolveAndAutoInstall(
                source_to_use,
                normalized_specifier,
                if (is_esm) .stmt else .require,
                jsc_vm.transpiler.resolver.opts.global_cache,
            )) {
                .success => |r| r,
                .failure => |e| e,
                .pending, .not_found => if (!retry_on_not_found)
                    error.ModuleNotFound
                else {
                    retry_on_not_found = false;

                    const specifier_cache_resolver_buf = &specifier_cache_resolver_bufs.get().buf;
                    const buster_name = name: {
                        if (std.fs.path.isAbsolute(normalized_specifier)) {
                            if (std.fs.path.dirname(normalized_specifier)) |dir| {
                                if (dir.len > specifier_cache_resolver_buf.len) {
                                    return error.ModuleNotFound;
                                }
                                // Normalized without trailing slash
                                break :name bun.strings.normalizeSlashesOnly(specifier_cache_resolver_buf, dir, std.fs.path.sep);
                            }
                        }

                        // If the specifier is too long to join, it can't name a real
                        // directory — skip the cache bust and fail.
                        if (source_to_use.len + normalized_specifier.len + 4 >= specifier_cache_resolver_buf.len) {
                            return error.ModuleNotFound;
                        }

                        var parts = [_]string{
                            source_to_use,
                            normalized_specifier,
                            bun.pathLiteral(".."),
                        };

                        break :name bun.path.joinAbsStringBufZ(
                            jsc_vm.transpiler.fs.top_level_dir,
                            specifier_cache_resolver_buf,
                            &parts,
                            .auto,
                        );
                    };

                    // Only re-query if we previously had something cached.
                    if (jsc_vm.transpiler.resolver.bustDirCache(bun.strings.withoutTrailingSlashWindowsPath(buster_name))) {
                        continue;
                    }

                    return error.ModuleNotFound;
                },
            };
        }
    };

    if (!jsc_vm.macro_mode) {
        jsc_vm.has_any_macro_remappings = jsc_vm.has_any_macro_remappings or jsc_vm.transpiler.options.macro_remap.count() > 0;
    }
    ret.result = result;
    ret.query_string = query_string;
    const result_path = result.pathConst() orelse return error.ModuleNotFound;
    ret.path = result_path.text;
}

pub fn resolve(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    query_string: ?*bun.String,
    is_esm: bool,
) bun.JSError!bun.String {
    return resolveMaybeNeedsTrailingSlash(global, specifier, source, query_string, is_esm, true, false);
}

fn normalizeSource(source: []const u8) []const u8 {
    if (strings.hasPrefixComptime(source, "file://")) {
        return source["file://".len..];
    }

    return source;
}

pub fn resolveMaybeNeedsTrailingSlash(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    query_string: ?*bun.String,
    is_esm: bool,
    comptime is_a_file_path: bool,
    is_user_require_resolve: bool,
) bun.JSError!bun.String {
    return (try resolveWithFailureMode(global, specifier, source, query_string, is_esm, is_a_file_path, is_user_require_resolve, .raise)) orelse unreachable;
}

const ResolveFailureMode = enum { raise, return_null };

fn resolveWithFailureMode(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    query_string: ?*bun.String,
    is_esm: bool,
    comptime is_a_file_path: bool,
    is_user_require_resolve: bool,
    comptime failure_mode: ResolveFailureMode,
) bun.JSError!?bun.String {
    if (is_a_file_path and specifier.length() > comptime @as(u32, @intFromFloat(@trunc(@as(f64, @floatFromInt(bun.MAX_PATH_BYTES)) * 1.5)))) {
        if (failure_mode == .return_null) return null;
        const specifier_utf8 = try specifier.toUTF8(bun.default_allocator);
        defer specifier_utf8.deinit();
        const source_utf8 = try source.toUTF8(bun.default_allocator);
        defer source_utf8.deinit();
        const import_kind: bun.ImportKind = if (is_esm) .stmt else if (is_user_require_resolve) .require_resolve else .require;
        const printed = try bun.api.ResolveMessage.fmt(
            bun.default_allocator,
            specifier_utf8.slice(),
            source_utf8.slice(),
            error.NameTooLong,
            import_kind,
        );
        defer bun.default_allocator.free(printed);
        const msg = logger.Msg{
            .data = logger.rangeData(
                null,
                logger.Range.None,
                printed,
            ),
            .metadata = .{ .resolve = .{
                .specifier = logger.MessageSubstring.in(printed, specifier_utf8.slice()),
                .import_kind = import_kind,
                .err = error.NameTooLong,
            } },
        };
        return global.throwValue(try bun.api.ResolveMessage.Binding.adoptNative(
            try bun.api.ResolveMessage.createNative(msg, source_utf8.slice()),
            global,
        ));
    }

    var result = ResolveFunctionResult{ .path = "", .result = null };
    const jsc_vm = global.bunVM();
    const specifier_utf8 = try specifier.toUTF8(bun.default_allocator);
    defer specifier_utf8.deinit();

    const source_utf8 = try source.toUTF8(bun.default_allocator);
    defer source_utf8.deinit();
    if (jsc_vm.plugin_runner) |plugin_runner| {
        if (PluginResolver.couldResolve(specifier_utf8.slice())) {
            const namespace = PluginResolver.extractNamespace(specifier_utf8.slice());
            const after_namespace = if (namespace.len == 0)
                specifier_utf8.slice()
            else
                specifier_utf8.slice()[namespace.len + 1 ..];

            var namespace_value = try bun.bindgen.DOMString.fromUTF8(namespace);
            const namespace_string = namespace_value.takeBunString();
            defer namespace_string.deref();
            var after_namespace_value = try bun.bindgen.DOMString.fromUTF8(after_namespace);
            const after_namespace_string = after_namespace_value.takeBunString();
            defer after_namespace_string.deref();
            if (try plugin_runner.onResolveJSC(namespace_string, after_namespace_string, source, .bun)) |resolved_path| {
                return resolved_path;
            }
        }
    }

    if (jsc.ModuleLoader.HardcodedModule.Alias.get(specifier_utf8.slice(), .bun, .{})) |hardcoded| {
        if (is_user_require_resolve and hardcoded.node_builtin) return specifier.dupeRef();
        var path = try bun.bindgen.DOMString.fromLatin1(hardcoded.path);
        return path.takeBunString();
    }

    const old_log = jsc_vm.log;
    // the logger can end up being called on another thread, it must not use threadlocal Heap Allocator
    var log = logger.Log.init(bun.default_allocator);
    defer log.deinit();
    jsc_vm.log = &log;
    jsc_vm.transpiler.resolver.log = &log;
    jsc_vm.transpiler.linker.log = &log;
    if (jsc_vm.transpiler.resolver.package_manager) |pm| {
        pm.log = &log;
    }
    defer {
        jsc_vm.log = old_log;
        jsc_vm.transpiler.linker.log = old_log;
        jsc_vm.transpiler.resolver.log = old_log;
        if (jsc_vm.transpiler.resolver.package_manager) |pm| {
            pm.log = old_log;
        }
    }
    jsc_vm._resolve(&result, specifier_utf8.slice(), normalizeSource(source_utf8.slice()), is_esm, is_a_file_path) catch |err_| {
        if (err_ == error.OutOfMemory) return error.OutOfMemory;
        if (failure_mode == .return_null) return null;
        var err = err_;
        var owned_message: ?[]const u8 = null;
        defer if (owned_message) |message| jsc_vm.allocator.free(message);
        const msg: logger.Msg = brk: {
            const msgs: []logger.Msg = log.msgs.items;

            for (msgs) |m| {
                if (m.metadata == .resolve) {
                    err = m.metadata.resolve.err;
                    break :brk m;
                }
            }

            const import_kind: bun.ImportKind = if (is_esm)
                .stmt
            else if (is_user_require_resolve)
                .require_resolve
            else
                .require;

            const printed = try bun.api.ResolveMessage.fmt(
                jsc_vm.allocator,
                specifier_utf8.slice(),
                source_utf8.slice(),
                err,
                import_kind,
            );
            owned_message = printed;
            break :brk logger.Msg{
                .data = logger.rangeData(
                    null,
                    logger.Range.None,
                    printed,
                ),
                .metadata = .{
                    .resolve = .{
                        .specifier = logger.MessageSubstring.in(printed, specifier_utf8.slice()),
                        .import_kind = import_kind,
                    },
                },
            };
        };

        return global.throwValue(try bun.api.ResolveMessage.Binding.adoptNative(
            try bun.api.ResolveMessage.createNative(msg, source_utf8.slice()),
            global,
        ));
    };

    var path = try bun.bindgen.DOMString.fromUTF8(result.path);
    defer path.deinit();
    if (query_string) |query| {
        var query_value = try bun.bindgen.DOMString.fromUTF8(result.query_string);
        query.* = query_value.takeBunString();
    }
    return path.takeBunString();
}

pub fn resolveModuleSpecifier(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    is_esm: bool,
    comptime is_file_path: bool,
    is_user_require_resolve: bool,
) bun.JSError!bun.String {
    return (try resolveModuleSpecifierWithFailureMode(global, specifier, source, is_esm, is_file_path, is_user_require_resolve, .raise)) orelse unreachable;
}

pub fn findModuleSpecifier(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
) bun.JSError!?bun.String {
    return resolveModuleSpecifierWithFailureMode(global, specifier, source, false, true, true, .return_null);
}

fn resolveModuleSpecifierWithFailureMode(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    is_esm: bool,
    comptime is_file_path: bool,
    is_user_require_resolve: bool,
    comptime failure_mode: ResolveFailureMode,
) bun.JSError!?bun.String {
    var query_string = bun.String.empty;
    defer query_string.deref();

    const decoded_specifier = if (specifier.hasPrefixComptime("file://"))
        (try bun.jsc.URL.pathFromFileURL(specifier)) orelse specifier.dupeRef()
    else
        specifier.dupeRef();
    defer decoded_specifier.deref();

    const resolved = (try resolveWithFailureMode(
        global,
        decoded_specifier,
        source,
        &query_string,
        is_esm,
        is_file_path,
        is_user_require_resolve,
        failure_mode,
    )) orelse return null;
    if (query_string.isEmpty()) return resolved;

    defer resolved.deref();
    return try bun.String.createFormat("{f}{f}", .{ resolved, query_string });
}

pub fn resolveModuleSpecifierWithPaths(
    global: *JSGlobalObject,
    specifier: bun.String,
    source: bun.String,
    is_esm: bool,
    is_user_require_resolve: bool,
    paths: []const bun.String,
) bun.JSError!bun.String {
    const resolver = &global.bunVM().transpiler.resolver;
    bun.assert(resolver.custom_dir_paths == null);
    resolver.custom_dir_paths = paths;
    defer resolver.custom_dir_paths = null;
    return resolveModuleSpecifier(global, specifier, source, is_esm, true, is_user_require_resolve);
}

pub const main_file_name: string = "bun:main";

pub fn drainMicrotasks(this: *VirtualMachine) bun.JSTerminated!void {
    try this.eventLoop().drainMicrotasks();
}

pub fn processFetchLog(globalThis: *JSGlobalObject, specifier: bun.String, referrer: bun.String, log: *logger.Log, ret: *ResolvedSourceResult, err: anyerror) bun.JSError!void {
    if (err == error.NativeAddonImport) {
        const failure = globalThis.throwTypeError("To load Node-API modules, use require() or process.dlopen instead of import.", .{});
        ret.* = .fail(try jsc.ModuleLoaderEngine.takeFailureAsRoot(globalThis, failure));
        return;
    }
    switch (log.msgs.items.len) {
        0 => {
            const message = if (err == error.UnexpectedPendingResolution)
                try std.fmt.allocPrint(globalThis.allocator(), "Unexpected pending import in \"{f}\". To automatically install npm packages with Bun, please use an import statement instead of require() or dynamic import().\nThis error can also happen if dependencies import packages which are not referenced anywhere. Worst case, run `bun install` and opt-out of the node_modules folder until we come up with a better way to handle this error.", .{specifier})
            else
                try std.fmt.allocPrint(globalThis.allocator(), "{s} while building {f}", .{ @errorName(err), specifier });
            defer globalThis.allocator().free(message);
            const msg: logger.Msg = .{
                .data = logger.rangeData(null, logger.Range.None, message),
            };
            ret.* = .fail(try LoggerEngine.msgToRoot(msg, globalThis));
            return;
        },

        1 => {
            const msg = log.msgs.items[0];
            const referrer_utf8 = try referrer.toUTF8(bun.default_allocator);
            defer referrer_utf8.deinit();
            ret.* = .fail(try LoggerEngine.msgToRootWithReferrer(msg, globalThis, referrer_utf8.slice()));
            return;
        },
        else => {
            const referrer_utf8 = try referrer.toUTF8(bun.default_allocator);
            defer referrer_utf8.deinit();

            const message = try std.fmt.allocPrint(globalThis.allocator(), "{d} errors building \"{f}\"", .{ log.msgs.items.len, specifier });
            defer globalThis.allocator().free(message);
            ret.* = .fail(try LoggerEngine.logToAggregateErrorRoot(log, globalThis, .{ .utf8 = message }, referrer_utf8.slice()));
        },
    }
}

pub fn deinit(this: *VirtualMachine) void {
    bun.assert(this.stopChildThreads(null) == .completed);
    this.worker_children.deinit();
    this.shutdownBackgroundTasks();
    this.auto_killer.deinit();
    this.regular_event_loop.deinit();
    if (this.has_enabled_macro_mode) this.macro_event_loop.deinit();

    if (source_code_printer) |print| {
        print.getMutableBuffer().deinit();
        print.ctx.written = &.{};
    }
    this.source_mappings.deinit();
    if (this.rare_data) |rare_data| {
        jsc.API.cron.CronJob.clearAllForVM(this, .teardown);
        // Paired with rareData()'s registerRootRegion. Without this, every
        // terminated Worker leaves a stale LSAN root entry pointing into a
        // freed arena (harmless to the final leak verdict but accumulates one
        // dead range per Worker for LSAN to scan).
        bun.asan.unregisterRootRegion(rare_data, @sizeOf(jsc.RareData));
        rare_data.deinit();
    }
    this.proxy_env_storage.deinit();
    this.overridden_main.deinit();
    this.entry_point.deinit();
    this.has_terminated = true;
    if (this.macro_configuration) |configuration| {
        this.macro_configuration = null;
        this.transpiler.deinit();
        configuration.destroy();
    }
    if (this.owns_log) {
        this.owns_log = false;
        this.log.deinit();
        this.allocator.destroy(this.log);
    }
}

pub fn shutdownBackgroundTasks(this: *VirtualMachine) void {
    if (this.background_tasks_deinitialized) return;
    this.background_tasks_deinitialized = true;
    this.background_tasks.close(.cancel_operations);
    this.pending_work.discardAll();
}

pub fn stopChildThreads(this: *VirtualMachine, timeout_ms: ?u64) jsc.WebWorker.Children.Shutdown {
    jsc.Debugger.stopAndJoin(this);
    return this.worker_children.closeAndJoin(this, timeout_ms);
}

pub fn prepareForJSCDestruction(this: *VirtualMachine) void {
    this.gc_controller.deinit();
    this.regular_event_loop.deferred_tasks.deinit();
    if (this.has_enabled_macro_mode) this.macro_event_loop.deferred_tasks.deinit();
    bun.bindgen.Engine(bun.bindgen.Module("BunDebugger").engineShim("disconnectInspectorConnections")).call(.{ .vm = @ptrCast(this.jsc_vm) });
    this.clearPendingEntryPromise();
    this.entry_point_result.value.deinit();
    if (this.rare_data) |rare| {
        rare.closeNativeCompletions();
        rare.closeDNSResolvers();
    }
    this.drainNativeFinalizers();
    this.shutdownBackgroundTasks();
    this.modules.close();
    jsc.API.cron.CronJob.clearAllForVM(this, .teardown);
    this.timer.event_loop_delay.deinit(this);
    // Socket close callbacks can run JavaScript, so they must precede JSC teardown.
    if (this.rare_data) |rare| rare.closeAllSocketGroups(this);
    _ = this.regular_event_loop.discardEngineTasks();
    if (this.has_enabled_macro_mode) _ = this.macro_event_loop.discardEngineTasks();
    bun.bindgen.Engine(DetachBindgenWrappersShim).call(.{ .global = @ptrCast(this.global) });
    while (true) {
        this.drainNativeFinalizers();
        var discarded = this.regular_event_loop.discardEngineTasks();
        if (this.has_enabled_macro_mode) discarded += this.macro_event_loop.discardEngineTasks();
        const discarded_microtasks = bun.bindgen.Engine(DiscardQueuedMicrotasksShim).call(.{ .vm = @ptrCast(this.global.vm()) });
        if (discarded == 0 and !discarded_microtasks) break;
    }
}

fn bindDrainNativeFinalizers(
    args: bun.bindgen.Args(DrainNativeFinalizersSchema),
) bun.bindgen.Return(DrainNativeFinalizersSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    vm.drainNativeFinalizers();
}

fn bindCloseNativeFinalizers(
    args: bun.bindgen.Args(CloseNativeFinalizersSchema),
) bun.bindgen.Return(CloseNativeFinalizersSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    if (vm.rare_data) |rare| rare.closeNativeFinalizers();
}

fn bindScriptExecutionStatus(
    args: bun.bindgen.Args(ScriptExecutionStatusSchema),
) bun.bindgen.Return(ScriptExecutionStatusSchema) {
    const vm: *const VirtualMachine = @ptrCast(@alignCast(args.vm));
    return @intCast(@backingInt(vm.scriptExecutionStatus()));
}

fn bindAllowAddons(
    args: bun.bindgen.Args(AllowAddonsSchema),
) bun.bindgen.Return(AllowAddonsSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    return vm.allowAddons();
}

fn bindAllowRejectionHandledWarning(
    args: bun.bindgen.Args(AllowRejectionHandledWarningSchema),
) bun.bindgen.Return(AllowRejectionHandledWarningSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    return vm.allowRejectionHandledWarning();
}

fn bindCurrentVirtualMachineIsMainThread(
    args: bun.bindgen.Args(CurrentVirtualMachineIsMainThreadSchema),
) bun.bindgen.Return(CurrentVirtualMachineIsMainThreadSchema) {
    _ = args;
    return VirtualMachine.get().is_main_thread;
}

fn bindSetDefaultGlobalObject(
    args: bun.bindgen.Args(SetDefaultGlobalObjectSchema),
) bun.bindgen.Return(SetDefaultGlobalObjectSchema) {
    const global: *JSGlobalObject = @ptrCast(@alignCast(args.global));
    VMHolder.setDefaultGlobalObject(global);
}

fn bindGetDefaultGlobalObject(
    args: bun.bindgen.Args(GetDefaultGlobalObjectSchema),
) bun.bindgen.Return(GetDefaultGlobalObjectSchema) {
    _ = args;
    return if (VMHolder.getDefaultGlobalObject()) |global| @ptrCast(global) else null;
}

fn bindGetExitCode(
    args: bun.bindgen.Args(GetExitCodeSchema),
) bun.bindgen.Return(GetExitCodeSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    return vm.exit_handler.exit_code;
}

fn bindSetExitCode(
    args: bun.bindgen.Args(SetExitCodeSchema),
) bun.bindgen.Return(SetExitCodeSchema) {
    const vm: *VirtualMachine = @ptrCast(@alignCast(args.vm));
    vm.exit_handler.exit_code = args.code;
}

fn bindUseIsolationSourceProviderCache(
    args: bun.bindgen.Args(UseIsolationSourceProviderCacheSchema),
) bun.bindgen.Return(UseIsolationSourceProviderCacheSchema) {
    const vm: *const VirtualMachine = @ptrCast(@alignCast(args.vm));
    return vm.useIsolationSourceProviderCache();
}

fn bindSetOverrideModuleRunMain(
    _: bun.bindgen.CallContext(SetOverrideModuleRunMainSchema),
    args: bun.bindgen.Args(SetOverrideModuleRunMainSchema),
) bun.bindgen.Return(SetOverrideModuleRunMainSchema) {
    jsc.ModuleRunMainOperations.setOverrideModuleRunMain(args);
}

fn bindSetOverrideModuleRunMainPromise(
    context: bun.bindgen.CallContext(SetOverrideModuleRunMainPromiseSchema),
    args: bun.bindgen.Args(SetOverrideModuleRunMainPromiseSchema),
) bun.JSError!bun.bindgen.Return(SetOverrideModuleRunMainPromiseSchema) {
    try jsc.ModuleRunMainOperations.setOverrideModuleRunMainPromise(context, args);
}

fn bindLogUnhandledException(
    context: bun.bindgen.CallContext(LogUnhandledExceptionSchema),
    args: bun.bindgen.Args(LogUnhandledExceptionSchema),
) bun.bindgen.Return(LogUnhandledExceptionSchema) {
    jsc.ModuleRunMainOperations.logUnhandledException(context, args);
}

fn bindSpecifierIsEvalEntryPoint(
    context: bun.bindgen.CallContext(SpecifierIsEvalEntryPointSchema),
    args: bun.bindgen.Args(SpecifierIsEvalEntryPointSchema),
) bun.JSError!bun.bindgen.Return(SpecifierIsEvalEntryPointSchema) {
    return jsc.ModuleRunMainOperations.specifierIsEvalEntryPoint(context, args);
}

fn bindSetEntryPointEvalResultESM(
    context: bun.bindgen.CallContext(SetEntryPointEvalResultESMSchema),
    args: bun.bindgen.Args(SetEntryPointEvalResultESMSchema),
) bun.JSError!bun.bindgen.Return(SetEntryPointEvalResultESMSchema) {
    try jsc.ModuleRunMainOperations.setEntryPointEvalResultESM(context, args);
}

fn bindSetEntryPointEvalResultCJS(
    context: bun.bindgen.CallContext(SetEntryPointEvalResultCJSSchema),
    args: bun.bindgen.Args(SetEntryPointEvalResultCJSSchema),
) bun.JSError!bun.bindgen.Return(SetEntryPointEvalResultCJSSchema) {
    try jsc.ModuleRunMainOperations.setEntryPointEvalResultCJS(context, args);
}

pub const ExceptionList = std.array_list.Managed(api.JsException);

pub noinline fn runErrorHandler(this: *VirtualMachine, result: JSValue, exception_list: ?*ExceptionList) void {
    @branchHint(.cold);

    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    const value = BindingEscape.borrowEngineValue(&scope, result);
    const prev_had_errors = this.had_errors;
    this.had_errors = false;
    defer this.had_errors = prev_had_errors;

    const writer = Output.errorWriterBuffered();
    defer {
        writer.flush() catch {};
    }

    var formatter = ConsoleObject.Formatter{
        .globalThis = this.global,
        .quote_strings = false,
        .single_line = false,
        .stack_check = bun.StackCheck.init(),
        .error_display_level = .full,
    };
    defer formatter.deinit();
    switch (Output.enable_ansi_colors_stderr) {
        inline else => |enable_colors| this.printErrorlikeObject(value, exception_list, &formatter, @TypeOf(writer), writer, enable_colors, true) catch |err| this.reportErrorPrintingFailure(err),
    }
}

fn reportErrorPrintingFailure(this: *VirtualMachine, err: bun.JSError) void {
    if (err == error.JSTerminated) return;
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    const exception = scope.takeException(err);
    if (scope.engineIn("errors", "jsValueIsTerminationException").call(.{ .value = exception.operand(&scope).asEngine() })) return;
    Output.printErrorln("Failed to print exception: {s}", .{@errorName(err)});
}

pub fn clearEntryPoint(this: *VirtualMachine) bun.JSError!void {
    if (this.main.len == 0) {
        return;
    }

    try this.global.deleteModuleRegistryEntry(main_file_name);
}

fn loadPreloads(this: *VirtualMachine) !?EntryPointPromise {
    this.is_in_preload = true;
    defer this.is_in_preload = false;

    for (this.preload) |preload| {
        var result = switch (this.transpiler.resolver.resolveAndAutoInstall(
            this.transpiler.fs.top_level_dir,
            normalizeSource(preload),
            .stmt,
            if (this.standalone_module_graph == null) .read_only else .disable,
        )) {
            .success => |r| r,
            .failure => |e| {
                try this.log.addErrorFmt(
                    null,
                    logger.Loc.Empty,
                    this.allocator,
                    "{s} resolving preload {f}",
                    .{
                        @errorName(e),
                        bun.fmt.formatJSONStringLatin1(preload),
                    },
                );
                return e;
            },
            .pending, .not_found => {
                try this.log.addErrorFmt(
                    null,
                    logger.Loc.Empty,
                    this.allocator,
                    "preload not found {f}",
                    .{
                        bun.fmt.formatJSONStringLatin1(preload),
                    },
                );
                return error.ModuleNotFound;
            },
        };
        var preload_path = try bun.bindgen.DOMString.fromUTF8(result.path().?.text);
        defer preload_path.deinit();
        var promise = try this.loadEntryModule(preload_path, "importModule");
        defer promise.deinit();
        this.storePendingEntryPromise(&promise);
        this.eventLoop().performGC();
        var settled = if (this.worker != null)
            try this.waitForPendingEntryPoint(true)
        else
            try this.waitForPendingEntryPoint(false);
        defer settled.deinit();
        if (this.entryPointPromiseStatus(&settled) == .rejected) return settled.take();
    }

    // Under --isolate each test file gets a fresh global, so preloads must
    // re-execute for every file. Otherwise, only load preloads once.
    if (!this.test_isolation_enabled) {
        this.preload.len = 0;
    }

    return null;
}

pub fn ensureDebugger(this: *VirtualMachine, block_until_connected: bool) !void {
    if (this.debugger != null) {
        try jsc.Debugger.create(this, this.global);

        if (block_until_connected) {
            try jsc.Debugger.waitForDebuggerIfNecessary(this);
        }
    }
}

pub fn reloadEntryPoint(this: *VirtualMachine, entry_path: []const u8) !EntryPointPromise {
    this.has_loaded = false;
    this.main = entry_path;
    this.main_resolved_path.deref();
    this.main_resolved_path = .empty;
    this.main_hash = Watcher.getHash(entry_path);
    this.overridden_main.deinit();

    try this.ensureDebugger(true);

    if (!this.main_is_html_entrypoint) {
        try this.entry_point.generate(
            this.bun_watcher != .none,
            entry_path,
        );
    }

    if (!this.transpiler.options.disable_transpilation) {
        if (this.preload.len > 0) {
            if (try this.loadPreloads()) |promise| {
                return promise;
            }

            // Check if Module.runMain was patched
            if (this.has_patched_run_main) {
                @branchHint(.cold);
                this.clearPendingEntryPromise();
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(this.global);
                defer scope.deinit();
                var argument = try bun.bindgen.DOMString.fromUTF8(main_file_name);
                defer argument.deinit();
                const argument_value = try scope.engineIn("js_strings", "stringToJS").call(.{ .value = argument.operand() });
                const result = try scope.engine(CallOverriddenRunMainShim).call(.{
                    .argument = argument_value.operand(&scope).asEngine(),
                });
                // If the override stored a promise itself, use that; otherwise
                // wrap its return value.
                if (this.pending_entry_promise) |*stored| return stored.clone();
                const resolved_value = try scope.engineIn("promises", "promiseCreateResolved").call(.{ .value = result.operand(&scope).asEngine() });
                if (this.pending_entry_promise) |*stored| return stored.clone();
                const resolved = try resolved_value.toOwned();
                this.storePendingEntryPromise(&resolved);
                return resolved;
            }
        }

        var promise: EntryPointPromise = undefined;
        if (!this.main_is_html_entrypoint) {
            var name = try bun.bindgen.DOMString.fromUTF8(main_file_name);
            defer name.deinit();
            promise = try this.loadEntryModule(name, "loadAndEvaluateModule");
        } else {
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            scope.init(this.global);
            defer scope.deinit();
            const value = try scope.engine(LoadHTMLEntryPointShim).call(.{});
            promise = try value.toOwned();
        }

        this.storePendingEntryPromise(&promise);
        return promise;
    } else {
        var main_string = try bun.bindgen.DOMString.fromUTF8(this.main);
        defer main_string.deinit();
        const promise = try this.loadEntryModule(main_string, "loadAndEvaluateModule");
        this.storePendingEntryPromise(&promise);

        return promise;
    }
}

pub inline fn useIsolationSourceProviderCache(this: *const VirtualMachine) bool {
    return this.test_isolation_enabled and !bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_ISOLATION_SOURCE_CACHE.get();
}

pub const EntryPointPromise = ModuleLoader.OwnedModulePromise;

fn loadEntryModule(this: *VirtualMachine, name: bun.bindgen.DOMString, comptime operation: []const u8) bun.JSError!EntryPointPromise {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    const result = try scope.engineIn("ModuleLoader", operation).call(.{ .moduleName = name.operand() });
    return result.toOwned();
}

pub fn entryPointPromiseStatus(this: *VirtualMachine, promise: *const EntryPointPromise) bun.bindgen.Return(bun.bindgen.Module("promises").engineShim("promiseStatus")) {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    return scope.engineIn("promises", "promiseStatus").call(.{ .promise = promise.operand(&scope) });
}

pub fn reportEntryPointRejection(this: *VirtualMachine, promise: *const EntryPointPromise) bun.JSError!bool {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    const reason = (try scope.engineIn("promises", "promiseResult").call(.{ .promise = promise.operand(&scope) })) orelse
        @panic("rejected entry-point promise has no result");
    return scope.reportUncaughtException(reason.operand(&scope).asAny(), true);
}

pub fn reportUnhandledEntryPoint(this: *VirtualMachine, promise: *const EntryPointPromise) bun.JSError!void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    const reason = (try scope.engineIn("promises", "promiseResult").call(.{ .promise = promise.operand(&scope) })) orelse
        @panic("rejected entry-point promise has no result");
    scope.reportUnhandledRejection(reason.operand(&scope).asAny(), promise.operand(&scope).asPromise());
}

fn storePendingEntryPromise(this: *VirtualMachine, promise: *const EntryPointPromise) void {
    const replacement = promise.clone();
    this.clearPendingEntryPromise();
    this.pending_entry_promise = replacement;
}

fn clearPendingEntryPromise(this: *VirtualMachine) void {
    if (this.pending_entry_promise) |*promise| promise.deinit();
    this.pending_entry_promise = null;
}

pub fn setOverrideModuleRunMain(this: *VirtualMachine, is_patched: bool) void {
    if (this.is_in_preload) {
        this.has_patched_run_main = is_patched;
    }
}
pub fn setOverrideModuleRunMainPromise(this: *VirtualMachine, promise: @FieldType(bun.bindgen.Args(SetOverrideModuleRunMainPromiseSchema), "promise")) bun.JSError!void {
    if (this.pending_entry_promise == null) {
        this.pending_entry_promise = try promise.toOwned();
    }
}

pub fn reloadEntryPointForTestRunner(this: *VirtualMachine, entry_path: []const u8) !EntryPointPromise {
    this.has_loaded = false;
    this.main = entry_path;
    this.main_resolved_path.deref();
    this.main_resolved_path = .empty;
    this.main_hash = Watcher.getHash(entry_path);
    this.overridden_main.deinit();

    this.eventLoop().ensureWaker();

    try this.ensureDebugger(true);

    if (!this.transpiler.options.disable_transpilation) {
        if (try this.loadPreloads()) |promise| {
            return promise;
        }
    }

    var main_string = try bun.bindgen.DOMString.fromUTF8(this.main);
    defer main_string.deinit();
    const promise = try this.loadEntryModule(main_string, "loadAndEvaluateModule");
    this.storePendingEntryPromise(&promise);

    return promise;
}

pub fn loadEntryPointForWebWorker(this: *VirtualMachine, entry_path: string) anyerror!EntryPointPromise {
    var promise = try this.reloadEntryPoint(entry_path);
    defer promise.deinit();
    this.eventLoop().performGC();
    return this.waitForPendingEntryPoint(true);
}

pub fn loadEntryPointForTestRunner(this: *VirtualMachine, entry_path: string) anyerror!EntryPointPromise {
    var promise = try this.reloadEntryPointForTestRunner(entry_path);
    defer promise.deinit();
    if (!this.isWatcherEnabled() and this.entryPointPromiseStatus(&promise) == .rejected) return promise.take();
    this.eventLoop().performGC();
    var settled = try this.waitForPendingEntryPoint(false);
    settled.deinit();
    this.eventLoop().autoTick();
    return this.waitForPendingEntryPoint(false);
}

pub fn loadEntryPoint(this: *VirtualMachine, entry_path: string) anyerror!EntryPointPromise {
    var promise = try this.reloadEntryPoint(entry_path);
    defer promise.deinit();
    if (!this.isWatcherEnabled() and this.entryPointPromiseStatus(&promise) == .rejected) return promise.take();
    this.eventLoop().performGC();
    return this.waitForPendingEntryPoint(false);
}

fn waitForPendingEntryPoint(this: *VirtualMachine, comptime worker_termination: bool) (bun.JSError || error{ WorkerTerminated, EntryPointLoadFailed })!EntryPointPromise {
    while (true) {
        if (worker_termination) {
            if (this.worker.?.hasRequestedTerminate()) return error.WorkerTerminated;
        }
        if (this.jsc_vm.executionForbidden()) return error.JSTerminated;
        switch (this.global.pendingExceptionKind()) {
            .none => {},
            .other => return error.JSError,
            .termination => return error.JSTerminated,
        }
        // A reentrant reload can fail after clearing the previous promise.
        const pending = if (this.pending_entry_promise) |*promise| promise else return error.EntryPointLoadFailed;
        if (this.entryPointPromiseStatus(pending) != .pending) return pending.clone();
        this.eventLoop().tick();
        if (worker_termination) {
            if (this.worker.?.hasRequestedTerminate()) return error.WorkerTerminated;
        }
        if (this.jsc_vm.executionForbidden() or this.global.pendingExceptionKind() != .none) continue;
        if (this.pending_entry_promise) |*promise| {
            if (this.entryPointPromiseStatus(promise) == .pending) this.eventLoop().autoTick();
        }
    }
}

/// `bun test --isolate`: tear down per-file OS resources, bump the generation
/// so stale callbacks self-cancel, then create a fresh `ZigGlobalObject` on
/// the same `JSC::VM` and point `this.global` at it. The old global is
/// gcUnprotect'd; its module graph becomes collectable on the next GC.
pub fn swapGlobalForTestIsolation(this: *VirtualMachine) void {
    bun.debugAssert(this.test_isolation_enabled);

    this.eventLoop().drainMicrotasks() catch |err|
        this.global.reportActiveExceptionAsUnhandled(err);

    bun.bindgen.Engine(ResetWebViewTransportsShim).call(.{ .vm = @ptrCast(this.jsc_vm) });
    if (this.rare_data) |rare| {
        rare.resetNativeCompletions();
        rare.closeAllWatchersForIsolation();
    }

    {
        // Groups that must survive the per-file isolation swap: this process's
        // own inbound IPC, the spawn-IPC pool, and the test-parallel channel.
        const skip_spawn_ipc: ?*uws.SocketGroup = if (this.rare_data) |rare| &rare.spawn_ipc_group else null;
        const skip_test_parallel_ipc: ?*uws.SocketGroup = if (this.rare_data) |rare| &rare.test_parallel_ipc_group else null;
        const skip_process_ipc: ?*uws.SocketGroup = if (Environment.isPosix)
            if (this.ipc) |ipc| switch (ipc) {
                .initialized => |inst| inst.group,
                .waiting => null,
            } else null
        else
            null;
        const loop = bun.uws.Loop.get();
        var maybe_group = loop.internal_loop_data.head;
        while (maybe_group) |group| {
            const next = group.next;
            if (group != skip_spawn_ipc and group != skip_process_ipc and group != skip_test_parallel_ipc) {
                group.closeAll();
            }
            // closeAll → on_close JS may close another group's last socket and
            // unlink our cached `next` from the loop list. Same guard as
            // us_loop_close_all_groups (loop.c) — restart from the head if so.
            maybe_group = if (next != null and next.?.linked == 0)
                loop.internal_loop_data.head
            else
                next;
        }
    }
    this.eventLoop().drainMicrotasks() catch |err|
        this.global.reportActiveExceptionAsUnhandled(err);

    _ = this.auto_killer.kill();
    this.auto_killer.clear();

    this.test_isolation_generation +%= 1;

    this.overridden_main.deinit();
    this.entry_point_result.value.deinit();
    this.entry_point_result.cjs_set_value = false;
    this.clearPendingEntryPromise();
    this.has_patched_run_main = false;
    this.main = "";
    this.main_hash = 0;
    this.main_resolved_path.deref();
    this.main_resolved_path = bun.String.empty;
    this.unhandled_error_counter = 0;

    const old_global = this.global;
    const new_global = JSGlobalObject.createForTestIsolation(old_global);
    this.global = new_global;
    VMHolder.cached_global_object = new_global;
    this.regular_event_loop.global = new_global;
    // macro_event_loop.global is assigned once from this.global at construction
    // and would otherwise keep the first file's dead global across the whole run.
    this.macro_event_loop.global = new_global;
    if (this.ipc) |ipc| if (ipc == .initialized) {
        ipc.initialized.globalThis = new_global;
    };
    // NapiEnv cleanup hooks registered via napi_internal_register_cleanup_zig
    // captured the old global in CleanupHook.globalThis; the C++ side has
    // already retargeted env->m_globalObject to the new global, so only the
    // Zig-side bookkeeping pointer is stale. Nothing currently reads it
    // (execute() only calls func(ctx) and there's no per-entry removal
    // path), but repoint it anyway so the field doesn't dangle at a freed
    // GC cell.
    if (this.rare_data) |rare| {
        for (rare.cleanup_hooks.items) |*hook| {
            if (hook.globalThis == old_global) hook.globalThis = new_global;
        }
    }

    // TODO(isolate): drain HTTPThread's keepalive pool. It lives on a separate
    // thread with its own uws loop; pooled sockets are JS-invisible and bounded
    // at HTTPContext.pool_size (64) per scheme, so serial --isolate leaks at
    // most ~128 fds regardless of file count. --parallel covers this via
    // worker recycling.
}

/// JavaScriptCore has many release assertions that require its API lock.
pub fn runWithAPILock(this: *VirtualMachine, comptime Context: type, ctx: *Context, comptime function: fn (ctx: *Context) void) void {
    const api_lock = this.global.vm().getAPILock();
    defer api_lock.release();
    function(ctx);
}

pub fn printErrorLikeObjectToConsole(this: *VirtualMachine, value: JSValue) void {
    this.runErrorHandler(value, null);
}

pub fn printFailureToConsole(this: *VirtualMachine, failure: bun.JSError) void {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(this.global);
    defer scope.deinit();
    const exception = scope.takeException(failure);
    if (scope.engineIn("errors", "jsValueIsTerminationException").call(.{ .value = exception.operand(&scope).asEngine() })) return;
    scope.runErrorHandler(exception.operand(&scope).asAny());
}

// When the Error-like object is one of our own, it's best to rely on the object directly instead of collecting a diagnostic snapshot.
// This is for:
// - BuildMessage
// - ResolveMessage
// If there were multiple errors, it could be contained in an AggregateError.
// In that case, this function becomes recursive.
// In all other cases, we will collect a diagnostic snapshot.
pub fn printErrorlikeObject(
    this: *VirtualMachine,
    value: bun.bindgen.EngineOperand,
    exception_list: ?*ExceptionList,
    formatter: *ConsoleObject.Formatter,
    comptime Writer: type,
    writer: *std.Io.Writer,
    comptime allow_ansi_color: bool,
    comptime allow_side_effects: bool,
) bun.JSError!void {
    const scope = value;
    const is_exception = value.isException();
    const display_value = if (is_exception) display: {
        const thrown = scope.engineIn("errors", "exceptionThrownValue").call(.{ .exception = value });
        break :display thrown.operand(&scope).asEngine();
    } else value;
    const errors_result = if (display_value.isAggregateError())
        try scope.engineIn("errors", "jsValueGetErrorsProperty").call(.{ .value = display_value })
    else
        null;
    if (errors_result) |result| {
        const errors = result.operand(&scope).asEngine();
        const AggregateErrorIterator = struct {
            writer: Writer,
            current_exception_list: ?*ExceptionList = null,
            formatter: *ConsoleObject.Formatter,

            pub fn iteratorWithColor(vm: *VM, globalObject: *JSGlobalObject, ctx: *@This(), nextValue: bun.bindgen.EngineOperand) void {
                iterator(vm, globalObject, nextValue, ctx, true);
            }
            pub fn iteratorWithOutColor(vm: *VM, globalObject: *JSGlobalObject, ctx: *@This(), nextValue: bun.bindgen.EngineOperand) void {
                iterator(vm, globalObject, nextValue, ctx, false);
            }
            fn iterator(_: *VM, global: *JSGlobalObject, nextValue: bun.bindgen.EngineOperand, this_: *@This(), comptime color: bool) void {
                global.bunVM().printErrorlikeObject(nextValue, this_.current_exception_list, this_.formatter, Writer, this_.writer, color, allow_side_effects) catch |err| bun.bindgen.voidFromJSError(err, global);
            }
        };
        var iter = AggregateErrorIterator{ .writer = writer, .current_exception_list = exception_list, .formatter = formatter };
        if (comptime allow_ansi_color) {
            try errors.forEach(&iter, AggregateErrorIterator.iteratorWithColor);
        } else {
            try errors.forEach(&iter, AggregateErrorIterator.iteratorWithOutColor);
        }
        return;
    }

    const was_internal = try this.printErrorFromMaybePrivateData(
        value,
        display_value,
        exception_list,
        formatter,
        Writer,
        writer,
        allow_ansi_color,
        allow_side_effects,
    );

    if (was_internal) {
        if (is_exception) {
            var diagnostic = Diagnostic.empty;
            defer diagnostic.deinit();
            var frame_result = try scope.engine(Diagnostic.StackSchema).call(.{ .exception = value, .limit = Diagnostic.frame_limit });
            var frames = try Diagnostic.takeFrames(&frame_result);
            defer frames.deinit();
            diagnostic.value.frames.replace(&frames);
            if (diagnostic.value.frames.len() > 0) {
                printStackTrace(Writer, writer, Diagnostic.trace(&diagnostic.value), allow_ansi_color) catch {};
            }
            if (exception_list) |list| {
                try Diagnostic.addToErrorList(&diagnostic.value, list, this.transpiler.fs.top_level_dir, &this.origin);
            }
        }
    }
}

fn printErrorFromMaybePrivateData(
    this: *VirtualMachine,
    value: bun.bindgen.EngineOperand,
    display_value: bun.bindgen.EngineOperand,
    exception_list: ?*ExceptionList,
    formatter: *ConsoleObject.Formatter,
    comptime Writer: type,
    writer: *std.Io.Writer,
    comptime allow_ansi_color: bool,
    comptime allow_side_effects: bool,
) bun.JSError!bool {
    const global = value.viewToken().globalObject();
    {
        if (try bun.api.BuildMessage.Binding.tryCast(BindingEscape.rawCallScopedValue(display_value, display_value.engineView()), global)) |build_handle_value| {
            var build_handle = build_handle_value;
            defer build_handle.deinit();
            const build_error = build_handle.get();
            defer Output.flush();
            if (!build_error.logged) {
                if (this.had_errors) {
                    writer.writeAll("\n") catch {};
                }
                build_error.loggerMessage().writeFormat(writer, allow_ansi_color) catch {};
                build_error.logged = true;
                writer.writeAll("\n") catch {};
            }
            this.had_errors = this.had_errors or build_error.loggerMessage().kind == .err;
            if (exception_list != null) {
                try build_error.loggerMessage().appendTo(this.log);
            }
            return true;
        } else if (try bun.api.ResolveMessage.Binding.tryCast(BindingEscape.rawCallScopedValue(display_value, display_value.engineView()), global)) |resolve_handle_value| {
            var resolve_handle = resolve_handle_value;
            defer resolve_handle.deinit();
            const resolve_error = resolve_handle.get();
            defer Output.flush();
            if (!resolve_error.logged) {
                if (this.had_errors) {
                    writer.writeAll("\n") catch {};
                }
                resolve_error.loggerMessage().writeFormat(writer, allow_ansi_color) catch {};
                resolve_error.logged = true;
                writer.writeAll("\n") catch {};
            }

            this.had_errors = this.had_errors or resolve_error.loggerMessage().kind == .err;

            if (exception_list != null) {
                try resolve_error.loggerMessage().appendTo(this.log);
            }
            return true;
        }
    }

    this.printErrorInstance(
        .js,
        value,
        .empty,
        exception_list,
        formatter,
        Writer,
        writer,
        allow_ansi_color,
        allow_side_effects,
    ) catch |err| {
        switch (err) {
            error.JSError, error.OutOfMemory, error.JSTerminated => return @errorCast(err),
            else => {},
        }
    };

    return false;
}

pub fn printStackTrace(comptime Writer: type, writer: Writer, trace: Diagnostic.Trace, comptime allow_ansi_colors: bool) !void {
    const stack = trace.frames;
    if (stack.len > 0) {
        var vm = VirtualMachine.get();
        const origin: ?*const URL = if (vm.is_from_devserver) &vm.origin else null;
        const dir = vm.transpiler.fs.top_level_dir;

        for (stack) |*frame| {
            const file_slice = try frame.sourceURL.toUTF8(bun.default_allocator);
            defer file_slice.deinit();
            const func_slice = try frame.functionName.toUTF8(bun.default_allocator);
            defer func_slice.deinit();

            const file = file_slice.slice();
            const func = func_slice.slice();

            if (file.len == 0 and func.len == 0) continue;

            const has_name = std.fmt.count("{f}", .{Diagnostic.nameFormatter(frame, false)}) > 0;

            if (has_name and Diagnostic.hasPosition(frame)) {
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r>      <d>at <r>{f}<d> (<r>{f}<d>)<r>\n",
                        allow_ansi_colors,
                    ),
                    .{
                        Diagnostic.nameFormatter(
                            frame,
                            allow_ansi_colors,
                        ),
                        Diagnostic.sourceURLFormatter(
                            frame,
                            dir,
                            origin,
                            false,
                            allow_ansi_colors,
                        ),
                    },
                );
            } else if (Diagnostic.hasPosition(frame)) {
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r>      <d>at <r>{f}\n",
                        allow_ansi_colors,
                    ),
                    .{
                        Diagnostic.sourceURLFormatter(
                            frame,
                            dir,
                            origin,
                            false,
                            allow_ansi_colors,
                        ),
                    },
                );
            } else if (has_name) {
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r>      <d>at <r>{f}<d>\n",
                        allow_ansi_colors,
                    ),
                    .{
                        Diagnostic.nameFormatter(
                            frame,
                            allow_ansi_colors,
                        ),
                    },
                );
            } else {
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r>      <d>at <r>{f}<d>\n",
                        allow_ansi_colors,
                    ),
                    .{
                        Diagnostic.sourceURLFormatter(
                            frame,
                            dir,
                            origin,
                            false,
                            allow_ansi_colors,
                        ),
                    },
                );
            }
        }
    }
}

pub fn remapStackFramePosition(this: *VirtualMachine, frame: *Diagnostic.Frame) bun.OOM!void {
    const query = SourceMap.LineColumnOffset.fromOptional(frame.line, frame.column) orelse return;

    // **Warning** this method can be called in the heap collector thread!!
    // https://github.com/oven-sh/bun/issues/17087
    this.remap_stack_frames_mutex.lockUncancelable(this.io);
    defer this.remap_stack_frames_mutex.unlock(this.io);

    // Cached map views borrow storage protected by this lock. The slow path
    // releases it before resolving external or standalone source maps.
    this.source_mappings.lock();
    var table_locked = true;
    defer if (table_locked) this.source_mappings.unlock();

    const sm = &this.source_mappings;
    if (!Diagnostic.hasPosition(frame) or frame.remapped) return;
    if (frame.sourceURL.isEmpty()) {
        frame.remapped = true;
        return;
    }
    const internal: ?SourceMap.InternalSourceMap = internal: {
        if (sm.getEntryLocked(frame.sourceURL.unsafePtr("the diagnostic frame owns the URL until source-map lookup returns").textView())) |entry| {
            if (entry.value.get(SourceMap.InternalSourceMap)) |ptr| {
                break :internal .{ .data = @as([*]const u8, @ptrCast(ptr)) };
            }
            if (entry.value.get(SourceMap.ParsedSourceMap)) |parsed| {
                if (parsed.internal != null and !parsed.isExternal()) break :internal parsed.internal;
                if (parsed.findMapping(query.lines, query.columns)) |mapping| {
                    const lookup: SourceMap.Mapping.Lookup = .{
                        .mapping = mapping,
                        .source_map = parsed,
                        .prefetched_source_code = null,
                    };
                    try applySourceMapping(frame, lookup, entry.path.bytes);
                }
                break :internal null;
            }

            entry.path.ref();
            defer entry.path.deref();
            sm.unlock();
            table_locked = false;
            try this.remapOneFrameSlow(frame, entry.path.bytes);
            return;
        }
        if (this.standalone_module_graph) |graph| {
            const file = graph.findText(frame.sourceURL.unsafePtr("the diagnostic frame owns the URL until source-map lookup returns").textView()) orelse break :internal null;
            sm.unlock();
            table_locked = false;
            try this.remapOneFrameSlow(frame, file.name);
            return;
        }
        break :internal null;
    };

    if (internal) |ism| {
        if (ism.findWithCache(query.lines, query.columns, &sm.find_cache)) |mapping| {
            try applySourceMapping(frame, .{ .mapping = mapping, .prefetched_source_code = null }, "");
        }
    }
    frame.remapped = true;
}

fn applySourceMapping(frame: *Diagnostic.Frame, lookup: SourceMap.Mapping.Lookup, path: []const u8) bun.OOM!void {
    if (try lookup.displaySourceURLIfNeeded(path)) |source| {
        defer source.deinit();
        const replacement = try bun.bindgen.DOMString.fromUTF8(source.slice());
        frame.sourceURL.deinit();
        frame.sourceURL = replacement;
    }
    frame.line = std.math.cast(u32, lookup.mapping.originalLine());
    frame.column = std.math.cast(u32, lookup.mapping.originalColumn());
    frame.remapped = true;
}

fn remapOneFrameSlow(this: *VirtualMachine, frame: *Diagnostic.Frame, path: []const u8) bun.OOM!void {
    if (try this.resolveSourceMapping(path, frame.line, frame.column, .no_source_contents)) |lookup| {
        defer if (lookup.source_map) |map| map.deref();
        try applySourceMapping(frame, lookup, path);
    }
    frame.remapped = true;
}

pub fn remapDiagnostic(
    this: *VirtualMachine,
    exception: *Diagnostic.Owned,
    scope: anytype,
    error_instance: bun.bindgen.EngineOperand,
    exception_list: ?*ExceptionList,
    allow_source_code_preview: bool,
) bun.JSError!void {
    const collect_source = allow_source_code_preview and
        !(bun.feature_flag.BUN_DISABLE_SOURCE_CODE_PREVIEW.get() or
            bun.feature_flag.BUN_DISABLE_TRANSPILED_SOURCE_CODE_PREVIEW.get());
    var collected = try Diagnostic.takeResult(try scope.engine(Diagnostic.DescribeSchema).call(.{
        .value = error_instance,
        .frameLimit = Diagnostic.frame_limit,
        .sourceLineLimit = if (collect_source) Diagnostic.source_line_limit else 0,
    }));
    defer collected.deinit();
    try this.remapExceptionFrames(&collected.value, scope, error_instance, collect_source);
    if (exception_list) |list| {
        try Diagnostic.addToErrorList(&collected.value, list, this.transpiler.fs.top_level_dir, &this.origin);
    }
    exception.replace(&collected);
}

fn remapExceptionFrames(
    this: *VirtualMachine,
    exception: *Diagnostic.Value,
    scope: anytype,
    error_instance: bun.bindgen.EngineOperand,
    allow_source_code_preview: bool,
) bun.JSError!void {
    var reset_parser_arena = false;
    defer if (reset_parser_arena) this.module_loader.resetArena(this);
    var enable_source_code_preview = allow_source_code_preview;
    defer if (!enable_source_code_preview) bun.assert(exception.sourceLines.len() == 0);

    const noisy_names = [_][]const u8{
        "asyncModuleEvaluation",
        "link",
        "linkAndEvaluateModule",
        "moduleEvaluation",
        "processTicksAndRejections",
    };

    if (this.hide_bun_stackframes) exception.frames.retain({}, struct {
        fn keep(_: void, frame: *const Diagnostic.Frame) bool {
            if (frame.sourceURL.eqlUTF8("bun:wrap") or frame.functionName.eqlUTF8("::bunternal::")) return false;
            if (frame.sourceURL.isEmpty() or frame.sourceURL.eqlUTF8("[unknown]") or frame.sourceURL.hasPrefixComptime("[source:")) {
                for (noisy_names) |name| if (frame.functionName.eqlUTF8(name)) return false;
            }
            return true;
        }
    }.keep);
    const frames = exception.frames.sliceMut();

    if (frames.len == 0) return;

    var top = &frames[0];
    var top_frame_is_builtin = false;
    if (this.hide_bun_stackframes) {
        for (frames) |*frame| {
            if (frame.sourceURL.hasPrefixComptime("bun:") or
                frame.sourceURL.hasPrefixComptime("node:") or
                frame.sourceURL.isEmpty() or
                frame.sourceURL.eqlUTF8("native") or
                frame.sourceURL.eqlUTF8("unknown") or
                frame.sourceURL.eqlUTF8("[unknown]") or
                frame.sourceURL.hasPrefixComptime("[source:"))
            {
                top_frame_is_builtin = true;
                continue;
            }

            top = frame;
            top_frame_is_builtin = false;
            break;
        }
    }

    // Don't show source code preview for REPL frames - it would show the
    // transformed IIFE wrapper code, not what the user typed.
    if (top.sourceURL.eqlUTF8("[repl]")) {
        enable_source_code_preview = false;
        exception.sourceLines.clear();
    }

    var top_source_url = try top.sourceURL.toUTF8(bun.default_allocator);
    defer top_source_url.deinit();

    const maybe_lookup = if (top.remapped) null else try this.resolveSourceMapping(
        top_source_url.slice(),
        top.line,
        top.column,
        .source_contents,
    );
    defer if (maybe_lookup) |lookup| if (lookup.source_map) |map| map.deref();
    if (maybe_lookup) |lookup| try applySourceMapping(top, lookup, top_source_url.slice());

    if (top.remapped) {
        const code = code: {
            if (!enable_source_code_preview) {
                break :code bun.String.Slice.empty;
            }

            if (maybe_lookup) |lookup| {
                if (lookup.source_map != null and lookup.source_map.?.isExternal()) {
                    if (try source_provider.getSourceCode(this.io, lookup, top_source_url.slice())) |src| {
                        break :code src;
                    }
                }
            }

            if (top_frame_is_builtin) {
                // Avoid printing "export default 'native'"
                break :code bun.String.Slice.empty;
            }
            var log = logger.Log.init(bun.default_allocator);
            defer log.deinit();

            var original_source = this.fetchDiagnosticSource(&top.sourceURL, &log) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return;
            };
            reset_parser_arena = true;
            defer original_source.deinit();
            break :code try original_source.source_code.toUTF8(bun.default_allocator);
        };

        defer code.deinit();
        if (enable_source_code_preview and code.length() == 0) {
            try collectExceptionSourceLines(scope, exception, error_instance);
        }

        if (code.length() > 0)
            try Diagnostic.setSourceText(exception, code.slice(), top.line orelse 0);
    } else if (enable_source_code_preview) {
        try collectExceptionSourceLines(scope, exception, error_instance);
    }

    for (frames) |*frame| {
        if (frame == top or frame.remapped or !Diagnostic.hasPosition(frame)) continue;
        const source_url = try frame.sourceURL.toUTF8(bun.default_allocator);
        defer source_url.deinit();
        if (try this.resolveSourceMapping(
            source_url.slice(),
            frame.line,
            frame.column,
            .no_source_contents,
        )) |lookup| {
            defer if (lookup.source_map) |map| map.deref();
            try applySourceMapping(frame, lookup, source_url.slice());
        }
    }
}

fn collectExceptionSourceLines(scope: anytype, exception: *Diagnostic.Value, value: bun.bindgen.EngineOperand) bun.JSError!void {
    // Without original source text, only the throwing line is reliable; surrounding provider text may be generated code.
    var line_result = (try scope.engine(Diagnostic.SourceLinesSchema).call(.{ .value = value, .limit = 1 })) orelse return;
    var lines = try Diagnostic.takeSourceLines(&line_result);
    defer lines.deinit();
    exception.sourceLines.replace(&lines);
}

pub fn printExternallyRemappedDiagnostic(
    this: *VirtualMachine,
    diagnostic: *const Diagnostic.Value,
    browser_url: bun.TextView,
    formatter: ?*ConsoleObject.Formatter,
    comptime Writer: type,
    writer: Writer,
    comptime allow_side_effects: bool,
    comptime allow_ansi_color: bool,
) !void {
    var default_formatter: ConsoleObject.Formatter = .{ .globalThis = this.global };
    defer default_formatter.deinit();
    try this.printErrorInstance(
        .diagnostic,
        diagnostic,
        browser_url,
        null,
        formatter orelse &default_formatter,
        Writer,
        writer,
        allow_ansi_color,
        allow_side_effects,
    );
}

fn printErrorInstance(
    this: *VirtualMachine,
    comptime mode: enum { js, diagnostic },
    error_instance: switch (mode) {
        .js => bun.bindgen.EngineOperand,
        .diagnostic => *const Diagnostic.Value,
    },
    browser_url: bun.TextView,
    exception_list: ?*ExceptionList,
    formatter: *ConsoleObject.Formatter,
    comptime Writer: type,
    writer: Writer,
    comptime allow_ansi_color: bool,
    comptime allow_side_effects: bool,
) !void {
    const global = if (mode == .js) error_instance.viewToken().globalObject() else this.global;
    var collected = Diagnostic.empty;
    const exception = if (mode == .js) &collected.value else error_instance;
    defer collected.deinit();
    defer if (mode == .js) error_instance.ensureStillAlive();

    if (mode == .js) {
        const scope = error_instance;
        try this.remapDiagnostic(
            &collected,
            &scope,
            error_instance,
            exception_list,
            formatter.error_display_level != .warn,
        );
    }
    const prev_had_errors = this.had_errors;
    this.had_errors = true;
    defer this.had_errors = prev_had_errors;

    if (allow_side_effects) {
        if (this.debugger) |*debugger| {
            try debugger.lifecycle_reporter_agent.reportError(exception);
        }
    }

    defer if (allow_side_effects and Output.is_github_action)
        printGithubAnnotation(exception) catch |err| global.reportActiveExceptionAsUnhandled(err);

    // This is a longer number than necessary because we don't handle this case very well
    // At the very least, we shouldn't dump 100 KB of minified code into your terminal.
    const max_line_length_with_divot = 512;
    const max_line_length = 1024;

    const lines = exception.sourceLines.slice();
    var max_display_line: u64 = 0;
    for (lines) |line| max_display_line = @max(max_display_line, @as(u64, line.line) + 1);
    const max_line_number_pad = std.fmt.count("{d}", .{max_display_line});

    var source_lines = Diagnostic.trace(exception).sourceLineIterator();
    var last_pad: u64 = 0;
    while (try source_lines.untilLast()) |source| {
        defer source.text.deinit();
        const display_line = @as(u64, source.line) + 1;

        const int_size = std.fmt.count("{d}", .{display_line});
        const pad = max_line_number_pad - int_size;
        last_pad = pad;
        try writer.splatByteAll(' ', pad);

        const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, source.text.slice(), "\n"), "\t ");
        const clamped = trimmed[0..@min(trimmed.len, max_line_length)];

        if (clamped.len != trimmed.len) {
            const fmt = if (comptime allow_ansi_color) "<r><d> | ... truncated <r>\n" else "\n";
            try writer.print(
                comptime Output.prettyFmt(
                    "<r><b>{d} |<r> {f}" ++ fmt,
                    allow_ansi_color,
                ),
                .{ display_line, bun.fmt.fmtJavaScript(clamped, .{ .enable_colors = allow_ansi_color }) },
            );
        } else {
            try writer.print(
                comptime Output.prettyFmt(
                    "<r><b>{d} |<r> {f}\n",
                    allow_ansi_color,
                ),
                .{ display_line, bun.fmt.fmtJavaScript(clamped, .{ .enable_colors = allow_ansi_color }) },
            );
        }
    }

    const name = exception.details.name.unsafePtr("the diagnostic owns the name until formatting returns").textView();
    const message = exception.details.message.unsafePtr("the diagnostic owns the message until formatting returns").textView();

    const is_error_instance = mode == .js and error_instance.jsType() == .ErrorInstance;
    var code_string: bun.String = .empty;
    defer code_string.deref();
    var code: ?[]const u8 = null;
    if (is_error_instance) {
        const scope = error_instance;
        const code_result = try scope.engine(ErrorCodeStringVMInquirySchema).call(.{
            .errorValue = error_instance,
        });
        if (code_result) |code_value| {
            var text = try scope.engineIn("js_strings", "stringFromJS").call(.{ .value = code_value.operand(&scope).asEngine() });
            code_string = text.takeBunString();
            if (code_string.is8Bit()) code = code_string.latin1();
        }
    }

    var did_print_name = false;
    if (try source_lines.next()) |source| brk: {
        if (source.text.length() == 0) break :brk;

        var top_frame = if (exception.frames.len() > 0) &exception.frames.slice()[0] else null;

        if (this.hide_bun_stackframes) {
            for (exception.frames.slice()) |*frame| {
                if (!Diagnostic.hasPosition(frame) or frame.sourceURL.hasPrefixComptime("bun:") or frame.sourceURL.hasPrefixComptime("node:")) continue;
                top_frame = frame;
                break;
            }
        }

        if (top_frame == null or !Diagnostic.hasPosition(top_frame.?)) {
            defer did_print_name = true;
            defer source.text.deinit();
            const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, source.text.slice(), "\n"), "\t ");

            const text = trimmed[0..@min(trimmed.len, max_line_length)];

            if (text.len != trimmed.len) {
                const fmt = if (comptime allow_ansi_color) "<r><d> | ... truncated <r>\n" else "\n";
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r><b>- |<r> {f}" ++ fmt,
                        allow_ansi_color,
                    ),
                    .{bun.fmt.fmtJavaScript(text, .{ .enable_colors = allow_ansi_color })},
                );
            } else {
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r><d>- |<r> {f}\n",
                        allow_ansi_color,
                    ),
                    .{bun.fmt.fmtJavaScript(text, .{ .enable_colors = allow_ansi_color })},
                );
            }

            try this.printErrorNameAndMessage(name, message, !browser_url.isEmpty(), code, Writer, writer, allow_ansi_color, formatter.error_display_level);
        } else if (top_frame) |top| {
            defer did_print_name = true;
            const display_line = @as(u64, source.line) + 1;
            const int_size = std.fmt.count("{d}", .{display_line});
            const pad = max_line_number_pad - int_size;
            try writer.splatByteAll(' ', pad);
            defer source.text.deinit();
            const text = source.text.slice();
            const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, text, "\n"), "\t ");

            // TODO: preserve the divot position and possibly use stringWidth() to figure out where to put the divot
            const clamped = trimmed[0..@min(trimmed.len, max_line_length)];

            if (clamped.len != trimmed.len) {
                const fmt = if (comptime allow_ansi_color) "<r><d> | ... truncated <r>\n\n" else "\n\n";
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r><b>{d} |<r> {f}" ++ fmt,
                        allow_ansi_color,
                    ),
                    .{ display_line, bun.fmt.fmtJavaScript(clamped, .{ .enable_colors = allow_ansi_color }) },
                );
            } else {
                try writer.print(
                    comptime Output.prettyFmt(
                        "<r><b>{d} |<r> {f}\n",
                        allow_ansi_color,
                    ),
                    .{ display_line, bun.fmt.fmtJavaScript(clamped, .{ .enable_colors = allow_ansi_color }) },
                );

                if (clamped.len < max_line_length_with_divot or @as(u64, top.column orelse 0) > max_line_length_with_divot) {
                    const indent = max_line_number_pad + " | ".len + @as(u64, top.column orelse 0);

                    try writer.splatByteAll(' ', indent);
                    try writer.print(comptime Output.prettyFmt(
                        "<red><b>^<r>\n",
                        allow_ansi_color,
                    ), .{});
                } else {
                    try writer.writeAll("\n");
                }
            }

            try this.printErrorNameAndMessage(name, message, !browser_url.isEmpty(), code, Writer, writer, allow_ansi_color, formatter.error_display_level);
        }
    }

    if (!did_print_name) {
        try this.printErrorNameAndMessage(name, message, !browser_url.isEmpty(), code, Writer, writer, allow_ansi_color, formatter.error_display_level);
    }

    var errors_to_append = std.array_list.Managed(bun.bindgen.Root).init(this.allocator);
    defer {
        for (errors_to_append.items) |*err| err.deinit();
        errors_to_append.deinit();
    }

    if (is_error_instance) {
        var saw_cause = false;
        const Iterator = jsc.JSPropertyIterator(.{
            .skip_empty_name = true,
            .own_properties_only = true,
            .observable = false,
            .only_non_index_properties = true,
        });
        const property_scope = error_instance;
        var error_root = try error_instance.toRoot();
        defer error_root.deinit();
        var iterator = try Iterator.init(&property_scope, &error_root);
        defer iterator.deinit();
        const longest_name = @min(iterator.getLongestPropertyName(&property_scope), 10);
        var is_first_property = true;
        while (try iterator.next(&property_scope)) |next_entry| {
            var entry = next_entry;
            const field = entry.name.takeBunString();
            defer field.deref();
            const value = entry.value.operand(&property_scope).asEngine();
            if (field.eqlComptime("message") or field.eqlComptime("name") or field.eqlComptime("stack")) {
                continue;
            }

            // We special-case the code property. Let's avoid printing it twice.
            if (field.eqlComptime("code") and code != null) {
                continue;
            }

            const kind = value.jsType();
            if (kind == .ErrorInstance and
                // avoid infinite recursion
                !prev_had_errors)
            {
                if (field.eqlComptime("cause")) {
                    saw_cause = true;
                }
                try errors_to_append.ensureUnusedCapacity(1);
                errors_to_append.appendAssumeCapacity(try value.asAny().toRoot());
            } else if (kind.isObject() or kind.isArray() or value.isPrimitive() or kind.isStringLike()) {
                var bun_str = bun.String.empty;
                defer bun_str.deref();
                const prev_disable_inspect_custom = formatter.disable_inspect_custom;
                const prev_quote_strings = formatter.quote_strings;
                const prev_max_depth = formatter.max_depth;
                const prev_format_buffer_as_text = formatter.format_buffer_as_text;
                formatter.depth += 1;
                formatter.format_buffer_as_text = true;
                defer {
                    formatter.depth -= 1;
                    formatter.max_depth = prev_max_depth;
                    formatter.quote_strings = prev_quote_strings;
                    formatter.disable_inspect_custom = prev_disable_inspect_custom;
                    formatter.format_buffer_as_text = prev_format_buffer_as_text;
                }
                formatter.max_depth = 1;
                formatter.quote_strings = true;
                formatter.disable_inspect_custom = true;

                const pad_left = longest_name -| field.length();
                is_first_property = false;
                try writer.splatByteAll(' ', pad_left);

                try writer.print(comptime Output.prettyFmt(" {f}<r><d>:<r> ", allow_ansi_color), .{field});

                // When we're printing errors for a top-level uncaught exception / rejection, suppress further errors here.
                if (allow_side_effects) {
                    if (global.hasException()) {
                        global.clearException();
                    }
                }

                formatter.format(
                    try jsc.Formatter.Tag.getAdvanced(
                        value,
                        global,
                        .{ .disable_inspect_custom = true, .hide_global = true },
                    ),
                    Writer,
                    writer,
                    value,
                    global,
                    allow_ansi_color,
                ) catch {};

                if (allow_side_effects) {
                    // When we're printing errors for a top-level uncaught exception / rejection, suppress further errors here.
                    if (global.hasException()) {
                        global.clearException();
                    }
                } else if (global.hasException() or formatter.failed) {
                    return;
                }

                try writer.writeAll(comptime Output.prettyFmt("<r><d>,<r>\n", allow_ansi_color));
            }
        }

        if (code) |code_str| {
            const pad_left = longest_name -| "code".len;
            is_first_property = false;
            try writer.splatByteAll(' ', pad_left);

            try writer.print(comptime Output.prettyFmt(" code<r><d>:<r> <green>{f}<r>\n", allow_ansi_color), .{
                bun.fmt.quote(code_str),
            });
        }

        if (!is_first_property) {
            try writer.writeAll("\n");
        }

        // Non-enumerable causes are omitted by the iterator; accessors must not run while formatting.
        if (!saw_cause) {
            if (try property_scope.engine(ErrorOwnCauseSchema).call(.{ .errorValue = iterator.object.operand(&property_scope) })) |cause| {
                try errors_to_append.ensureUnusedCapacity(1);
                errors_to_append.appendAssumeCapacity(try cause.asAny(&property_scope).toRoot());
            }
        }
    } else if (mode == .js) {
        // If you do reportError([1,2,3]] we should still show something at least.
        const tag = try jsc.Formatter.Tag.getAdvanced(
            error_instance,
            global,
            .{ .disable_inspect_custom = true, .hide_global = true },
        );
        if (tag.tag != .NativeCode) {
            try formatter.format(
                tag,
                Writer,
                writer,
                error_instance,
                global,
                allow_ansi_color,
            );

            // Always include a newline in this case
            try writer.writeAll("\n");
        }
    }

    try printStackTrace(@TypeOf(writer), writer, Diagnostic.trace(exception), allow_ansi_color);

    if (!browser_url.isEmpty()) {
        try writer.print(
            comptime Output.prettyFmt(
                "    <d>from <r>browser tab <magenta>{f}<r>\n",
                allow_ansi_color,
            ),
            .{browser_url},
        );
    }

    var engine_scope: bun.bindgen.FocusedEngineScope = undefined;
    engine_scope.init(global);
    defer engine_scope.deinit();
    for (errors_to_append.items) |*root| {
        const err = BindingEscape.rootValue(&engine_scope, root);
        // Check for circular references to prevent infinite recursion in cause chains
        if (formatter.map_node == null) {
            formatter.map_node = ConsoleObject.Formatter.Visited.Pool.get(default_allocator);
            formatter.map_node.?.data.clearRetainingCapacity();
            formatter.map = formatter.map_node.?.data;
        }

        const entry = formatter.map.getOrPut(err) catch unreachable;
        if (entry.found_existing) {
            try writer.writeAll("\n");
            try writer.writeAll(comptime Output.prettyFmt("<r><cyan>[Circular]<r>", allow_ansi_color));
            continue;
        }

        try writer.writeAll("\n");
        try this.printErrorInstance(.js, BindingEscape.borrowEngineValue(&engine_scope, err), .empty, exception_list, formatter, Writer, writer, allow_ansi_color, allow_side_effects);
        _ = formatter.map.remove(err);
    }
}

fn printErrorNameAndMessage(
    _: *VirtualMachine,
    name: bun.TextView,
    message: bun.TextView,
    is_browser_error: bool,
    optional_code: ?[]const u8,
    comptime Writer: type,
    writer: Writer,
    comptime allow_ansi_color: bool,
    error_display_level: ConsoleObject.FormatOptions.ErrorDisplayLevel,
) !void {
    if (is_browser_error) try writer.writeAll(Output.prettyFmt("<red>frontend<r> ", true));
    var display_name = name;
    var display_message = message;
    if (name.eqlBytes("Error") and !message.isEmpty()) {
        display_name = .empty;
        if (optional_code) |code| {
            if (bun.strings.isAllASCII(code) and message.len() > code.len + 3 and
                message.substringWithLen(0, code.len).eqlBytes(code) and
                message.substringWithLen(code.len, code.len + 2).eqlBytes(": "))
            {
                display_name = .{ .latin1 = code };
                display_message = message.substring(code.len + 2);
            }
        }
    }
    if (!display_message.isEmpty()) {
        try writer.print(comptime Output.prettyFmt("{f}<b>{f}<r>\n", allow_ansi_color), .{
            error_display_level.formatter(display_name, allow_ansi_color, .include_colon),
            display_message,
        });
    } else {
        try writer.print("{f}\n", .{error_display_level.formatter(display_name, allow_ansi_color, if (display_name.isEmpty()) .exclude_colon else .include_colon)});
    }
}

// In Github Actions, emit an annotation that renders the error and location.
// https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#setting-an-error-message
pub noinline fn printGithubAnnotation(exception: *const Diagnostic.Value) bun.OOM!void {
    @branchHint(.cold);
    const name = exception.details.name.unsafePtr("the diagnostic owns the name until formatting returns").textView();
    const message = exception.details.message.unsafePtr("the diagnostic owns the message until formatting returns").textView();
    const frames = exception.frames.slice();
    const top_frame = if (frames.len > 0) &frames[0] else null;
    const dir = bun.env_var.GITHUB_WORKSPACE.get() orelse bun.fs.FileSystem.instance.top_level_dir;
    const allocator = bun.default_allocator;
    Output.flush();

    var writer = Output.errorWriterBuffered();
    defer {
        writer.flush() catch {};
    }

    var has_location = false;

    if (top_frame) |frame| {
        if (Diagnostic.hasPosition(frame)) {
            const source_url = try frame.sourceURL.toUTF8(allocator);
            defer source_url.deinit();
            const file = try std.fs.path.relative(allocator, dir, null, dir, source_url.slice());
            defer allocator.free(file);
            bun.path.platformToPosixInPlace(u8, file);
            writer.print("\n::error file={s},line={d},col={d},title=", .{
                file,
                if (frame.line) |line| @as(u64, line) + 1 else 0,
                if (frame.column) |column| @as(u64, column) + 1 else 0,
            }) catch {};
            has_location = true;
        }
    }

    if (!has_location) {
        writer.print("\n::error title=", .{}) catch {};
    }

    if (name.isEmpty() or name.eqlBytes("Error")) {
        writer.print("error", .{}) catch {};
    } else {
        const bytes = try name.toSlice(allocator);
        defer bytes.deinit();
        writer.print("{f}", .{bun.fmt.githubAction(bytes.slice())}) catch {};
    }

    if (!message.isEmpty()) {
        const message_slice = try message.toSlice(allocator);
        defer message_slice.deinit();
        const msg = message_slice.slice();

        var cursor: u32 = 0;
        while (strings.indexOfNewlineOrNonASCIIOrANSI(msg, cursor)) |i| {
            cursor = i + 1;
            if (msg[i] == '\n') {
                writer.print(": {f}::", .{bun.fmt.githubAction(msg[0..i])}) catch {};
                break;
            }
        } else {
            writer.print(": {f}::", .{bun.fmt.githubAction(msg)}) catch {};
        }

        while (strings.indexOfNewlineOrNonASCIIOrANSI(msg, cursor)) |i| {
            cursor = i + 1;
            if (msg[i] == '\n') {
                break;
            }
        }

        if (cursor > 0) {
            writer.print("{f}", .{bun.fmt.githubAction(msg[cursor..])}) catch {};
        }
    } else {
        writer.print("::", .{}) catch {};
    }

    // TODO: cleanup and refactor to use printStackTrace()
    if (top_frame) |_| {
        const vm = VirtualMachine.get();
        const origin = if (vm.is_from_devserver) &vm.origin else null;

        for (frames) |*frame| {
            const source_url = try frame.sourceURL.toUTF8(allocator);
            defer source_url.deinit();
            const file = try std.fs.path.relative(allocator, dir, null, dir, source_url.slice());
            defer allocator.free(file);
            bun.path.platformToPosixInPlace(u8, file);
            if (file.len == 0 and frame.functionName.isEmpty()) continue;

            const has_name = std.fmt.count("{f}", .{Diagnostic.nameFormatter(
                frame,
                false,
            )}) > 0;

            // %0A = escaped newline
            if (has_name) {
                writer.print(
                    "%0A      at {f} ({f})",
                    .{
                        Diagnostic.nameFormatter(frame, false),
                        Diagnostic.sourceURLFormatter(
                            frame,
                            file,
                            origin,
                            false,
                            false,
                        ),
                    },
                ) catch {};
            } else {
                writer.print(
                    "%0A      at {f}",
                    .{
                        Diagnostic.sourceURLFormatter(
                            frame,
                            file,
                            origin,
                            false,
                            false,
                        ),
                    },
                ) catch {};
            }
        }
    }

    writer.print("\n", .{}) catch {};
}

pub fn resolveSourceMapping(
    this: *VirtualMachine,
    path: []const u8,
    line: ?u32,
    column: ?u32,
    source_handling: SourceMap.SourceContentHandling,
) bun.OOM!?SourceMap.Mapping.Lookup {
    const query = SourceMap.LineColumnOffset.fromOptional(line, column) orelse return null;
    return try this.source_mappings.resolveMapping(path, query.lines, query.columns, source_handling) orelse {
        if (this.standalone_module_graph) |graph| {
            const file = graph.find(path) orelse return null;
            const map = try file.sourcemap.load(this.io) orelse return null;

            map.ref();

            this.source_mappings.putValue(path, SavedSourceMap.Value.init(map)) catch |err| {
                map.deref();
                return err;
            };

            const mapping = map.findMapping(query.lines, query.columns) orelse
                return null;

            map.ref();
            return .{
                .mapping = mapping,
                .source_map = map,
                .prefetched_source_code = null,
            };
        }

        return null;
    };
}

pub const IPCInstanceUnion = union(enum) {
    /// IPC is put in this "enabled but not started" state when IPC is detected
    /// but the client JavaScript has not yet done `.on("message")`
    waiting: struct {
        fd: bun.FD,
        mode: IPC.Mode,
    },
    initialized: *IPCInstance,
};

pub const IPCInstance = struct {
    pub const new = bun.TrivialNew(@This());

    globalThis: *JSGlobalObject,
    /// Embedded per-VM group on `RareData.spawn_ipc_group`; this is just a
    /// borrowed handle so the isolation swap can skip it.
    group: if (Environment.isPosix) *uws.SocketGroup else void,
    data: IPC.SendQueue,

    const NodeClusterEngine = @import("../runtime/node/NodeClusterEngine.zig");

    pub fn ipc(this: *IPCInstance) ?*IPC.SendQueue {
        return &this.data;
    }

    /// Only reached from the `getIPCInstance` error path. On Windows,
    /// `windowsConfigureClient` sets `data.socket = .open` before calling
    /// `uv_read_start`; if that fails it calls `closeSocket()` which queues
    /// the tracked `_onAfterIPCClosed` task holding `*SendQueue` — so
    /// `SendQueue.deinit()` must run here to cancel it before this
    /// allocation (and the embedded `SendQueue`) is freed.
    pub fn deinit(this: *IPCInstance) void {
        this.data.deinit();
        bun.destroy(this);
    }

    pub fn getGlobalThis(this: *IPCInstance) ?*JSGlobalObject {
        return this.globalThis;
    }

    pub fn handleIPCMessage(this: *IPCInstance, message: *const IPC.DecodedIPCMessage) void {
        const globalThis = this.globalThis;
        const event_loop = jsc.VirtualMachine.get().eventLoop();

        switch (message.*) {
            .version => |v| {
                IPC.log("Parent IPC version is {d}", .{v});
            },
            .data => |*data| {
                IPC.log("Received IPC message from parent", .{});
                event_loop.enter();
                defer event_loop.exit();
                var scope: bun.bindgen.FocusedEngineScope = undefined;
                scope.init(globalThis);
                defer scope.deinit();
                scope.engine(ProcessEmitMessageEventShim).call(.{
                    .value = data.operand(&scope).asEngine(),
                }) catch |err| globalThis.reportActiveExceptionAsUnhandled(err);
            },
            .internal => |*data| {
                IPC.log("Received IPC internal message from parent", .{});
                event_loop.enter();
                defer event_loop.exit();
                var message_root = data.toAnyRoot();
                defer message_root.deinit();
                NodeClusterEngine.handleInternalMessageChild(&message_root) catch |err|
                    globalThis.reportActiveExceptionAsUnhandled(err);
            },
        }
    }

    pub fn handleIPCClose(this: *IPCInstance) void {
        _ = this;
        IPC.log("IPCInstance#handleIPCClose", .{});
        var vm = VirtualMachine.get();
        const event_loop = vm.eventLoop();
        NodeClusterEngine.child_singleton.deinit();
        event_loop.enter();
        bun.bindgen.Engine(ProcessEmitDisconnectEventShim).call(vm.global, .{}) catch |err|
            vm.global.reportActiveExceptionAsUnhandled(err);
        event_loop.exit();
        // Group is embedded in RareData and shared with subprocess IPC; nothing
        // to free here.
        vm.channel_ref.disable();
    }

    pub const Handlers = IPC.NewIPCHandler(IPCInstance);
};

pub fn initIPCInstance(this: *VirtualMachine, fd: bun.FD, mode: IPC.Mode) void {
    IPC.log("initIPCInstance {f}", .{fd});
    this.ipc = .{ .waiting = .{ .fd = fd, .mode = mode } };
}

pub fn getIPCInstance(this: *VirtualMachine) bun.OOM!?*IPCInstance {
    if (this.ipc == null) return null;
    if (this.ipc.? != .waiting) return this.ipc.?.initialized;
    const opts = this.ipc.?.waiting;

    IPC.log("getIPCInstance {f}", .{opts.fd});

    this.event_loop.ensureWaker();

    const instance = switch (Environment.os) {
        else => instance: {
            const group = (try this.tryRareData()).spawnIPCGroup(this);

            const instance = try bun.default_allocator.create(IPCInstance);
            instance.* = .{
                .globalThis = this.global,
                .group = group,
                .data = undefined,
            };

            instance.data = .init(opts.mode, .{ .virtual_machine = instance }, .uninitialized);
            instance.data.prepareVersionPacket() catch |err| {
                instance.deinit();
                return err;
            };

            const socket = switch (IPC.Socket.fromFd(group, .spawn_ipc, opts.fd, IPC.SendQueue, &instance.data, null, true)) {
                .socket => |socket| socket,
                .failed => |failure| {
                    instance.deinit();
                    if (failure.isOutOfMemory()) return error.OutOfMemory;
                    this.ipc = null;
                    if (failure.systemErrno() != .EBADF)
                        _ = opts.fd.closeAllowingStandardIo(null);
                    Output.warn("Unable to start IPC socket: {any}", .{failure});
                    return null;
                },
            };
            socket.setTimeout(0);

            instance.data.socket = .{ .open = socket };

            break :instance instance;
        },
        .windows => instance: {
            const instance = try bun.default_allocator.create(IPCInstance);
            instance.* = .{
                .globalThis = this.global,
                .group = {},
                .data = undefined,
            };
            instance.data = .init(opts.mode, .{ .virtual_machine = instance }, .uninitialized);
            instance.data.prepareVersionPacket() catch |err| {
                instance.deinit();
                return err;
            };

            instance.data.windowsConfigureClient(opts.fd) catch |err| {
                const fd_was_adopted = instance.data.socket != .uninitialized;
                instance.deinit();
                if (err == error.OutOfMemory and !fd_was_adopted) return error.OutOfMemory;
                this.ipc = null;
                if (!fd_was_adopted) _ = opts.fd.closeAllowingStandardIo(null);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                Output.warn("Unable to start IPC pipe '{f}'", .{opts.fd});
                return null;
            };

            break :instance instance;
        },
    };

    this.ipc = .{ .initialized = instance };
    instance.data.start(this.global);
    return instance;
}

/// To satisfy the interface from NewHotReloader()
pub fn getLoaders(vm: *VirtualMachine) *bun.options.Loader.HashTable {
    return &vm.transpiler.options.loaders;
}

/// To satisfy the interface from NewHotReloader()
pub fn bustDirCache(vm: *VirtualMachine, path: []const u8) bool {
    return vm.transpiler.resolver.bustDirCache(path);
}

pub const ExitHandler = struct {
    exit_code: u8 = 0,

    pub fn dispatchOnExit(this: *ExitHandler) void {
        const vm: *VirtualMachine = @alignCast(@fieldParentPtr("exit_handler", this));
        bun.bindgen.Engine(ProcessDispatchOnExitShim).call(vm.global, .{ .exitCode = this.exit_code }) catch |err|
            vm.global.reportActiveExceptionAsUnhandled(err);
        bun.bindgen.Engine(CloseAllSQLiteDatabasesForTerminationShim).call(vm.global, .{});
        bun.bindgen.Engine(CloseAllWebViewsForTerminationShim).call(.{ .vm = @ptrCast(vm) });
    }

    pub fn dispatchOnBeforeExit(this: *ExitHandler) void {
        const vm: *VirtualMachine = @alignCast(@fieldParentPtr("exit_handler", this));
        bun.bindgen.Engine(ProcessDispatchOnBeforeExitShim).call(vm.global, .{ .exitCode = this.exit_code }) catch |err|
            return vm.global.reportActiveExceptionAsUnhandled(err);
    }
};

const string = []const u8;

const Config = @import("./config.zig");
const Counters = @import("./Counters.zig");
const Fs = @import("../resolver/fs.zig");
const IPC = @import("./ipc.zig");
const Resolver = @import("../resolver/resolver.zig");
const Runtime = @import("../js_parser/runtime.zig");
const std = @import("std");
const SystemTimer = @import("../perf/system_timer.zig").Timer;
const PackageManager = @import("../install/install.zig").PackageManager;
const URL = @import("../url/url.zig").URL;
const Allocator = std.mem.Allocator;

const CPUProfiler = @import("./BunCPUProfiler.zig");
const CPUProfilerConfig = CPUProfiler.CPUProfilerConfig;

const HeapProfiler = @import("./BunHeapProfiler.zig");
const HeapProfilerConfig = HeapProfiler.HeapProfilerConfig;

const bun = @import("bun");
const Async = bun.Async;
const DotEnv = bun.DotEnv;
const Environment = bun.Environment;
const Global = bun.Global;
const MutableString = bun.MutableString;
const Ordinal = bun.Ordinal;
const Output = bun.Output;
const SourceMap = bun.SourceMap;
const source_provider = @import("../sourcemap_jsc/SourceProviderEngine.zig");
const String = bun.String;
const Transpiler = bun.Transpiler;
const MacroEngine = @import("../js_parser_jsc/MacroEngine.zig");
const transpiler_engine_capabilities: Transpiler.EngineCapabilities = .{
    .javascript_semantics = JavaScriptSemanticsEngine.javascript_semantics,
    .macro_context_factory = MacroEngine.context_factory,
    .bytecode_generator = BundlerEngine.bytecode_generator,
};
const BundlerEngine = @import("../bundler/BundlerEngine.zig");
const Watcher = bun.Watcher;
const default_allocator = bun.default_allocator;
const js_ast = bun.ast;
const js_printer = bun.js_printer;
const logger = bun.logger;
const LoggerEngine = @import("../logger_jsc/LoggerEngine.zig");
const options = bun.options;
const strings = bun.strings;
const uws = bun.uws;
const Arena = bun.allocators.MimallocArena;
const PluginRunner = @import("../bundler_jsc/PluginRunnerEngine.zig").PluginRunner;
const PluginResolver = @import("../bundler/PluginResolver.zig");
const api = bun.schema.api;
const DNSResolver = bun.api.dns.Resolver;

const jsc = bun.jsc;
const JavaScriptSemanticsEngine = jsc.JavaScriptSemanticsEngine;
const ConsoleObject = jsc.ConsoleObject;
const ResolvedSourceResult = jsc.ResolvedSourceResult;
const EventLoop = jsc.EventLoop;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const Node = jsc.Node;
const ResolvedSource = jsc.ResolvedSource;
const SavedSourceMap = jsc.SavedSourceMap;
const VM = jsc.VM;
const Diagnostic = jsc.Diagnostic;
const Bun = jsc.API.Bun;

const ModuleLoader = jsc.ModuleLoader;
const PackageManagerEngine = @import("../install/PackageManagerEngine.zig");
const FetchFlags = ModuleLoader.FetchFlags;
const RuntimeTranspilerStore = jsc.ModuleLoader.RuntimeTranspilerStore;
const node_fallbacks = ModuleLoader.node_fallbacks;

const HotReloader = jsc.hot_reloader.HotReloader;
const ImportWatcher = jsc.hot_reloader.ImportWatcher;

const ServerEntryPoint = bun.transpiler.EntryPoints.ServerEntryPoint;

const webcore = bun.webcore;
const Body = webcore.Body;
const BakeProductionBindings = bun.bindgen.Module("BakeProduction");
const HTMLEntryPointBindings = bun.bindgen.Module("html_entry_point");
const ErrorBindings = bun.bindgen.Module("errors");
const PromiseBindings = bun.bindgen.Module("promises");
const JSStringBindings = bun.bindgen.Module("js_strings");
const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const SQLiteTerminationBindings = bun.bindgen.Module("sqlite_termination");
const WebViewBindings = bun.bindgen.Module("webview");
const ProcessHostBindings = bun.bindgen.Module("ProcessHost");
const GlobalObjectBindings = bun.bindgen.Module("global_objects");
const VirtualMachineBindings = bun.bindgen.Module("virtual_machine");
const ModuleRunMainBindings = bun.bindgen.Module("module_run_main");
const NodeModuleModuleBindings = bun.bindgen.Module("NodeModuleModule");
const SetStringAllocationLimitShim = JSStringBindings.engineShim("setStringAllocationLimit");
const SetBunTestModeShim = ModuleLoaderBindings.engineShim("setBunTestMode");
const PromiseIsErrorLikeShim = PromiseBindings.engineShim("promiseIsErrorLike");
const NoSideEffectsToStringShim = JSStringBindings.engineShim("noSideEffectsToString");
const ErrorCodeStringVMInquirySchema = ErrorBindings.engineShim("errorCodeStringVMInquiry");
const ErrorOwnCauseSchema = ErrorBindings.engineShim("errorOwnCause");
const EmitUnhandledRejectionWarningShim = ProcessHostBindings.engineShim("emitUnhandledRejectionWarning");
const ProcessHandleUncaughtExceptionShim = ProcessHostBindings.engineShim("processHandleUncaughtException");
const ProcessEmitMessageEventShim = ProcessHostBindings.engineShim("processEmitMessageEvent");
const ProcessEmitDisconnectEventShim = ProcessHostBindings.engineShim("processEmitDisconnectEvent");
const ProcessDispatchOnBeforeExitShim = ProcessHostBindings.engineShim("processDispatchOnBeforeExit");
const ProcessDispatchOnExitShim = ProcessHostBindings.engineShim("processDispatchOnExit");
const CloseAllSQLiteDatabasesForTerminationShim = SQLiteTerminationBindings.engineShim("closeAllSQLiteDatabasesForTermination");
const CloseAllWebViewsForTerminationShim = WebViewBindings.engineShim("closeAllWebViewsForTermination");
const ShutdownWebViewTransportsShim = WebViewBindings.engineShim("shutdownWebViewTransports");
const ResetWebViewTransportsShim = WebViewBindings.engineShim("resetWebViewTransports");
const GlobalObjectDestructOnExitShim = GlobalObjectBindings.engineShim("globalObjectDestructOnExit");
const CreateBakeProductionGlobalShim = BakeProductionBindings.engineShim("createBakeProductionGlobal");
const LoadHTMLEntryPointShim = HTMLEntryPointBindings.engineShim("loadHTMLEntryPoint");
const DetachBindgenWrappersShim = GlobalObjectBindings.engineShim("detachBindgenWrappers");
const DiscardQueuedMicrotasksShim = bun.bindgen.Module("microtasks").engineShim("discardQueuedTasks");
const CallOverriddenRunMainShim = NodeModuleModuleBindings.engineShim("callOverriddenRunMain");
const DrainNativeFinalizersSchema = VirtualMachineBindings.nativeExport("virtualMachineDrainNativeFinalizers");
const CloseNativeFinalizersSchema = VirtualMachineBindings.nativeExport("virtualMachineCloseNativeFinalizers");
const ScriptExecutionStatusSchema = VirtualMachineBindings.nativeExport("virtualMachineScriptExecutionStatus");
const AllowAddonsSchema = VirtualMachineBindings.nativeExport("virtualMachineAllowAddons");
const AllowRejectionHandledWarningSchema = VirtualMachineBindings.nativeExport("virtualMachineAllowRejectionHandledWarning");
const CurrentVirtualMachineIsMainThreadSchema = VirtualMachineBindings.nativeExport("currentVirtualMachineIsMainThread");
const SetDefaultGlobalObjectSchema = VirtualMachineBindings.nativeExport("setDefaultGlobalObject");
const GetDefaultGlobalObjectSchema = VirtualMachineBindings.nativeExport("getDefaultGlobalObject");
const GetExitCodeSchema = VirtualMachineBindings.nativeExport("virtualMachineGetExitCode");
const SetExitCodeSchema = VirtualMachineBindings.nativeExport("virtualMachineSetExitCode");
const UseIsolationSourceProviderCacheSchema = VirtualMachineBindings.nativeExport("virtualMachineUseIsolationSourceProviderCache");
const SetOverrideModuleRunMainSchema = ModuleRunMainBindings.nativeExport("setOverrideModuleRunMain");
const SetOverrideModuleRunMainPromiseSchema = ModuleRunMainBindings.nativeExport("setOverrideModuleRunMainPromise");
const LogUnhandledExceptionSchema = ModuleRunMainBindings.nativeExport("logUnhandledException");
const SpecifierIsEvalEntryPointSchema = ModuleRunMainBindings.nativeExport("specifierIsEvalEntryPoint");
const SetEntryPointEvalResultESMSchema = ModuleRunMainBindings.nativeExport("setEntryPointEvalResultESM");
const SetEntryPointEvalResultCJSSchema = ModuleRunMainBindings.nativeExport("setEntryPointEvalResultCJS");
const DrainNativeFinalizersBinding = bun.bindgen.Fn(DrainNativeFinalizersSchema, bindDrainNativeFinalizers);
const CloseNativeFinalizersBinding = bun.bindgen.Fn(CloseNativeFinalizersSchema, bindCloseNativeFinalizers);
const ScriptExecutionStatusBinding = bun.bindgen.Fn(ScriptExecutionStatusSchema, bindScriptExecutionStatus);
const AllowAddonsBinding = bun.bindgen.Fn(AllowAddonsSchema, bindAllowAddons);
const AllowRejectionHandledWarningBinding = bun.bindgen.Fn(AllowRejectionHandledWarningSchema, bindAllowRejectionHandledWarning);
const CurrentVirtualMachineIsMainThreadBinding = bun.bindgen.Fn(CurrentVirtualMachineIsMainThreadSchema, bindCurrentVirtualMachineIsMainThread);
const SetDefaultGlobalObjectBinding = bun.bindgen.Fn(SetDefaultGlobalObjectSchema, bindSetDefaultGlobalObject);
const GetDefaultGlobalObjectBinding = bun.bindgen.Fn(GetDefaultGlobalObjectSchema, bindGetDefaultGlobalObject);
const GetExitCodeBinding = bun.bindgen.Fn(GetExitCodeSchema, bindGetExitCode);
const SetExitCodeBinding = bun.bindgen.Fn(SetExitCodeSchema, bindSetExitCode);
const UseIsolationSourceProviderCacheBinding = bun.bindgen.Fn(UseIsolationSourceProviderCacheSchema, bindUseIsolationSourceProviderCache);
const SetOverrideModuleRunMainBinding = bun.bindgen.Fn(SetOverrideModuleRunMainSchema, bindSetOverrideModuleRunMain);
const SetOverrideModuleRunMainPromiseBinding = bun.bindgen.Fn(SetOverrideModuleRunMainPromiseSchema, bindSetOverrideModuleRunMainPromise);
const LogUnhandledExceptionBinding = bun.bindgen.Fn(LogUnhandledExceptionSchema, bindLogUnhandledException);
const SpecifierIsEvalEntryPointBinding = bun.bindgen.Fn(SpecifierIsEvalEntryPointSchema, bindSpecifierIsEvalEntryPoint);
const SetEntryPointEvalResultESMBinding = bun.bindgen.Fn(SetEntryPointEvalResultESMSchema, bindSetEntryPointEvalResultESM);
const SetEntryPointEvalResultCJSBinding = bun.bindgen.Fn(SetEntryPointEvalResultCJSSchema, bindSetEntryPointEvalResultCJS);

comptime {
    _ = DrainNativeFinalizersBinding;
    _ = CloseNativeFinalizersBinding;
    _ = ScriptExecutionStatusBinding;
    _ = AllowAddonsBinding;
    _ = AllowRejectionHandledWarningBinding;
    _ = CurrentVirtualMachineIsMainThreadBinding;
    _ = SetDefaultGlobalObjectBinding;
    _ = GetDefaultGlobalObjectBinding;
    _ = GetExitCodeBinding;
    _ = SetExitCodeBinding;
    _ = UseIsolationSourceProviderCacheBinding;
    _ = SetOverrideModuleRunMainBinding;
    _ = SetOverrideModuleRunMainPromiseBinding;
    _ = LogUnhandledExceptionBinding;
    _ = SpecifierIsEvalEntryPointBinding;
    _ = SetEntryPointEvalResultESMBinding;
    _ = SetEntryPointEvalResultCJSBinding;
}
