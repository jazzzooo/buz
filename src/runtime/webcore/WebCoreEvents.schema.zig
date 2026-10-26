const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const webcore_bindings = @import("binding_schema_WebCoreBindings");
const structured_clone = @import("binding_schema_StructuredClone");

const event_listener_options_dictionary = b.dictionaryWithOptions("EventListenerOptions", .{
    b.dictionaryField("capture", b.boolean, .{}),
}, .{ .user_facing_name = "EventListenerOptions", .cpp_name = "RemoveEventListenerOptionsFields" });

const add_event_listener_options_dictionary = b.dictionaryWithOptions("AddEventListenerOptions", .{
    b.dictionaryField("capture", b.boolean, .{}),
    b.dictionaryField("once", b.boolean, .{}),
    b.dictionaryField("passive", b.boolean, .{}),
    b.dictionaryField("signal", b.optionalUndefined(b.classRefByName("WebCoreEvents", "AbortSignal")), .{}),
}, .{ .user_facing_name = "AddEventListenerOptions", .cpp_name = "AddEventListenerOptionsFields" });

pub const add_event_listener_options = b.unionType("AddEventListenerOptionsOrBoolean", .{
    b.unionMember("options", add_event_listener_options_dictionary),
    b.unionMember("capture", b.boolean),
}, .{ .cpp_name = "AddEventListenerOptionsInput" });

pub const remove_event_listener_options = b.unionType("EventListenerOptionsOrBoolean", .{
    b.unionMember("options", event_listener_options_dictionary),
    b.unionMember("capture", b.boolean),
}, .{ .cpp_name = "RemoveEventListenerOptionsInput" });

pub const event_value = b.classRefByName("WebCoreEvents", "Event");
const dispatch_event_value = b.classRefByNameWithOptions("WebCoreEvents", "Event", .{ .no_match_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "Argument 1 ('event') to EventTarget.dispatchEvent must be an instance of Event",
} });

const add_event_listener_value = archetypes.eventListenerValue("AddEventListenerValue", .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "Argument 2 ('listener') to EventTarget.addEventListener must be an object",
});
const remove_event_listener_value = archetypes.eventListenerValue("RemoveEventListenerValue", .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "Argument 2 ('listener') to EventTarget.removeEventListener must be an object",
});

const event_missing_arguments: b.MissingRequiredArguments = .{ .failure = .{
    .kind = .{ .code = "ERR_MISSING_ARGS" },
    .message = "Not enough arguments",
} };

const event_target_wrapper_parent = b.engineParent(.{
    .cpp_class = .{ .specialization = .{ .name = "WebCore::JSDOMWrapper", .arguments = &.{.{ .named = "WebCore::EventTarget" }} } },
    .cpp_impl = "WebCore::EventTarget",
    .header = "JSDOMWrapper.h",
    .prototype = .object,
    .constructor = .function,
});

