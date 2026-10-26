const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const shared = @import("binding_schema_bindgen_shared");
const hash_types = @import("binding_schema_HashTypes");
const structured_clone = @import("binding_schema_StructuredClone");

const deferred_test_conversion = "the bindgen fixture conditionally forces this value to verify deferred conversion behavior";

const boolean_nullish_or_any = b.unionType("BooleanNullishOrAny", .{
    b.unionMember("boolean", b.boolean),
    b.unionMember("nulled", b.null_literal),
    b.unionMember("undefined", b.undefined_literal),
    b.unionMember("other", b.discarded),
}, .{ .ordered = true, .fallback_member = "other" });
const string_or_buffer_view_or_ignored = b.unionType("StringOrBufferViewOrIgnored", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("buffer", b.bufferView(.lease)),
    b.unionMember("ignored", b.discarded),
}, .{ .ordered = true, .fallback_member = "ignored" });
const non_detached_buffer_view = b.bufferViewWithOptions(.lease, .{ .allow_detached = false });
const cpp_optional_string_union = b.unionType("CppOptionalStringUnion", .{
    b.unionMember("string", archetypes.optional_dom_string),
    b.unionMember("integer", b.int32),
}, .{ .ordered = true });
const cpp_external_ref_sequence = b.sequence(b.abort_signal);
const cpp_dictionary_source = b.dictionary("CppDictionarySourceOptions", .{
    b.dictionaryField("source", b.engine_value, .{ .source = .dictionary, .required = true }),
});
const cpp_dictionary_source_sequence = b.sequence(cpp_dictionary_source);
const dictionary_source_input = b.dictionary("BindgenDictionarySource", .{
    b.dictionaryRetainedSource("source"),
    b.dictionaryField("trigger", b.dom_string, .{}),
});

const gc_entry_callback = b.callback("GCEntryCallback", .{
    b.argument("value", b.invocation_any, .{}),
}, b.int32, .{ .receiver = null, .profile = .exact });
const gc_entry = b.dictionary("GCEntry", .{
    b.dictionaryField("value", b.invocation_any, .{ .required = true }),
    b.dictionaryField("callback", gc_entry_callback, .{ .required = true }),
    b.dictionaryField("bytes", b.buffer(.lease), .{ .required = true }),
});
const native_record_callback = b.callback("NativeRecordCallback", .{}, b.int32, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const native_record_factory = b.callback("NativeRecordFactory", .{}, native_record_callback, .{ .receiver = null, .profile = .exact });
const native_record_item = b.dictionaryWithOptions("NativeRecordItem", .{
    b.dictionaryField("callback", native_record_callback, .{ .required = true }),
    b.dictionaryField("bytes", b.buffer(.copy), .{ .required = true }),
}, .{ .cpp_name = "BindgenNativeRecordItem" });
const native_callback_record = b.record(b.dom_string, native_record_item);
const callback_record_factory = b.callback("CallbackRecordFactory", .{}, native_callback_record, .{ .receiver = null, .profile = .exact });

const identity_callback = b.callback("IdentityCallback", .{}, b.none, .{ .receiver = null, .profile = .exact, .retains_async_context = true });
const change_context_callback = b.callback("ChangeContextCallback", .{}, b.none, .{ .receiver = null, .profile = .exact });
const stored_root_snapshots = b.dictionary("StoredRootSnapshots", .{
    b.dictionaryField("root", b.any, .{ .required = true }),
    b.dictionaryField("optional", b.any, .{ .required = true }),
    b.dictionaryField("engine", b.engine_value, .{ .required = true }),
    b.dictionaryField("promise", b.js_promise, .{ .required = true }),
    b.dictionaryField("replacement", b.any, .{ .required = true }),
    b.dictionaryField("cleared", b.boolean, .{ .required = true }),
    b.dictionaryField("reused", b.boolean, .{ .required = true }),
});
const lazy_iterable = b.lazy(b.optional(b.sequenceWithOptions(b.int32, .{ .container = .iterable })));
const nested_lazy_fields = b.dictionary("BindgenNestedLazyFields", .{
    b.dictionaryField("items", b.lazy(b.sequenceWithOptions(b.int32, .{ .container = .iterable })), .{ .required = true, .deferred_reason = deferred_test_conversion }),
    b.dictionaryField("label", b.lazy(archetypes.coerced_dom_string), .{ .required = true, .deferred_reason = deferred_test_conversion }),
    b.dictionaryField("ignored", b.lazy(archetypes.coerced_dom_string), .{ .required = true, .deferred_reason = deferred_test_conversion }),
});
const nested_lazy_container = b.dictionary("BindgenNestedLazyContainer", .{
    b.dictionaryField("options", b.lazy(nested_lazy_fields), .{ .required = true, .deferred_reason = deferred_test_conversion }),
});
const lazy_path_leaf = b.dictionary("BindgenLazyPathLeaf", .{
    b.dictionaryField("text", b.dom_string, .{ .required = true }),
});
const lazy_path_options = b.dictionary("BindgenLazyPathOptions", .{
    b.dictionaryField("relative", b.lazy(lazy_path_leaf), .{ .required = true, .deferred_reason = deferred_test_conversion }),
    b.dictionaryField("absolute", b.lazy(lazy_path_leaf), .{ .required = true, .deferred_reason = deferred_test_conversion, .diagnostic_name = "fixed.absolute" }),
});
const pattern_nested_value = b.unionType("BindgenPatternNestedValue", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("number", b.int32),
}, .{});
const pattern_value = b.unionType("BindgenPatternValue", .{
    b.unionMember("flag", b.boolean),
    b.unionMember("nested", pattern_nested_value),
}, .{ .ordered = true, .fallback_member = "nested" });
const pattern_values = b.sequenceWithOptions(pattern_value, .{ .element_pattern = .{
    .members = &.{ "flag", "nested" },
    .incomplete_error = .{ .kind = .type_error, .message = "Expected flag and value pairs" },
} });

const opaque_native_handle = b.nominalHandle("BindgenTestOpaque", .{
    .cpp_type = .{ .pointer = &.void },
    .cpp_declarations = &.{},
    .raw_pointer_escape = "the conformance fixture exercises an opaque foreign address",
    .access_thread = .any,
});

const transfer_handle = b.nominalHandle("BindgenTestTransfer", .{
    .cpp_type = .{ .pointer = &.{ .named = "WTF::StringImpl" } },
    .cpp_declarations = &.{.{ .class = "WTF::StringImpl" }},
    .ownership = .owned,
    .cpp_release = "releaseBindgenTestTransfer",
    .access_thread = .vm,
    .destroy_thread = .vm,
});
const transferred_value = b.dictionary("BindgenTransferredValue", .{
    b.dictionaryField("handle", transfer_handle, .{ .required = true }),
    b.dictionaryField("value", b.engine_value, .{ .required = true }),
});

const runtime_failure = b.domainError("runtime_failure", b.dom_string, .{
    .class = .generic_error,
    .message = .payload,
});
const runtime_failures = b.domainErrors(.{runtime_failure});
const async_runtime_failure = b.domainError("runtime_failure", b.thread_safe_dom_string, .{
    .class = .generic_error,
    .message = .payload,
});
const async_runtime_failures = b.domainErrors(.{async_runtime_failure});

const failures = b.domainErrors(.{
    b.domainError(
        "rejected",
        b.dom_string,
        .{
            .class = .range_error,
            .code = "ERR_BINDGEN_TEST",
            .message = .payload,
        },
    ),
    b.domainError(
        "fixed",
        b.none,
        .{
            .class = .type_error,
            .message = .{ .literal = "fixed bindgen failure" },
        },
    ),
    b.systemError("system"),
    runtime_failure,
});

const async_failures = b.domainErrors(.{
    b.domainError(
        "rejected",
        b.thread_safe_dom_string,
        .{
            .class = .range_error,
            .code = "ERR_BINDGEN_TEST",
            .message = .payload,
        },
    ),
    b.domainError(
        "fixed",
        b.none,
        .{
            .class = .type_error,
            .message = .{ .literal = "fixed bindgen failure" },
        },
    ),
    b.systemError("system"),
    async_runtime_failure,
});

