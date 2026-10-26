const b = @import("bindgen_schema");
const deferred_cdp_params = "CDP rejects closed views, non-Chrome backends, and unattached sessions before serializing params";
const archetypes = @import("binding_schema_archetypes");
const webcore_events = @import("binding_schema_WebCoreEvents");
const engine_types = @import("binding_schema_engine_types");

const native_view = b.nominalHandle("WebViewNative", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebViewEventTarget" } },
    .cpp_declarations = &.{.{ .class = "Bun::WebViewEventTarget" }},
    .ownership = .owned,
    .cpp_release = "releaseWebViewNative",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const finalizer = b.nominalHandle("WebViewFinalizer", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::WebViewFinalizer" } },
    .cpp_declarations = &.{.{ .structure = "Bun::WebViewFinalizer" }},
    .zig_type = "api.WebViewEventsEngine.Finalizer",
    .ownership = .owned,
    .cpp_release = "releaseWebViewFinalizer",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const backend_kind = b.enumerationWithOptions("WebViewBackendKind", .{
    b.enumerationValue("webkit", "webkit"),
    b.enumerationValue("chrome", "chrome"),
}, .{ .cpp_name = "WebViewBackendKind", .strict_errors = .{
    .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = "backend.type must be a string" },
    .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_VALUE" }, .message = "backend.type must be \"webkit\" or \"chrome\"" },
} });

fn stdioMode(comptime name: []const u8, comptime stream: []const u8) b.Type {
    const message = "backend." ++ stream ++ " must be \"inherit\" or \"ignore\"";
    return b.enumerationWithOptions(name, .{
        b.enumerationValue("inherit", "inherit"),
        b.enumerationValue("ignore", "ignore"),
    }, .{ .cpp_name = name, .strict_errors = .{
        .invalid_type = .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = message },
        .invalid_value = .{ .kind = .{ .code = "ERR_INVALID_ARG_VALUE" }, .message = message },
    } });
}

fn strictString(comptime message: []const u8) b.Type {
    return b.strictString(b.dom_string, .{ .kind = .{ .code = "ERR_INVALID_ARG_TYPE" }, .message = message });
}

// `url: "ws://..."` connects to an existing DevTools endpoint; `url: false`
// skips DevToolsActivePort auto-detection and always spawns.
const backend_url = b.unionType("WebViewBackendUrl", .{
    b.unionMember("url", b.dom_string),
    b.unionMember("flag", b.boolean),
}, .{ .cpp_name = "WebViewBackendUrl" });

const backend_options = b.dictionaryWithOptions("WebViewBackendOptions", .{
    b.dictionaryField("type", backend_kind, .{ .required = true, .missing_required = .convert_undefined }),
    b.dictionaryField("path", strictString("backend.path must be a string"), .{}),
    b.dictionaryField("url", backend_url, .{}),
    b.dictionaryField("argv", b.sequence(strictString("backend.argv entries must be strings")), .{}),
    // Not named after the JS properties: stdout/stderr are macros on Darwin.
    b.dictionaryField("stdout_mode", stdioMode("WebViewStdoutMode", "stdout"), .{ .js_name = "stdout" }),
    b.dictionaryField("stderr_mode", stdioMode("WebViewStderrMode", "stderr"), .{ .js_name = "stderr" }),
}, .{ .cpp_name = "WebViewBackendOptions" });

const backend_choice = b.unionType("WebViewBackendChoice", .{
    b.unionMember("kind", backend_kind),
    b.unionMember("options", backend_options),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .cpp_name = "WebViewBackendChoice", .ordered = true, .fallback_member = "ignored" });

const ephemeral_kind = b.enumerationWithOptions("WebViewDataStoreKind", .{
    b.enumerationValue("ephemeral", "ephemeral"),
}, .{ .cpp_name = "WebViewDataStoreKind" });

const data_store_options = b.dictionaryWithOptions("WebViewDataStoreOptions", .{
    b.dictionaryField("directory", b.dom_string, .{ .required = true }),
}, .{ .cpp_name = "WebViewDataStoreOptions" });

