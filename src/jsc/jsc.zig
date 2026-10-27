//! Bindings to JavaScriptCore and other JavaScript primatives such as
//! VirtualMachine, JSGlobalObject (Zig::GlobalObject), and the event loop.
//!
//! Web and runtime-specific APIs should go in `bun.webcore` and `bun.api`.
//!
//! TODO: Remove remaining aliases to `webcore` and `api`

/// The calling convention used for JavaScript functions <> Native
pub const conv: std.builtin.CallingConvention = if (bun.Environment.isWindows and bun.Environment.isX64)
    .{ .x86_64_sysv = .{} }
else
    .c;

/// Web Template Framework
pub const wtf = @import("./WTF.zig").WTF;

pub const NodeURL = @import("./NodeURL.zig");

/// Initialize JavaScriptCore before creating a VM.
pub fn initialize(eval_mode: bool) void {
    bun.analytics.Features.jsc += 1;
    var environment: std.ArrayList(u8) = .empty;
    defer environment.deinit(bun.default_allocator);
    for (0..bun.environ.len) |reverse_index| {
        const raw_entry = bun.environ[bun.environ.len - reverse_index - 1];
        const entry = std.mem.span(raw_entry);
        if (!std.mem.startsWith(u8, entry, "BUN_JSC_")) continue;
        bun.handleOom(environment.appendSlice(bun.default_allocator, entry));
        bun.handleOom(environment.append(bun.default_allocator, 0));
    }

    const invalid_offset = bun.bindgen.Engine(JSCInitializeSchema).call(.{
        .environment = environment.items,
        .evalMode = eval_mode,
    });
    if (invalid_offset) |offset| {
        if (offset >= environment.items.len) @panic("JSC returned an invalid environment offset");
        const entry = environment.items[offset..];
        const terminator = std.mem.indexOfScalar(u8, entry, 0) orelse
            @panic("JSC returned an unterminated environment offset");
        onJSCInvalidEnvVar(entry[0..terminator]);
    }
}

pub const JSValue = @import("./JSValue.zig").JSValue;
pub const JavaScriptSemanticsEngine = @import("./JavaScriptSemanticsEngine.zig");
pub const NodeClusterBinding = @import("../runtime/node_jsc/NodeClusterBindingEngine.zig");
pub const NodeCryptoBinding = @import("../runtime/node_jsc/node_crypto_binding.zig");
pub const NodeClusterEngine = @import("../runtime/node/NodeClusterEngine.zig");
pub const NodeCryptoEngine = @import("../runtime/node/NodeCryptoEngine.zig");
pub const NodeFSBindingEngine = @import("../runtime/node_jsc/NodeFSBindingEngine.zig");
pub const NodeFSBinding = NodeFSBindingEngine.Bindings;
pub const NodeFSWatcherEngine = @import("../runtime/node/FSWatcherEngine.zig");
pub const NodeStatWatcherEngine = @import("../runtime/node/StatWatcherEngine.zig");
pub const NodeHTTPEngine = @import("../runtime/node/NodeHTTPEngine.zig");
pub const NodeNetEngine = @import("../runtime/node/NodeNetEngine.zig");
pub const NodeProcessEngine = @import("../runtime/node/NodeProcessEngine.zig");

pub const voidFromJSError = bun.bindgen.voidFromJSError;