pub const reducer = b.callback(
    "Reducer",
    .{
        b.argument("value", b.int32, .{}),
        b.argument("label", b.dom_string, .{}),
    },
    b.int32,
    .{ .receiver = null, .profile = .exact },
);

pub const string_mapper = b.callback(
    "StringMapper",
    .{b.argument("input", b.dom_string, .{})},
    b.usv_string,
    .{ .receiver = null, .profile = .exact },
);

const scheduled_callback = b.callback(
    "BindgenScheduledCallback",
    .{b.argument("value", b.invocation_any, .{})},
    b.none,
    .{ .receiver = b.invocation_any, .schedule_next_tick = true, .retains_async_context = true },
);

pub const nullable_string_mapper = b.callback(
    "NullableStringMapper",
    .{b.argument("input", b.optional(b.dom_string), .{})},
    b.optional(b.dom_string),
    .{ .receiver = null, .profile = .exact },
);

pub const bytes_mapper = b.callback(
    "BytesMapper",
    .{b.argument("input", b.node_buffer, .{})},
    b.buffer(.copy),
    .{ .receiver = null, .profile = .exact },
);

pub const value_mapper = b.callback(
    "ValueMapper",
    .{b.argument("input", b.invocation_any, .{})},
    b.any,
    .{ .receiver = null, .profile = .exact },
);

const async_materialized_result = b.dictionary("AsyncMaterializedResult", .{
    b.dictionaryField("value", b.int32, .{ .required = true }),
    b.dictionaryField("label", b.any, .{ .required = true }),
});

pub const rest_callback = b.callback(
    "RestCallback",
    .{
        b.argument("prefix", b.int32, .{}),
        b.rest("values", b.invocation_any),
    },
    b.int32,
    .{ .receiver = null, .profile = .exact },
);

const structured_clone_serialization_context = b.enumerationWithOptions(
    "StructuredCloneSerializationContext",
    .{
        b.enumerationValueWithOptions("default_context", "default", .{ .native_value = 0 }),
        b.enumerationValueWithOptions("worker", "worker", .{ .native_value = 1 }),
        b.enumerationValueWithOptions("window", "window", .{ .aliases = &.{"postMessage"}, .native_value = 2 }),
    },
    .{ .cpp_name = "StructuredCloneSerializationContext", .invalid_value_error = .type },
);
pub const typed_rest_callback = b.callback(
    "TypedRestCallback",
    .{
        b.argument("prefix", b.int32, .{}),
        b.rest("values", b.int32),
    },
    b.int32,
    .{ .receiver = null, .profile = .exact },
);

pub const reducer_factory = b.callback(
    "ReducerFactory",
    .{},
    reducer,
    .{ .receiver = null, .profile = .exact },
);

pub const observer = b.callback(
    "Observer",
    .{b.argument("value", b.int32, .{})},
    b.none,
    .{ .receiver = null, .profile = .exact },
);

pub const integer_mapper = b.callback(
    "IntegerMapper",
    .{
        b.argument("signed8", b.int8, .{}),
        b.argument("signed16", b.int16, .{}),
        b.argument("unsigned16", b.uint16, .{}),
        b.argument("unsigned32", b.uint32, .{}),
        b.argument("signed64", b.int64, .{}),
        b.argument("unsigned64", b.uint64, .{}),
    },
    b.uint64,
    .{ .receiver = null, .profile = .exact },
);

pub const test_mode = b.enumerationWithOptions(
    "BindgenTestMode",
    .{
        b.enumerationValue("fast", "fast"),
        b.enumerationValue("safe", "safe-mode"),
        b.enumerationValue("unicode", "unicode-😀"),
    },
    .{ .invalid_value_error = .type },
);

pub const test_metadata = b.dictionary("BindgenTestMetadata", .{
    b.dictionaryField("mode", test_mode, .{ .required = true }),
    b.dictionaryField("note", b.dom_string, .{}),
});

pub const test_options = b.dictionary("BindgenTestOptions", .{
    b.dictionaryField("count", b.int32, .{
        .required = true,
        .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = 100 } },
    }),
    b.dictionaryField("label", b.dom_string, .{}),
    b.dictionaryField("enabled", b.boolean, .{ .default_value = .{ .boolean = true } }),
    b.dictionaryField("metadata", test_metadata, .{ .required = true }),
    b.dictionaryField("bytes", b.buffer(.copy), .{}),
});

pub const nullable_field_options = b.dictionary("BindgenNullableFieldOptions", .{
    b.dictionaryField("input", b.optional(b.int32), .{}),
    b.dictionaryField("bytes", b.buffer(.lease), .{}),
});

pub const lease_options = b.dictionary("BindgenLeaseOptions", .{
    b.dictionaryField("bytes", b.buffer(.lease), .{ .required = true }),
    b.dictionaryField("marker", b.discardAny(.ignored), .{ .required = true }),
});

pub const test_scalar = b.unionType("BindgenTestScalar", .{
    b.unionMember("integer", b.int32),
    b.unionMember("text", b.dom_string),
    b.unionMember("flag", b.boolean),
}, .{});

pub const test_lease_value = b.unionType("BindgenTestLeaseValue", .{
    b.unionMember("bytes", b.buffer(.lease)),
    b.unionMember("text", b.dom_string),
}, .{});
pub const test_scalars = b.sequence(test_scalar);
pub const test_record = b.record(b.dom_string, test_scalar);
pub const node_strings = archetypes.dom_strings;

pub const node_alias_options = b.dictionary("BindgenNodeAliasOptions", .{
    b.dictionaryField("hostname", b.dom_string, .{
        .required = true,
        .aliases = &.{"host"},
    }),
    b.dictionaryField("port", b.int32, .{ .required = true }),
});

pub const test_bundle = b.dictionary("BindgenTestBundle", .{
    b.dictionaryField("metadata", test_metadata, .{ .required = true }),
    b.dictionaryField("scalars", test_scalars, .{ .required = true }),
    b.dictionaryField("lookup", test_record, .{ .required = true }),
});

pub const test_bundle_visitor = b.callback(
    "BindgenTestBundleVisitor",
    .{b.argument("bundle", test_bundle, .{})},
    b.int32,
    .{ .receiver = null, .profile = .exact },
);

const callback_counter = b.classRefByName("bindgen_test", "Counter");
const callback_counter_or_number = b.unionType("BindgenCallbackCounterOrNumber", .{
    b.unionMember("counter", callback_counter),
    b.unionMember("number", b.int32),
}, .{});
const callback_composite = b.dictionary("BindgenCallbackComposite", .{
    b.dictionaryField("choice", callback_counter_or_number, .{ .required = true }),
    b.dictionaryField("labels", archetypes.dom_strings, .{ .required = true }),
    b.dictionaryField("value", b.any, .{ .required = true }),
    b.dictionaryField("observer", change_context_callback, .{ .required = true }),
    b.dictionaryField("label", b.dom_string, .{ .required = true }),
});
const composite_callback = b.callback("BindgenCompositeCallback", .{}, callback_composite, .{ .receiver = null, .profile = .exact });

