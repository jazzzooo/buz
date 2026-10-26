const b = @import("bindgen_schema");
const crypto = @import("binding_schema_Crypto");
const webcrypto_key = @import("binding_schema_WebCryptoKey");
const subtle_crypto = @import("binding_schema_SubtleCryptoHost");
const bun_object = @import("binding_schema_BunObject");
const bun_object_surface = @import("binding_schema_BunObjectSurface");
const buffer_host = @import("binding_schema_BufferHost");
const global_object = @import("binding_schema_GlobalObjectHost");
const error_code = @import("binding_schema_ErrorCode");
const internal_module_registry = @import("binding_schema_InternalModuleRegistry");
const builtin_binding = @import("binding_schema_BuiltinBindingResolver");
const node_timers = @import("binding_schema_NodeTimers");
const prompt = @import("binding_schema_prompt");
const runtime = @import("binding_schema_RuntimeFunctions");
const surface_builtins = @import("binding_schema_SurfaceBuiltins");
const webcore_dom_exception = @import("binding_schema_WebCoreDOMException");
const webcore_events = @import("binding_schema_WebCoreEvents");
const webcore_form_data = @import("binding_schema_WebCoreFormData");
const webcore_headers = @import("binding_schema_WebCoreHeaders");
const webcore_performance = @import("binding_schema_WebCorePerformance");
const webcore_streams = @import("binding_schema_WebCoreStreams");
const webcore_url = @import("binding_schema_WebCoreURL");
const webcore_web_socket = @import("binding_schema_WebCoreWebSocket");
const webcore_worker = @import("binding_schema_WebCoreWorker");
const webcore_functions = @import("binding_schema_WebCoreFunctions");

const configurable = b.SurfaceMemberOptions{ .attributes = .{} };
const hidden = b.SurfaceMemberOptions{ .attributes = .{ .enumerable = false } };
const direct_configurable = b.SurfaceMemberOptions{ .attributes = .{}, .placement = .direct };
const hidden_permanent = b.SurfaceMemberOptions{
    .attributes = .{ .enumerable = false, .configurable = false },
};
const readonly_permanent = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};
const global_static = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
    .placement = .global_static,
};
const global_static_hidden = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false, .configurable = false },
    .placement = .global_static,
    .function_name = "@bindingFactory",
};
const bun_cell = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};

fn globalFunction(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, global_object.schema.function(declaration_name), configurable);
}

fn timerFunction(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, node_timers.schema.function(name), configurable);
}

fn promptFunction(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, prompt.schema.function(name), configurable);
}

fn webcoreFunction(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, webcore_functions.schema.function(declaration_name), configurable);
}

fn lazy(comptime name: []const u8, comptime callback: []const u8) b.SurfaceMember {
    return b.surfaceLazyProperty(name, global_object.schema.function(callback), configurable);
}

fn classStructure(comptime name: []const u8, comptime member: []const u8) b.SurfaceMember {
    return b.surfaceClassStructure(name, member, configurable);
}

