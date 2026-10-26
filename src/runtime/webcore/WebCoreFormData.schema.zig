const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const native_form_data = @import("binding_schema_dom_form_data");

const form_data_blob_input = b.classRefByName("Blob", "Blob");
const form_data_blob_value = b.classValueByName("Blob", "Blob");
const form_data_wrapper = b.classValueByName("WebCoreFormData", "FormData");
const form_data_entry_value = b.unionType("FormDataEntryValue", .{
    b.unionMember("string", b.usv_string),
    b.unionMember("blob", b.classRefByName("Blob", "Blob")),
}, .{ .cpp_name = "FormDataEntryValue" });
const form_data_get_result = b.optionalNullish(form_data_entry_value);
const form_data_get_all_result = b.sequence(form_data_entry_value);
const form_data_callback_entry = b.dictionary("FormDataCallbackEntry", .{
    b.dictionaryField("key", b.usv_string, .{ .required = true }),
    b.dictionaryField("value", form_data_entry_value, .{ .required = true }),
});
const form_data_iterator_item = b.unionType("FormDataIteratorItem", .{
    b.unionMember("entry", b.sequence(form_data_entry_value)),
    b.unionMember("value", form_data_entry_value),
}, .{ .cpp_name = "FormDataIteratorItem" });
const form_data_iterator_result = b.dictionaryWithOptions(
    "FormDataIteratorResult",
    .{
        b.dictionaryField("value", b.optionalUndefined(form_data_iterator_item), .{ .required = true }),
        b.dictionaryField("done", b.boolean, .{ .required = true }),
    },
    .{ .cpp_name = "FormDataIteratorResultDictionary" },
);
const form_data_iterator_kind = b.enumerationWithOptions("FormDataIteratorKind", .{
    b.enumerationValue("entries", "entries"),
    b.enumerationValue("keys", "keys"),
    b.enumerationValue("values", "values"),
}, .{
    .cpp_name = "FormDataIteratorKind",
});
const form_data_iterator_class = b.classWithDataProperties(
    "FormDataIterator",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("next", .{}, form_data_iterator_result, .{ .length = 0, .configurable = true, .this_value_type = b.this_class_ref }),
    },
    .{b.cachedSlot("form", b.classRefByName("WebCoreFormData", "FormData"), .{ .writable = true, .exposed = false })},
    .{b.dataProperty("toStringTag", .{ .string = "FormData Iterator" }, .{ .symbol = .to_string_tag, .enumerable = false })},
    .{
        .backend = .zig,
        .profile = .webidl,
        .display_name = "FormData Iterator",
        .ownership = .unique,
        .identity = .fresh,
        .prototype_base = .iterator,
    },
);
const form_data_iterator_value = b.classRefByName("WebCoreFormData", "FormDataIterator");
const form_data_json_value = b.unionType("FormDataJSONValue", .{
    b.unionMember("value", form_data_entry_value),
    b.unionMember("values", b.sequence(form_data_entry_value)),
}, .{ .cpp_name = "FormDataJSONValue" });
const form_data_json_result = b.recordWithOptions(
    b.usv_string,
    form_data_json_value,
    .{ .result_to_string_tag = "FormData" },
);
const form_data_for_each_callback = b.callback("FormDataForEachCallback", .{
    b.argument("value", form_data_entry_value, .{}),
    b.argument("key", b.usv_string, .{}),
    b.argument("formData", b.classRefByName("WebCoreFormData", "FormData"), .{}),
}, b.none, .{
    .receiver = b.optionalUndefined(b.invocation_any),
});

const form_data_from_input = b.unionType("FormDataFromInput", .{
    b.unionMember("value", blob_types.or_string_or_buffer),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });
