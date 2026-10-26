const std = @import("std");
const b = @import("bindgen_schema");

pub const schema = b.module("ModuleRegistry", .{});

pub const id = b.enumerationWithOptions("InternalModuleId", .{
    javascript("BunFFI", "bun/ffi.ts"),
    javascript("BunIndex", "bun/index.ts"),
    javascript("BunSql", "bun/sql.ts"),
    javascript("BunSqlite", "bun/sqlite.ts"),
    javascript("BunTest", "bun/test.ts"),
    javascript("InternalAbortListener", "internal/abort_listener.ts"),
    javascript("InternalAssertAssertionError", "internal/assert/assertion_error.ts"),
    javascript("InternalAssertCalltracker", "internal/assert/calltracker.ts"),
    javascript("InternalAssertMyersDiff", "internal/assert/myers_diff.ts"),
    javascript("InternalAssertUtils", "internal/assert/utils.ts"),
    javascript("InternalBuffer", "internal/buffer.ts"),
    javascript("InternalClusterRoundRobinHandle", "internal/cluster/RoundRobinHandle.ts"),
    javascript("InternalClusterWorker", "internal/cluster/Worker.ts"),
    javascript("InternalClusterChild", "internal/cluster/child.ts"),
    javascript("InternalClusterIsPrimary", "internal/cluster/isPrimary.ts"),
    javascript("InternalClusterPrimary", "internal/cluster/primary.ts"),
    javascript("InternalCryptoX509", "internal/crypto/x509.ts"),
    javascript("InternalDebugger", "internal/debugger.ts"),
    javascript("InternalErrors", "internal/errors.ts"),
    javascript("InternalFifo", "internal/fifo.ts"),
    javascript("InternalFixedQueue", "internal/fixed_queue.ts"),
    javascript("InternalFreelist", "internal/freelist.ts"),
    javascript("InternalFSCpOptions", "internal/fs/cp-options.ts"),
    javascript("InternalFSCpSync", "internal/fs/cp-sync.ts"),
    javascript("InternalFSCp", "internal/fs/cp.ts"),
    javascript("InternalFSGlob", "internal/fs/glob.ts"),
    javascript("InternalFSStreams", "internal/fs/streams.ts"),
    javascript("InternalHtml", "internal/html.ts"),
    javascript("InternalHttp", "internal/http.ts"),
    javascript("InternalHttpFakeSocket", "internal/http/FakeSocket.ts"),
    javascript("InternalLinkedlist", "internal/linkedlist.ts"),
    javascript("InternalNetIsIP", "internal/net/isIP.ts"),
    javascript("InternalPerfHooksMonitorEventLoopDelay", "internal/perf_hooks/monitorEventLoopDelay.ts"),
    javascript("InternalPrimordials", "internal/primordials.js"),
    javascript("InternalPromisify", "internal/promisify.ts"),
    javascript("InternalShared", "internal/shared.ts"),
    javascript("InternalShell", "internal/shell.ts"),
    javascript("InternalSqlErrors", "internal/sql/errors.ts"),
    javascript("InternalSqlMysql", "internal/sql/mysql.ts"),
    javascript("InternalSqlPostgres", "internal/sql/postgres.ts"),
    javascript("InternalSqlQuery", "internal/sql/query.ts"),
    javascript("InternalSqlShared", "internal/sql/shared.ts"),
    javascript("InternalSqlSqlite", "internal/sql/sqlite.ts"),
    javascript("InternalStreamPromises", "internal/stream.promises.ts"),
    javascript("InternalStream", "internal/stream.ts"),
    javascript("InternalStreamsAddAbortSignal", "internal/streams/add-abort-signal.ts"),
    javascript("InternalStreamsCompose", "internal/streams/compose.ts"),
    javascript("InternalStreamsDestroy", "internal/streams/destroy.ts"),
    javascript("InternalStreamsDuplex", "internal/streams/duplex.ts"),
    javascript("InternalStreamsDuplexify", "internal/streams/duplexify.ts"),
    javascript("InternalStreamsDuplexpair", "internal/streams/duplexpair.ts"),
    javascript("InternalStreamsEndOfStream", "internal/streams/end-of-stream.ts"),
    javascript("InternalStreamsFrom", "internal/streams/from.ts"),
    javascript("InternalStreamsLazyTransform", "internal/streams/lazy_transform.ts"),
    javascript("InternalStreamsLegacy", "internal/streams/legacy.ts"),
    javascript("InternalStreamsNativeReadable", "internal/streams/native-readable.ts"),
    javascript("InternalStreamsOperators", "internal/streams/operators.ts"),
    javascript("InternalStreamsPassthrough", "internal/streams/passthrough.ts"),
    javascript("InternalStreamsPipeline", "internal/streams/pipeline.ts"),
    javascript("InternalStreamsReadable", "internal/streams/readable.ts"),
    javascript("InternalStreamsState", "internal/streams/state.ts"),
    javascript("InternalStreamsTransform", "internal/streams/transform.ts"),
    javascript("InternalStreamsUtils", "internal/streams/utils.ts"),
    javascript("InternalStreamsWritable", "internal/streams/writable.ts"),
    javascript("InternalTimers", "internal/timers.ts"),
    javascript("InternalTLS", "internal/tls.ts"),
    javascript("InternalTty", "internal/tty.ts"),
    javascript("InternalUrl", "internal/url.ts"),
    javascript("InternalUtilColors", "internal/util/colors.ts"),
    javascript("InternalUtilDeprecate", "internal/util/deprecate.ts"),
    javascript("InternalUtilInspect", "internal/util/inspect.js"),
    javascript("InternalUtilMime", "internal/util/mime.ts"),
    javascript("InternalValidators", "internal/validators.ts"),
    javascript("InternalWebstreamsAdapters", "internal/webstreams_adapters.ts"),
    javascript("NodeHttp2Upgrade", "node/_http2_upgrade.ts"),
    javascript("NodeHttpAgent", "node/_http_agent.ts"),
    javascript("NodeHttpClient", "node/_http_client.ts"),
    javascript("NodeHttpCommon", "node/_http_common.ts"),
    javascript("NodeHttpIncoming", "node/_http_incoming.ts"),
    javascript("NodeHttpOutgoing", "node/_http_outgoing.ts"),
    javascript("NodeHttpServer", "node/_http_server.ts"),
    javascript("NodeStreamDuplex", "node/_stream_duplex.ts"),
    javascript("NodeStreamPassthrough", "node/_stream_passthrough.ts"),
    javascript("NodeStreamReadable", "node/_stream_readable.ts"),
    javascript("NodeStreamTransform", "node/_stream_transform.ts"),
    javascript("NodeStreamWrap", "node/_stream_wrap.ts"),
    javascript("NodeStreamWritable", "node/_stream_writable.ts"),
    javascript("NodeTLSCommon", "node/_tls_common.ts"),
    javascript("NodeAssertStrict", "node/assert.strict.ts"),
    javascript("NodeAssert", "node/assert.ts"),
    javascript("NodeAsyncHooks", "node/async_hooks.ts"),
    javascript("NodeChildProcess", "node/child_process.ts"),
    javascript("NodeCluster", "node/cluster.ts"),
    javascript("NodeConsole", "node/console.ts"),
    javascript("NodeCrypto", "node/crypto.ts"),
    javascript("NodeDgram", "node/dgram.ts"),
    javascript("NodeDiagnosticsChannel", "node/diagnostics_channel.ts"),
    javascript("NodeDNSPromises", "node/dns.promises.ts"),
    javascript("NodeDNS", "node/dns.ts"),
    javascript("NodeDomain", "node/domain.ts"),
    javascript("NodeEvents", "node/events.ts"),
    javascript("NodeFSPromises", "node/fs.promises.ts"),
    javascript("NodeFS", "node/fs.ts"),
    javascript("NodeHttp", "node/http.ts"),
    javascript("NodeHttp2", "node/http2.ts"),
    javascript("NodeHttps", "node/https.ts"),
    javascript("NodeInspectorPromises", "node/inspector.promises.ts"),
    javascript("NodeInspector", "node/inspector.ts"),
    javascript("NodeModule", "node/module.ts"),
    javascript("NodeNet", "node/net.ts"),
    javascript("NodeOS", "node/os.ts"),
    javascript("NodePathPosix", "node/path.posix.ts"),
    javascript("NodePath", "node/path.ts"),
    javascript("NodePathWin32", "node/path.win32.ts"),
    javascript("NodePerfHooks", "node/perf_hooks.ts"),
    javascriptWithDefault("NodeProcess", "node/process.ts", .module_object),
    javascript("NodePunycode", "node/punycode.ts"),
    javascript("NodeQuerystring", "node/querystring.ts"),
    javascript("NodeReadlinePromises", "node/readline.promises.ts"),
    javascript("NodeReadline", "node/readline.ts"),
    javascript("NodeRepl", "node/repl.ts"),
    javascript("NodeStreamConsumers", "node/stream.consumers.ts"),
    javascript("NodeStreamPromises", "node/stream.promises.ts"),
    javascript("NodeStream", "node/stream.ts"),
    javascript("NodeStreamWeb", "node/stream.web.ts"),
    javascript("NodeTest", "node/test.ts"),
    javascript("NodeTimersPromises", "node/timers.promises.ts"),
    javascript("NodeTimers", "node/timers.ts"),
    javascript("NodeTLS", "node/tls.ts"),
    javascript("NodeTraceEvents", "node/trace_events.ts"),
    javascript("NodeTty", "node/tty.ts"),
    javascript("NodeUrl", "node/url.ts"),
    javascript("NodeUtil", "node/util.ts"),
    javascript("NodeV8", "node/v8.ts"),
    javascript("NodeVM", "node/vm.ts"),
    javascript("NodeWasi", "node/wasi.ts"),
    javascript("NodeWorkerThreads", "node/worker_threads.ts"),
    javascript("NodeZlib", "node/zlib.ts"),
    javascript("ThirdpartyIsomorphicFetch", "thirdparty/isomorphic-fetch.ts"),
    javascript("ThirdpartyNodeFetch", "thirdparty/node-fetch.ts"),
    javascript("ThirdpartyUndici", "thirdparty/undici.js"),
    javascript("ThirdpartyVercelFetch", "thirdparty/vercel_fetch.js"),
    javascript("ThirdpartyWS", "thirdparty/ws.js"),
    javascript("InternalForTesting", "internal-for-testing.ts"),
    native("BunJSC", "bun:jsc"),
    native("BunApp", "bun:app"),
    native("NodeBuffer", "node:buffer"),
    native("NodeConstants", "node:constants"),
    native("NodeStringDecoder", "node:string_decoder"),
    native("NodeUtilTypes", "node:util/types"),
    native("UTF8Validate", "utf-8-validate"),
    native("AbortControllerModule", "abort-controller"),
}, .{ .tag = .u16, .internal_module_registry = true, .cpp_name = "InternalModuleId" });

