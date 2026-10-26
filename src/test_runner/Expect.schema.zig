const std = @import("std");
const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const any_missing_argument: b.ConversionFailure = .{
    .kind = .generic_error,
    .message = "any() expects to be passed a constructor function. Please pass one or use anything() to match any object.",
};
const any_constructor_value = b.brandedValueWithBrand(b.brandOf(archetypes.constructor_value), .{
    .no_match_error = .{
        .kind = .generic_error,
        .message = "expect.any(constructor)\n\nExpected a constructor\n",
    },
});
const string_containing_value = b.brandedValueWithBrand(b.brandOf(archetypes.string_like_value), .{
    .no_match_error = .{
        .kind = .generic_error,
        .message = "expect.stringContaining(string)\n\nExpected a string\n",
    },
});

const string_or_regexp_value = b.brandedValueWithBrand(b.cppBrand("StringOrRegExpValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isStringOrRegExp",
    .header = "BindgenTypePredicates.h",
}, "string | RegExp"), .{
    .error_kind = .type,
    .expectation = "a string or RegExp",
    .node_requirement = "string or RegExp",
});

const comparable_number = b.unionType("ExpectComparableNumber", .{
    b.unionMember("number", b.double),
    b.unionMember("bigint", b.js_big_int),
}, .{ .ordered = true });

const unreachable_input = b.optionalNullish(b.unionType("ExpectUnreachableInput", .{
    b.unionMember("message", b.dom_string),
    b.unionMember("thrown", b.engine_value),
}, .{ .ordered = true, .fallback_member = "thrown" }));