const advanced_label_converter = archetypes.test_converters.test_prefix_label;
const nullable_label_converter = archetypes.test_converters.test_nullable_label;
const array_buffer_view_predicate_input = b.unionType("BindgenTestArrayBufferViewPredicateInput", .{
    b.unionMember("view", b.js_array_buffer_view),
    b.unionMember("other", b.discarded),
}, .{ .ordered = true, .fallback_member = "other", .cpp_name = "BindgenTestArrayBufferViewPredicateInput" });
const non_reified_static_predicate_input = b.unionType("BindgenTestNonReifiedStaticPredicateInput", .{
    b.unionMember("object", b.js_object),
    b.unionMember("other", b.discarded),
}, .{ .ordered = true, .fallback_member = "other", .cpp_name = "BindgenTestNonReifiedStaticPredicateInput" });
const custom_integers = b.sequence(b.int32);
const converted_label = b.converted(b.dom_string, b.dom_string, advanced_label_converter, .{});
const nullable_label = b.converted(b.optional(b.dom_string), b.optional(b.dom_string), nullable_label_converter, .{});
const rest_entry = b.dictionary("BindgenRestEntry", .{
    b.dictionaryField("label", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", test_scalar, .{ .required = true }),
});
const engine_buffer_sequence = b.sequence(b.buffer(.copy));

const functions = .{
    b.function("retainCallbackRecord", .{b.argument("factory", callback_record_factory, .{})}, native_callback_record, .{ .profile = .exact }),
    b.function("inspectCallbackRecordViews", .{
        b.argument("factory", callback_record_factory, .{}),
        b.argument("failAfter", b.uint32, .{ .presence = .optional }),
    }, b.int32, .{ .profile = .exact }),
    b.function(
        "settlePromiseWithPendingException",
        .{
            b.argument("promise", b.js_promise, .{}),
            b.argument("failure", b.engine_value, .{ .missing = .omitted }),
            b.argument("settlement", b.enumeration("TestPromiseSettlement", .{
                b.enumerationValue("resolve", "resolve"),
                b.enumerationValue("reject", "reject"),
                b.enumerationValue("rejectHandled", "rejectHandled"),
            }), .{}),
        },
        b.none,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "throwOutOfMemoryWithPendingException",
        .{b.argument("failure", b.engine_value, .{ .presence = .optional, .missing = .omitted })},
        b.none,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "add",
        .{
            b.argument("a", b.int32, .{}),
            b.argument("b", b.int32, .{
                .presence = .default_value,
                .missing = .undefined_or_null,
                .default_value = .{ .signed = -1 },
            }),
        },
        b.int32,
        .{ .backend = .zig, .profile = .webidl, .errors = runtime_failures },
    ),
    b.function("echoInt8", .{b.argument("input", b.int8, .{})}, b.int8, .{ .profile = .exact }),
    b.function("echoInt16", .{b.argument("input", b.int16, .{})}, b.int16, .{ .profile = .exact }),
    b.function("echoUint16", .{b.argument("input", b.uint16, .{})}, b.uint16, .{ .profile = .exact }),
    b.function("echoUint32", .{b.argument("input", b.uint32, .{})}, b.uint32, .{ .profile = .exact }),
    b.function(
        "echoInt64",
        .{b.argument("input", b.int64, .{
            .integer_conversion = .{ .enforce_range = .{
                .min = std.math.minInt(i64),
                .max = std.math.maxInt(i64),
            } },
        })},
        b.int64,
        .{ .profile = .exact },
    ),
    b.function(
        "echoUint64",
        .{b.argument("input", b.uint64, .{
            .integer_conversion = .{ .enforce_range = .{
                .min = 0,
                .max = std.math.maxInt(u64),
            } },
        })},
        b.uint64,
        .{ .profile = .exact },
    ),
    b.function(
        "requiredAndOptionalArg",
        .{
            b.argument("a", b.boolean, .{}),
            b.argument("b", b.size, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
            b.argument("c", b.int32, .{
                .presence = .default_value,
                .missing = .undefined_or_null,
                .default_value = .{ .signed = 42 },
                .integer_conversion = .{ .enforce_range = .{ .min = 0, .max = 100 } },
            }),
            b.argument("d", b.uint8, .{
                .presence = .optional,
                .missing = .undefined_or_null,
            }),
        },
        b.int32,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "echoTestOptions",
        .{b.argument("options", test_options, .{})},
        test_options,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoDictionarySource",
        .{b.argument("input", dictionary_source_input, .{})},
        b.any,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "echoTestScalars",
        .{b.argument("input", test_scalars, .{})},
        test_scalars,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "roundTripTestBundle",
        .{b.argument("input", test_bundle, .{})},
        test_bundle,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "visitTestBundle",
        .{
            b.argument("input", test_bundle, .{}),
            b.argument("visitor", test_bundle_visitor, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "dispatchAdvanced",
        b.overloads(.{
            b.overloadCase("bytes", .{
                b.argument("input", b.buffer(.copy), .{}),
                b.argument("label", converted_label, .{}),
            }),
            b.overloadCase("iterable", .{
                b.argument("input", lazy_iterable, .{
                    .deferred_reason = "the fixture invokes a callback before consuming the selected iterable",
                }),
                b.argument("label", converted_label, .{}),
                b.argument("trigger", change_context_callback, .{ .presence = .optional }),
            }),
            b.overloadCase("options", .{
                b.argument("input", test_options, .{}),
                b.argument("label", converted_label, .{}),
                b.argument("trigger", change_context_callback, .{ .presence = .optional }),
            }),
        }, .{ .ordered = true }),
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectNodeConversionOrder",
        b.overloads(.{
            b.overloadCase("options", .{
                b.argument("input", node_alias_options, .{}),
            }),
            b.overloadCase("fallback", .{
                b.argument("input", b.discardAny(.classification), .{}),
            }),
        }, .{ .ordered = true }),
        b.int32,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function(
        "inspectCustomConverters",
        .{
            b.argument("numbers", custom_integers, .{}),
            b.argument("nullableLabel", nullable_label, .{}),
            b.argument("optionalLabel", converted_label, .{
                .presence = .optional,
            }),
            b.argument("defaultLabel", converted_label, .{
                .presence = .default_value,
                .default_value = .{ .string = "fallback" },
            }),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectLazyOptions",
        .{
            b.argument("input", b.lazy(test_options), .{ .deferred_reason = deferred_test_conversion }),
            b.argument("shouldConvert", b.boolean, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectLazyConvertedLabel",
        .{b.argument("input", b.lazy(converted_label), .{ .deferred_reason = deferred_test_conversion })},
        b.size,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function("inspectLazyReceiverIndex", .{
        b.argument("index", b.lazy(b.size), .{
            .integer_conversion = .{ .node_receiver_byte_length = .integer },
            .deferred_reason = "the callback may change the receiver before index validation",
        }),
        b.argument("trigger", change_context_callback, .{}),
    }, b.size, .{ .profile = .node, .this_value_type = b.js_array_buffer_view }),
    b.function("inspectLazyRestLease", .{
        b.argument("bytes", b.buffer(.lease), .{}),
        b.argument("trigger", change_context_callback, .{}),
        b.argument("discardLast", b.boolean, .{}),
        b.lazyRest("values", archetypes.coerced_dom_string, deferred_test_conversion),
    }, b.size, .{ .profile = .exact }),
    b.function("retryLazyString", .{
        b.argument("input", b.lazy(b.dom_string), .{ .deferred_reason = deferred_test_conversion }),
    }, b.size, .{ .backend = .zig, .profile = .webidl }),
    b.function("retryCppLazyString", .{
        b.argument("input", b.lazy(b.dom_string), .{ .deferred_reason = deferred_test_conversion }),
    }, b.size, .{ .backend = .cpp, .profile = .webidl }),
    b.function("callbackIdentityAfterReentry", .{
        b.argument("first", identity_callback, .{}),
        b.argument("second", b.lazy(identity_callback), .{ .deferred_reason = deferred_test_conversion }),
        b.argument("changeContext", change_context_callback, .{}),
    }, b.boolean, .{ .backend = .zig, .profile = .exact }),
    b.function(
        "domStringLength",
        .{b.argument("input", b.dom_string, .{})},
        b.size,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function("isolateEngineString", .{
        b.argument("input", b.dom_string, .{}),
        b.argument("fail", b.boolean, .{}),
    }, b.dom_string, .{ .backend = .zig, .profile = .exact }),
    b.function(
        "echoDOMString",
        .{b.argument("input", b.dom_string, .{})},
        b.dom_string,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "echoUSVString",
        .{b.argument("input", b.usv_string, .{})},
        b.usv_string,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "echoByteString",
        .{b.argument("input", b.byte_string, .{})},
        b.byte_string,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "strictUSVString",
        .{b.argument("input", b.usv_string, .{})},
        b.usv_string,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "strictByteString",
        .{b.argument("input", b.byte_string, .{})},
        b.byte_string,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoBuffer",
        .{b.argument("input", b.buffer(.lease), .{})},
        b.buffer(.copy),
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "fillMutableLease",
        .{
            b.argument("input", b.writableBufferView(.lease), .{}),
            b.argument("value", b.uint8, .{}),
        },
        b.none,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "setMutableLeaseByte",
        .{
            b.argument("input", b.writableBufferView(.lease), .{}),
            b.argument("index", b.uint32, .{}),
            b.argument("value", b.uint8, .{}),
        },
        b.none,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "inspectInt32FromJS",
        .{b.argument("input", b.lazy(b.int32), .{ .deferred_reason = deferred_test_conversion })},
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectLeaseOptionsFromJS",
        .{b.argument("input", b.lazy(lease_options), .{ .deferred_reason = deferred_test_conversion })},
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectLeaseAfterCallback",
        .{
            b.argument("input", b.buffer(.lease), .{}),
            b.argument("callback", observer, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectNestedLeaseAfterCallback",
        .{
            b.argument("input", test_lease_value, .{}),
            b.argument("callback", observer, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoNullableBuffer",
        .{b.argument("input", b.optional(b.buffer(.copy)), .{})},
        b.optional(b.buffer(.copy)),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function("visitGCEntries", .{
        b.argument("entries", b.sequence(gc_entry), .{}),
        b.argument("trigger", archetypes.coerced_dom_string, .{}),
    }, b.int32, .{ .backend = .zig, .profile = .exact }),
    b.function("visitDeferredGCEntries", .{
        b.argument("entries", b.lazy(b.sequence(gc_entry)), .{ .deferred_reason = deferred_test_conversion }),
        b.argument("trigger", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_test_conversion }),
        b.argument("ignored", b.lazy(archetypes.coerced_dom_string), .{ .presence = .optional, .deferred_reason = deferred_test_conversion }),
    }, b.int32, .{ .backend = .zig, .profile = .exact }),
    b.function("leaseWithIgnoredOperand", .{
        b.argument("input", b.buffer(.lease), .{}),
        b.argument("ignored", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_test_conversion }),
        b.argument("before", b.lazy(archetypes.coerced_dom_string), .{ .presence = .optional, .deferred_reason = deferred_test_conversion }),
    }, b.uint8, .{ .backend = .zig, .profile = .exact }),
    b.function("inspectNestedLazyFields", .{
        b.argument("input", b.lazy(nested_lazy_container), .{ .deferred_reason = deferred_test_conversion }),
        b.argument("bytes", b.buffer(.lease), .{}),
        b.argument("trigger", change_context_callback, .{}),
    }, b.int32, .{ .backend = .zig, .profile = .exact }),
    b.function("inspectEagerLazyFields", .{
        b.argument("input", nested_lazy_container, .{}),
        b.argument("bytes", b.buffer(.lease), .{}),
    }, b.int32, .{ .backend = .zig, .profile = .exact }),
    b.function("inspectNestedLazyRest", .{
        b.lazyRest("values", nested_lazy_container, deferred_test_conversion),
    }, b.int32, .{ .backend = .zig, .profile = .exact }),
    b.function("forceLazyPath", .{
        b.argument("options", lazy_path_options, .{}),
        b.argument("absolute", b.boolean, .{}),
    }, b.size, .{ .backend = .zig, .profile = .exact }),
    b.function("describePatternValues", .{
        b.argument("values", pattern_values, .{}),
    }, b.dom_string, .{ .backend = .zig, .profile = .exact }),
    b.function(
        "echoAny",
        .{b.argument("input", b.any, .{})},
        b.any,
        .{
            .backend = .zig,
            .profile = .exact,
        },
    ),
    b.function(
        "invocationThis",
        .{},
        b.any,
        .{
            .backend = .zig,
            .profile = .exact,
            .this_value_type = b.any,
        },
    ),
    b.function("snapshotStoredRoots", .{
        b.argument("input", b.any, .{}),
        b.argument("replacement", b.any, .{}),
        b.argument("engine", b.engine_value, .{}),
        b.argument("promise", b.js_promise, .{}),
        b.argument("collect", change_context_callback, .{}),
        b.argument("failAfter", b.uint32, .{ .presence = .optional, .missing = .omitted }),
    }, stored_root_snapshots, .{ .backend = .zig, .profile = .exact }),
    b.function("preserveTransferredRoot", .{
        b.argument("input", b.engine_value, .{}),
        b.argument("collect", change_context_callback, .{}),
    }, b.engine_value, .{ .backend = .zig, .profile = .exact }),
    b.function(
        "invokeCallback",
        .{
            b.argument("callback", reducer, .{}),
            b.argument("value", b.int32, .{}),
            b.argument("label", b.dom_string, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeOwnedCallback",
        .{
            b.argument("callback", reducer, .{}),
            b.argument("value", b.int32, .{}),
            b.argument("label", b.dom_string, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function("scheduleCallback", .{
        b.argument("callback", scheduled_callback, .{}),
        b.argument("receiver", b.any, .{}),
        b.argument("value", b.any, .{}),
    }, b.none, .{ .backend = .zig, .profile = .exact }),
    b.function(
        "echoCallback",
        .{b.argument("callback", reducer, .{})},
        reducer,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeStringCallback",
        .{
            b.argument("callback", string_mapper, .{}),
            b.argument("input", b.dom_string, .{}),
        },
        b.usv_string,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeNullableStringCallback",
        .{
            b.argument("callback", nullable_string_mapper, .{}),
            b.argument("input", b.optional(b.dom_string), .{}),
        },
        b.optional(b.dom_string),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeBufferCallback",
        .{
            b.argument("callback", bytes_mapper, .{}),
            b.argument("input", b.buffer(.copy), .{}),
        },
        b.buffer(.copy),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeAnyCallback",
        .{
            b.argument("callback", value_mapper, .{}),
            b.argument("input", b.invocation_any, .{}),
        },
        b.any,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeCompositeCallback",
        .{b.argument("callback", composite_callback, .{})},
        callback_composite,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeRestCallback",
        .{
            b.argument("callback", rest_callback, .{}),
            b.argument("prefix", b.int32, .{}),
            b.rest("values", b.invocation_any),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeTypedRestCallback",
        .{
            b.argument("callback", typed_rest_callback, .{}),
            b.argument("prefix", b.int32, .{}),
            b.rest("values", b.int32),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeCallbackFactory",
        .{
            b.argument("factory", reducer_factory, .{}),
            b.argument("value", b.int32, .{}),
            b.argument("label", b.dom_string, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeObserver",
        .{
            b.argument("callback", observer, .{}),
            b.argument("value", b.int32, .{}),
        },
        b.none,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "invokeIntegerCallback",
        .{
            b.argument("callback", integer_mapper, .{}),
            b.argument("signed8", b.int8, .{}),
            b.argument("signed16", b.int16, .{}),
            b.argument("unsigned16", b.uint16, .{}),
            b.argument("unsigned32", b.uint32, .{}),
            b.argument("signed64", b.int64, .{}),
            b.argument("unsigned64", b.uint64, .{}),
        },
        b.uint64,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "clampInteger",
        .{b.argument("input", b.int32, .{
            .integer_conversion = .{ .clamp = .{ .min = -10, .max = 10 } },
        })},
        b.int32,
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "validateInteger",
        .{b.argument("input", b.int32, .{
            .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 100 } },
        })},
        b.int32,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function(
        "validateNodeBoolean",
        .{b.argument("input", b.boolean, .{})},
        b.boolean,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function(
        "validateNodeNumber",
        .{b.argument("input", b.double, .{})},
        b.double,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function(
        "validateNodeString",
        .{b.argument("input", b.dom_string, .{})},
        b.size,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function(
        "validateNodeStrings",
        .{b.argument("input", node_strings, .{})},
        b.size,
        .{ .backend = .zig, .profile = .node },
    ),
    b.function(
        "defaultString",
        .{b.argument("input", b.dom_string, .{
            .presence = .default_value,
            .default_value = .{ .string = "default 😀" },
        })},
        b.dom_string,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "defaultAny",
        .{b.argument("input", b.any, .{
            .presence = .default_value,
            .default_value = .null,
        })},
        b.any,
        .{
            .backend = .zig,
            .profile = .exact,
        },
    ),
    b.function(
        "classifyPresence",
        .{b.argument("input", boolean_nullish_or_any, .{
            .presence = .optional,
            .missing = .omitted,
        })},
        b.dom_string,
        .{ .backend = .zig, .length = 2, .profile = .exact },
    ),
    b.function(
        "inspectRest",
        .{
            b.argument("prefix", b.int32, .{}),
            b.lazyRest("values", boolean_nullish_or_any, deferred_test_conversion),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function("inspectBrandedRest", .{b.rest("values", b.js_array)}, b.size, .{ .profile = .exact }),
    b.function("cppInspectStringRest", .{b.rest("values", b.dom_string)}, b.size, .{ .backend = .cpp, .profile = .webidl }),
    b.function(
        "inspectStringRest",
        .{b.lazyRest("values", b.dom_string, deferred_test_conversion)},
        b.size,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoStringRest",
        .{b.rest("values", b.optional(b.dom_string))},
        b.sequence(b.optional(b.dom_string)),
        .{ .backend = .zig, .profile = .webidl },
    ),
    b.function(
        "echoBufferRest",
        .{
            b.argument("callback", change_context_callback, .{}),
            b.rest("values", b.optional(b.buffer(.copy))),
        },
        b.sequence(b.optional(b.buffer(.copy))),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoAggregateRest",
        .{b.rest("values", rest_entry)},
        b.sequence(rest_entry),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoNullableInt",
        .{b.argument("input", shared.nullable_int, .{})},
        shared.nullable_int,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "classifyNullablePresence",
        .{b.argument("input", b.optional(b.int32), .{
            .presence = .optional,
            .missing = .omitted,
        })},
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoNullableString",
        .{b.argument("input", b.optional(b.dom_string), .{})},
        b.optional(b.dom_string),
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "echoNullableAny",
        .{b.argument("input", b.optional(b.any), .{})},
        b.optional(b.any),
        .{
            .backend = .zig,
            .profile = .exact,
        },
    ),
    b.function(
        "readCounterValue",
        .{b.argument("value", b.classRefByName("bindgen_test", "Counter"), .{})},
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "inspectCounterWrapperHandles",
        .{
            b.argument("value", b.classRefByName("bindgen_test", "Counter"), .{}),
            b.argument("beforeRead", change_context_callback, .{ .presence = .optional, .missing = .omitted }),
        },
        b.boolean,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "readSharedCounterValue",
        .{b.argument("value", b.classRefByName("bindgen_test", "SharedCounter"), .{})},
        b.int32,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "domainError",
        .{
            b.argument("kind", b.uint8, .{}),
            b.argument("message", b.dom_string, .{}),
        },
        b.int32,
        .{ .backend = .zig, .profile = .exact, .errors = failures },
    ),
    b.function(
        "asyncResult",
        .{
            b.argument("kind", b.uint8, .{}),
            b.argument("message", b.thread_safe_dom_string, .{}),
        },
        b.int32,
        .{
            .backend = .zig,
            .profile = .exact,
            .errors = async_failures,
            .completion = .{
                .retention = .strong,
                .sender_drop = .{ .reject = "binding completion dropped" },
            },
        },
    ),
    b.function(
        "asyncEcho",
        .{b.argument("message", b.thread_safe_dom_string, .{})},
        b.thread_safe_dom_string,
        .{
            .backend = .zig,
            .profile = .webidl,
            .completion = .{
                .retention = .strong,
                .sender_drop = .leave_pending,
            },
        },
    ),
    b.function(
        "asyncUTF8Strings",
        .{},
        b.sequence(b.utf8_string),
        .{
            .backend = .zig,
            .profile = .exact,
            .errors = async_runtime_failures,
            .completion = .{
                .retention = .strong,
                .sender_drop = .cancel,
            },
        },
    ),
    b.function(
        "asyncMaterialized",
        .{
            b.argument("value", b.int32, .{}),
            b.argument("label", b.retained_any, .{}),
        },
        async_materialized_result,
        .{
            .backend = .zig,
            .profile = .exact,
            .completion = .{
                .retention = .strong,
                .sender_drop = .cancel,
                .delivery = .vm,
            },
        },
    ),
    b.function(
        "asyncWeakEcho",
        .{
            b.argument("kind", b.uint8, .{}),
            b.argument("message", b.thread_safe_dom_string, .{}),
        },
        b.thread_safe_dom_string,
        .{
            .backend = .zig,
            .profile = .exact,
            .errors = async_runtime_failures,
            .completion = .{
                .retention = .weak,
                .sender_drop = .cancel,
            },
        },
    ),
    b.function(
        "asyncPendingEcho",
        .{b.argument("message", b.thread_safe_dom_string, .{})},
        b.thread_safe_dom_string,
        .{
            .backend = .zig,
            .profile = .exact,
            .errors = async_runtime_failures,
            .completion = .{
                .retention = .pending_activity,
                .sender_drop = .cancel,
            },
        },
    ),
    b.function(
        "setTransferAllocationFailureCountdown",
        .{b.argument("countdown", b.int32, .{})},
        b.none,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "setWeakAllocationFailureCountdown",
        .{b.argument("countdown", b.int32, .{})},
        b.none,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "setRootAllocationFailureCountdown",
        .{b.argument("countdown", b.int32, .{})},
        b.none,
        .{ .backend = .zig, .profile = .exact },
    ),
    b.function(
        "readIndexViaEngine",
        .{
            b.argument("target", b.engine_value, .{}),
            b.argument("index", b.uint8, .{}),
        },
        b.engine_value,
        .{
            .backend = .zig,
            .profile = .exact,
        },
    ),
    b.function(
        "sumIntegerWidthsViaEngine",
        .{
            b.argument("signed8", b.int8, .{}),
            b.argument("signed16", b.int16, .{}),
            b.argument("unsigned16", b.uint16, .{}),
            b.argument("unsigned32", b.uint32, .{}),
            b.argument("signed64", b.int64, .{}),
            b.argument("unsigned64", b.uint64, .{}),
        },
        b.int64,
        .{
            .backend = .zig,
            .profile = .exact,
        },
    ),
    b.function(
        "engineBufferSequenceLengthViaEngine",
        .{},
        b.size,
        .{
            .backend = .zig,
            .profile = .exact,
        },
    ),
    b.function(
        "nodePathLengthViaEngine",
        .{b.argument("input", b.node_path, .{})},
        b.size,
        .{
            .backend = .zig,
            .profile = .node,
        },
    ),
    b.function(
        "builtinAdd",
        .{
            b.argument("a", b.int32, .{}),
            b.argument("b", b.int32, .{}),
        },
        b.int32,
        .{
            .backend = .builtin,
            .builtin = "bindgenTestBuiltinAddCodeGenerator",
            .profile = .webidl,
        },
    ),
    b.function(
        "cppAdd",
        .{
            b.argument("a", b.int32, .{}),
            b.argument("b", b.int32, .{}),
        },
        b.int32,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppOverload",
        b.overloads(.{
            b.overloadCase("integer", .{b.argument("value", b.int32, .{})}),
            b.overloadCase("string", .{b.argument("value", b.dom_string, .{})}),
        }, .{}),
        b.int32,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppEchoString",
        .{b.argument("input", b.dom_string, .{})},
        b.dom_string,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppExternalRefPresent",
        .{b.argument("input", b.abort_signal, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppExternalRefSequenceLength",
        .{b.argument("input", cpp_external_ref_sequence, .{})},
        b.size,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppDictionarySourceSequenceLength",
        .{b.argument("input", cpp_dictionary_source_sequence, .{})},
        b.size,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppOptionalUnionPresent",
        .{b.argument("input", cpp_optional_string_union, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppLazyStringLength",
        .{
            b.argument("input", b.lazy(b.dom_string), .{ .deferred_reason = deferred_test_conversion }),
            b.argument("convert", b.boolean, .{}),
        },
        b.size,
        .{ .backend = .cpp, .profile = .webidl },
    ),
    b.function(
        "cppBufferLength",
        .{b.argument("input", b.buffer(.lease), .{})},
        b.size,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppClassifyNullablePresence",
        .{b.argument("input", b.optional(b.int32), .{
            .presence = .optional,
            .missing = .omitted,
        })},
        b.int32,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppClassifyNullableFieldPresence",
        .{b.argument("options", nullable_field_options, .{})},
        b.int32,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppInspectRest",
        .{
            b.argument("prefix", b.int32, .{}),
            b.rest("values", b.discarded),
        },
        b.size,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppEchoBuffer",
        .{b.argument("input", b.buffer(.copy), .{})},
        b.buffer(.copy),
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppSumIntegerWidths",
        .{
            b.argument("signed8", b.int8, .{}),
            b.argument("signed16", b.int16, .{}),
            b.argument("unsigned16", b.uint16, .{}),
            b.argument("unsigned32", b.uint32, .{}),
            b.argument("signed64", b.int64, .{}),
            b.argument("unsigned64", b.uint64, .{}),
        },
        b.int64,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppCallZigExport",
        .{
            b.argument("a", b.int32, .{}),
            b.argument("b", b.int32, .{}),
            b.argument("bias", b.int32, .{}),
        },
        b.int32,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "cppCallZigNativeString",
        .{
            b.argument("label", b.dom_string, .{}),
            b.argument("input", b.buffer(.copy), .{}),
        },
        b.dom_string,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function("cppCallZigNativeRecord", .{
        b.argument("factory", native_record_factory, .{}),
        b.argument("input", b.buffer(.copy), .{}),
    }, native_callback_record, .{ .backend = .cpp, .profile = .exact }),
    b.function(
        "arrayBufferViewHasBuffer",
        .{b.argument("value", array_buffer_view_predicate_input, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "hasNonReifiedStatic",
        .{b.argument("value", non_reified_static_predicate_input, .{})},
        b.boolean,
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "lsanDoLeakCheck",
        .{},
        b.engine_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "decodeURIComponentSIMD",
        .{b.argument("input", string_or_buffer_view_or_ignored, .{})},
        b.optionalUndefined(b.usv_string),
        .{ .backend = .cpp, .profile = .exact },
    ),
    b.function(
        "xxHash3ForTesting",
        .{
            b.argument("view", non_detached_buffer_view, .{}),
            hash_types.strictSeed("seed", .{
                .presence = .default_value,
                .default_value = .{ .unsigned = 0 },
            }),
        },
        b.integerRepresentation(b.uint64, .bigint),
        .{ .backend = .cpp, .length = 2, .profile = .exact },
    ),
    b.function(
        "structuredCloneAdvanced",
        .{
            b.argument("value", b.engine_value, .{}),
            b.argument("transfer_list", structured_clone.transferable_sequence, .{}),
            b.argument("for_transfer", b.boolean, .{}),
            b.argument("for_storage", b.boolean, .{}),
            b.argument("serialization_context", structured_clone_serialization_context, .{ .presence = .optional }),
        },
        b.engine_value,
        .{ .backend = .cpp, .length = 5, .profile = .exact },
    ),
};

const engine_shims = .{
    b.engineShim("createTransferHandle", .{}, transfer_handle, .{
        .throws = .never,
        .realm = .current,
        .affinity = .vm,
    }),
    b.engineShim("consumeTransferredValue", .{
        b.argument("input", transferred_value, .{ .ownership = .transfer }),
    }, b.none, .{
        .throws = .never,
        .realm = .current,
        .affinity = .vm,
    }),
    b.engineShim("isolatedStringResult", .{
        b.argument("input", b.thread_safe_dom_string, .{}),
        b.argument("fail", b.boolean, .{}),
    }, b.thread_safe_dom_string, .{
        .throws = .out_of_memory,
        .realm = .none,
        .affinity = .any,
        .check_traps = false,
    }),
    b.engineShim("forceLazyIterable", .{
        b.argument("input", lazy_iterable, .{ .deferred_reason = deferred_test_conversion }),
    }, b.size, .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .profile = .exact }),
    b.engineShim("forceLazyString", .{
        b.argument("input", b.lazy(b.dom_string), .{ .deferred_reason = deferred_test_conversion }),
    }, b.size, .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .profile = .webidl }),
    b.engineShim("forceCoercedLazyString", .{
        b.argument("input", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_test_conversion }),
    }, b.size, .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .profile = .exact }),
    b.engineShim(
        "getIndex",
        .{
            b.argument("target", b.engine_value, .{}),
            b.argument("index", b.uint8, .{}),
        },
        b.engine_value,
        .{
            .throws = .js_exception,
            .realm = .current,
            .affinity = .vm,
        },
    ),
    b.engineShim(
        "sumIntegerWidths",
        .{
            b.argument("signed8", b.int8, .{}),
            b.argument("signed16", b.int16, .{}),
            b.argument("unsigned16", b.uint16, .{}),
            b.argument("unsigned32", b.uint32, .{}),
            b.argument("signed64", b.int64, .{}),
            b.argument("unsigned64", b.uint64, .{}),
        },
        b.int64,
        .{
            .throws = .never,
            .realm = .current,
            .affinity = .vm,
        },
    ),
    b.engineShim(
        "bufferSequence",
        .{},
        engine_buffer_sequence,
        .{
            .throws = .js_exception,
            .realm = .current,
            .affinity = .vm,
        },
    ),
    b.engineShim(
        "nodePathLength",
        .{b.argument("input", b.node_path, .{})},
        b.size,
        .{
            .throws = .never,
            .realm = .current,
            .affinity = .vm,
            .profile = .node,
        },
    ),
};

const native_exports = .{
    b.nativeExportWithOptions("nativeCallbackRecord", .{
        b.argument("factory", native_record_factory, .{}),
        b.argument("input", b.buffer(.copy), .{}),
    }, native_callback_record, .{ .realm = .current, .throws = .js_exception }),
    b.nativeExportWithOptions("nativeLazyStringLength", .{
        b.argument("input", b.lazy(archetypes.coerced_dom_string), .{ .deferred_reason = deferred_test_conversion }),
    }, b.size, .{ .throws = .js_exception, .realm = .current }),
    b.nativeExport(
        "multiplyAdd",
        .{
            b.argument("a", b.int32, .{}),
            b.argument("b", b.int32, .{}),
            b.argument("bias", b.int32, .{}),
        },
        b.int32,
    ),
    b.nativeExport(
        "nativeStringBufferHandle",
        .{
            b.argument("label", b.dom_string, .{}),
            b.argument("input", b.buffer(.copy), .{}),
            b.argument("handle", opaque_native_handle, .{}),
        },
        b.dom_string,
    ),
    b.nativeExport(
        "optionalNativeString",
        .{b.argument("input", b.optional(b.dom_string), .{})},
        b.optional(b.dom_string),
    ),
    b.nativeExportWithOptions(
        "nativeStringSequenceLength",
        .{b.argument("values", node_strings, .{})},
        b.size,
        .{ .throws = .js_exception, .realm = .current },
    ),
};

const counter_class = b.classWithDataProperties(
    "Counter",
    b.constructor(
        .{b.argument("initial", b.int32, .{
            .presence = .default_value,
            .default_value = .{ .signed = 0 },
        })},
        .{ .new_target_type = b.retained_any },
    ),
    .{
        b.method(
            "increment",
            .{b.argument("delta", b.int32, .{
                .presence = .default_value,
                .default_value = .{ .signed = 1 },
            })},
            b.int32,
            .{ .errors = runtime_failures },
        ),
        b.getter("invalidatableValue", b.int32, .{
            .cache = "hiddenCached",
            .cache_on_construction = true,
            .errors = runtime_failures,
            .implementation = "getInvalidatableValue",
        }),
        b.method("invalidateValueCache", .{}, b.none, .{ .this_value_type = b.this_class_ref }),
        b.method("setCachedCallback", .{b.argument("callback", identity_callback, .{})}, b.none, .{ .this_value_type = b.this_class_ref }),
        b.method("invokeCachedCallback", .{}, b.none, .{ .this_value_type = b.this_class_ref }),
        b.method(
            "privateIncrement",
            .{b.argument("delta", b.int32, .{})},
            b.int32,
            .{ .errors = runtime_failures, .private_symbol = "pull" },
        ),
        b.method(
            "sum",
            b.overloads(
                .{
                    b.overloadCase("one", .{b.argument("value", b.int32, .{})}),
                    b.overloadCase("two", .{
                        b.argument("left", b.int32, .{}),
                        b.argument("right", b.int32, .{}),
                    }),
                },
                .{},
            ),
            b.int32,
            .{ .errors = runtime_failures, .profile = .webidl },
        ),
        b.method(
            "incrementViaBuiltin",
            .{b.argument("delta", b.int32, .{})},
            b.int32,
            .{
                .backend = .builtin,
                .builtin = "bindgenTestCounterIncrementCodeGenerator",
            },
        ),
        b.method(
            "incrementViaCpp",
            .{b.argument("delta", b.int32, .{})},
            b.int32,
            .{ .backend = .cpp },
        ),
        b.getter(
            "doubledViaBuiltin",
            b.int32,
            .{
                .backend = .builtin,
                .builtin = "bindgenTestCounterDoubledCodeGenerator",
            },
        ),
        b.method("toPrimitive", .{}, b.int32, .{ .symbol = .to_primitive }),
        b.method("inspectCustom", .{}, b.dom_string, .{ .symbol = .inspect_custom }),
        b.getter("value", b.int32, .{ .implementation = "getValue" }),
        b.setter("value", b.int32, .{ .implementation = "setValue" }),
        b.getter("newTarget", b.any, .{ .implementation = "getNewTarget" }),
        b.staticMethod("kind", .{}, b.dom_string, .{}),
        b.staticGetter("defaultValue", b.int32, .{ .implementation = "getDefaultValue" }),
        b.staticSetter("defaultValue", b.int32, .{ .implementation = "setDefaultValue" }),
        b.staticGetter("destroyedCount", b.size, .{ .implementation = "getDestroyedCount" }),
        b.staticMethod("adoptAfterCallback", .{b.argument("callback", change_context_callback, .{})}, b.classRefByName("bindgen_test", "Counter"), .{}),
    },
    .{
        b.cachedSlot("cached", b.retained_any, .{ .writable = true }),
        b.cachedSlot("cachedCallback", identity_callback, .{ .writable = true }),
        b.cachedSlot("cachedString", b.optional(b.dom_string), .{ .writable = true }),
        b.cachedSlot("hiddenCached", b.int32, .{ .writable = true, .exposed = false }),
        b.cachedSlot("cachedEngineValue", b.engine_value, .{ .writable = true, .exposed = false }),
    },
    .{
        b.dataProperty("label", .{ .string = "Counter" }, .{}),
        b.dataProperty("version", .{ .unsigned = 1 }, .{
            .storage = .constructor,
            .writable = true,
            .enumerable = false,
            .configurable = false,
        }),
    },
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .any,
        .has_pending_activity = true,
        .lifecycle = .{ .wrapper_created = true },
    },
);

const scaled_counter_class = b.class(
    "ScaledCounter",
    b.constructor(
        .{
            b.argument("initial", b.int32, .{
                .presence = .default_value,
                .default_value = .{ .signed = 0 },
            }),
            b.argument("factor", b.int32, .{
                .presence = .default_value,
                .default_value = .{ .signed = 2 },
            }),
        },
        .{ .new_target_type = b.retained_any },
    ),
    .{
        b.method("scale", .{}, b.int32, .{ .errors = runtime_failures }),
        b.getter("factor", b.int32, .{ .implementation = "getFactor" }),
    },
    .{b.cachedSlot("scaledCached", b.retained_any, .{ .writable = true })},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .parent = b.parentClass(counter_class),
        .upcast = "asCounter",
        .memory_usage = .vm,
    },
);

const shared_counter_class = b.class(
    "SharedCounter",
    b.constructor(
        .{b.argument("initial", b.int32, .{
            .presence = .default_value,
            .default_value = .{ .signed = 0 },
        })},
        .{},
    ),
    .{
        b.method(
            "increment",
            .{b.argument("delta", b.int32, .{
                .presence = .default_value,
                .default_value = .{ .signed = 1 },
            })},
            b.int32,
            .{ .errors = runtime_failures },
        ),
        b.method(
            "incrementAsync",
            .{b.argument("delta", b.int32, .{})},
            b.int32,
            .{
                .errors = async_runtime_failures,
                .completion = .{
                    .retention = .strong,
                    .sender_drop = .leave_pending,
                },
            },
        ),
        b.getter("value", b.int32, .{ .implementation = "getValue" }),
        b.staticMethod(
            "identity",
            .{b.argument("value", b.classRefByName("bindgen_test", "SharedCounter"), .{})},
            b.classRefByName("bindgen_test", "SharedCounter"),
            .{},
        ),
        b.staticMethod(
            "holdForRealmTest",
            .{b.argument("value", b.classRefByName("bindgen_test", "SharedCounter"), .{})},
            b.none,
            .{ .errors = runtime_failures },
        ),
        b.staticMethod(
            "heldForRealmTest",
            .{},
            b.classRefByName("bindgen_test", "SharedCounter"),
            .{ .errors = runtime_failures },
        ),
        b.staticMethod("releaseForRealmTest", .{}, b.none, .{ .errors = runtime_failures }),
        b.staticMethod("releaseHeldOffThreadForTest", .{}, b.none, .{ .errors = runtime_failures }),
        b.staticGetter("destroyedCount", b.size, .{ .implementation = "getDestroyedCount" }),
        b.staticMethod("adoptAfterCallback", .{b.argument("callback", change_context_callback, .{})}, b.classRefByName("bindgen_test", "SharedCounter"), .{}),
        b.staticMethod("wrapAfterCallback", .{
            b.argument("value", b.classRefByName("bindgen_test", "SharedCounter"), .{}),
            b.argument("callback", change_context_callback, .{}),
        }, b.classRefByName("bindgen_test", "SharedCounter"), .{}),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .per_realm,
        .reference_thread = .any,
    },
);

const shared_scaled_counter_class = b.class(
    "SharedScaledCounter",
    b.constructor(
        .{
            b.argument("initial", b.int32, .{
                .presence = .default_value,
                .default_value = .{ .signed = 0 },
            }),
            b.argument("factor", b.int32, .{
                .presence = .default_value,
                .default_value = .{ .signed = 2 },
            }),
        },
        .{},
    ),
    .{
        b.method("scale", .{}, b.int32, .{ .errors = runtime_failures }),
        b.getter("factor", b.int32, .{ .implementation = "getFactor" }),
        b.staticGetter("destroyedCount", b.size, .{ .implementation = "getDestroyedCount" }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .identity = .per_realm,
        .reference_thread = .any,
        .parent = b.parentClass(shared_counter_class),
        .upcast = "asSharedCounter",
    },
);

const clone_box_class = b.class(
    "CloneBox",
    b.constructor(
        .{b.argument("value", b.int32, .{})},
        .{},
    ),
    .{
        b.getter("value", b.int32, .{ .implementation = "getValue" }),
        b.setter("value", b.int32, .{ .implementation = "setValue" }),
        b.method("setSerializationFailure", .{b.argument("enabled", b.boolean, .{})}, b.none, .{}),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .structured_clone = .{
            .tag = 249,
            .serialize_thread = .any,
        },
    },
);

const sweep_box_class = b.class(
    "SweepBox",
    b.constructor(.{}, .{}),
    .{},
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .last_release = b.sweep("Test fixture teardown only frees its native allocation"),
        .constructor_call = b.constructorCall(.{}, b.int32, .{}),
    },
);

const sweep_shared_box_class = b.class(
    "SweepSharedBox",
    b.constructor(.{}, .{}),
    .{},
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .shared,
        .fresh_identity_reason = "the fixture creates one wrapper per independently allocated shared counter",
    },
);

pub const schema = b.moduleWithDeclarations(
    "bindgen_test",
    functions,
    .{ counter_class, scaled_counter_class, shared_counter_class, shared_scaled_counter_class, clone_box_class, sweep_box_class, sweep_shared_box_class },
    engine_shims,
    native_exports,
);
pub const add = schema.function("add");
pub const echo_int8 = schema.function("echoInt8");
pub const echo_int16 = schema.function("echoInt16");
pub const echo_uint16 = schema.function("echoUint16");
pub const echo_uint32 = schema.function("echoUint32");
pub const echo_int64 = schema.function("echoInt64");
pub const echo_uint64 = schema.function("echoUint64");
pub const required_and_optional_arg = schema.function("requiredAndOptionalArg");
pub const echo_test_options = schema.function("echoTestOptions");
pub const echo_dictionary_source = schema.function("echoDictionarySource");
pub const echo_test_scalars = schema.function("echoTestScalars");
pub const round_trip_test_bundle = schema.function("roundTripTestBundle");
pub const visit_test_bundle = schema.function("visitTestBundle");
pub const inspect_node_conversion_order = schema.function("inspectNodeConversionOrder");
pub const inspect_custom_converters = schema.function("inspectCustomConverters");
pub const inspect_lazy_options = schema.function("inspectLazyOptions");
pub const dom_string_length = schema.function("domStringLength");
pub const isolate_engine_string = schema.function("isolateEngineString");
pub const echo_dom_string = schema.function("echoDOMString");
pub const echo_usv_string = schema.function("echoUSVString");
pub const echo_byte_string = schema.function("echoByteString");
pub const strict_usv_string = schema.function("strictUSVString");
pub const strict_byte_string = schema.function("strictByteString");
pub const echo_buffer = schema.function("echoBuffer");
pub const fill_mutable_lease = schema.function("fillMutableLease");
pub const set_mutable_lease_byte = schema.function("setMutableLeaseByte");
pub const inspect_int32_from_js = schema.function("inspectInt32FromJS");
pub const inspect_lease_options_from_js = schema.function("inspectLeaseOptionsFromJS");
pub const inspect_lease_after_callback = schema.function("inspectLeaseAfterCallback");
pub const echo_nullable_buffer = schema.function("echoNullableBuffer");
pub const echo_any = schema.function("echoAny");
pub const invocation_this = schema.function("invocationThis");
pub const invoke_callback = schema.function("invokeCallback");
pub const invoke_owned_callback = schema.function("invokeOwnedCallback");
pub const echo_callback = schema.function("echoCallback");
pub const invoke_composite_callback = schema.function("invokeCompositeCallback");
pub const invoke_string_callback = schema.function("invokeStringCallback");
pub const invoke_nullable_string_callback = schema.function("invokeNullableStringCallback");
pub const invoke_buffer_callback = schema.function("invokeBufferCallback");
pub const invoke_any_callback = schema.function("invokeAnyCallback");
pub const invoke_rest_callback = schema.function("invokeRestCallback");
pub const invoke_typed_rest_callback = schema.function("invokeTypedRestCallback");
pub const invoke_callback_factory = schema.function("invokeCallbackFactory");
pub const invoke_observer = schema.function("invokeObserver");
pub const invoke_integer_callback = schema.function("invokeIntegerCallback");
pub const clamp_integer = schema.function("clampInteger");
pub const validate_integer = schema.function("validateInteger");
pub const validate_node_boolean = schema.function("validateNodeBoolean");
pub const validate_node_number = schema.function("validateNodeNumber");
pub const validate_node_string = schema.function("validateNodeString");
pub const validate_node_strings = schema.function("validateNodeStrings");
pub const default_string = schema.function("defaultString");
pub const default_any = schema.function("defaultAny");
pub const classify_presence = schema.function("classifyPresence");
pub const inspect_rest = schema.function("inspectRest");
pub const inspect_string_rest = schema.function("inspectStringRest");
pub const echo_string_rest = schema.function("echoStringRest");
pub const echo_buffer_rest = schema.function("echoBufferRest");
pub const echo_aggregate_rest = schema.function("echoAggregateRest");
pub const echo_nullable_int = schema.function("echoNullableInt");
pub const classify_nullable_presence = schema.function("classifyNullablePresence");
pub const echo_nullable_string = schema.function("echoNullableString");
pub const echo_nullable_any = schema.function("echoNullableAny");
pub const read_counter_value = schema.function("readCounterValue");
pub const inspect_counter_wrapper_handles = schema.function("inspectCounterWrapperHandles");
pub const read_shared_counter_value = schema.function("readSharedCounterValue");
pub const domain_error = schema.function("domainError");
pub const async_result = schema.function("asyncResult");
pub const async_echo = schema.function("asyncEcho");
pub const async_utf8_strings = schema.function("asyncUTF8Strings");
pub const async_materialized = schema.function("asyncMaterialized");
pub const async_weak_echo = schema.function("asyncWeakEcho");
pub const async_pending_echo = schema.function("asyncPendingEcho");
pub const set_transfer_allocation_failure_countdown = schema.function("setTransferAllocationFailureCountdown");
pub const set_weak_allocation_failure_countdown = schema.function("setWeakAllocationFailureCountdown");
pub const set_root_allocation_failure_countdown = schema.function("setRootAllocationFailureCountdown");
pub const read_index_via_engine = schema.function("readIndexViaEngine");
pub const sum_integer_widths_via_engine = schema.function("sumIntegerWidthsViaEngine");
pub const engine_buffer_sequence_length_via_engine = schema.function("engineBufferSequenceLengthViaEngine");
pub const node_path_length_via_engine = schema.function("nodePathLengthViaEngine");
pub const builtin_add = schema.function("builtinAdd");
pub const cpp_add = schema.function("cppAdd");
pub const cpp_overload = schema.function("cppOverload");
pub const cpp_echo_string = schema.function("cppEchoString");
pub const cpp_external_ref_present = schema.function("cppExternalRefPresent");
pub const cpp_external_ref_sequence_length = schema.function("cppExternalRefSequenceLength");
pub const cpp_dictionary_source_sequence_length = schema.function("cppDictionarySourceSequenceLength");
pub const cpp_optional_union_present = schema.function("cppOptionalUnionPresent");
pub const cpp_lazy_string_length = schema.function("cppLazyStringLength");
pub const cpp_buffer_length = schema.function("cppBufferLength");
pub const cpp_classify_nullable_presence = schema.function("cppClassifyNullablePresence");
pub const cpp_classify_nullable_field_presence = schema.function("cppClassifyNullableFieldPresence");
pub const cpp_inspect_rest = schema.function("cppInspectRest");
pub const cpp_echo_buffer = schema.function("cppEchoBuffer");
pub const cpp_sum_integer_widths = schema.function("cppSumIntegerWidths");
pub const cpp_call_zig_export = schema.function("cppCallZigExport");
pub const cpp_call_zig_native_string = schema.function("cppCallZigNativeString");
pub const get_index = schema.engineShim("getIndex");
pub const sum_integer_widths = schema.engineShim("sumIntegerWidths");
pub const buffer_sequence = schema.engineShim("bufferSequence");
pub const node_path_length = schema.engineShim("nodePathLength");
pub const multiply_add = schema.nativeExport("multiplyAdd");
pub const native_string_buffer_handle = schema.nativeExport("nativeStringBufferHandle");
pub const optional_native_string = schema.nativeExport("optionalNativeString");
pub const native_string_sequence_length = schema.nativeExport("nativeStringSequenceLength");
pub const counter = schema.class("Counter");
pub const scaled_counter = schema.class("ScaledCounter");
pub const shared_counter = schema.class("SharedCounter");
pub const shared_scaled_counter = schema.class("SharedScaledCounter");
pub const clone_box = schema.class("CloneBox");
pub const sweep_box = schema.class("SweepBox");
pub const sweep_shared_box = schema.class("SweepSharedBox");