fn javascript(comptime name: []const u8, comptime source: []const u8) b.EnumerationValue {
    return javascriptWithDefault(name, source, .property);
}

fn javascriptWithDefault(comptime name: []const u8, comptime source: []const u8, comptime default_export: b.InternalModuleDefault) b.EnumerationValue {
    @setEvalBranchQuota(100_000);
    const stem = comptime blk: {
        var result: [source.len - 3]u8 = source[0 .. source.len - 3].*;
        for (&result) |*byte| if (byte.* == '.') {
            byte.* = '/';
        };
        break :blk result;
    };
    const specifier = comptime if (std.mem.eql(u8, source, "internal-for-testing.ts"))
        "bun:internal-for-testing"
    else if (std.mem.eql(u8, source, "bun/index.ts"))
        "bun"
    else if (std.mem.startsWith(u8, &stem, "node/"))
        "node:" ++ stem[5..]
    else if (std.mem.startsWith(u8, &stem, "bun/"))
        "bun:" ++ stem[4..]
    else if (std.mem.startsWith(u8, &stem, "internal/"))
        "internal:" ++ stem[9..]
    else if (std.mem.startsWith(u8, &stem, "thirdparty/"))
        stem[11..]
    else
        @compileError("internal module sources require a declared module namespace");
    return b.enumerationValueWithOptions(name, specifier, .{
        .internal_module = .{ .javascript = source },
        .internal_module_default = default_export,
        .aliases = if (std.mem.startsWith(u8, &stem, "internal/")) &.{&stem} else &.{},
    });
}

fn native(comptime name: []const u8, comptime specifier: []const u8) b.EnumerationValue {
    return b.enumerationValueWithOptions(name, specifier, .{ .internal_module = .native });
}