// JSC Classes Bindings
pub const CachedBytecode = @import("./CachedBytecode.zig").CachedBytecode;
pub const CallFrame = opaque {};
pub const CommonAbortReason = @import("../http_types/CommonAbortReason.zig").CommonAbortReason;
pub const DOMFormData = @import("./DOMFormData.zig").DOMFormData;
pub const JSArrayIterator = @import("./JSArrayIterator.zig").JSArrayIterator;
pub const JSGlobalObjectModule = @import("./JSGlobalObject.zig");
pub const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
pub const WasmStreamingCompilerHandle = opaque {};
pub const TLSDefaults = @import("./TLSDefaults.zig");
pub const IntrusiveTask = @import("./IntrusiveTask.zig");
pub const NativeCompletionRegistry = @import("../event_loop/NativeCompletionRegistry.zig");
pub const NativeFinalizerQueue = @import("./NativeFinalizerQueue.zig");
pub const InternalTestingEngine = @import("./InternalTestingEngine.zig");
pub const ModuleLoaderEngine = @import("./ModuleLoaderEngine.zig");
pub const ModuleRunMainOperations = @import("./ModuleRunMainOperations.zig");
pub const PromiseRejectionOperations = @import("./PromiseRejectionOperations.zig");
pub const RefString = @import("./RefString.zig");
pub const ScriptExecutionStatus = @import("./ScriptExecutionStatus.zig").ScriptExecutionStatus;
pub const SourceType = @import("./SourceType.zig").SourceType;
pub const URL = @import("./URL.zig").URL;
pub const URLSearchParams = @import("./URLSearchParams.zig").URLSearchParams;
pub const VM = @import("./VM.zig").VM;
pub const SourceProvider = @import("./SourceProvider.zig").SourceProvider;
pub const RegularExpression = @import("./RegularExpression.zig").RegularExpression;
pub const Counters = @import("./Counters.zig");
pub const NodeModuleModule = @import("./NodeModuleModule.zig");
pub const GlobalObjectHost = @import("./GlobalObjectHost.zig");
pub const JSMockHost = @import("./JSMockHost.zig");
pub const WebCoreFunctions = @import("./WebCoreFunctions.zig");
pub const BindgenTest = @import("./bindgen_test.zig");
pub const formatting_bindings = @import("./fmt_jsc.zig");
pub const IPC = @import("./ipc.zig");
pub const resolve_path_bindings = @import("./resolve_path_jsc.zig");
pub const resolver_bindings = @import("./resolver_jsc.zig");
pub const virtual_machine_exports = @import("./virtual_machine_exports.zig");
pub const Secrets = @import("./JSSecrets.zig");

// JavaScript-related
pub const ResolvedSource = @import("./ResolvedSource.zig").ResolvedSource;
pub const ResolvedSourceResult = @import("./ResolvedSource.zig").ResolvedSourceResult;
pub const ErrorCode = @import("./ErrorCode.zig").ErrorCode;
pub const Debugger = @import("./Debugger.zig");
pub const SavedSourceMap = @import("./SavedSourceMap.zig");
pub const VirtualMachine = @import("./VirtualMachine.zig");
pub const WebWorker = @import("./web_worker.zig");
pub const ModuleLoader = @import("./ModuleLoader.zig");
pub const RareData = @import("./rare_data.zig");
pub const EventType = @import("./EventType.zig").EventType;

pub const ConsoleObject = @import("./ConsoleObject.zig");
pub const Formatter = ConsoleObject.Formatter;

pub const hot_reloader = @import("./hot_reloader.zig");

// TODO: move into bun.api
pub const Jest = @import("../test_runner/JestEngine.zig");
pub const Expect = @import("../test_runner/expect/ExpectEngine.zig");
pub const ExpectMatcherEngine = @import("../test_runner/expect/MatcherEngine.zig");
pub const Snapshot = @import("../test_runner/snapshot.zig");

pub const js_property_iterator = @import("./JSPropertyIterator.zig");
pub const JSPropertyIterator = js_property_iterator.JSPropertyIterator;
pub const JSPropertyIteratorOptions = js_property_iterator.JSPropertyIteratorOptions;

