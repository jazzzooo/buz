const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const process_types = @import("binding_schema_NodeProcessTypes");

const deferred_warning_operand = "warning kind and overload selection determine whether code and message coercion are observable";
const deferred_assert_message = "process assertion messages are coerced only when the assertion fails";
const execve_argument = b.strictString(b.dom_string, .{
    .kind = .{ .code = "ERR_INVALID_ARG_VALUE" },
    .message = "The \"args\" argument must contain strings without null bytes",
});
const execve_environment_value = b.strictString(b.dom_string, .{
    .kind = .{ .code = "ERR_INVALID_ARG_VALUE" },
    .message = "The \"env\" argument must contain string values without null bytes",
});
const deferred_execve_operand = "execve validates platform and process state before coercing path, arguments, and environment";

const dlopen_module = b.brandedValueWithBrand(b.brandOf(b.js_object), .{
    .no_match_error = .{ .kind = .type_error, .message = "dlopen requires an object as first argument" },
});

const process_object_value = process_types.process_object;
const process_title_string_value = b.js_string;

fn processObjectOrIgnored(comptime operation: []const u8) b.Type {
    _ = operation;
    return b.optionalMatch(process_object_value);
}

fn processTitleString() b.Type {
    return b.optionalMatch(process_title_string_value);
}

fn lazySurfaceFunction(comptime name: []const u8, comptime return_type: b.Type) b.Function {
    return b.function(name, .{}, return_type, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = b.brandCast(process_object_value, .{ .name = "bindingThis", .failure = .assert }),
    });
}

fn propertyGetter(comptime name: []const u8, comptime result: b.Type, comptime receiver: b.Type) b.Function {
    return b.function(name, .{}, result, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = receiver,
    });
}

fn propertySetter(comptime name: []const u8, comptime value: b.Type, comptime receiver: b.Type) b.Function {
    return b.function(name, .{b.argument("value", value, .{})}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .exact,
        .this_value_type = receiver,
    });
}

const cpu_usage_previous = b.dictionaryWithOptions("NodeCPUUsagePrevious", .{
    archetypes.nodeNumberField("user", .{
        .min = 0,
        .max = 9_007_199_254_740_991,
        .error_kind = .invalid_value,
    }, .{ .required = true, .missing_required = .convert_undefined }),
    archetypes.nodeNumberField("system", .{
        .min = 0,
        .max = 9_007_199_254_740_991,
        .error_kind = .invalid_value,
    }, .{ .required = true, .missing_required = .convert_undefined }),
}, .{
    .user_facing_name = "prevValue",
    .node_allow_array = true,
    .node_allow_callable = true,
});

const cpu_usage_result = b.dictionaryWithOptions("NodeCPUUsageResult", .{
    b.dictionaryField("user", b.double, .{ .required = true }),
    b.dictionaryField("system", b.double, .{ .required = true }),
}, .{ .cpp_name = "NodeCPUUsage" });

const memory_usage_result = b.dictionaryWithOptions("NodeMemoryUsageResult", .{
    b.dictionaryField("rss", b.double, .{ .required = true }),
    b.dictionaryField("heapTotal", b.double, .{ .required = true }),
    b.dictionaryField("heapUsed", b.double, .{ .required = true }),
    b.dictionaryField("external", b.double, .{ .required = true }),
    b.dictionaryField("arrayBuffers", b.double, .{ .required = true }),
}, .{ .cpp_name = "NodeMemoryUsage" });

const resource_usage_result = b.dictionaryWithOptions("NodeResourceUsageResult", .{
    b.dictionaryField("userCPUTime", b.double, .{ .required = true }),
    b.dictionaryField("systemCPUTime", b.double, .{ .required = true }),
    b.dictionaryField("maxRSS", b.double, .{ .required = true }),
    b.dictionaryField("sharedMemorySize", b.double, .{ .required = true }),
    b.dictionaryField("unsharedDataSize", b.double, .{ .required = true }),
    b.dictionaryField("unsharedStackSize", b.double, .{ .required = true }),
    b.dictionaryField("minorPageFault", b.double, .{ .required = true }),
    b.dictionaryField("majorPageFault", b.double, .{ .required = true }),
    b.dictionaryField("swappedOut", b.double, .{ .required = true }),
    b.dictionaryField("fsRead", b.double, .{ .required = true }),
    b.dictionaryField("fsWrite", b.double, .{ .required = true }),
    b.dictionaryField("ipcSent", b.double, .{ .required = true }),
    b.dictionaryField("ipcReceived", b.double, .{ .required = true }),
    b.dictionaryField("signalsCount", b.double, .{ .required = true }),
    b.dictionaryField("voluntaryContextSwitches", b.double, .{ .required = true }),
    b.dictionaryField("involuntaryContextSwitches", b.double, .{ .required = true }),
}, .{ .cpp_name = "NodeResourceUsage" });