pub const event_target_class = webcore_bindings.wrapperClass(
    "EventTarget",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.method("addEventListener", .{
            b.argument("type", b.dom_string, .{}),
            b.argument("listener", add_event_listener_value, .{}),
            b.argument("options", add_event_listener_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.none, .{ .length = 2, .configurable = true, .missing_required_arguments = event_missing_arguments }),
        b.method("removeEventListener", .{
            b.argument("type", b.dom_string, .{}),
            b.argument("listener", remove_event_listener_value, .{}),
            b.argument("options", remove_event_listener_options, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.none, .{ .length = 2, .configurable = true, .missing_required_arguments = event_missing_arguments }),
        b.method("dispatchEvent", .{
            b.argument("event", dispatch_event_value, .{}),
        }, b.boolean, .{ .length = 1, .configurable = true, .missing_required_arguments = event_missing_arguments }),
    },
    .{},
    "WebCore EventTarget listener graph, wrapper-cache identity, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("EventTarget", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = event_target_wrapper_parent,
        .engine_native = .{
            .cpp_type = "WebCore::EventTarget",
            .header = "EventTargetOwner.h",
            .wrapper_discriminator = "eventTargetInterface",
            .wrapper_tag = "WebCore::EventTargetInterfaceType",
            .wrapper_global_scope = .{
                .tag = "WebCore::DOMWindowEventTargetInterfaceType",
                .cpp_type = "WebCore::WorkerGlobalScope",
            },
        },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
        .immutable_prototype = true,
        .final = false,
    },
);

/// Parent for engine classes whose impl is a plain ref-counted WebCore type
/// (not an EventTarget): the wrapper chain is just `JSDOMWrapper<Impl>`.
const event_emitter_self_value = b.classRefByName("WebCoreEvents", "EventEmitter");
const event_emitter_event_names_value = b.sequence(archetypes.property_key);
const event_emitter_listeners_value = b.sequence(archetypes.callable_value);
const event_emitter_listener_arguments = .{
    b.argument("event", b.any, .{}),
    b.argument("listener", archetypes.event_listener_value, .{}),
    b.argumentProjection("key", "event", archetypes.coerced_property_key, "Listener validation precedes event-key coercion; newListener receives the original event argument"),
};
const event_emitter_class = webcore_bindings.wrapperClassWithDataProperties(
    "EventEmitter",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.method("addListener", event_emitter_listener_arguments, event_emitter_self_value, .{
            .length = 2,
            .configurable = true,
            .aliases = &.{b.memberAlias("on", .{ .enumerable = false })},
        }),
        b.method("once", event_emitter_listener_arguments, event_emitter_self_value, .{ .length = 2, .configurable = true }),
        b.method("prependListener", event_emitter_listener_arguments, event_emitter_self_value, .{ .length = 2, .configurable = true }),
        b.method("prependOnceListener", event_emitter_listener_arguments, event_emitter_self_value, .{ .length = 2, .configurable = true }),
        b.method("removeListener", .{
            b.argument("event", b.lazy(archetypes.coerced_property_key), .{ .deferred_reason = "Listener validation precedes event-key coercion" }),
            b.argument("listener", archetypes.event_listener_value, .{
                .presence = .optional,
                .missing = .omitted,
            }),
        }, event_emitter_self_value, .{
            .length = 2,
            .configurable = true,
            .aliases = &.{b.memberAlias("off", .{ .enumerable = false })},
        }),
        b.method("removeAllListeners", .{
            b.argument("event", archetypes.coerced_property_key, .{ .presence = .optional, .missing = .omitted }),
        }, event_emitter_self_value, .{ .length = 1, .configurable = true }),
        b.method("emit", .{
            b.argument("event", archetypes.coerced_property_key, .{}),
            b.rest("values", b.any),
        }, b.boolean, .{ .length = 1, .configurable = true }),
        b.method("eventNames", .{}, event_emitter_event_names_value, .{ .length = 0, .configurable = true }),
        b.method("listenerCount", .{
            b.argument("event", archetypes.coerced_property_key, .{}),
        }, b.int32, .{ .length = 1, .configurable = true }),
        b.method("listeners", .{
            b.argument("event", archetypes.coerced_property_key, .{}),
        }, event_emitter_listeners_value, .{
            .length = 1,
            .configurable = true,
            .aliases = &.{b.memberAlias("rawListeners", .{ .enumerable = false })},
        }),
        b.method("setMaxListeners", .{
            b.argument("maxListeners", b.uint32, .{
                .presence = .optional,
                .missing = .omitted,
                .integer_conversion = .webidl,
            }),
        }, b.none, .{ .length = 1, .profile = .exact, .configurable = true }),
        b.method("getMaxListeners", .{}, b.uint32, .{ .length = 0, .configurable = true }),
    },
    .{},
    .{b.dataProperty("defaultMaxListeners", .{ .unsigned = 10 }, .{
        .storage = .constructor,
        .writable = true,
        .enumerable = true,
        .configurable = true,
    })},
    "WebCore EventEmitter listener graph, wrapper-cache identity, and GC tracing",
    .{
        .profile = .webidl,
        .parent = webcore_bindings.wrapperParent("WebCore::EventEmitter"),
        .engine_native = .{ .cpp_type = "WebCore::EventEmitter", .header = "EventEmitterOwner.h" },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
        .immutable_prototype = true,
        .constructor_call = b.constructorCall(.{}, event_emitter_self_value, .{
            .backend = .cpp,
            .length = 0,
        }),
        .final = false,
    },
);

const broadcast_channel_class = webcore_bindings.wrapperClass(
    "BroadcastChannel",
    b.constructor(.{b.argument("name", b.dom_string, .{})}, .{ .length = 1 }),
    .{
        b.getter("name", b.dom_string, .{ .configurable = true }),
        webcore_bindings.eventHandlerGetter("onmessage"),
        webcore_bindings.eventHandlerSetter("onmessage"),
        webcore_bindings.eventHandlerGetter("onmessageerror"),
        webcore_bindings.eventHandlerSetter("onmessageerror"),
        b.method("postMessage", .{b.argument("message", b.engine_value, .{})}, b.none, .{
            .length = 1,
            .configurable = true,
        }),
        b.method("close", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("ref", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("unref", .{}, b.classRefByName("WebCoreEvents", "BroadcastChannel"), .{ .length = 0, .configurable = true }),
        b.method("inspectCustom", .{
            b.argument("depth", b.optionalNullish(b.double), .{}),
            b.argument("options", b.js_object, .{}),
        }, b.dom_string, .{ .symbol = .inspect_custom, .length = 2, .display_name = "inspect" }),
    },
    .{},
    "WebCore BroadcastChannel event-target identity, liveness, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("BroadcastChannel", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(event_target_class),
        .engine_native = .{ .cpp_type = "WebCore::BroadcastChannel", .header = "BroadcastChannelOwner.h", .wrapper_tag = "WebCore::BroadcastChannelEventTargetInterfaceType" },
        .identity = .per_realm,
    },
);

const abort_signal_brand = b.cppBrand("AbortSignal", .{
    .symbol = "Bun::Bindgen::TypePredicates::isAbortSignal",
    .header = "BindgenTypePredicates.h",
}, "AbortSignal");
pub const abort_signal_js_value = b.brandedValueWithBrand(abort_signal_brand, .{});

const abort_signal_sequence = b.sequenceWithOptions(b.classRefByName("WebCoreEvents", "AbortSignal"), .{
    .container = .iterable,
    .node_error = .{ .element = .{ .kind = .instance, .expected = "AbortSignal", .site = .element } },
});
const abort_signal_any_errors = b.domainErrors(.{b.domainError("missing_signals", b.none, .{
    .class = .type_error,
    .code = "ERR_INVALID_ARG_TYPE",
    .message = .{ .literal = "signals can not be converted to sequence" },
})});
const abort_signal_value = b.classRefByName("WebCoreEvents", "AbortSignal");

const abort_signal_class = webcore_bindings.wrapperClass(
    "AbortSignal",
    b.illegalConstructor(),
    .{
        b.getter("aborted", b.boolean, .{ .configurable = true }),
        b.getter("reason", b.engine_value, .{ .configurable = true }),
        webcore_bindings.eventHandlerGetter("onabort"),
        webcore_bindings.eventHandlerSetter("onabort"),
        b.method("throwIfAborted", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.staticMethod("abort", .{
            b.argument("reason", b.engine_value, .{ .presence = .optional, .missing = .undefined }),
        }, abort_signal_value, .{ .length = 0, .configurable = true }),
        b.staticMethod("timeout", .{
            b.argument("milliseconds", b.uint64, .{
                .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = (1 << 53) - 1 } },
            }),
        }, abort_signal_value, .{ .length = 1, .configurable = true }),
        b.staticMethod("any", .{
            b.argument("signals", b.optionalNullish(abort_signal_sequence), .{}),
        }, abort_signal_value, .{ .length = 1, .configurable = true, .profile = .node, .errors = abort_signal_any_errors }),
    },
    .{},
    "WebCore AbortSignal event-target identity, dependent signals, and GC tracing",
    .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("AbortSignal", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .brand = abort_signal_brand,
        .parent = b.parentClass(event_target_class),
        .engine_native = .{ .cpp_type = "WebCore::AbortSignal", .header = "AbortSignalOwner.h", .wrapper_tag = "WebCore::AbortSignalEventTargetInterfaceType" },
        .identity = .per_realm,
        .memory_usage = .vm,
        .engine_tracing = .additional_children,
    },
);

const abort_controller_class = webcore_bindings.wrapperClass(
    "AbortController",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.getter("signal", abort_signal_value, .{ .configurable = true }),
        b.method("abort", .{
            b.argument("reason", b.engine_value, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .length = 0, .configurable = true }),
    },
    .{},
    "WebCore AbortController signal ownership, wrapper identity, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("AbortController", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = webcore_bindings.wrapperParent("WebCore::AbortController"),
        .engine_native = .{ .cpp_type = "WebCore::AbortController", .header = "AbortControllerOwner.h" },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
    },
);