const global = b.objectSurface("ZigGlobalObject", .{
    globalFunction("addEventListener", "jsFunctionAddEventListener"),
    promptFunction("alert"),
    globalFunction("atob", "functionATOB"),
    globalFunction("btoa", "functionBTOA"),
    timerFunction("clearImmediate"),
    timerFunction("clearInterval"),
    timerFunction("clearTimeout"),
    promptFunction("confirm"),
    globalFunction("dispatchEvent", "jsFunctionDispatchEvent"),
    b.surfaceCallableValue("fetch", bun_object.schema.function("fetch"), bun_object_surface.fetch_function, configurable),
    webcoreFunction("postMessage", "jsFunctionPostMessage"),
    promptFunction("prompt"),
    globalFunction("queueMicrotask", "functionQueueMicrotask"),
    globalFunction("removeEventListener", "jsFunctionRemoveEventListener"),
    globalFunction("reportError", "functionReportError"),
    timerFunction("setImmediate"),
    timerFunction("setInterval"),
    timerFunction("setTimeout"),
    webcoreFunction("structuredClone", "jsFunctionStructuredClone"),
    lazy("global", "GlobalObject_getGlobalThis"),

    b.surfaceCellProperty("Bun", "m_bunObject", bun_cell),
    classStructure("File", "m_BunBindgen_Blob_File"),
    b.surfaceLazyProperty("crypto", crypto.schema.nativeExport("cryptoObjectCreate"), configurable),
    b.surfaceCellProperty("navigator", "m_navigatorObject", configurable),
    lazy("performance", "GlobalObject_getPerformanceObject"),
    b.surfaceCellProperty("process", "m_processObject", configurable),

    classStructure("Blob", "m_BunBindgen_Blob_Blob"),
    classStructure("Buffer", "m_JSBufferClassStructure"),
    classStructure("BuildError", "m_BunBindgen_BuildMessage_BuildMessage"),
    classStructure("BuildMessage", "m_BunBindgen_BuildMessage_BuildMessage"),
    classStructure("Crypto", "m_BunBindgen_Crypto_Crypto"),
    classStructure("HTMLRewriter", "m_BunBindgen_HTMLRewriter_HTMLRewriter"),
    classStructure("Request", "m_BunBindgen_Request_Request"),
    classStructure("ResolveError", "m_BunBindgen_ResolveMessage_ResolveMessage"),
    classStructure("ResolveMessage", "m_BunBindgen_ResolveMessage_ResolveMessage"),
    classStructure("Response", "m_BunBindgen_Response_Response"),
    classStructure("TextDecoder", "m_BunBindgen_TextDecoder_TextDecoder"),

    b.surfaceLazyProperty("AbortController", webcore_events.abort_controller, configurable),
    b.surfaceLazyProperty("AbortSignal", webcore_events.abort_signal, configurable),
    b.surfaceLazyProperty("BroadcastChannel", webcore_events.broadcast_channel, configurable),
    b.surfaceLazyProperty("ByteLengthQueuingStrategy", webcore_streams.byte_length_queuing_strategy, configurable),
    b.surfaceLazyProperty("CloseEvent", webcore_events.close_event, configurable),
    b.surfaceLazyProperty("CompressionStream", webcore_streams.compression_stream, configurable),
    b.surfaceLazyProperty("CountQueuingStrategy", webcore_streams.count_queuing_strategy, configurable),
    b.surfaceLazyProperty("CryptoKey", webcrypto_key.crypto_key, configurable),
    b.surfaceLazyProperty("CustomEvent", webcore_events.custom_event, configurable),
    b.surfaceLazyProperty("DecompressionStream", webcore_streams.decompression_stream, configurable),
    b.surfaceLazyProperty("DOMException", webcore_dom_exception.dom_exception, configurable),
    b.surfaceLazyProperty("ErrorEvent", webcore_events.error_event, configurable),
    b.surfaceLazyProperty("Event", webcore_events.event, configurable),
    b.surfaceLazyProperty("EventTarget", webcore_events.event_target, configurable),
    b.surfaceLazyProperty("FormData", webcore_form_data.form_data, configurable),
    b.surfaceLazyProperty("Headers", webcore_headers.headers, configurable),
    b.surfaceLazyProperty("MessageChannel", webcore_events.message_channel, configurable),
    b.surfaceLazyProperty("MessageEvent", webcore_events.message_event, configurable),
    b.surfaceLazyProperty("MessagePort", webcore_events.message_port, configurable),
    b.surfaceLazyProperty("Performance", webcore_performance.performance, configurable),
    b.surfaceLazyProperty("PerformanceEntry", webcore_performance.performance_entry, configurable),
    b.surfaceLazyProperty("PerformanceMark", webcore_performance.performance_mark, configurable),
    b.surfaceLazyProperty("PerformanceMeasure", webcore_performance.performance_measure, configurable),
    b.surfaceLazyProperty("PerformanceObserver", webcore_performance.performance_observer, configurable),
    b.surfaceLazyProperty("PerformanceObserverEntryList", webcore_performance.PerformanceObserverEntryList, configurable),
    b.surfaceLazyProperty("PerformanceResourceTiming", webcore_performance.performance_resource_timing, configurable),
    b.surfaceLazyProperty("PerformanceServerTiming", webcore_performance.PerformanceServerTiming, configurable),
    b.surfaceLazyProperty("PerformanceTiming", webcore_performance.PerformanceTiming, configurable),
    b.surfaceLazyProperty("ReadableByteStreamController", webcore_streams.readable_byte_stream_controller, configurable),
    b.surfaceLazyProperty("ReadableStream", webcore_streams.readable_stream, configurable),
    b.surfaceLazyProperty("ReadableStreamBYOBReader", webcore_streams.readable_stream_byob_reader, configurable),
    b.surfaceLazyProperty("ReadableStreamBYOBRequest", webcore_streams.readable_stream_byob_request, configurable),
    b.surfaceLazyProperty("ReadableStreamDefaultController", webcore_streams.readable_stream_default_controller, configurable),
    b.surfaceLazyProperty("ReadableStreamDefaultReader", webcore_streams.readable_stream_default_reader, configurable),
    b.surfaceLazyProperty("SubtleCrypto", subtle_crypto.subtle_crypto, configurable),
    b.surfaceLazyProperty("TextDecoderStream", webcore_streams.text_decoder_stream, configurable),
    b.surfaceLazyProperty("TextEncoder", webcore_streams.text_encoder, configurable),
    b.surfaceLazyProperty("TextEncoderStream", webcore_streams.text_encoder_stream, configurable),
    b.surfaceLazyProperty("TransformStream", webcore_streams.transform_stream, configurable),
    b.surfaceLazyProperty("TransformStreamDefaultController", webcore_streams.transform_stream_default_controller, configurable),
    b.surfaceLazyProperty("URL", webcore_url.url, hidden),
    b.surfaceLazyProperty("URLPattern", webcore_url.url_pattern, configurable),
    b.surfaceLazyProperty("URLSearchParams", webcore_url.url_search_params, hidden),
    b.surfaceLazyProperty("WebSocket", webcore_web_socket.web_socket, configurable),
    b.surfaceLazyProperty("Worker", webcore_worker.worker, configurable),
    b.surfaceLazyProperty("WritableStream", webcore_streams.writable_stream, configurable),
    b.surfaceLazyProperty("WritableStreamDefaultController", webcore_streams.writable_stream_default_controller, configurable),
    b.surfaceLazyProperty("WritableStreamDefaultWriter", webcore_streams.writable_stream_default_writer, configurable),

    b.surfaceFunctionAt(b.surfaceBuiltinName("bindingFactoryPrivateName"), builtin_binding.schema.function("resolve"), global_static_hidden),
    b.surfaceFunctionAt(b.surfaceBuiltinName("makeGetterTypeErrorPrivateName"), global_object.schema.function("makeGetterTypeErrorForBuiltins"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("makeDOMExceptionPrivateName"), global_object.schema.function("makeDOMExceptionForBuiltins"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("addAbortAlgorithmToSignalPrivateName"), global_object.schema.function("addAbortAlgorithmToSignal"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("removeAbortAlgorithmFromSignalPrivateName"), global_object.schema.function("removeAbortAlgorithmFromSignal"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("cloneArrayBufferPrivateName"), webcore_functions.schema.function("cloneArrayBuffer"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("structuredCloneForStreamPrivateName"), webcore_functions.schema.function("structuredCloneForStream"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("isAbortSignalPrivateName"), global_object.schema.function("isAbortSignal"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("peekPromiseStatusPrivateName"), global_object.schema.function("jsBunPeekPromiseStatus"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("peekPromiseSettledValuePrivateName"), global_object.schema.function("jsBunPeekPromiseSettledValue"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("pokePromiseAsHandledPrivateName"), global_object.schema.function("jsBunPokePromiseAsHandled"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("getInternalWritableStreamPrivateName"), global_object.schema.function("getInternalWritableStream"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("createWritableStreamFromInternalPrivateName"), global_object.schema.function("createWritableStreamFromInternal"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("fulfillModuleSyncPrivateName"), global_object.schema.function("functionFulfillModuleSync"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("esmNamespaceForCjsPrivateName"), global_object.schema.function("functionEsmNamespaceForCjs"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("esmRegistryDeletePrivateName"), global_object.schema.function("functionEsmRegistryDelete"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("esmRegistryEvaluatedKeysPrivateName"), global_object.schema.function("functionEsmRegistryEvaluatedKeys"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("esmLoadSyncPrivateName"), global_object.schema.function("functionEsmLoadSync"), global_static),
    b.surfaceLazyPropertyAt(b.surfaceEngineBuiltinName("ArrayBufferPrivateName"), global_object.schema.function("arrayBufferConstructorValue"), global_static),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("internalModuleRegistryPrivateName"), global_object.schema.function("internalModuleRegistryValue"), global_static),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("processBindingConstantsPrivateName"), global_object.schema.function("processBindingConstantsValue"), global_static),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("requireMapPrivateName"), global_object.schema.function("requireMapValue"), global_static),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("TextEncoderStreamEncoderPrivateName"), global_object.schema.function("textEncoderStreamEncoderConstructorValue"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("makeErrorWithCodePrivateName"), error_code.schema.function("makeErrorWithCode"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("toClassPrivateName"), global_object.schema.function("jsFunctionToClass"), global_static),
    b.surfaceFunctionAt(b.surfaceBuiltinName("makeAbortErrorPrivateName"), error_code.schema.function("makeAbortError"), .{
        .attributes = global_static.attributes,
        .placement = .global_static,
        .function_visibility = .internal,
    }),
    b.surfaceFunctionAt(b.surfaceBuiltinName("checkBufferReadPrivateName"), global_object.schema.function("jsFunctionCheckBufferRead"), global_static),

    b.surfaceFunctionAt(b.surfaceBuiltinName("createFIFOPrivateName"), surface_builtins.schema.function("createFIFO"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("requireESMPrivateName"), surface_builtins.schema.function("requireESM"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("loadEsmIntoCjsPrivateName"), surface_builtins.schema.function("loadEsmIntoCjs"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("internalRequirePrivateName"), surface_builtins.schema.function("internalRequire"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("overridableRequirePrivateName"), surface_builtins.schema.function("overridableRequire"), configurable),
    b.surfaceFunctionAt(b.surfaceBuiltinName("createUninitializedArrayBufferPrivateName"), global_object.schema.function("functionCreateUninitializedArrayBuffer"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("resolveSyncPrivateName"), runtime.schema.function("functionImportMeta__resolveSyncPrivate"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("createInternalModuleByIdPrivateName"), internal_module_registry.schema.function("createById"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("createCommonJSModulePrivateName"), runtime.schema.function("jsFunctionCreateCommonJSModule"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("evaluateCommonJSModulePrivateName"), runtime.schema.function("jsFunctionEvaluateCommonJSModule"), readonly_permanent),
    b.surfaceFunctionAt(b.surfaceBuiltinName("evictIsolationSourceProviderCachePrivateName"), runtime.schema.function("jsFunctionEvictIsolationSourceProviderCache"), readonly_permanent),

    b.surfaceFunctionAccessorAt(b.surfaceBuiltinName("BufferPrivateName"), buffer_host.schema.function("getJSBufferConstructor"), null, readonly_permanent),
    b.surfaceFunctionAccessorAt(b.surfaceBuiltinName("lazyStreamPrototypeMapPrivateName"), global_object.schema.function("readableStreamNativeMapValue"), null, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("TransformStreamPrivateName"), webcore_streams.transform_stream, hidden),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("TransformStreamDefaultControllerPrivateName"), webcore_streams.transform_stream_default_controller, hidden),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("ReadableByteStreamControllerPrivateName"), webcore_streams.readable_byte_stream_controller, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("ReadableStreamPrivateName"), webcore_streams.readable_stream, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("ReadableStreamBYOBReaderPrivateName"), webcore_streams.readable_stream_byob_reader, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("ReadableStreamDefaultControllerPrivateName"), webcore_streams.readable_stream_default_controller, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("ReadableStreamDefaultReaderPrivateName"), webcore_streams.readable_stream_default_reader, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("WritableStreamPrivateName"), webcore_streams.writable_stream, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("WritableStreamDefaultControllerPrivateName"), webcore_streams.writable_stream_default_controller, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("WritableStreamDefaultWriterPrivateName"), webcore_streams.writable_stream_default_writer, readonly_permanent),
    b.surfaceLazyPropertyAt(b.surfaceBuiltinName("AbortSignalPrivateName"), webcore_events.abort_signal, readonly_permanent),
    b.surfaceFunctionAccessor("self", global_object.schema.function("functionGetSelf"), global_object.schema.function("functionSetSelf"), configurable),
    b.surfaceFunctionAccessor("onmessage", global_object.schema.function("globalOnMessageValue"), global_object.schema.function("setGlobalOnMessageValue"), direct_configurable),
    b.surfaceFunctionAccessor("onerror", global_object.schema.function("globalOnErrorValue"), global_object.schema.function("setGlobalOnErrorValue"), direct_configurable),
}, .{ .cpp_class = "GlobalObject" });

const error_constructor = b.objectSurface("ErrorConstructorExtensions", .{
    b.surfaceFunction("captureStackTrace", runtime.schema.function("errorConstructorFuncCaptureStackTrace"), hidden),
    b.surfaceFunction("appendStackTrace", runtime.schema.function("errorConstructorFuncAppendStackTrace"), .{
        .attributes = .{ .enumerable = false },
        .function_visibility = .internal,
    }),
    b.surfaceFunctionAccessor("prepareStackTrace", global_object.schema.function("errorPrepareStackTraceValue"), global_object.schema.function("setErrorPrepareStackTraceValue"), hidden),
}, .{ .installation = .direct });

const console_object = b.objectSurface("ConsoleObjectExtensions", .{
    b.surfaceFunctionAt(b.surfaceSymbol(.async_iterator), surface_builtins.schema.function("consoleAsyncIterator"), configurable),
    b.surfaceFunctionAt(b.surfaceBuiltinName("writePublicName"), surface_builtins.schema.function("consoleWrite"), configurable),
    b.surfaceFunctionGetter("Console", global_object.schema.function("consoleConstructorValue"), configurable),
    b.surfaceFunctionGetter("_stdout", global_object.schema.function("consoleStdoutValue"), hidden),
    b.surfaceFunctionGetter("_stderr", global_object.schema.function("consoleStderrValue"), hidden),
}, .{ .installation = .direct });

const module_namespace_prototype = b.objectSurface("ModuleNamespacePrototype", .{
    b.surfaceFunctionAccessorAt(
        b.surfaceEngineName("__esModule"),
        global_object.schema.function("moduleNamespaceESModuleValue"),
        global_object.schema.function("setModuleNamespaceESModuleValue"),
        hidden_permanent,
    ),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("ZigGlobalObjectSurface", .{
    global,
    error_constructor,
    console_object,
    module_namespace_prototype,
});