const data_store = b.unionType("WebViewDataStore", .{
    b.unionMember("kind", ephemeral_kind),
    b.unionMember("options", data_store_options),
}, .{ .cpp_name = "WebViewDataStore" });

fn viewDimension(comptime name: []const u8, comptime default: u64) b.DictionaryField {
    return b.dictionaryField(name, b.uint32, .{
        .default_value = .{ .unsigned = default },
        .integer_conversion = .{ .node_validate = .{ .min = 1, .max = 16384 } },
    });
}

const global_console_brand = b.cppRealmBrand("WebViewGlobalConsole", .{
    .symbol = "Bun::Bindgen::WebViewPredicates::isGlobalConsole",
    .header = "WebViewBindings.h",
}, "Console");
const global_console_value = b.brandedValueWithBrand(global_console_brand, .{
    .error_kind = .type,
    .expectation = "globalThis.console",
    .node_requirement = "globalThis.console",
});
const console_source = b.unionType("WebViewConsoleSource", .{
    b.unionMember("callback", archetypes.callable_value),
    b.unionMember("global_console", global_console_value),
}, .{ .ordered = true, .cpp_name = "WebViewConsoleSource", .no_match_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "console must be globalThis.console or a function",
} });
const pending_promise = b.js_promise;

const navigated_callback = b.callback("WebViewNavigatedCallback", .{
    b.argument("url", b.dom_string, .{}),
    b.argument("title", archetypes.optional_dom_string, .{}),
}, b.none, .{ .receiver = null, .profile = .exact });

const navigation_failed_callback = b.callback("WebViewNavigationFailedCallback", .{
    b.argument("error", b.js_error_instance, .{}),
}, b.none, .{ .receiver = null, .profile = .exact });

const console_callback = b.callback("WebViewConsoleCallback", .{
    b.argument("type", b.dom_string, .{}),
    b.rest("arguments", b.invocation_any),
}, b.none, .{ .receiver = null, .profile = .exact });

const construct_options = b.dictionaryWithOptions("WebViewConstructOptions", .{
    viewDimension("width", 800),
    viewDimension("height", 600),
    b.dictionaryField("headless", b.boolean, .{}),
    b.dictionaryField("backend", backend_choice, .{}),
    b.dictionaryField("url", b.dom_string, .{}),
    // The current realm's intrinsic console routes page output to the native
    // console sink; any callable is called as (type, ...args).
    b.dictionaryField("console", console_source, .{}),
    b.dictionaryField("dataStore", data_store, .{}),
}, .{ .cpp_name = "WebViewConstructOptions" });

const screenshot_format = b.enumerationWithOptions("WebViewScreenshotFormat", .{
    b.enumerationValue("png", "png"),
    b.enumerationValue("jpeg", "jpeg"),
    b.enumerationValue("webp", "webp"),
}, .{ .cpp_name = "WebViewScreenshotFormat" });

const screenshot_encoding = b.enumerationWithOptions("WebViewScreenshotEncoding", .{
    b.enumerationValue("blob", "blob"),
    b.enumerationValue("buffer", "buffer"),
    b.enumerationValue("base64", "base64"),
    b.enumerationValue("shmem", "shmem"),
}, .{ .cpp_name = "WebViewScreenshotEncoding" });

const screenshot_options = b.dictionaryWithOptions("WebViewScreenshotOptions", .{
    b.dictionaryField("format", screenshot_format, .{}),
    b.dictionaryField("quality", b.uint8, .{
        .default_value = .{ .unsigned = 80 },
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 100 } },
    }),
    b.dictionaryField("encoding", screenshot_encoding, .{}),
}, .{ .cpp_name = "WebViewScreenshotOptions" });