const form_data_from_boundary = b.unionType("FormDataFromBoundary", .{
    b.unionMember("value", archetypes.string_or_buffer),
    b.unionMember("invalid", b.discarded),
}, .{ .ordered = true, .fallback_member = "invalid" });
const form_data_from_errors = b.domainErrors(.{
    b.domainError("string_too_long", b.none, .{
        .class = .generic_error,
        .code = "ERR_STRING_TOO_LONG",
        .message = .{ .literal = "Cannot create a string longer than 2^32-1 characters" },
    }),
    b.domainError("empty_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "input must not be empty" },
    }),
    b.domainError("invalid_input", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "input must be a string or ArrayBufferView" },
    }),
    b.domainError("invalid_boundary", b.none, .{
        .class = .type_error,
        .code = "ERR_INVALID_ARG_TYPE",
        .message = .{ .literal = "boundary must be a string or ArrayBufferView" },
    }),
    b.domainError("parse_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});
const form_data_instance = b.classRefByName("WebCoreFormData", "FormData");

const form_data_class = b.class(
    "FormData",
    b.constructor(.{}, .{ .length = 0 }),
    .{
        b.method("append", b.overloads(.{
            b.overloadCase("blob", .{
                b.argument("name", b.usv_string, .{}),
                b.argument("value", form_data_blob_input, .{}),
                b.argument("filename", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
            }),
            b.overloadCase("string", .{
                b.argument("name", b.usv_string, .{}),
                b.argument("value", b.usv_string, .{}),
            }),
        }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "string" }), b.none, .{ .length = 2, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("delete", .{b.argument("name", b.usv_string, .{})}, b.none, .{
            .length = 1,
            .configurable = true,
            .this_value_type = b.this_class_ref,
        }),
        b.method("get", .{b.argument("name", b.usv_string, .{})}, form_data_get_result, .{
            .length = 1,
            .configurable = true,
            .this_value_type = b.this_class_ref,
        }),
        b.method("getAll", .{b.argument("name", b.usv_string, .{})}, form_data_get_all_result, .{
            .length = 1,
            .configurable = true,
            .this_value_type = b.this_class_ref,
        }),
        b.method("has", .{b.argument("name", b.usv_string, .{})}, b.boolean, .{
            .length = 1,
            .configurable = true,
        }),
        b.method("set", b.overloads(.{
            b.overloadCase("blob", .{
                b.argument("name", b.usv_string, .{}),
                b.argument("value", form_data_blob_input, .{}),
                b.argument("filename", b.usv_string, .{ .presence = .optional, .missing = .undefined }),
            }),
            b.overloadCase("string", .{
                b.argument("name", b.usv_string, .{}),
                b.argument("value", b.usv_string, .{}),
            }),
        }, .{ .ordered = true, .accept_extra_arguments = true, .fallback_case = "string" }), b.none, .{ .length = 2, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("entries", .{}, form_data_iterator_value, .{
            .backend = .zig,
            .this_value_type = b.this_class_ref,
            .length = 0,
            .configurable = true,
            .aliases = &.{b.memberSymbolAlias(.iterator, .{ .enumerable = false })},
        }),
        b.method("keys", .{}, form_data_iterator_value, .{ .backend = .zig, .length = 0, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("values", .{}, form_data_iterator_value, .{ .backend = .zig, .length = 0, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("forEach", .{
            b.argument("callback", form_data_for_each_callback, .{}),
            b.argument("thisArg", b.any, .{ .presence = .optional, .missing = .undefined }),
        }, b.none, .{ .backend = .zig, .implementation = "bindForEach", .length = 1, .configurable = true, .this_value_type = b.this_class_ref }),
        b.method("toJSON", .{}, form_data_json_result, .{
            .length = 1,
            .native_reference = true,
            .this_value_type = b.this_class_ref,
        }),
        b.method("inspectCustom", .{}, form_data_json_result, .{
            .length = 0,
            .symbol = .inspect_custom,
            .this_value_type = b.this_class_ref,
            .enumerable = false,
        }),
        b.getter("length", b.size, .{ .implementation = "getLength", .enumerable = false }),
        b.staticMethod("from", .{
            b.argument("input", form_data_from_input, .{ .presence = .optional, .missing = .undefined_or_null }),
            b.argument("boundary", form_data_from_boundary, .{ .presence = .optional, .missing = .undefined_or_null }),
        }, form_data_instance, .{
            .backend = .zig,
            .profile = .exact,
            .errors = form_data_from_errors,
            .implementation = "fromMultipartData",
            .length = 1,
        }),
    },
    .{b.cachedSlot("files", b.js_map, .{ .writable = true, .exposed = false })},
    .{
        .constructor_call_error = archetypes.constructorNewSuggestion("FormData", "ERR_ILLEGAL_CONSTRUCTOR"),
        .backend = .zig,
        .profile = .webidl,
        .ownership = .unique,
        .identity = .fresh,
        .memory_usage = .vm,
    },
);

const form_data_engine_shims = .{
    b.engineShim("formDataAppendString", .{
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
        b.argument("value", b.usv_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("formDataAppendBlob", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("original", form_data_blob_value, .{}),
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
        b.argument("value", form_data_blob_input, .{}),
        b.argument("filename", b.optional(b.usv_string), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("formDataDelete", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("formDataGet", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
    }, form_data_get_result, .current_realm_throwing),
    b.engineShim("formDataGetAll", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
    }, form_data_get_all_result, .current_realm_throwing),
    b.engineShim("formDataHas", .{
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
    }, b.boolean, .vm_thread_nonthrowing),
    b.engineShim("formDataSetString", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
        b.argument("value", b.usv_string, .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("formDataSetBlob", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("original", form_data_blob_value, .{}),
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.usv_string, .{}),
        b.argument("value", form_data_blob_input, .{}),
        b.argument("filename", b.optional(b.usv_string), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("formDataJSON", .{
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("wrapper", form_data_wrapper, .{}),
    }, form_data_json_result, .current_realm_throwing),
    b.engineShim("formDataCount", .{b.argument("form", native_form_data.dom_form_data, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("formDataIteratorEntry", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("iterator", native_form_data.iterator_handle, .{}),
    }, b.optional(form_data_callback_entry), .current_realm_throwing),
    b.engineShim("formDataIteratorNext", .{
        b.argument("wrapper", form_data_wrapper, .{}),
        b.argument("iterator", native_form_data.iterator_handle, .{}),
        b.argument("kind", form_data_iterator_kind, .{}),
    }, form_data_iterator_result, .current_realm_throwing),
    b.engineShim("formDataCreate", .{}, native_form_data.owned_form_data, .vm_thread_allocating),
    b.engineShim("formDataCreateFromURLQuery", .{b.argument("query", b.buffer(.copy), .{})}, native_form_data.owned_form_data, .vm_thread_allocating),
    b.engineShim("formDataAppend", .{
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.buffer(.copy), .{}),
        b.argument("value", b.buffer(.copy), .{}),
    }, b.none, .current_realm_throwing),
    b.engineShim("formDataAppendFile", .{
        b.argument("form", native_form_data.dom_form_data, .{}),
        b.argument("name", b.buffer(.copy), .{}),
        b.argument("value", b.buffer(.copy), .{}),
        b.argument("filename", b.buffer(.copy), .{}),
        b.argument("contentType", b.buffer(.copy), .{}),
    }, b.none, .current_realm_throwing),
};

pub const schema = b.moduleWithClassesAndEngineShims(
    "WebCoreFormData",
    .{},
    .{ form_data_iterator_class, form_data_class },
    form_data_engine_shims,
);
pub const form_data_iterator = schema.class("FormDataIterator");
pub const form_data = schema.class("FormData");