const custom_matcher_pass = b.unionType("ExpectMatcherPassResult", .{
    b.unionMember("object", b.dictionary("ExpectMatcherPass", .{
        b.dictionaryField("pass", b.boolean, .{ .missing = .absent, .boolean_conversion = .truthy }),
    })),
    b.unionMember("invalid", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "invalid" });
const custom_matcher_message = b.unionType("ExpectMatcherMessage", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("callback", archetypes.callable_value),
    b.unionMember("invalid", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "invalid" });
const custom_matcher_message_record = b.dictionary("ExpectMatcherMessageRecord", .{
    b.dictionaryField("message", custom_matcher_message, .{ .missing = .absent }),
});

const integer_value = b.brandedValueWithBrand(b.cppBrand("ExpectIntegerValue", .{
    .symbol = "Bun::Bindgen::TypePredicates::isAnyInt",
    .header = "BindgenTypePredicates.h",
}, "number"), .{
    .error_kind = .type,
    .expectation = "an integer",
    .node_requirement = "integer",
});

const javascript_type = b.enumerationWithOptions("ExpectJavaScriptType", .{
    b.enumerationValue("function", "function"),
    b.enumerationValue("object", "object"),
    b.enumerationValue("bigint", "bigint"),
    b.enumerationValue("boolean", "boolean"),
    b.enumerationValue("number", "number"),
    b.enumerationValue("string", "string"),
    b.enumerationValue("symbol", "symbol"),
    b.enumerationValue("undefined", "undefined"),
}, .{ .invalid_value_error = .type });

const snapshot_arguments = b.overloads(.{
    b.overloadCase("properties_hint", .{
        b.argument("properties", b.js_object, .{}),
        b.argument("hint", b.dom_string, .{}),
    }),
    b.overloadCase("hint", .{b.argument("hint", b.dom_string, .{})}),
    b.overloadCase("properties", .{b.argument("properties", b.js_object, .{})}),
    b.overloadCase("empty", .{}),
}, .{ .ordered = true });

const inline_snapshot_properties = b.brandedValueWithBrand(b.brandOf(b.js_object), .{
    .no_match_error = .{
        .kind = .generic_error,
        .message = "expect(received).toMatchInlineSnapshot(properties, hint)\n\nMatcher error: Expected properties must be an object\n",
    },
});

// Non-string saved values request creation; the source updater validates that the argument can be replaced.
const inline_snapshot_text = b.unionType("ExpectInlineSnapshotText", .{
    b.unionMember("text", b.dom_string),
    b.unionMember("absent", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "absent" });

const inline_snapshot_arguments = b.overloads(.{
    b.overloadCase("properties_snapshot", .{
        b.argument("properties", inline_snapshot_properties, .{}),
        b.argument("snapshot", inline_snapshot_text, .{}),
        b.rest("ignored", b.discarded),
    }),
    b.overloadCase("snapshot", .{b.argument("snapshot", b.dom_string, .{})}),
    b.overloadCase("properties", .{b.argument("properties", inline_snapshot_properties, .{})}),
    b.overloadCase("empty", .{}),
}, .{ .ordered = true });

const exception_snapshot_arguments = b.overloads(.{
    b.overloadCase("snapshot", .{b.argument("snapshot", b.dom_string, .{})}),
    b.overloadCase("empty", .{}),
}, .{ .ordered = true });

const throw_expectation = b.unionType("ExpectThrowExpectation", .{
    b.unionMember("string_or_regexp", string_or_regexp_value),
    b.unionMember("object", b.js_object),
    b.unionMember("undefined_value", b.undefined_literal),
}, .{ .ordered = true });

const throw_arguments = b.overloads(.{
    b.overloadCase("expected", .{b.argument("expected", throw_expectation, .{})}),
    b.overloadCase("empty", .{}),
}, .{ .ordered = true });

fn optionalEngineValue(comptime name: []const u8) b.Argument {
    return b.argument(name, b.engine_value, .{ .presence = .optional, .missing = .omitted });
}

fn engineValueRest(comptime name: []const u8) b.Argument {
    return b.rest(name, b.engine_value);
}

fn positiveCallIndex(comptime name: []const u8) b.Argument {
    return b.argument(name, b.uint32, .{
        .integer_conversion = .{ .enforce_range = .{ .min = 1, .max = std.math.maxInt(u32) } },
    });
}

pub const wrapping_function_value = b.brandedValueWithBrand(b.cppDynamicCastBrand("ExpectWrappingFunctionValue", .{
    .type_name = "Zig::JSWrappingFunction",
    .header = "JSWrappingFunction.h",
}, "Function"), .{});

const matcher_hint_options = b.dictionaryWithOptions("MatcherHintOptions", .{
    b.dictionaryField("is_not", b.boolean, .{ .boolean_conversion = .truthy, .js_name = "isNot" }),
    b.dictionaryField("comment", archetypes.coerced_dom_string, .{}),
    b.dictionaryField("promise", archetypes.coerced_dom_string, .{}),
    b.dictionaryField("second_argument", archetypes.coerced_dom_string, .{ .js_name = "secondArgument" }),
}, .{ .user_facing_name = "matcher hint options" });

const asymmetric_matcher_reference = b.unionType("ExpectAsymmetricMatcherReference", .{
    b.unionMember("custom", b.classRefByName("Expect", "ExpectCustomAsymmetricMatcher")),
    b.unionMember("any", b.classRefByName("Expect", "ExpectAny")),
    b.unionMember("anything", b.classRefByName("Expect", "ExpectAnything")),
    b.unionMember("string_matching", b.classRefByName("Expect", "ExpectStringMatching")),
    b.unionMember("close_to", b.classRefByName("Expect", "ExpectCloseTo")),
    b.unionMember("object_containing", b.classRefByName("Expect", "ExpectObjectContaining")),
    b.unionMember("string_containing", b.classRefByName("Expect", "ExpectStringContaining")),
    b.unionMember("array_containing", b.classRefByName("Expect", "ExpectArrayContaining")),
}, .{ .ordered = true });

const flags_and_processed_value = b.dictionary("ExpectFlagsAndProcessedValue", .{
    b.dictionaryField("value", b.optional(b.engine_value), .{ .required = true }),
    b.dictionaryField("flags", b.uint8, .{ .required = true }),
});

const asymmetric_matcher_constructor_type = b.enumerationWithOptions("AsymmetricMatcherConstructorType", .{
    b.enumerationValue("none", "none"),
    b.enumerationValue("Symbol", "symbol"),
    b.enumerationValue("String", "string"),
    b.enumerationValue("Object", "object"),
    b.enumerationValue("Array", "array"),
    b.enumerationValue("BigInt", "bigint"),
    b.enumerationValue("Boolean", "boolean"),
    b.enumerationValue("Number", "number"),
    b.enumerationValue("Promise", "promise"),
    b.enumerationValue("InstanceOf", "instanceof"),
}, .{ .cpp_name = "AsymmetricMatcherConstructorType" });

const native_exports = .{
    b.nativeExportWithOptions("expectCustomAsymmetricMatcherExecute", .{
        b.argument("matcher", b.classRefByName("Expect", "ExpectCustomAsymmetricMatcher"), .{}),
        b.argument("received", b.engine_value, .{}),
    }, b.boolean, .current_realm_throwing),
    b.nativeExportWithOptions("expectMatcherUtilsCreate", .{}, b.classRefByName("Expect", "ExpectMatcherUtils"), .current_realm_throwing),
    b.nativeExportWithOptions("readFlagsAndProcessPromise", .{
        b.argument("instanceValue", asymmetric_matcher_reference, .{}),
        b.argument("value", b.engine_value, .{}),
    }, flags_and_processed_value, .current_realm_throwing),
    b.nativeExportWithOptions("expectAnyConstructorValue", .{b.argument("matcher", b.classRefByName("Expect", "ExpectAny"), .{})}, any_constructor_value, .current_realm_nonthrowing),
    b.nativeExportWithOptions("expectStringContainingValue", .{b.argument("matcher", b.classRefByName("Expect", "ExpectStringContaining"), .{})}, string_containing_value, .current_realm_nonthrowing),
    b.nativeExportWithOptions("expectStringMatchingValue", .{b.argument("matcher", b.classRefByName("Expect", "ExpectStringMatching"), .{})}, string_or_regexp_value, .current_realm_nonthrowing),
    b.nativeExportWithOptions("expectArrayContainingValue", .{b.argument("matcher", b.classRefByName("Expect", "ExpectArrayContaining"), .{})}, b.js_array, .current_realm_nonthrowing),
    b.nativeExportWithOptions("expectObjectContainingValue", .{b.argument("matcher", b.classRefByName("Expect", "ExpectObjectContaining"), .{})}, b.js_object, .current_realm_nonthrowing),
    b.nativeExportWithOptions("expectCloseToMatches", .{
        b.argument("matcher", b.classRefByName("Expect", "ExpectCloseTo"), .{}),
        b.argument("received", b.double, .{}),
    }, b.boolean, .current_realm_nonthrowing),
};

const matcher_context = b.class(
    "ExpectMatcherContext",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method(
            "equals",
            .{
                optionalEngineValue("received"),
                optionalEngineValue("expected"),
                b.argument("customTesters", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted }),
            },
            b.boolean,
            .{
                .length = 3,
            },
        ),
        b.getter("expand", b.boolean, .{ .implementation = "getExpand" }),
        b.getter("isNot", b.boolean, .{ .implementation = "getIsNot" }),
        b.getter("promise", b.dom_string, .{ .implementation = "getPromise" }),
        b.getter("utils", b.classRefByName("Expect", "ExpectMatcherUtils"), .{
            .implementation = "getUtils",
        }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const matcher_utils = b.class(
    "ExpectMatcherUtils",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method(
            "EXPECTED_COLOR",
            .{optionalEngineValue("value")},
            b.dom_string,
            .{ .implementation = "printExpectedColor", .length = 1 },
        ),
        b.method(
            "matcherHint",
            .{
                b.argument("matcherName", b.dom_string, .{ .presence = .optional, .missing = .omitted }),
                optionalEngineValue("received"),
                optionalEngineValue("expected"),
                b.argument("options", b.optionalNullish(matcher_hint_options), .{ .presence = .optional, .missing = .omitted }),
            },
            b.dom_string,
            .{ .length = 1 },
        ),
        b.method(
            "printExpected",
            .{optionalEngineValue("value")},
            b.dom_string,
            .{ .length = 1 },
        ),
        b.method(
            "printReceived",
            .{optionalEngineValue("value")},
            b.dom_string,
            .{ .length = 1 },
        ),
        b.method(
            "RECEIVED_COLOR",
            .{optionalEngineValue("value")},
            b.dom_string,
            .{ .implementation = "printReceivedColor", .length = 1 },
        ),
        b.method(
            "stringify",
            .{optionalEngineValue("value")},
            b.dom_string,
            .{ .length = 1 },
        ),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

const custom_asymmetric_matcher = b.class(
    "ExpectCustomAsymmetricMatcher",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method(
            "asymmetricMatch",
            .{optionalEngineValue("received")},
            b.boolean,
            .{
                .length = 1,
            },
        ),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

fn asymmetricMatcherClass(comptime name: []const u8, comptime slots: anytype) b.Class {
    return b.class(
        name,
        b.constructor(.{}, .{ .exposure = .never }),
        .{},
        slots,
        .{
            .backend = .zig,
            .profile = .exact,
            .ownership = .unique,
            .identity = .fresh,
        },
    );
}

const anything = asymmetricMatcherClass("ExpectAnything", .{});
const any_matcher = asymmetricMatcherClass("ExpectAny", .{});
const string_matching = asymmetricMatcherClass("ExpectStringMatching", .{});
const close_to = asymmetricMatcherClass("ExpectCloseTo", .{});
const object_containing = asymmetricMatcherClass("ExpectObjectContaining", .{});
const string_containing = asymmetricMatcherClass("ExpectStringContaining", .{});
const array_containing = asymmetricMatcherClass("ExpectArrayContaining", .{});

fn simpleExpectMethod(comptime name: []const u8) b.ClassMember {
    return matcherMethodWithArguments(name, .{}, 0);
}

fn noArgumentMatcherMethod(comptime name: []const u8, comptime canonical_name: []const u8) b.ClassMember {
    return b.method(name, .{b.argument("unexpected", b.discardAny(.presence), .{
        .presence = .optional,
        .missing = .undefined,
    })}, b.none, .{
        .implementation = "bind_instance_" ++ name,
        .length = 0,
        .this_value_type = b.this_class_ref,
        .errors = b.domainErrors(.{b.domainError("unexpected_argument", b.none, .{
            .class = .type_error,
            .code = "ERR_INVALID_ARG_TYPE",
            .message = .{ .literal = canonical_name ++ "() must not have an argument" },
        })}),
    });
}

fn undefinedDefaultEngineValue(comptime name: []const u8) b.Argument {
    return b.argument(name, b.engine_value, .{ .presence = .default_value, .default_value = .undefined });
}

fn matcherMessage(comptime name: []const u8) b.Argument {
    return b.argument("message", b.strictString(b.dom_string, .{
        .kind = .{ .code = "ERR_INVALID_ARG_TYPE" },
        .message = "Expected message to be a string for '" ++ name ++ "'.",
    }), .{ .presence = .optional, .missing = .omitted });
}

fn matcherMethodWithArguments(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime length: u16,
) b.ClassMember {
    return b.method(name, arguments, b.none, .{
        .implementation = "bind_instance_" ++ name,
        .length = length,
        .this_value_type = b.this_class_ref,
    });
}

fn matcherCallerSourceMethodWithArguments(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime length: u16,
) b.ClassMember {
    return b.method(name, arguments, b.none, .{
        .implementation = "bind_instance_" ++ name,
        .length = length,
        .this_value_type = b.this_class_ref,
        .caller_source_location = true,
    });
}

fn expectGetter(comptime name: []const u8, comptime _: []const u8) b.ClassMember {
    return b.getter(name, b.this_class_ref, .{
        .implementation = "bind_instance_" ++ name,
        .this_value_type = b.this_class_ref,
    });
}

fn expectGlobalMethod(
    comptime name: []const u8,
    comptime arguments: anytype,
    comptime result: b.Type,
    comptime length: u16,
) b.ClassMember {
    return b.staticMethod(name, arguments, result, .{
        .implementation = "bind_static_" ++ name,
        .length = length,
    });
}

fn expectGlobalGetter(comptime name: []const u8) b.ClassMember {
    return b.staticGetter(name, b.classRefByName("Expect", "ExpectStatic"), .{
        .implementation = "bind_static_" ++ name,
    });
}

const expect_class = b.class(
    "Expect",
    b.illegalConstructor(),
    .{
        matcherMethodWithArguments("fail", .{matcherMessage("fail")}, 1),
        matcherMethodWithArguments("lastCalledWith", .{engineValueRest("expected")}, 0),
        matcherMethodWithArguments("lastReturnedWith", .{undefinedDefaultEngineValue("expected")}, 1),
        expectGetter("not", "getNot"),
        matcherMethodWithArguments("nthCalledWith", .{ positiveCallIndex("index"), engineValueRest("expected") }, 0),
        matcherMethodWithArguments(
            "nthReturnedWith",
            .{ positiveCallIndex("index"), undefinedDefaultEngineValue("expected") },
            1,
        ),
        matcherMethodWithArguments("pass", .{matcherMessage("pass")}, 1),
        expectGetter("rejects", "getRejects"),
        expectGetter("resolves", "getResolves"),
        matcherMethodWithArguments("toBe", .{b.argument("expected", b.engine_value, .{})}, 1),
        simpleExpectMethod("toBeArray"),
        matcherMethodWithArguments("toBeArrayOfSize", .{b.argument("size", b.int64, .{})}, 1),
        simpleExpectMethod("toBeBoolean"),
        noArgumentMatcherMethod("toBeCalled", "toHaveBeenCalled"),
        matcherMethodWithArguments("toBeCalledTimes", .{b.argument("expected", b.uint32, .{})}, 1),
        matcherMethodWithArguments("toBeCalledWith", .{engineValueRest("expected")}, 0),
        matcherMethodWithArguments(
            "toBeCloseTo",
            .{
                b.argument("expected", b.double, .{}),
                b.argument("precision", b.double, .{ .presence = .optional, .missing = .omitted }),
            },
            1,
        ),
        simpleExpectMethod("toBeDate"),
        simpleExpectMethod("toBeDefined"),
        simpleExpectMethod("toBeEmpty"),
        simpleExpectMethod("toBeEmptyObject"),
        simpleExpectMethod("toBeEven"),
        simpleExpectMethod("toBeFalse"),
        simpleExpectMethod("toBeFalsy"),
        simpleExpectMethod("toBeFinite"),
        simpleExpectMethod("toBeFunction"),
        matcherMethodWithArguments("toBeGreaterThan", .{b.argument("expected", comparable_number, .{})}, 1),
        matcherMethodWithArguments("toBeGreaterThanOrEqual", .{b.argument("expected", comparable_number, .{})}, 1),
        matcherMethodWithArguments("toBeInstanceOf", .{b.argument("constructor", archetypes.constructor_value, .{})}, 1),
        simpleExpectMethod("toBeInteger"),
        matcherMethodWithArguments("toBeLessThan", .{b.argument("expected", comparable_number, .{})}, 1),
        matcherMethodWithArguments("toBeLessThanOrEqual", .{b.argument("expected", comparable_number, .{})}, 1),
        simpleExpectMethod("toBeNaN"),
        simpleExpectMethod("toBeNegative"),
        simpleExpectMethod("toBeNil"),
        simpleExpectMethod("toBeNull"),
        simpleExpectMethod("toBeNumber"),
        simpleExpectMethod("toBeObject"),
        simpleExpectMethod("toBeOdd"),
        matcherMethodWithArguments("toBeOneOf", .{b.argument("values", b.engine_value, .{})}, 1),
        simpleExpectMethod("toBePositive"),
        simpleExpectMethod("toBeString"),
        simpleExpectMethod("toBeSymbol"),
        simpleExpectMethod("toBeTrue"),
        simpleExpectMethod("toBeTruthy"),
        matcherMethodWithArguments("toBeTypeOf", .{b.argument("expected", javascript_type, .{})}, 1),
        simpleExpectMethod("toBeUndefined"),
        simpleExpectMethod("toBeValidDate"),
        matcherMethodWithArguments(
            "toBeWithin",
            .{
                b.argument("start", b.double, .{}),
                b.argument("end", b.double, .{}),
            },
            2,
        ),
        matcherMethodWithArguments("toContain", .{b.argument("expected", b.engine_value, .{})}, 1),
        matcherMethodWithArguments("toContainAllKeys", .{b.argument("expected", b.js_array, .{})}, 1),
        matcherMethodWithArguments("toContainAllValues", .{b.argument("expected", b.js_array, .{})}, 1),
        matcherMethodWithArguments("toContainAnyKeys", .{b.argument("expected", b.js_array, .{})}, 1),
        matcherMethodWithArguments("toContainAnyValues", .{b.argument("expected", b.js_array, .{})}, 1),
        matcherMethodWithArguments("toContainEqual", .{b.argument("expected", b.engine_value, .{})}, 1),
        matcherMethodWithArguments("toContainKey", .{b.argument("expected", b.engine_value, .{})}, 1),
        matcherMethodWithArguments("toContainKeys", .{b.argument("expected", b.js_array, .{})}, 1),
        matcherMethodWithArguments("toContainValue", .{b.argument("expected", b.engine_value, .{})}, 1),
        matcherMethodWithArguments("toContainValues", .{b.argument("expected", b.js_array, .{})}, 1),
        matcherMethodWithArguments("toEndWith", .{b.argument("expected", archetypes.string_value, .{})}, 1),
        matcherMethodWithArguments("toEqual", .{b.argument("expected", b.engine_value, .{})}, 1),
        matcherMethodWithArguments("toEqualIgnoringWhitespace", .{b.argument("expected", b.brandedValueWithBrand(b.brandOf(archetypes.string_value), .{
            .no_match_error = .{ .kind = .generic_error, .message = "toEqualIgnoringWhitespace() requires argument to be a string" },
        }), .{})}, 1),
        noArgumentMatcherMethod("toHaveBeenCalled", "toHaveBeenCalled"),
        simpleExpectMethod("toHaveBeenCalledOnce"),
        matcherMethodWithArguments("toHaveBeenCalledTimes", .{b.argument("expected", b.uint32, .{})}, 1),
        matcherMethodWithArguments("toHaveBeenCalledWith", .{engineValueRest("expected")}, 0),
        matcherMethodWithArguments("toHaveBeenLastCalledWith", .{engineValueRest("expected")}, 0),
        matcherMethodWithArguments("toHaveBeenNthCalledWith", .{ positiveCallIndex("index"), engineValueRest("expected") }, 0),
        matcherMethodWithArguments("toHaveLastReturnedWith", .{undefinedDefaultEngineValue("expected")}, 1),
        matcherMethodWithArguments("toHaveLength", .{b.argument("expected", b.uint64, .{})}, 1),
        matcherMethodWithArguments(
            "toHaveNthReturnedWith",
            .{ positiveCallIndex("index"), undefinedDefaultEngineValue("expected") },
            1,
        ),
        matcherMethodWithArguments(
            "toHaveProperty",
            .{
                b.argument("path", archetypes.property_path, .{}),
                b.argument("expected", b.engine_value, .{ .presence = .optional, .missing = .omitted }),
            },
            2,
        ),
        noArgumentMatcherMethod("toHaveReturned", "toHaveReturned"),
        matcherMethodWithArguments("toHaveReturnedTimes", .{b.argument("expected", b.uint32, .{})}, 1),
        matcherMethodWithArguments("toHaveReturnedWith", .{undefinedDefaultEngineValue("expected")}, 1),
        matcherMethodWithArguments("toInclude", .{b.argument("expected", archetypes.string_value, .{})}, 1),
        matcherMethodWithArguments(
            "toIncludeRepeated",
            .{
                b.argument("substring", archetypes.string_value, .{}),
                b.argument("count", integer_value, .{}),
            },
            2,
        ),
        matcherMethodWithArguments("toMatch", .{b.argument("expected", string_or_regexp_value, .{})}, 1),
        matcherCallerSourceMethodWithArguments("toMatchInlineSnapshot", inline_snapshot_arguments, 1),
        matcherMethodWithArguments("toMatchObject", .{b.argument("expected", b.js_object, .{})}, 1),
        matcherMethodWithArguments("toMatchSnapshot", snapshot_arguments, 1),
        noArgumentMatcherMethod("toReturn", "toHaveReturned"),
        matcherMethodWithArguments("toSatisfy", .{b.argument("predicate", archetypes.callable_value, .{})}, 1),
        matcherMethodWithArguments("toStartWith", .{b.argument("expected", archetypes.string_value, .{})}, 1),
        matcherMethodWithArguments("toStrictEqual", .{b.argument("expected", b.engine_value, .{})}, 1),
        matcherMethodWithArguments("toThrow", throw_arguments, 1),
        matcherMethodWithArguments("toThrowError", throw_arguments, 1),
        matcherCallerSourceMethodWithArguments("toThrowErrorMatchingInlineSnapshot", exception_snapshot_arguments, 1),
        matcherMethodWithArguments("toThrowErrorMatchingSnapshot", exception_snapshot_arguments, 1),
        expectGlobalMethod("addSnapshotSerializer", .{}, b.none, 1),
        b.staticMethod(
            "any",
            .{b.argument("constructorValue", any_constructor_value, .{})},
            b.classRefByName("Expect", "ExpectAny"),
            .{
                .implementation = "bind_static_any",
                .length = 1,
                .missing_required_arguments = .{ .failure = any_missing_argument },
            },
        ),
        expectGlobalMethod("anything", .{}, b.classRefByName("Expect", "ExpectAnything"), 1),
        expectGlobalMethod(
            "arrayContaining",
            .{b.argument("arrayValue", b.js_array, .{})},
            b.classRefByName("Expect", "ExpectArrayContaining"),
            1,
        ),
        expectGlobalMethod("assertions", .{b.argument("expected", b.uint32, .{})}, b.none, 1),
        expectGlobalMethod(
            "closeTo",
            .{
                b.argument("numberValue", b.double, .{}),
                b.argument("precisionValue", b.double, .{ .presence = .optional, .missing = .undefined }),
            },
            b.classRefByName("Expect", "ExpectCloseTo"),
            1,
        ),
        expectGlobalMethod("extend", .{b.argument("matchers", b.js_object, .{})}, b.none, 1),
        expectGlobalMethod("hasAssertions", .{}, b.none, 1),
        expectGlobalGetter("not"),
        expectGlobalMethod(
            "objectContaining",
            .{b.argument("objectValue", b.js_object, .{})},
            b.classRefByName("Expect", "ExpectObjectContaining"),
            1,
        ),
        expectGlobalGetter("rejectsTo"),
        expectGlobalGetter("resolvesTo"),
        b.staticMethod(
            "stringContaining",
            .{b.argument("stringValue", string_containing_value, .{})},
            b.classRefByName("Expect", "ExpectStringContaining"),
            .{
                .implementation = "bind_static_stringContaining",
                .length = 1,
                .missing_required_arguments = .convert_undefined,
            },
        ),
        expectGlobalMethod(
            "stringMatching",
            .{b.argument("testValue", string_or_regexp_value, .{})},
            b.classRefByName("Expect", "ExpectStringMatching"),
            1,
        ),
        expectGlobalMethod(
            "unreachable",
            .{b.argument("value", unreachable_input, .{ .presence = .optional, .missing = .undefined })},
            b.none,
            1,
        ),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .reference_thread = .vm,
        .constructor_call = b.constructorCall(
            .{
                b.argument("value", b.any, .{ .presence = .optional, .missing = .undefined }),
                b.argument("customLabel", b.any, .{ .presence = .optional, .missing = .undefined }),
            },
            b.classRefByName("Expect", "Expect"),
            .{ .backend = .builtin, .builtin = "bunTestExpectCodeGenerator", .length = 1 },
        ),
    },
);

const apply_custom_matcher_receiver = b.unionType("ExpectCustomMatcherReceiver", .{
    b.unionMember("expect", b.classRefByName("Expect", "Expect")),
    b.unionMember("expect_static", b.classRefByName("Expect", "ExpectStatic")),
    b.unionMember("other", b.discardAny(.classification)),
}, .{ .ordered = true, .fallback_member = "other" });
const apply_custom_matcher_result = b.unionType("ExpectCustomMatcherResult", .{
    b.unionMember("expect", b.classRefByName("Expect", "Expect")),
    b.unionMember("asymmetric", b.classRefByName("Expect", "ExpectCustomAsymmetricMatcher")),
}, .{ .ordered = true });
const apply_custom_matcher = b.function(
    "applyCustomMatcher",
    .{b.rest("values", b.invocation_any)},
    apply_custom_matcher_result,
    .{
        .profile = .exact,
        .this_value_type = apply_custom_matcher_receiver,
        .callee_value_type = wrapping_function_value,
    },
);

const create_expect = b.function("createExpect", .{
    b.argument("value", b.engine_value, .{}),
    b.argument("customLabel", b.dom_string, .{}),
}, b.classRefByName("Expect", "Expect"), .{ .backend = .zig, .profile = .exact });

fn expectTypeOfGetter(comptime name: []const u8) b.ClassMember {
    return b.getter(name, b.classRefByName("Expect", "ExpectTypeOf"), .{});
}

fn expectTypeOfVoidMethod(comptime name: []const u8) b.ClassMember {
    return b.method(
        name,
        .{b.argument("value", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted })},
        b.none,
        .{ .length = 1 },
    );
}

const expect_type_of_class = b.class(
    "ExpectTypeOf",
    b.illegalConstructor(),
    .{
        expectTypeOfGetter("asserts"),
        expectTypeOfGetter("branded"),
        expectTypeOfGetter("constructorParameters"),
        expectTypeOfVoidMethod("exclude"),
        expectTypeOfVoidMethod("extract"),
        expectTypeOfGetter("guards"),
        expectTypeOfGetter("instance"),
        expectTypeOfGetter("items"),
        b.method(
            "map",
            .{b.argument("value", b.discardAny(.ignored), .{ .presence = .optional, .missing = .omitted })},
            b.classRefByName("Expect", "ExpectTypeOf"),
            .{ .length = 1 },
        ),
        expectTypeOfGetter("not"),
        expectTypeOfVoidMethod("omit"),
        expectTypeOfVoidMethod("parameter"),
        expectTypeOfGetter("parameters"),
        expectTypeOfVoidMethod("pick"),
        expectTypeOfGetter("resolves"),
        expectTypeOfGetter("returns"),
        expectTypeOfGetter("thisParameter"),
        expectTypeOfVoidMethod("toBeAny"),
        expectTypeOfVoidMethod("toBeArray"),
        expectTypeOfVoidMethod("toBeBigInt"),
        expectTypeOfVoidMethod("toBeBoolean"),
        expectTypeOfVoidMethod("toBeCallableWith"),
        expectTypeOfVoidMethod("toBeConstructibleWith"),
        expectTypeOfVoidMethod("toBeFunction"),
        expectTypeOfVoidMethod("toBeNever"),
        expectTypeOfVoidMethod("toBeNull"),
        expectTypeOfVoidMethod("toBeNumber"),
        expectTypeOfVoidMethod("toBeObject"),
        expectTypeOfVoidMethod("toBeString"),
        expectTypeOfVoidMethod("toBeSymbol"),
        expectTypeOfVoidMethod("toBeUndefined"),
        expectTypeOfVoidMethod("toBeUnknown"),
        expectTypeOfVoidMethod("toBeVoid"),
        expectTypeOfVoidMethod("toEqualTypeOf"),
        expectTypeOfVoidMethod("toExtend"),
        expectTypeOfVoidMethod("toHaveProperty"),
        expectTypeOfVoidMethod("toMatchObjectType"),
        expectTypeOfVoidMethod("toMatchTypeOf"),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
        .constructor_call = b.constructorCall(.{}, b.classRefByName("Expect", "ExpectTypeOf"), .{ .length = 0 }),
    },
);

const expect_static_class = b.class(
    "ExpectStatic",
    b.constructor(.{}, .{ .exposure = .never }),
    .{
        b.method("any", .{b.argument("constructorValue", any_constructor_value, .{})}, b.classRefByName("Expect", "ExpectAny"), .{
            .length = 1,
            .missing_required_arguments = .{ .failure = any_missing_argument },
        }),
        b.method("anything", .{}, b.classRefByName("Expect", "ExpectAnything"), .{ .length = 1 }),
        b.method("arrayContaining", .{b.argument("arrayValue", b.js_array, .{})}, b.classRefByName("Expect", "ExpectArrayContaining"), .{ .length = 1 }),
        b.method(
            "closeTo",
            .{
                b.argument("numberValue", b.double, .{}),
                b.argument("precisionValue", b.double, .{ .presence = .optional, .missing = .undefined }),
            },
            b.classRefByName("Expect", "ExpectCloseTo"),
            .{ .length = 1 },
        ),
        b.getter("not", b.classRefByName("Expect", "ExpectStatic"), .{ .implementation = "getNot" }),
        b.method("objectContaining", .{b.argument("objectValue", b.js_object, .{})}, b.classRefByName("Expect", "ExpectObjectContaining"), .{ .length = 1 }),
        b.getter("rejectsTo", b.classRefByName("Expect", "ExpectStatic"), .{ .implementation = "getRejectsTo" }),
        b.getter("resolvesTo", b.classRefByName("Expect", "ExpectStatic"), .{ .implementation = "getResolvesTo" }),
        b.method("stringContaining", .{b.argument("stringValue", string_containing_value, .{})}, b.classRefByName("Expect", "ExpectStringContaining"), .{
            .length = 1,
            .missing_required_arguments = .convert_undefined,
        }),
        b.method("stringMatching", .{b.argument("testValue", string_or_regexp_value, .{})}, b.classRefByName("Expect", "ExpectStringMatching"), .{ .length = 1 }),
    },
    .{},
    .{
        .backend = .zig,
        .profile = .exact,
        .ownership = .unique,
        .identity = .fresh,
    },
);

fn optionalBrandCast(comptime name: []const u8, comptime match: b.Type) b.EngineShim {
    return b.engineShim(name, .{b.argument("value", b.brandCast(match, .{ .failure = .absent, .input = .engine_value }), .{})}, b.optional(match), .current_realm_unchecked);
}

const engine_shims = .{
    b.engineShim(
        "customMatcherPass",
        .{b.argument("value", b.engine_value, .{})},
        custom_matcher_pass,
        .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .result_source = .javascript },
    ),
    b.engineShim(
        "customMatcherMessage",
        .{b.argument("value", b.engine_value, .{})},
        custom_matcher_message_record,
        .{ .throws = .js_exception, .realm = .current, .affinity = .vm, .result_source = .javascript },
    ),
    b.engineShim("asymmetricMatcherConstructorTypeFromJS", .{b.argument("value", archetypes.constructor_value, .{})}, asymmetric_matcher_constructor_type, .current_realm_throwing),
    b.engineShim("mockFunctionCalls", .{b.argument("value", b.engine_value, .{})}, b.optionalUndefined(b.js_array), .current_realm_throwing),
    b.engineShim("mockFunctionReturns", .{b.argument("value", b.engine_value, .{})}, b.optionalUndefined(b.js_array), .current_realm_throwing),
    b.engineShim("jestTestModuleObject", .{}, b.js_object, .current_realm_throwing),
    b.engineShim("expectMatcherUtilsObject", .{}, b.classRefByName("Expect", "ExpectMatcherUtils"), .current_realm_throwing),
    b.engineShim("wrappingFunctionWrapped", .{b.argument("function", wrapping_function_value, .{})}, archetypes.callable_value, .current_realm_nonthrowing),
    b.engineShim("createArgumentArray", .{b.argument("values", b.sequence(b.engine_value), .{})}, b.js_array, .current_realm_throwing),
    b.engineShim("installCustomMatcher", .{
        b.argument("symbolName", b.dom_string, .{}),
        b.argument("wrappedFunction", b.brandCast(archetypes.callable_value, .{ .failure = .assert, .input = .engine_value }), .{}),
    }, b.none, .current_realm_throwing),
    optionalBrandCast("tryCastObjectValue", b.js_object),
    optionalBrandCast("tryCastCallableValue", archetypes.callable_value),
};

pub const schema = b.moduleWithDeclarations(
    "Expect",
    .{ apply_custom_matcher, create_expect },
    .{
        expect_class,
        matcher_context,
        matcher_utils,
        custom_asymmetric_matcher,
        anything,
        any_matcher,
        string_matching,
        close_to,
        object_containing,
        string_containing,
        array_containing,
        expect_type_of_class,
        expect_static_class,
    },
    engine_shims,
    native_exports,
);

pub const expect = schema.class("Expect");
pub const expect_matcher_context = schema.class("ExpectMatcherContext");
pub const expect_matcher_utils = schema.class("ExpectMatcherUtils");
pub const expect_custom_asymmetric_matcher = schema.class("ExpectCustomAsymmetricMatcher");
pub const expect_anything = schema.class("ExpectAnything");
pub const expect_any = schema.class("ExpectAny");
pub const expect_string_matching = schema.class("ExpectStringMatching");
pub const expect_close_to = schema.class("ExpectCloseTo");
pub const expect_object_containing = schema.class("ExpectObjectContaining");
pub const expect_string_containing = schema.class("ExpectStringContaining");
pub const expect_array_containing = schema.class("ExpectArrayContaining");
pub const expect_type_of = schema.class("ExpectTypeOf");
pub const expect_static = schema.class("ExpectStatic");