const process_warning_input = b.unionType("ProcessWarningInput", .{
    b.unionMember("message", b.dom_string),
    b.unionMember("error", b.js_error_instance),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string or Error" },
});

const process_warning_callable = b.callback(
    "ProcessWarningCallable",
    .{b.rest("arguments", b.invocation_any)},
    b.any,
    .{ .receiver = null, .profile = .node },
);

const process_warning_code_input = b.unionType("ProcessWarningCodeInput", .{
    b.unionMember("callable", b.discard(process_warning_callable)),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("string", b.dom_string),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string" },
});

const process_warning_detail_input = b.unionType("ProcessWarningDetailInput", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });

const process_warning_options = b.dictionaryWithOptions("ProcessWarningOptions", .{
    b.dictionaryField("constructor", b.discardAny(.ignored), .{
        .required = true,
        .missing_required = .convert_undefined,
        .js_name = "ctor",
    }),
    b.dictionaryField("code", b.lazy(process_warning_code_input), .{
        .required = true,
        .missing_required = .convert_undefined,
        .deferred_reason = "code is read before detail and type, but its validation follows type validation",
        .lazy_property_read = .eager,
    }),
    b.dictionaryField("detail", process_warning_detail_input, .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
    b.dictionaryField("type", b.optionalFalsy(b.dom_string), .{
        .required = true,
        .missing_required = .convert_undefined,
    }),
}, .{ .cpp_name = "ProcessWarningOptions" });

const process_warning_type_input = b.unionType("ProcessWarningTypeInput", .{
    b.unionMember("callable", b.discard(process_warning_callable)),
    b.unionMember("options", process_warning_options),
    b.unionMember("name", b.dom_string),
    b.unionMember("undefined", b.undefined_literal),
}, .{
    .ordered = true,
    .node_error = .{ .expected_type = "string, function, or object" },
});
const process_assertion_message_input = b.optionalFalsy(archetypes.coerced_dom_string);

const process_send_callback = b.callback(
    "ProcessSendCallback",
    .{b.rest("arguments", b.invocation_any)},
    b.boolean,
    .{ .receiver = null, .profile = .exact },
);
const process_disconnect_callback = b.callback(
    "ProcessDisconnectCallback",
    .{},
    b.none,
    .{ .receiver = null, .profile = .exact },
);
const process_next_tick_work = b.callback(
    "ProcessNextTickWork",
    .{b.rest("arguments", b.invocation_any)},
    b.none,
    .{ .receiver = null, .profile = .exact },
);
const process_next_tick_callback = b.callback(
    "ProcessNextTickCallback",
    .{
        b.argument("callback", process_next_tick_work, .{}),
        b.rest("arguments", b.invocation_any),
    },
    b.none,
    .{ .receiver = null, .profile = .exact },
);

const functions = .{
    b.function("getCanonicalProcess", .{}, process_object_value, .{ .backend = .cpp, .profile = .exact, .length = 0 }),
    lazySurfaceFunction("constructArch", b.dom_string),
    lazySurfaceFunction("constructArgv0", b.dom_string),
    lazySurfaceFunction("constructProcessChannel", b.optionalUndefined(b.js_object)),
    lazySurfaceFunction("constructProcessDisconnect", b.optionalUndefined(process_disconnect_callback)),
    lazySurfaceFunction("constructEnv", b.js_object),
    lazySurfaceFunction("constructExecPath", b.dom_string),
    lazySurfaceFunction("constructMainModuleProperty", b.engine_value),
    lazySurfaceFunction("constructProcessNextTickFn", process_next_tick_callback),
    lazySurfaceFunction("constructPid", b.int32),
    lazySurfaceFunction("constructPlatform", b.dom_string),
    lazySurfaceFunction("constructRevision", b.dom_string),
    lazySurfaceFunction("constructProcessSend", b.optionalUndefined(process_send_callback)),
    lazySurfaceFunction("constructStderr", b.optionalUndefined(b.js_object)),
    lazySurfaceFunction("constructStdin", b.optionalUndefined(b.js_object)),
    lazySurfaceFunction("constructStdout", b.optionalUndefined(b.js_object)),
    lazySurfaceFunction("constructVersion", b.dom_string),
    propertyGetter("processGetEval", archetypes.optional_dom_string, process_types.processObjectReceiver("_eval")),
    propertySetter("setProcessGetEval", b.discardAny(.ignored), process_types.processObjectReceiver("_eval")),
    propertyGetter("processConnected", archetypes.optional_boolean, processObjectOrIgnored("connected")),
    b.function("setProcessConnected", .{b.argument("value", b.discardAny(.ignored), .{})}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("processDebugPort", .{}, b.double, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("setProcessDebugPort", .{b.argument("value", b.double, .{ .number_conversion = .coerce })}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    propertyGetter("processExitCode", b.optionalUndefined(b.uint8), processObjectOrIgnored("exitCode")),
    b.function("setProcessExitCode", .{b.argument("code", b.lazy(archetypes.node_exit_code), .{
        .deferred_reason = "exit code validation follows the process receiver check",
    })}, b.boolean, .{
        .backend = .cpp,
        .length = 0,
        .profile = .node,
        .this_value_type = processObjectOrIgnored("exitCode"),
    }),
    b.function("processNoDeprecation", .{}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("setProcessNoDeprecation", .{b.argument("value", b.boolean, .{})}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("processPpid", .{}, b.int32, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("setProcessPpid", .{b.argument("value", b.retained_any, .{})}, b.boolean, .{
        .backend = .builtin,
        .builtin = "processObjectInternalsSetPpidCodeGenerator",
        .length = 1,
        .profile = .exact,
    }),
    b.function("processThrowDeprecation", .{}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("setProcessThrowDeprecation", .{b.argument("value", b.boolean, .{})}, b.boolean, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("processTitle", .{}, b.dom_string, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    propertySetter("setProcessTitle", processTitleString(), b.optionalMatch(b.js_object)),
    b.function("abort", .{}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("assert", .{
        archetypes.truthyBoolean("condition", .{
            .presence = .default_value,
            .missing = .undefined,
            .default_value = .{ .boolean = false },
        }),
        b.argument("message", b.lazy(process_assertion_message_input), .{ .presence = .optional, .missing = .undefined, .deferred_reason = deferred_assert_message }),
    }, b.none, .{
        .backend = .cpp,
        .length = 1,
        .profile = .exact,
    }),
    b.function("availableMemory", .{}, b.uint64, .{ .backend = .zig, .profile = .exact }),
    b.function("binding", .{b.argument("moduleName", archetypes.coerced_dom_string, .{})}, b.js_object, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("chdir", .{b.argument("directory", b.dom_string, .{})}, b.none, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("constrainedMemory", .{}, b.uint64, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "cpuUsage",
        .{b.argument("prevValue", b.optionalFalsy(cpu_usage_previous), .{})},
        cpu_usage_result,
        .{
            .backend = .cpp,
            .length = 1,
            .profile = .node,
            .this_value_type = process_types.processObjectReceiver("cpuUsage"),
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function("cwd", .{}, b.dom_string, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("disconnect", .{}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("dlopen", .{
        b.argument("module", b.lazy(dlopen_module), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "Addon policy and argument presence are checked before inspecting the module",
        }),
        b.argument("filename", b.lazy(archetypes.coerced_dom_string), .{
            .presence = .optional,
            .missing = .omitted,
            .deferred_reason = "Addon policy, argument presence, and module exports are validated before filename coercion",
        }),
    }, b.engine_value, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("empty", .{}, b.none, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "fatalException",
        .{b.argument("exception", b.discardAny(.ignored), .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function("emptyArray", .{}, b.js_array, .{
        .backend = .builtin,
        .builtin = "processObjectInternalsEmptyArrayCodeGenerator",
        .length = 0,
        .profile = .exact,
    }),
    b.function("emptyStringArray", .{}, archetypes.dom_strings, .{
        .backend = .builtin,
        .builtin = "processObjectInternalsEmptyArrayCodeGenerator",
        .length = 0,
        .profile = .exact,
    }),
    b.function("emitHelper", .{
        b.argument("process", process_object_value, .{}),
        b.argument("eventName", b.dom_string, .{}),
        b.argument("event", b.invocation_any, .{}),
    }, b.any, .{
        .backend = .builtin,
        .builtin = "processObjectInternalsEmitHelperCodeGenerator",
        .length = 3,
        .profile = .exact,
    }),
    b.function("emitWarning", .{
        b.argument("warning", b.lazy(process_warning_input), .{ .deferred_reason = deferred_warning_operand }),
        b.argument("type", process_warning_type_input, .{}),
        b.argument("code", b.lazy(process_warning_code_input), .{ .deferred_reason = deferred_warning_operand }),
        b.argument("constructor", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
    }, b.none, .{
        .backend = .cpp,
        .length = 1,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
    }),
    b.function("emitWarningEvent", .{b.argument("value", b.js_error_instance, .{})}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function(
        "execve",
        .{
            b.argument("execPath", b.lazy(b.dom_string), .{ .deferred_reason = deferred_execve_operand }),
            b.argument("args", b.lazy(b.sequence(execve_argument)), .{ .deferred_reason = deferred_execve_operand }),
            b.argument("env", b.lazy(b.optionalUndefined(b.record(b.dom_string, execve_environment_value))), .{ .deferred_reason = deferred_execve_operand }),
        },
        b.none,
        .{
            .backend = .cpp,
            .length = 3,
            .profile = .node,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "exit",
        .{b.argument("code", archetypes.node_exit_code, .{})},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .node, .missing_required_arguments = .convert_undefined },
    ),
    b.function("getegid", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("geteuid", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("getgid", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("getgroups", .{}, b.sequence(b.uint32), .{ .backend = .cpp, .profile = .exact }),
    b.function("getReport", .{}, b.js_object, .{ .backend = .cpp, .profile = .exact }),
    b.function("processReportOnUncaughtException", .{}, b.boolean, .{ .backend = .cpp, .profile = .exact }),
    b.function("processVersionsBun", .{}, b.dom_string, .{ .backend = .cpp, .profile = .exact }),
    b.function("processVersionsUV", .{}, b.dom_string, .{ .backend = .cpp, .profile = .exact }),
    b.function("getuid", .{}, b.uint32, .{ .backend = .cpp, .profile = .exact }),
    b.function("hasUncaughtExceptionCaptureCallback", .{}, b.boolean, .{ .backend = .cpp, .profile = .exact }),
    b.function("hrtime", .{b.argument("time", b.js_array, .{ .presence = .optional })}, archetypes.doubles, .{ .backend = .cpp, .profile = .exact, .length = 1 }),
    b.function("hrtimeBigInt", .{}, b.integerRepresentation(b.uint64, .bigint), .{ .backend = .cpp, .profile = .exact }),
    b.function("kill", .{
        b.argument("pid", b.invocation_any, .{}),
        b.argument("signal", b.invocation_any, .{ .presence = .optional, .missing = .omitted }),
    }, b.boolean, .{
        .backend = .builtin,
        .builtin = "processObjectInternalsKillCodeGenerator",
        .length = 2,
        .profile = .exact,
        .missing_required_arguments = .convert_undefined,
    }),
    b.function("processObject", .{}, process_object_value, .{ .backend = .cpp, .length = 0, .profile = .exact }),
    b.function("processSignalNumber", .{
        b.argument("signal", archetypes.coerced_property_key, .{}),
    }, b.optionalUndefined(b.uint8), .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("processKillResult", .{
        b.argument("errorNumber", b.int32, .{}),
    }, b.boolean, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("loadBuiltinModule", .{b.argument("moduleName", b.dom_string, .{})}, b.engine_value, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("memoryUsage", .{}, memory_usage_result, .{ .backend = .cpp, .profile = .exact, .this_value_type = process_types.processObjectReceiver("memoryUsage") }),
    b.function("memoryUsageRSS", .{}, b.uint64, .{ .backend = .cpp, .profile = .exact }),
    b.function("openStdin", .{}, b.optionalUndefined(b.js_object), .{ .backend = .cpp, .profile = .exact }),
    b.function("reallyExit", .{archetypes.coercedInteger("code", b.uint8, .{
        .presence = .default_value,
        .missing = .undefined,
        .default_value = .{ .unsigned = 0 },
    })}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("reallyKill", .{
        archetypes.coercedInteger("pid", b.int32, .{}),
        archetypes.coercedInteger("signal", b.int32, .{}),
    }, b.int32, .{ .backend = .cpp, .length = 2, .profile = .exact }),
    b.function("ref", .{b.argument("value", archetypes.object_or_ignored, .{ .presence = .optional, .missing = .omitted })}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("resourceUsage", .{}, resource_usage_result, .{ .backend = .cpp, .profile = .exact, .this_value_type = process_types.processObjectReceiver("resourceUsage") }),
    b.function(
        "setSourceMapsEnabled",
        .{b.argument("enabled", b.boolean, .{})},
        b.none,
        .{ .backend = .cpp, .profile = .node },
    ),
    b.function(
        "reportUncaughtException",
        .{b.argument("value", b.engine_value, .{})},
        b.none,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function("setegid", .{b.argument("id", archetypes.node_credential_id, .{})}, b.int32, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("seteuid", .{b.argument("id", archetypes.node_credential_id, .{})}, b.int32, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("setgid", .{b.argument("id", archetypes.node_credential_id, .{})}, b.int32, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("setgroups", .{
        b.argument("groups", b.sequenceWithOptions(archetypes.node_credential_id, .{ .container = .concrete_array }), .{}),
    }, b.int32, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("setuid", .{b.argument("id", archetypes.node_credential_id, .{})}, b.int32, .{ .backend = .cpp, .length = 1, .profile = .node }),
    b.function("setUncaughtExceptionCaptureCallback", .{b.argument("fn", archetypes.node_nullable_callable_value, .{})}, b.none, .{
        .backend = .cpp,
        .length = 1,
        .profile = .node,
        .missing_required_arguments = .convert_undefined,
    }),
    b.function("throwValue", .{b.argument("value", b.engine_value, .{})}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("drainMicrotaskQueue", .{}, b.none, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "umask",
        .{archetypes.fileMode("mask", .{ .presence = .optional, .missing = .undefined })},
        b.uint32,
        .{ .backend = .cpp, .length = 1, .profile = .node },
    ),
    b.function("unref", .{b.argument("value", archetypes.object_or_ignored, .{ .presence = .optional, .missing = .omitted })}, b.none, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("uptime", .{}, b.double, .{ .backend = .cpp, .length = 1, .profile = .exact }),
    b.function("writeReport", .{b.argument("filename", b.any, .{ .presence = .optional, .missing = .omitted })}, b.optionalUndefined(b.any), .{ .backend = .cpp, .length = 1, .profile = .exact }),
};

const engine_shims = .{
    b.engineShim("processEmitSignal", .{b.argument("signal", b.int32, .{})}, b.none, .current_realm_throwing),
    b.engineShim("emitUnhandledRejectionWarning", .{b.argument("reason", b.engine_value, .{})}, b.none, .current_realm_throwing),
    b.engineShim(
        "processHandleUncaughtException",
        .{
            b.argument("exception", b.engine_value, .{}),
            b.argument("isRejection", b.boolean, .{}),
        },
        b.boolean,
        .current_realm_throwing,
    ),
    b.engineShim(
        "processHandleUnhandledRejection",
        .{
            b.argument("reason", b.engine_value, .{}),
            b.argument("promise", b.optionalUndefined(b.js_promise), .{}),
        },
        b.boolean,
        .current_realm_throwing,
    ),
    b.engineShim("processEmitHandledPromiseEvent", .{b.argument("promise", b.js_promise, .{})}, b.boolean, .current_realm_throwing),
    b.engineShim(
        "processEmitMessageEvent",
        .{
            b.argument("value", b.engine_value, .{}),
        },
        b.none,
        .current_realm_throwing,
    ),
    b.engineShim("processEmitDisconnectEvent", .{}, b.none, .current_realm_throwing),
    b.engineShim("processDispatchOnBeforeExit", .{b.argument("exitCode", b.uint8, .{})}, b.none, .current_realm_throwing),
    b.engineShim("processDispatchOnExit", .{b.argument("exitCode", b.uint8, .{})}, b.none, .current_realm_throwing),
};

const native_exports = .{
    b.nativeExport("runProcessExitHooks", .{}, b.none),
};

pub const schema = b.moduleWithDeclarations("ProcessHost", functions, .{}, engine_shims, native_exports);