const cdp_params_input = b.unionType("WebViewCDPParamsInput", .{
    b.unionMember("object", b.js_object),
    b.unionMember("undefined_value", b.undefined_literal),
    b.unionMember("null_value", b.null_literal),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid", .cpp_name = "WebViewCDPParamsInput" });

const mouse_button = b.enumerationWithOptions("WebViewMouseButton", .{
    b.enumerationValue("left", "left"),
    b.enumerationValue("right", "right"),
    b.enumerationValue("middle", "middle"),
}, .{ .cpp_name = "WebViewMouseButton" });

const modifier_names = archetypes.dom_strings;

fn timeoutField() b.DictionaryField {
    return b.dictionaryField("timeout", b.uint32, .{
        .default_value = .{ .unsigned = 30000 },
        .integer_conversion = .{ .clamp = .{ .min = 0, .max = 4294967295 } },
    });
}

const click_options = b.dictionaryWithOptions("WebViewClickOptions", .{
    b.dictionaryField("button", mouse_button, .{}),
    b.dictionaryField("modifiers", modifier_names, .{}),
    b.dictionaryField("clickCount", b.int32, .{
        .default_value = .{ .unsigned = 1 },
        .integer_conversion = .{ .clamp = .{ .min = 1, .max = 3 } },
    }),
    timeoutField(),
}, .{ .cpp_name = "WebViewClickOptions" });

const press_options = b.dictionaryWithOptions("WebViewPressOptions", .{
    b.dictionaryField("modifiers", modifier_names, .{}),
}, .{ .cpp_name = "WebViewPressOptions" });

const scroll_block = b.enumerationWithOptions("WebViewScrollBlock", .{
    b.enumerationValue("start", "start"),
    b.enumerationValue("center", "center"),
    b.enumerationValue("end", "end"),
    b.enumerationValue("nearest", "nearest"),
}, .{ .cpp_name = "WebViewScrollBlock" });

const scroll_to_options = b.dictionaryWithOptions("WebViewScrollToOptions", .{
    timeoutField(),
    b.dictionaryField("block", scroll_block, .{}),
}, .{ .cpp_name = "WebViewScrollToOptions" });

fn optionsArgument(comptime value_type: b.Type) b.Argument {
    return b.argument("options", value_type, .{ .presence = .optional, .missing = .undefined_or_null });
}

fn finiteNumber(comptime name: []const u8) b.Argument {
    const max_finite = 1.7976931348623157e308;
    return b.argument(name, b.double, .{
        .number_conversion = .{ .node_validate = .{ .min = -max_finite, .max = max_finite } },
    });
}

fn viewSize(comptime name: []const u8) b.Argument {
    return b.argument(name, b.uint32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 1, .max = 16384 } },
    });
}

