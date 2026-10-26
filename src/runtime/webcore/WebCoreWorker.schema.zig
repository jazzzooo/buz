const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_bindings = @import("binding_schema_WebCoreBindings");
const structured_clone = @import("binding_schema_StructuredClone");
const events = @import("binding_schema_WebCoreEvents");

const worker_script_url_input = b.unionType("WorkerScriptURLInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("url", b.classValueByName("WebCoreURL", "URL")),
}, .{
    .cpp_name = "WorkerScriptURLInput",
    .node_error = .{ .type_or_instance = .{ .expected_type = "string", .expected_instances = "URL" } },
});
const worker_preload = b.unionType("WorkerPreload", .{
    b.unionMember("module", b.dom_string),
    b.unionMember("modules", archetypes.dom_strings),
}, .{
    .cpp_name = "WorkerPreload",
    .no_match_error = .{ .kind = .generic_error, .message = "preload must be an array or string" },
});
const worker_shared_environment = b.brandedValueWithBrand(b.cppBrand("WorkerSharedEnvironment", .{
    .symbol = "Bun::Bindgen::isWorkerSharedEnvironment",
    .header = "webcore/WorkerBindingInputs.h",
}, "typeof import(\"node:worker_threads\").SHARE_ENV"), .{
    .error_kind = .type,
    .expectation = "an environment object or worker_threads.SHARE_ENV",
});
const worker_environment = b.unionType("WorkerEnvironmentInput", .{
    b.unionMember("shared", worker_shared_environment),
    b.unionMember("record", archetypes.dom_string_record),
}, .{ .ordered = true, .cpp_name = "WorkerEnvironmentInput" });
const worker_argument_symbol = b.brandedValueWithBrand(b.cppBrand("WorkerArgumentSymbol", .{
    .symbol = "Bun::Bindgen::TypePredicates::isSymbol",
    .header = "BindgenTypePredicates.h",
}, "symbol"), .{});
const worker_argument = b.unionType("WorkerArgumentInput", .{
    b.unionMember("symbol", worker_argument_symbol),
    b.unionMember("value", archetypes.coerced_dom_string),
}, .{ .ordered = true, .fallback_member = "value", .cpp_name = "WorkerArgumentInput" });
const worker_arguments = b.sequenceWithOptions(worker_argument, .{
    .node_error = .{
        .container = .{ .expected = "Array" },
        .element = .{ .expected = "string", .site = .element },
    },
});

fn workerArgumentsField(comptime name: []const u8) b.DictionaryField {
    return b.dictionaryField(name, b.optionalNullish(worker_arguments), .{
        .required = true,
        .missing_required = .convert_undefined,
        .profile = .node,
    });
}

fn workerOption(comptime name: []const u8, comptime value_type: b.Type) b.DictionaryField {
    return b.dictionaryField(name, value_type, .{ .profile = .webidl });
}

const worker_options_shape = b.dictionaryWithOptions("WorkerOptionsInput", .{
    b.dictionaryField("name", archetypes.strict_dom_string_or_ignored, .{
        .required = true,
        .missing_required = .convert_undefined,
        .profile = .webidl,
    }),
    workerOption("smol", b.boolean),
    workerOption("ref", b.boolean),
    workerOption("eval", b.boolean),
    workerOption("preload", b.optionalNullish(worker_preload)),
    b.dictionaryField("workerData", b.engine_value, .{ .missing = .absent, .aliases = &.{"data"}, .profile = .webidl }),
    workerOption("transferList", structured_clone.transferable_sequence),
    workerOption("env", worker_environment),
    workerArgumentsField("argv"),
    workerArgumentsField("execArgv"),
}, .{
    .cpp_name = "WorkerOptionsInput",
    .user_facing_name = "options",
    .node_allow_array = true,
    .node_allow_callable = true,
});
const worker_constructor_options = b.unionType("WorkerConstructorOptions", .{
    b.unionMember("options", worker_options_shape),
    b.unionMember("ignored", b.discardAny(.ignored)),
}, .{ .ordered = true, .fallback_member = "ignored" });
const worker_heap_snapshot_options = b.dictionary("WorkerHeapSnapshotOptions", .{
    b.dictionaryField("exposeInternals", b.boolean, .{}),
    b.dictionaryField("exposeNumericValues", b.boolean, .{}),
});
const worker_heap_snapshot_errors = b.domainErrors(.{
    b.domainError("worker_not_running", b.none, .{
        .class = .generic_error,
        .code = "ERR_WORKER_NOT_RUNNING",
        .message = .{ .literal = "Worker instance not running" },
    }),
});

const worker_class = webcore_bindings.wrapperClass(
    "Worker",
    b.constructor(.{
        b.argument("filename", worker_script_url_input, .{}),
        b.argument("options", worker_constructor_options, .{}),
        b.argument("nodeWorkerObject", b.js_object, .{ .presence = .optional, .missing = .omitted }),
    }, .{ .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined }),
    .{
        webcore_bindings.eventHandlerGetter("onerror"),
        webcore_bindings.eventHandlerSetter("onerror"),
        webcore_bindings.eventHandlerGetter("onmessage"),
        webcore_bindings.eventHandlerSetter("onmessage"),
        webcore_bindings.eventHandlerGetter("onmessageerror"),
        webcore_bindings.eventHandlerSetter("onmessageerror"),
        b.method("postMessage", .{
            b.argument("message", b.engine_value, .{}),
            b.argument("second", structured_clone.second, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("ref", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("unref", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("terminate", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("getHeapSnapshot", .{
            b.argument("options", worker_heap_snapshot_options, .{ .presence = .optional, .missing = .undefined }),
        }, b.thread_safe_dom_string, .{
            .backend = .zig,
            .completion = .{
                .retention = .strong,
                .sender_drop = .{ .reject = "Worker heap snapshot did not complete" },
            },
            .errors = worker_heap_snapshot_errors,
            .length = 0,
            .configurable = true,
            .profile = .node,
        }),
        b.getter("threadId", b.int32, .{ .invalid_this = .no_op }),
    },
    .{},
    "WebCore Worker event-target identity, lifecycle, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("Worker", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(events.event_target_class),
        .engine_native = .{ .cpp_type = "WebCore::Worker", .header = "WorkerOwner.h", .wrapper_tag = "WebCore::WorkerEventTargetInterfaceType" },
        .identity = .per_realm,
    },
);

pub const schema = b.moduleWithClasses("WebCoreWorker", .{}, .{worker_class});
pub const worker = schema.class("Worker");