const event_wrapper_parent = b.engineParent(.{
    .cpp_class = .{ .specialization = .{ .name = "WebCore::JSDOMWrapper", .arguments = &.{.{ .named = "WebCore::Event" }} } },
    .cpp_impl = "WebCore::Event",
    .header = "JSDOMWrapper.h",
    .prototype = .object,
    .constructor = .function,
    .cell_kind = .event,
});

/// EventInit members shared by every event-init dictionary. Fields read in
/// WebIDL order: inherited members first, each level alphabetical.
const event_init_fields = .{
    b.dictionaryField("bubbles", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("cancelable", b.boolean, .{ .default_value = .{ .boolean = false } }),
    b.dictionaryField("composed", b.boolean, .{ .default_value = .{ .boolean = false } }),
};

const event_init = b.dictionaryWithOptions("EventInit", event_init_fields, .{ .user_facing_name = "options", .object_error_profile = .node });
const event_target_object = b.brandedValueWithBrand(b.cppDynamicCastBrand("EventTargetObject", .{
    .type_name = "WebCore::JSEventTarget",
    .header = "JSEventTarget.h",
}, "EventTarget"), .{});
const event_target_value = b.optional(event_target_object);
const event_composed_path_value = b.sequence(event_target_object);
const event_timestamp_value = b.optionalUndefined(b.double);

const event_phase_codes = .{
    .{ "NONE", 0 },
    .{ "CAPTURING_PHASE", 1 },
    .{ "AT_TARGET", 2 },
    .{ "BUBBLING_PHASE", 3 },
};

fn eventPhaseConstants(comptime storage: b.DataPropertyStorage) [event_phase_codes.len]b.DataProperty {
    var result: [event_phase_codes.len]b.DataProperty = undefined;
    for (event_phase_codes, 0..) |entry, index| {
        result[index] = archetypes.integerDataProperty(entry[0], entry[1], storage);
    }
    return result;
}

const event_class = webcore_bindings.wrapperClassWithDataProperties(
    "Event",
    b.constructor(.{
        b.argument("type", b.dom_string, .{}),
        b.argument("eventInitDict", event_init, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{ .length = 1, .missing_required_arguments = event_missing_arguments }),
    .{
        b.getter("type", b.dom_string, .{ .configurable = true }),
        b.getter("target", event_target_value, .{ .configurable = true }),
        b.getter("currentTarget", event_target_value, .{ .configurable = true }),
        b.getter("eventPhase", b.uint16, .{ .configurable = true }),
        b.getter("cancelBubble", b.boolean, .{ .configurable = true }),
        b.setter("cancelBubble", b.boolean, .{ .configurable = true }),
        b.getter("bubbles", b.boolean, .{ .configurable = true }),
        b.getter("cancelable", b.boolean, .{ .configurable = true }),
        b.getter("defaultPrevented", b.boolean, .{ .configurable = true }),
        b.getter("composed", b.boolean, .{ .configurable = true }),
        b.getter("isTrusted", b.boolean, .{ .unforgeable = true }),
        b.getter("timeStamp", event_timestamp_value, .{ .configurable = true }),
        b.getter("srcElement", event_target_value, .{ .configurable = true }),
        b.getter("returnValue", b.boolean, .{ .configurable = true }),
        b.setter("returnValue", b.boolean, .{ .configurable = true }),
        b.method("composedPath", .{}, event_composed_path_value, .{ .length = 0, .configurable = true }),
        b.method("stopPropagation", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("stopImmediatePropagation", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("preventDefault", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("initEvent", .{
            b.argument("type", b.dom_string, .{}),
            b.argument("bubbles", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
            b.argument("cancelable", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
        }, b.none, .{ .length = 1, .configurable = true }),
    },
    .{},
    eventPhaseConstants(.prototype) ++ eventPhaseConstants(.constructor),
    "WebCore Event dispatch state, wrapper-cache identity, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("Event", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = event_wrapper_parent,
        .engine_native = .{
            .cpp_type = "WebCore::Event",
            .header = "EventOwner.h",
            .wrapper_discriminator = "eventInterface",
            .wrapper_tag = "WebCore::EventInterfaceType",
        },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
        .final = false,
    },
);

const close_event_init = b.dictionary("CloseEventInit", event_init_fields ++ .{
    b.dictionaryField("code", b.uint16, .{ .default_value = .{ .unsigned = 0 } }),
    b.dictionaryField("reason", b.usv_string, .{ .default_value = .{ .string = "" } }),
    b.dictionaryField("was_clean", b.boolean, .{ .default_value = .{ .boolean = false }, .js_name = "wasClean" }),
});

const close_event_class = webcore_bindings.wrapperClass(
    "CloseEvent",
    b.constructor(.{
        b.argument("type", b.dom_string, .{}),
        b.argument("eventInitDict", close_event_init, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{ .length = 1 }),
    .{
        b.getter("wasClean", b.boolean, .{ .configurable = true }),
        b.getter("code", b.uint16, .{ .configurable = true }),
        b.getter("reason", b.usv_string, .{ .configurable = true }),
    },
    .{},
    "WebCore CloseEvent dispatch state, wrapper-cache identity, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("CloseEvent", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(event_class),
        .engine_native = .{ .cpp_type = "WebCore::CloseEvent", .header = "CloseEvent.h", .wrapper_tag = "WebCore::CloseEventInterfaceType" },
        .identity = .per_realm,
    },
);

const custom_event_init = b.dictionaryWithOptions("CustomEventInit", event_init_fields ++ .{
    b.dictionaryField("detail", b.retained_any, .{ .default_value = .null }),
}, .{ .object_error = .{
    .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
    .message = "The \"options\" argument must be of type object.",
} });

const custom_event_class = webcore_bindings.wrapperClass(
    "CustomEvent",
    b.constructor(.{
        b.argument("type", b.dom_string, .{}),
        b.argument("eventInitDict", custom_event_init, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{ .length = 1, .missing_required_arguments = event_missing_arguments }),
    .{
        b.getter("detail", b.optional(b.any), .{ .configurable = true }),
        b.method("initCustomEvent", .{
            b.argument("type", b.dom_string, .{}),
            b.argument("bubbles", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
            b.argument("cancelable", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
            b.argument("detail", b.retained_any, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .null,
            }),
        }, b.none, .{ .length = 1, .configurable = true }),
    },
    .{},
    "Event dispatch identity with a traced arbitrary detail value",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("CustomEvent", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(event_class),
        .engine_native = .{ .cpp_type = "WebCore::CustomEvent", .header = "CustomEvent.h", .wrapper_tag = "WebCore::CustomEventInterfaceType" },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
    },
);

const error_event_init = b.dictionary("ErrorEventInit", event_init_fields ++ .{
    b.dictionaryField("colno", b.uint32, .{ .default_value = .{ .unsigned = 0 } }),
    b.dictionaryField("error", b.engine_value, .{ .default_value = .null }),
    b.dictionaryField("filename", b.usv_string, .{ .default_value = .{ .string = "" } }),
    b.dictionaryField("lineno", b.uint32, .{ .default_value = .{ .unsigned = 0 } }),
    b.dictionaryField("message", b.dom_string, .{ .default_value = .{ .string = "" } }),
});

const error_event_class = webcore_bindings.wrapperClass(
    "ErrorEvent",
    b.constructor(.{
        b.argument("type", b.dom_string, .{}),
        b.argument("eventInitDict", error_event_init, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{ .length = 1 }),
    .{
        b.getter("message", b.dom_string, .{ .configurable = true }),
        b.getter("filename", b.usv_string, .{ .configurable = true }),
        b.getter("lineno", b.uint32, .{ .configurable = true }),
        b.getter("colno", b.uint32, .{ .configurable = true }),
        b.getter("error", b.engine_value, .{ .configurable = true }),
    },
    .{},
    "WebCore ErrorEvent error reachability, wrapper-cache identity, and GC tracing",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("ErrorEvent", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(event_class),
        .engine_native = .{ .cpp_type = "WebCore::ErrorEvent", .header = "ErrorEvent.h", .wrapper_tag = "WebCore::ErrorEventInterfaceType" },
        .identity = .per_realm,
        .engine_tracing = .additional_children,
    },
);

const message_port_class = webcore_bindings.wrapperClass(
    "MessagePort",
    b.illegalConstructor(),
    .{
        webcore_bindings.eventHandlerGetter("onmessage"),
        webcore_bindings.eventHandlerSetter("onmessage"),
        webcore_bindings.eventHandlerGetter("onmessageerror"),
        webcore_bindings.eventHandlerSetter("onmessageerror"),
        b.method("postMessage", .{
            b.argument("message", b.engine_value, .{}),
            b.argument("second", structured_clone.second, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, b.none, .{ .length = 1, .configurable = true }),
        b.method("start", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("close", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("ref", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("unref", .{}, b.none, .{ .length = 0, .configurable = true }),
        b.method("hasRef", .{}, b.boolean, .{ .length = 0, .configurable = true }),
    },
    .{},
    "WebCore MessagePort entanglement, event-target identity, and GC tracing",
    .{
        .illegal_constructor_errors = archetypes.illegalConstructorNewSuggestion("MessagePort", "ERR_CONSTRUCT_CALL_INVALID"),
        .profile = .webidl,
        .parent = b.parentClass(event_target_class),
        .engine_native = .{ .cpp_type = "WebCore::MessagePort", .header = "MessagePortOwner.h", .wrapper_tag = "WebCore::MessagePortEventTargetInterfaceType" },
        .identity = .per_realm,
    },
);
const message_port_value = b.classRefByName("WebCoreEvents", "MessagePort");

const message_channel_receiver = b.dictionary("MessageChannelReceiver", .{
    b.dictionaryField("port1", message_port_value, .{ .required = true, .private_symbol = "messageChannelPort1" }),
    b.dictionaryField("port2", message_port_value, .{ .required = true, .private_symbol = "messageChannelPort2" }),
});

const message_channel_class = b.plainClass(
    "MessageChannel",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.getter("port1", message_port_value, .{ .configurable = true, .this_value_type = message_channel_receiver }),
        b.getter("port2", message_port_value, .{ .configurable = true, .this_value_type = message_channel_receiver }),
    },
    .{
        b.instanceProperty("port1", .{ .value = message_port_value, .private_symbol = "messageChannelPort1" }),
        b.instanceProperty("port2", .{ .value = message_port_value, .private_symbol = "messageChannelPort2" }),
    },
    .{
        .backend = .cpp,
        .profile = .webidl,
        .representation = .plain,
        .plain_reason = "A channel owns two MessagePort values in declared JavaScript properties and has no independent native state",
        .constructor_call_error = archetypes.constructorNewSuggestion("MessageChannel", "ERR_CONSTRUCT_CALL_REQUIRED"),
    },
);

const message_port_class_ref = b.classRefByName("WebCoreEvents", "MessagePort");
const message_port_iterable = b.sequenceWithOptions(message_port_class_ref, .{ .container = .iterable });
const message_event_source = b.optionalNullish(message_port_class_ref);
const message_event_ports = b.optionalUndefined(message_port_iterable);
const message_event_source_value = message_event_source;
const message_event_ports_value = b.frozenArray(message_port_class_ref);
const message_event_data = b.unionType("MessageEventData", .{
    b.unionMember("stored", b.optional(b.retained_any)),
    b.unionMember("deserialized", b.engine_value),
    b.unionMember("text", b.dom_string),
    b.unionMember("blob", b.classRefByName("Blob", "Blob")),
    b.unionMember("array_buffer", b.js_array_buffer_object),
    b.unionMember("node_buffer", archetypes.node_buffer_value),
}, .{ .ordered = true, .cpp_name = "MessageEventData" });

const message_event_init = b.dictionary("MessageEventInit", event_init_fields ++ .{
    b.dictionaryField("data", b.retained_any, .{ .default_value = .null }),
    b.dictionaryField("last_event_id", b.dom_string, .{ .default_value = .{ .string = "" }, .js_name = "lastEventId" }),
    b.dictionaryField("origin", b.usv_string, .{ .default_value = .{ .string = "" } }),
    b.dictionaryField("ports", message_event_ports, .{}),
    b.dictionaryField("source", message_event_source, .{}),
});

const message_event_class = webcore_bindings.wrapperClass(
    "MessageEvent",
    b.constructor(.{
        b.argument("type", b.dom_string, .{}),
        b.argument("eventInitDict", message_event_init, .{ .presence = .optional, .missing = .undefined_or_null }),
    }, .{ .length = 1 }),
    .{
        b.getter("origin", b.usv_string, .{ .configurable = true }),
        b.getter("lastEventId", b.dom_string, .{ .configurable = true }),
        b.getter("source", message_event_source_value, .{ .configurable = true }),
        b.getter("data", message_event_data, .{ .cache = "data", .configurable = true }),
        b.getter("ports", message_event_ports_value, .{ .cache = "ports", .configurable = true }),
        b.method("initMessageEvent", .{
            b.argument("type", b.dom_string, .{}),
            b.argument("bubbles", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
            b.argument("cancelable", b.boolean, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .boolean = false },
            }),
            b.argument("data", b.retained_any, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .null,
            }),
            b.argument("originArg", b.usv_string, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .string = "" },
            }),
            b.argument("lastEventId", b.dom_string, .{
                .presence = .default_value,
                .missing = .undefined,
                .default_value = .{ .string = "" },
            }),
            b.argument("source", message_port_class_ref, .{ .presence = .optional, .missing = .undefined_or_null }),
            b.argument("ports", message_port_iterable, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .length = 1, .configurable = true }),
    },
    .{
        b.cachedSlot("data", message_event_data, .{ .exposed = false }),
        b.cachedSlot("ports", message_event_ports_value, .{ .exposed = false }),
    },
    "Event dispatch identity with traced payloads, transferred MessagePorts, and wrapper-world-specific structured-clone and JSON materialization",
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("MessageEvent", "ERR_ILLEGAL_CONSTRUCTOR"),
        .profile = .webidl,
        .parent = b.parentClass(event_class),
        .engine_native = .{ .cpp_type = "WebCore::MessageEvent", .header = "MessageEvent.h", .wrapper_tag = "WebCore::MessageEventInterfaceType" },
        .identity = .per_realm,
        .memory_usage = .vm,
        .engine_tracing = .additional_children,
    },
);

pub const schema = b.moduleWithClasses("WebCoreEvents", .{}, .{
    event_target_class,
    event_emitter_class,
    broadcast_channel_class,
    abort_signal_class,
    abort_controller_class,
    event_class,
    close_event_class,
    custom_event_class,
    error_event_class,
    message_port_class,
    message_channel_class,
    message_event_class,
});
pub const event_target = schema.class("EventTarget");
pub const event_emitter = schema.class("EventEmitter");
pub const broadcast_channel = schema.class("BroadcastChannel");
pub const abort_signal = schema.class("AbortSignal");
pub const abort_controller = schema.class("AbortController");
pub const event = schema.class("Event");
pub const close_event = schema.class("CloseEvent");
pub const custom_event = schema.class("CustomEvent");
pub const error_event = schema.class("ErrorEvent");
pub const message_port = schema.class("MessagePort");
pub const message_channel = schema.class("MessageChannel");
pub const message_event = schema.class("MessageEvent");