const web_view_class = b.class(
    "WebView",
    b.constructor(.{optionsArgument(construct_options)}, .{ .length = 1 }),
    .{
        b.method("navigate", .{b.argument("url", b.dom_string, .{})}, b.js_promise, .{ .length = 1 }),
        b.method("evaluate", .{b.argument("script", b.dom_string, .{})}, b.js_promise, .{ .length = 1 }),
        b.method("screenshot", .{optionsArgument(screenshot_options)}, b.js_promise, .{ .length = 0 }),
        b.method("cdp", .{
            b.argument("method", b.dom_string, .{}),
            b.argument("params", b.lazy(cdp_params_input), .{
                .presence = .optional,
                .missing = .undefined,
                .deferred_reason = deferred_cdp_params,
            }),
        }, b.js_promise, .{ .length = 1 }),
        b.method("click", b.overloads(.{
            b.overloadCase("selector", .{
                b.argument("selector", b.dom_string, .{}),
                optionsArgument(click_options),
            }),
            b.overloadCase("point", .{
                finiteNumber("x"),
                finiteNumber("y"),
                optionsArgument(click_options),
            }),
        }, .{ .ordered = true }), b.js_promise, .{ .length = 2 }),
        b.method("type", .{b.argument("text", b.dom_string, .{})}, b.js_promise, .{ .length = 1 }),
        b.method("press", .{
            b.argument("key", b.dom_string, .{}),
            optionsArgument(press_options),
        }, b.js_promise, .{ .length = 1 }),
        b.method("scroll", .{ finiteNumber("dx"), finiteNumber("dy") }, b.js_promise, .{ .length = 2 }),
        b.method("scrollTo", .{
            b.argument("selector", b.dom_string, .{}),
            optionsArgument(scroll_to_options),
        }, b.js_promise, .{ .length = 1 }),
        b.method("resize", .{ viewSize("width"), viewSize("height") }, b.js_promise, .{ .length = 2 }),
        b.method("goBack", .{}, b.js_promise, .{ .length = 0 }),
        b.method("goForward", .{}, b.js_promise, .{ .length = 0 }),
        b.method("reload", .{}, b.js_promise, .{ .length = 0 }),
        b.method("close", .{}, b.none, .{ .length = 0 }),
        b.method("closeDispose", .{}, b.none, .{ .symbol = .dispose, .display_name = "close" }),
        b.method("closeAsyncDispose", .{}, b.none, .{ .symbol = .async_dispose, .display_name = "close" }),
        b.getter("url", b.dom_string, .{}),
        b.getter("title", b.dom_string, .{}),
        b.getter("loading", b.boolean, .{}),
        b.staticMethod("closeAll", .{}, b.none, .{ .length = 0, .enumerable = false }),
    },
    .{
        b.cachedSlot("onNavigated", b.optional(navigated_callback), .{ .writable = true }),
        b.cachedSlot("onNavigationFailed", b.optional(navigation_failed_callback), .{ .writable = true }),
        b.cachedSlot("onConsole", b.optional(console_callback), .{ .exposed = false }),
        b.cachedSlot("pendingNavigate", pending_promise, .{ .exposed = false }),
        b.cachedSlot("pendingEval", pending_promise, .{ .exposed = false }),
        b.cachedSlot("pendingScreenshot", pending_promise, .{ .exposed = false }),
        b.cachedSlot("pendingMisc", pending_promise, .{ .exposed = false }),
        b.cachedSlot("pendingCdp", pending_promise, .{ .exposed = false }),
    },
    .{
        .backend = .cpp,
        .profile = .node,
        .representation = .engine,
        .engine_intrinsic = "WebKit page identity and UI-process callbacks",
        .parent = b.parentClass(webcore_events.event_target_class),
        .engine_native = .{ .cpp_type = "Bun::WebViewEventTarget", .header = "WebViewEventTarget.h", .wrapper_tag = "WebCore::BunWebViewEventTargetInterfaceType" },
        .identity = .per_realm,
    },
);

const engine_shims = .{
    b.engineShim("resetWebViewTransports", .{
        b.argument("vm", engine_types.jsc_vm, .{}),
    }, b.none, .vm_thread_nonthrowing),
    b.engineShim("shutdownWebViewTransports", .{
        b.argument("vm", engine_types.jsc_vm, .{}),
    }, b.none, .vm_thread_nonthrowing),
    b.engineShim("closeWebViewNative", .{
        b.argument("view", native_view, .{}),
        b.argument("shutting_down", b.boolean, .{}),
    }, b.none, .vm_thread_nonthrowing),
    b.engineShim("closeAllWebViewsForTermination", .{b.argument("vm", engine_types.bun_vm, .{})}, b.none, .vm_thread_nonthrowing),
};

const native_exports = .{
    b.nativeExportWithOptions("createWebViewFinalizer", .{
        b.argument("vm", engine_types.bun_vm, .{}),
    }, finalizer, .allocating),
    b.nativeExport("enqueueWebViewFinalizer", .{
        b.argument("finalizer", finalizer, .{ .ownership = .transfer }),
        b.argument("view", native_view, .{ .ownership = .transfer }),
    }, b.none),
    b.nativeExport("discardWebViewFinalizer", .{
        b.argument("finalizer", finalizer, .{ .ownership = .transfer }),
    }, b.none),
    b.nativeExportWithOptions("dispatchNavigated", .{
        b.argument("callback", navigated_callback, .{}),
        b.argument("url", b.dom_string, .{}),
        b.argument("title", archetypes.optional_dom_string, .{}),
    }, b.none, .current_realm_nonthrowing),
    b.nativeExportWithOptions("dispatchNavigationFailed", .{
        b.argument("callback", navigation_failed_callback, .{}),
        b.argument("error", b.js_error_instance, .{}),
    }, b.none, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithDeclarations("webview", .{}, .{web_view_class}, engine_shims, native_exports);
pub const web_view = schema.class("WebView");