pub const EventLoop = @import("./event_loop.zig");
pub const AbstractVM = EventLoop.AbstractVM;
pub const AnyTask = EventLoop.AnyTask;
pub const NativeMicrotask = @import("./NativeMicrotask.zig");
pub const AnyTaskWithExtraContext = EventLoop.AnyTaskWithExtraContext;
pub const ConcurrentCppTask = EventLoop.ConcurrentCppTask;
pub const ConcurrentTask = EventLoop.ConcurrentTask;
pub const CppTask = EventLoop.CppTask;
pub const JSCDeferredWorkTask = @import("./JSCScheduler.zig").JSCDeferredWorkTask;
pub const NativeEventSignal = EventLoop.CppTaskModule.NativeEventSignal;
pub const NativeEventTarget = EventLoop.CppTaskModule.NativeEventTarget;
pub const DeferredTaskQueue = EventLoop.DeferredTaskQueue;
pub const EventLoopHandle = EventLoop.EventLoopHandle;
pub const EventLoopKind = EventLoop.EventLoopKind;
pub const EventLoopTask = EventLoop.EventLoopTask;
pub const EventLoopTaskPtr = EventLoop.EventLoopTaskPtr;
pub const GarbageCollectionController = EventLoop.GarbageCollectionController;
pub const JsVM = EventLoop.JsVM;
pub const ManagedTask = EventLoop.ManagedTask;
pub const MiniEventLoop = EventLoop.MiniEventLoop;
pub const MiniVM = EventLoop.MiniVM;
pub const PlatformEventLoop = if (bun.Environment.isPosix) bun.uws.Loop else bun.Async.Loop;
pub const PosixSignalHandle = EventLoop.PosixSignalHandle;
pub const PosixSignalTask = EventLoop.PosixSignalTask;
pub const Task = EventLoop.Task;
pub const WorkTask = EventLoop.WorkTask;
pub const setLoopVM = EventLoop.setLoopVM;

/// Deprecated: Use `bun.webcore`
pub const WebCore = bun.webcore;
/// Deprecated: Use `bun.api`
pub const API = bun.api;
/// Deprecated: Use `bun.api.node`
pub const Node = bun.api.node;

pub const Subprocess = bun.api.Subprocess;

pub const NodeError = @import("./NodeErrorEngine.zig");

/// According to https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Date,
/// maximum Date in JavaScript is less than Number.MAX_SAFE_INTEGER (u52).
pub const JSTimeType = u52;
pub fn toJSTime(sec: isize, nsec: isize) JSTimeType {
    const millisec = @as(u64, @intCast(@divTrunc(nsec, std.time.ns_per_ms)));
    return @as(JSTimeType, @truncate(@as(u64, @intCast(sec * std.time.ms_per_s)) + millisec));
}

pub const MAX_SAFE_INTEGER = 9007199254740991;

fn onJSCInvalidEnvVar(name: []const u8) noreturn {
    bun.Output.errGeneric(
        \\invalid JSC environment variable
        \\
        \\    <b>{s}<r>
        \\
        \\For a list of options, see this file:
        \\
        \\    https://github.com/oven-sh/webkit/blob/main/Source/JavaScriptCore/runtime/OptionsList.h
        \\
        \\Environment variables must be prefixed with "BUN_JSC_". This code runs before .env files are loaded, so those won't work here.
        \\
        \\Warning: options change between releases of Bun and WebKit without notice. This is not a stable API, you should not rely on it beyond debugging something, and it may be removed entirely in a future version of Bun.
    ,
        .{name},
    );
    bun.Global.exit(1);
}

pub const math = struct {
    pub fn pow(x: f64, y: f64) f64 {
        return bun.bindgen.Engine(OperationMathPowShim).call(.{
            .base = x,
            .exponent = y,
        });
    }
};

const bun = @import("bun");
const std = @import("std");
const JSCInitializationBindings = bun.bindgen.Module("jsc_initialization");
const NumericConversionBindings = bun.bindgen.Module("numeric_conversions");
const JSCInitializeSchema = JSCInitializationBindings.engineShim("jscInitialize");
const OperationMathPowShim = NumericConversionBindings.engineShim("operationMathPow");

pub const Diagnostic = @import("./Diagnostic.zig");
