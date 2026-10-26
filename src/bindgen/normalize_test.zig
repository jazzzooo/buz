//! Schema-rule tests: each case normalizes a small schema and expects the
//! normalizer to reject it with a diagnostic naming the violated rule.
const std = @import("std");
const b = @import("bindgen_schema");
const normalize = @import("normalize.zig");

fn expectDiagnostic(comptime modules: []const b.Module, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var stems: [modules.len][]const u8 = undefined;
    for (modules, &stems) |module, *stem| stem.* = module.name;
    var normalizer: normalize.Normalizer = .{
        .arena = arena.allocator(),
        .modules = modules,
        .source_stems = &stems,
        .input = .{ .target = .x86_64_linux },
    };
    switch (try normalizer.normalize()) {
        .ir => std.debug.print("expected a diagnostic containing \"{s}\"; normalization succeeded\n", .{expected}),
        .diagnostics => |diagnostics| {
            for (diagnostics) |diagnostic| {
                if (std.mem.indexOf(u8, diagnostic.message, expected) != null) return;
            }
            std.debug.print("expected a diagnostic containing \"{s}\"; got:\n", .{expected});
            for (diagnostics) |diagnostic| std.debug.print("  {s}: {s}\n", .{ diagnostic.location, diagnostic.message });
        },
    }
    return error.TestExpectedDiagnostic;
}

fn expectFunctionDiagnostic(comptime function: b.Function, expected: []const u8) !void {
    return expectDiagnostic(&.{b.module("invalid", .{function})}, expected);
}

fn expectArgumentDiagnostic(comptime argument: b.Argument, expected: []const u8) !void {
    return expectFunctionDiagnostic(b.function("invalid", .{argument}, b.none, .{}), expected);
}

fn expectArgumentTypeDiagnostic(comptime argument_type: b.Type, expected: []const u8) !void {
    return expectArgumentDiagnostic(b.argument("value", argument_type, .{}), expected);
}

fn expectEngineShimDiagnostic(comptime shim: b.EngineShim, expected: []const u8) !void {
    return expectDiagnostic(&.{b.moduleWithEngineShims("invalid", .{}, .{shim})}, expected);
}

fn expectNativeExportDiagnostic(comptime native_export: b.NativeExport, expected: []const u8) !void {
    return expectDiagnostic(&.{b.moduleWithNativeExports("invalid", .{}, .{native_export})}, expected);
}

fn expectClassDiagnostic(comptime class: b.Class, expected: []const u8) !void {
    return expectDiagnostic(&.{b.moduleWithClasses("invalid", .{}, .{class})}, expected);
}

const realm_free_any_thread: b.EngineShimOptions = .{
    .throws = .never,
    .realm = .none,
    .affinity = .any,
    .check_traps = false,
};

const realm_free_vm: b.EngineShimOptions = .{
    .throws = .never,
    .realm = .none,
    .affinity = .vm,
    .check_traps = false,
};

fn reviewedConverter(comptime name: []const u8) b.Converter {
    return b.customConverter(name, .{ .audit_reason = "exercises a rejected converter declaration" });
}

// ─── results ───

test "record values containing any are rejected at their declaration" {
    const values = comptime b.dictionary("RecordValue", .{
        b.dictionaryField("value", b.optional(b.any), .{ .required = true }),
    });
    const modules = comptime [_]b.Module{b.module("RecordModule", .{
        b.function("read", .{b.argument("values", b.record(b.dom_string, values), .{})}, b.none, .{}),
    })};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try normalize.normalize(arena.allocator(), &modules, &.{"record"}, .{ .target = .x86_64_linux });
    switch (result) {
        .ir => return error.TestExpectedDiagnostic,
        .diagnostics => |diagnostics| {
            for (diagnostics) |diagnostic| {
                if (!std.mem.eql(u8, diagnostic.message, "record values cannot contain borrowed JavaScript values")) continue;
                try std.testing.expectEqualStrings("RecordModule.read", diagnostic.location);
                return;
            }
            return error.TestExpectedDiagnostic;
        },
    }
}

test "borrowed buffer results" {
    try expectFunctionDiagnostic(b.function("invalid", .{}, b.buffer(.lease), .{}), "buffer results require copy ownership");
}

test "lazy results" {
    try expectFunctionDiagnostic(b.function("invalid", .{}, b.lazy(b.dom_string), .{ .backend = .zig }), "lazy values cannot be function results");
}

test "converted results" {
    const converted = comptime b.converted(b.dom_string, b.dom_string, reviewedConverter("convertResult"), .{});
    const result = comptime b.dictionary("ConvertedResult", .{
        b.dictionaryField("values", b.sequence(b.optional(converted)), .{ .required = true }),
    });
    try expectFunctionDiagnostic(
        b.function("invalid", .{}, result, .{ .backend = .zig }),
        "converted semantic types are argument-only; return their native value type",
    );
}

test "external reference results" {
    try expectFunctionDiagnostic(
        b.function("invalid", .{}, b.promise(b.optional(b.blob)), .{}),
        "external references are argument-only; return a class reference",
    );
}

test "NodePath results" {
    try expectFunctionDiagnostic(
        b.function("invalid", .{}, b.node_path, .{ .backend = .zig, .profile = .node }),
        "NodePath is an argument-only semantic type",
    );
}

test "UTF8String results of C++ bindings" {
    try expectFunctionDiagnostic(
        b.function("invalid", .{}, b.sequence(b.utf8_string), .{ .backend = .cpp, .profile = .exact }),
        "UTF8String results require a Zig backend",
    );
}

// ─── arguments ───

test "void arguments" {
    try expectArgumentTypeDiagnostic(b.none, "binding arguments require a value type");
}

test "UTF8String arguments" {
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("value", b.utf8_string, .{})}, b.none, .{ .backend = .zig, .profile = .exact }),
        "UTF8String is a native-to-JavaScript type and cannot be used as a JavaScript argument",
    );
}

test "native slice JavaScript arguments" {
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("output", b.nativeSlice(.uint8, .read_write), .{})}, b.none, .{ .backend = .zig, .profile = .exact }),
        "native slices cannot be used as a JavaScript argument",
    );
}

test "NodePath outside the node profile" {
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("path", b.node_path, .{})}, b.none, .{ .backend = .zig, .profile = .exact }),
        "NodePath requires the node conversion profile",
    );
}

test "node integer validation outside the node profile" {
    try expectFunctionDiagnostic(b.function("invalid", .{b.argument("value", b.int32, .{
        .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 1 } },
    })}, b.none, .{ .profile = .exact }), "node integer validation requires the node conversion profile");
}

test "ToLength conversion of narrow integers" {
    try expectArgumentDiagnostic(
        b.argument("value", b.uint32, .{ .integer_conversion = .to_length }),
        "ToLength conversion requires an unsigned 64-bit argument",
    );
}

test "argument names reserved by the wire ABI" {
    try expectArgumentDiagnostic(b.argument("namespace", b.any, .{}), "argument name is reserved in the C/C++ wire ABI: namespace");
}

test "dictionary field names reserved by the wire ABI" {
    try expectArgumentTypeDiagnostic(
        b.dictionary("Invalid", .{b.dictionaryField("errno", b.int32, .{})}),
        "dictionary field name is reserved in the C/C++ wire ABI: errno",
    );
}

test "private-symbol fields of Zig bindings" {
    const nested = comptime b.dictionary("PrivateSymbolNested", .{
        b.dictionaryField("secret", b.uint32, .{ .required = true, .private_symbol = "secret" }),
    });
    const options = comptime b.dictionary("PrivateSymbolOptions", .{
        b.dictionaryField("nested", b.optional(nested), .{ .required = true }),
    });
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("options", options, .{})}, b.none, .{ .backend = .zig }),
        "private-symbol dictionary fields are restricted to C++ binding implementations",
    );
}

test "incompatible lazy dictionary fields" {
    const nested = comptime b.dictionary("CppLazyIncompatibleNested", .{
        b.dictionaryField("other", b.uint32, .{}),
        b.dictionaryField("value", b.lazy(b.uint32), .{
            .required = true,
            .node_incompatible_with = "other",
            .deferred_reason = "the fixture exercises incompatible lazy fields",
        }),
    });
    const options = comptime b.dictionary("CppLazyIncompatibleOptions", .{
        b.dictionaryField("nested", b.optional(nested), .{ .required = true }),
    });
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("options", options, .{})}, b.none, .{ .backend = .cpp, .profile = .node }),
        "lazy dictionary fields cannot use node_incompatible_with",
    );
}

test "receiver byte-length conversion inside converters" {
    const match = comptime b.dictionary("NestedReceiverMatch", .{
        b.dictionaryField("index", b.size, .{ .required = true, .integer_conversion = .{ .node_receiver_byte_length = .integer } }),
    });
    const converted = comptime b.converted(b.uint32, match, reviewedConverter("convertNestedReceiver"), .{});
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("value", converted, .{})}, b.none, .{ .backend = .cpp, .profile = .node, .this_value_type = b.js_date }),
        "receiver byte-length conversion requires a typed ArrayBufferView receiver",
    );
}

// ─── discarded values ───

test "discarded arguments without a purpose" {
    try expectArgumentTypeDiagnostic(
        b.discarded,
        "arguments that discard a value require discardAny(.classification), discardAny(.presence), or discardAny(.ignored)",
    );
}

test "discarded dictionary fields without a purpose" {
    try expectArgumentTypeDiagnostic(b.dictionary("InvalidDiscardedDictionary", .{
        b.dictionaryField("value", b.optionalUndefined(b.discarded), .{}),
    }), "dictionary fields that discard a value require discardAny(.presence) or discardAny(.ignored)");
}

test "ignored union members before the fallback" {
    try expectArgumentTypeDiagnostic(b.unionType("InvalidDiscardedUnion", .{
        b.unionMember("number", b.double),
        b.unionMember("ignored", b.discardAny(.ignored)),
    }, .{ .ordered = true }), "discarded shape-selected union members require classification; an ignored value is allowed only as the fallback");
}

test "discarded rest arguments without the count purpose" {
    try expectArgumentDiagnostic(b.rest("values", b.discardAny(.ignored)), "discarded rest arguments require the count purpose");
}

// ─── rest arguments ───

test "converted rest elements" {
    const converted = comptime b.converted(b.dom_string, b.dom_string, reviewedConverter("convertValue"), .{});
    try expectArgumentDiagnostic(b.rest("values", b.optional(converted)), "this binding type cannot be used as a rest element");
}

test "borrowed buffer rest elements" {
    try expectArgumentDiagnostic(b.rest("values", b.dictionary("Entry", .{
        b.dictionaryField("bytes", b.optional(b.buffer(.lease)), .{}),
    })), "rest arguments require copy ownership for buffers");
}

// ─── sequences ───

test "integer conversion of non-integer sequence elements" {
    try expectArgumentTypeDiagnostic(b.sequenceWithOptions(b.dom_string, .{
        .element_conversion = .{ .integer_conversion = .webidl },
    }), "integer conversion requires an integer sequence element");
}

test "node validation of sequence elements outside the node profile" {
    const values = comptime b.sequenceWithOptions(b.uint8, .{
        .element_conversion = .{ .integer_conversion = .{ .node_validate = .{ .min = 0, .max = 255 } } },
    });
    try expectFunctionDiagnostic(
        b.function("invalid", .{b.argument("values", values, .{})}, b.none, .{ .profile = .exact }),
        "node integer validation requires the node conversion profile",
    );
}

test "FrozenArray element conversion" {
    try expectArgumentTypeDiagnostic(b.sequenceWithOptions(b.uint8, .{
        .flavor = .frozen_array,
        .element_conversion = .{ .integer_conversion = .webidl },
    }), "FrozenArray cannot declare sequence input-conversion options");
}

// ─── overloads ───

fn overloadedFunction(comptime options: b.OverloadOptions) b.Function {
    return b.function("invalid", b.overloads(.{
        b.overloadCase("string", .{b.argument("value", b.dom_string, .{})}),
        b.overloadCase("number", .{b.argument("value", b.double, .{})}),
    }, options), b.none, .{});
}

test "overload fallbacks without ordered conversion" {
    try expectFunctionDiagnostic(overloadedFunction(.{ .fallback_case = "number" }), "an overload fallback requires ordered conversion");
}

test "overload fallbacks before the final case" {
    try expectFunctionDiagnostic(overloadedFunction(.{ .ordered = true, .fallback_case = "string" }), "an overload fallback must be the final case");
}

test "overload fallbacks naming no case" {
    try expectFunctionDiagnostic(overloadedFunction(.{ .ordered = true, .fallback_case = "absent" }), "overload fallback does not name a case: absent");
}

// ─── converters ───

test "custom converters without an audit reason" {
    try expectArgumentTypeDiagnostic(
        b.converted(b.dom_string, b.dom_string, b.customConverter("convertUnreviewed", .{}), .{}),
        "custom converters require an audit reason: convertUnreviewed",
    );
}

test "custom converters with conflicting C++ return types" {
    const converter = comptime reviewedConverter("conflictingConverter");
    const integer = comptime b.converted(b.uint32, b.dom_string, converter, .{});
    const boolean = comptime b.converted(b.boolean, b.dom_string, converter, .{});
    try expectDiagnostic(&.{b.module("conflicting_converters", .{
        b.function("integer", .{b.argument("value", integer, .{})}, b.none, .{}),
        b.function("boolean", .{b.argument("value", boolean, .{})}, b.none, .{}),
    })}, "custom converter has conflicting declarations: conflictingConverter");
}

test "reserved converter kinds outside their constructor" {
    const forged: b.Converter = .{ .kind = .brand_cast, .name = "forgedBrandCast", .options = .{} };
    try expectArgumentTypeDiagnostic(b.converted(b.uint32, b.uint32, forged, .{}), "reserved converters must use their schema constructor");
}

test "optional integer presence requires a supported matcher" {
    try expectArgumentTypeDiagnostic(
        b.optionalMatch(b.int8),
        "this value has no optional presence test",
    );
}

test "unsupported brand casts are rejected during normalization" {
    try expectArgumentTypeDiagnostic(
        b.brandCast(b.js_object, .{}),
        "brand casts that raise have no engine-operand definition",
    );
    try expectArgumentTypeDiagnostic(
        b.brandCast(b.js_object, .{ .failure = .absent, .input = .optional_engine_value }),
        "absent-on-mismatch brand casts do not support optional inputs",
    );
}

test "brands that share a name share a matcher" {
    try expectFunctionDiagnostic(b.function("invalid", .{
        b.argument("first", b.brandedValueWithBrand(b.cppBrand("SharedBrand", .{ .symbol = "Bun::isFirst", .header = "Shared.h" }, "unknown"), .{}), .{}),
        b.argument("second", b.brandedValueWithBrand(b.cppBrand("SharedBrand", .{ .symbol = "Bun::isSecond", .header = "Shared.h" }, "unknown"), .{}), .{}),
    }, b.none, .{}), "brands sharing this name use different matchers");
}

test "converted callback parameters" {
    const converted = comptime b.converted(b.dom_string, b.dom_string, reviewedConverter("convertValue"), .{});
    try expectArgumentTypeDiagnostic(
        b.callback("Invalid", .{b.argument("value", converted, .{})}, b.none, .{
            .receiver = null,
        }),
        "converted semantic values cannot be callback parameters",
    );
}

test "callback receivers must be materializable values" {
    try expectArgumentTypeDiagnostic(
        b.callback("InvalidReceiver", .{}, b.none, .{ .receiver = b.none }),
        "a callback receiver cannot have the void type",
    );
    try expectArgumentTypeDiagnostic(
        b.callback("InvalidReceiver", .{}, b.none, .{ .receiver = b.retained_any }),
        "callback receivers",
    );
}

test "nullable dictionaries cannot promise an object-typed source" {
    try expectArgumentTypeDiagnostic(b.dictionary("ObjectSource", .{
        b.dictionaryField("source", b.js_object, .{ .source = .dictionary, .required = true }),
    }), "an object-typed dictionary source requires a non-nullable dictionary conversion");
}

test "converters producing borrowed buffers" {
    try expectArgumentTypeDiagnostic(
        b.converted(b.buffer(.lease), b.dom_string, reviewedConverter("convertValue"), .{}),
        "custom buffer converters require copy ownership",
    );
}

test "custom converter match buffers must be readable before lease acquisition" {
    try expectArgumentTypeDiagnostic(
        b.converted(b.int32, b.optional(b.buffer(.lease)), reviewedConverter("readBytes"), .{}),
        "custom converters require copy-buffer match inputs",
    );
}

test "converters matching generic engine values" {
    try expectArgumentTypeDiagnostic(
        b.converted(b.dom_string, b.js_object, reviewedConverter("convertGenericObject"), .{}),
        "custom converters require a specific JavaScript brand; generic engine values cannot be converter inputs",
    );
}

test "converters producing engine objects" {
    try expectArgumentTypeDiagnostic(
        b.converted(b.js_uint8_array, b.js_uint8_array, reviewedConverter("convertUint8Array"), .{}),
        "custom converters cannot produce engine objects",
    );
}

test "converters producing external resources" {
    try expectArgumentTypeDiagnostic(
        b.converted(b.fetch_headers, b.dom_string, reviewedConverter("convertHeaders"), .{}),
        "custom converters cannot produce external resources",
    );
}

test "converters producing owned nominal handles" {
    const owned_handle = comptime b.nominalHandle("OwnedConverterHandle", .{
        .cpp_type = .{ .pointer = &.{ .named = "OwnedConverterHandle" } },
        .cpp_declarations = &.{.{ .structure = "OwnedConverterHandle" }},
        .ownership = .owned,
        .cpp_release = "releaseOwnedConverterHandle",
        .access_thread = .any,
        .destroy_thread = .any,
    });
    const owned_conversion = comptime b.converted(owned_handle, b.any, reviewedConverter("convertOwnedHandle"), .{});
    try expectArgumentTypeDiagnostic(
        b.dictionary("Options", .{b.dictionaryField("handle", owned_conversion, .{})}),
        "custom converters cannot produce nominal resources; use a schema-declared native operation",
    );
}

// ─── nominal handles ───

test "nominal handles without an access thread" {
    try expectArgumentTypeDiagnostic(b.nominalHandle("ImplicitAccessHandle", .{
        .cpp_type = .{ .pointer = &.{ .named = "ImplicitAccessHandle" } },
        .cpp_declarations = &.{.{ .structure = "ImplicitAccessHandle" }},
    }), "nominal handles require an explicit access thread: ImplicitAccessHandle");
}

test "owned nominal handles without a destruction thread" {
    try expectArgumentTypeDiagnostic(b.nominalHandle("InvalidOwnedHandle", .{
        .cpp_type = .{ .pointer = &.{ .named = "InvalidOwnedHandle" } },
        .cpp_declarations = &.{.{ .structure = "InvalidOwnedHandle" }},
        .ownership = .owned,
        .cpp_release = "releaseInvalidOwnedHandle",
        .access_thread = .any,
    }), "owned nominal handles require an explicit destruction thread");
}

test "borrowed nominal handles exposing bytes" {
    try expectArgumentTypeDiagnostic(b.nominalHandle("BorrowedBytes", .{
        .cpp_type = .{ .pointer = &.{ .named = "BorrowedBytes" } },
        .cpp_declarations = &.{.{ .structure = "BorrowedBytes" }},
        .cpp_read_bytes = "readBorrowedBytes",
        .access_thread = .any,
    }), "borrowed nominal handles cannot expose owned byte storage");
}

test "raw nominal pointers without an escape reason" {
    try expectArgumentTypeDiagnostic(
        b.nominalHandle("InvalidRawPointer", .{ .cpp_type = .{ .pointer = &.{ .named = "uint8_t" } }, .access_thread = .any }),
        "unstructured nominal pointer handles require an explicit raw_pointer_escape reason: InvalidRawPointer",
    );
}

// ─── completions ───

test "completion results bound to the VM thread" {
    try expectDiagnostic(&.{b.module("invalid_completion", .{
        b.function("run", .{}, b.dom_string, .{ .completion = .{} }),
    })}, "must be encodable and destructible on any thread");
}

test "completion domain errors bound to the VM thread" {
    try expectDiagnostic(&.{b.module("invalid_completion", .{b.function("run", .{}, b.dom_string, .{
        .completion = .{ .delivery = .vm },
        .errors = b.domainErrors(.{b.domainError("failed", b.dom_string, .{
            .class = .generic_error,
            .message = .payload,
        })}),
    })})}, "invalid_completion_run domain error failed must be encodable and destructible on any thread");
}

// ─── engine shims ───

test "engine shim borrowed buffer arguments" {
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{b.argument("value", b.buffer(.lease), .{})}, b.none, .{
        .throws = .never,
        .realm = .current,
        .affinity = .vm,
    }), "engine shims only support copy-buffer arguments");
}

test "current-realm engine shims off the VM thread" {
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{}, b.boolean, .{
        .throws = .never,
        .realm = .current,
        .affinity = .any,
    }), "current-realm engine shims require VM affinity");
}

test "realm-free engine shims throwing exceptions" {
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{}, b.boolean, .{
        .throws = .js_exception,
        .realm = .none,
        .affinity = .any,
        .check_traps = false,
    }), "realm-free engine shims cannot throw JavaScript exceptions");
}

test "realm-free engine shim arguments carrying JavaScript values" {
    const expected = "realm-free engine shim arguments cannot carry JavaScript reachability or realm-bound resources";
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{b.argument("value", b.any, .{})}, b.none, realm_free_vm), expected);
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{b.argument("value", b.js_object, .{})}, b.none, realm_free_vm), expected);
    const values = comptime b.dictionary("Values", .{
        b.dictionaryField("items", b.sequence(b.optional(b.engine_value)), .{ .required = true }),
    });
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{b.argument("values", values, .{})}, b.none, realm_free_vm), expected);
}

test "realm-free engine shim results carrying JavaScript values" {
    try expectEngineShimDiagnostic(
        b.engineShim("invalid", .{}, b.any, realm_free_any_thread),
        "realm-free engine shim results cannot carry JavaScript reachability or realm-bound resources",
    );
}

test "any-thread engine shim arguments bound to the VM thread" {
    const expected = "any-thread engine shim arguments require any-thread resource contracts: invalid_invalid";
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{b.argument("value", b.dom_string, .{})}, b.none, realm_free_any_thread), expected);
    const vm_handle = comptime b.nominalHandle("VMHandle", .{
        .cpp_type = .{ .pointer = &.{ .named = "VMHandle" } },
        .cpp_declarations = &.{.{ .structure = "VMHandle" }},
        .access_thread = .vm,
    });
    try expectEngineShimDiagnostic(b.engineShim("invalid", .{b.argument("value", vm_handle, .{})}, b.none, realm_free_any_thread), expected);
}

test "any-thread engine shim results bound to the VM thread" {
    try expectEngineShimDiagnostic(
        b.engineShim("invalid", .{}, b.dom_string, realm_free_any_thread),
        "any-thread engine shim results require any-thread resource contracts: invalid_invalid",
    );
}

test "engine shim allocating adapters without error propagation" {
    const result = comptime b.dictionary("Result", .{
        b.dictionaryField("label", b.optional(b.thread_safe_dom_string), .{ .required = true }),
    });
    try expectEngineShimDiagnostic(
        b.engineShim("copyLabel", .{}, result, realm_free_any_thread),
        "engine shim invalid_copyLabel requires error propagation for allocating adapters",
    );
}

test "native slice engine shim results" {
    try expectEngineShimDiagnostic(
        b.engineShim("invalid", .{}, b.nativeSlice(.uint8, .read_only), realm_free_any_thread),
        "native slices are restricted to direct engine shim arguments",
    );
}

test "nested native slice engine shim arguments" {
    const options = comptime b.dictionary("Options", .{
        b.dictionaryField("output", b.nativeSlice(.uint8, .read_write), .{}),
    });
    try expectEngineShimDiagnostic(
        b.engineShim("invalid", .{b.argument("options", options, .{})}, b.none, realm_free_any_thread),
        "native slices are restricted to direct engine shim arguments",
    );
}

// ─── native exports ───

test "lazy native export arguments without exception propagation" {
    try expectNativeExportDiagnostic(b.nativeExportWithOptions(
        "lazy",
        .{b.argument("value", b.lazy(b.dom_string), .{ .deferred_reason = "the fixture exercises invalid native-export deferral" })},
        b.none,
        .{ .throws = .never, .realm = .current },
    ), "lazy native export arguments require JavaScript exception propagation");
}

test "nested native slice native export arguments" {
    const nested = comptime b.dictionary("NestedNativeSlice", .{
        b.dictionaryField("output", b.nativeSlice(.uint8, .read_write), .{ .required = true }),
    });
    try expectNativeExportDiagnostic(
        b.nativeExportWithOptions("invalid", .{b.argument("nested", nested, .{})}, b.none, .{ .throws = .never, .realm = .current }),
        "native slices are restricted to direct native-export arguments",
    );
}

test "native export allocating adapters without error propagation" {
    try expectNativeExportDiagnostic(
        b.nativeExport("copyBytes", .{}, b.sequence(b.uint8)),
        "native export requires error propagation for allocating C++ adapters",
    );
}

// ─── internal module registries ───

fn registryFunction(comptime registry: b.Type) b.Function {
    return b.function("get", .{b.argument("id", registry, .{})}, b.none, .{ .profile = .exact });
}

test "internal module registries sharing a source" {
    try expectFunctionDiagnostic(registryFunction(b.enumerationWithOptions("Registry", .{
        b.enumerationValueWithOptions("First", "test:first", .{ .internal_module = .{ .javascript = "internal/same.ts" } }),
        b.enumerationValueWithOptions("Second", "test:second", .{ .internal_module = .{ .javascript = "internal/same.ts" } }),
    }, .{ .internal_module_registry = true })), "duplicate internal module source: internal/same.ts");
}

test "internal module registries with sparse IDs" {
    try expectFunctionDiagnostic(registryFunction(b.enumerationWithOptions("Registry", .{
        b.enumerationValueWithOptions("First", "test:first", .{
            .native_value = 1,
            .internal_module = .{ .javascript = "internal/first.ts" },
        }),
    }, .{ .internal_module_registry = true })), "internal module IDs must be contiguous and start at zero");
}

test "internal module registries naming a missing native surface" {
    try expectFunctionDiagnostic(registryFunction(b.enumerationWithOptions("Registry", .{
        b.enumerationValueWithOptions("Missing", "test:missing", .{ .internal_module = .native }),
    }, .{ .internal_module_registry = true })), "internal registry entry has no exposed native module surface: test:missing");
}

// ─── classes ───

test "C++ native-representation constructors" {
    try expectClassDiagnostic(b.class("Invalid", b.constructor(.{}, .{}), .{}, .{}, .{
        .backend = .cpp,
        .fresh_identity_reason = "fixture objects would have one construction wrapper",
    }), "native-representation constructors create Zig state and require a Zig backend");
}

test "native members of function-prototype classes" {
    try expectClassDiagnostic(b.class(
        "InvalidFunctionPrototypeClass",
        b.constructor(.{}, .{ .exposure = .never }),
        .{b.method("run", .{}, b.none, .{})},
        .{},
        .{ .ownership = .unique, .prototype_base = .function },
    ), "InvalidFunctionPrototypeClass.run");
}

test "native references from getters" {
    try expectClassDiagnostic(b.class(
        "Invalid",
        b.constructor(.{}, .{}),
        .{b.getter("value", b.uint32, .{ .native_reference = true })},
        .{},
        .{ .ownership = .unique },
    ), "native function references require a class method");
}

test "unique classes with mobile references" {
    try expectClassDiagnostic(b.class("Invalid", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .reference_thread = .any,
    }), "unique bindgen classes do not support reference mobility");
}

test "inline sweep finalization of shared classes" {
    try expectClassDiagnostic(b.class("Invalid", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .shared,
        .last_release = b.sweep("teardown only frees native allocations"),
    }), "inline sweep finalization requires unique ownership: Invalid");
}

test "JavaScript-assigned cached slots of native types" {
    try expectClassDiagnostic(b.class(
        "Invalid",
        b.constructor(.{}, .{}),
        .{},
        .{b.cachedSlot("value", b.int32, .{ .writable = true })},
        .{ .ownership = .unique },
    ), "cached slots assigned from JavaScript only support JavaScript value, callback, string, and optional types");
}

test "structured clone deserialization off the VM thread" {
    try expectClassDiagnostic(b.class("Invalid", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .structured_clone = .{ .tag = 128, .deserialize_thread = .any },
    }), "structured clone deserialization requires the VM thread");
}

fn engineClass(comptime cpp_type: []const u8) b.Class {
    return b.class("InvalidNative", b.constructor(.{}, .{ .exposure = .never }), .{}, .{}, .{
        .representation = .engine,
        .engine_intrinsic = "fixture engine wrapper",
        .parent = b.engineParent(.{
            .cpp_class = .{ .named = "Test::JSInvalidNative" },
            .cpp_impl = "Test::InvalidNative",
            .header = "InvalidNative.h",
            .prototype = .object,
            .constructor = .function,
        }),
        .engine_native = .{ .cpp_type = cpp_type, .header = "InvalidNative.h" },
    });
}

test "unqualified engine class native types" {
    try expectClassDiagnostic(engineClass("InvalidNative"), "an engine class native type must be namespace-qualified: InvalidNative");
}

test "engine class native types that cannot be forward-declared" {
    try expectClassDiagnostic(
        engineClass("Test::InvalidNative<int>"),
        "an engine class native type must be forward-declarable: Test::InvalidNative<int>",
    );
}

/// A module declaring `Base` and a `Child` that inherits from it.
fn inheritance(comptime base_options: b.ClassOptions, comptime child_options: b.ClassOptions) []const b.Module {
    const base = b.class("Base", b.constructor(.{}, .{}), .{}, .{}, base_options);
    var options = child_options;
    options.parent = b.parentClass(base);
    options.upcast = "asBase";
    const child = b.class("Child", b.constructor(.{}, .{}), .{}, .{}, options);
    return &.{b.moduleWithClasses("invalid", .{}, .{ base, child })};
}

test "inheritance across ownership" {
    try expectDiagnostic(inheritance(
        .{ .ownership = .shared, .fresh_identity_reason = "the fixture creates one wrapper for the base object" },
        .{ .ownership = .unique },
    ), "native class inheritance requires matching ownership: Child");
}

test "class parents must be present in the binding manifest" {
    const parent = comptime b.class("Missing", b.constructor(.{}, .{}), .{}, .{}, .{ .ownership = .unique });
    const child = comptime b.class("Child", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .parent = b.parentClass(parent),
        .upcast = "asMissing",
    });
    try expectDiagnostic(&.{b.moduleWithClasses("missing_parent", .{}, .{child})}, "class parent is absent from the binding manifest");
}

test "shared inheritance across reference threads" {
    try expectDiagnostic(inheritance(.{
        .ownership = .shared,
        .reference_thread = .vm,
        .fresh_identity_reason = "the fixture creates one wrapper for the base object",
    }, .{
        .ownership = .shared,
        .reference_thread = .any,
        .fresh_identity_reason = "the fixture creates one wrapper for the child object",
    }), "shared native class inheritance requires matching reference threads: Child");
}

test "shared inheritance across wrapper identities" {
    try expectDiagnostic(inheritance(.{
        .ownership = .shared,
        .identity = .fresh,
        .fresh_identity_reason = "the fixture creates one wrapper for the base object",
    }, .{
        .ownership = .shared,
        .identity = .per_realm,
    }), "shared native class inheritance requires matching wrapper identity: Child");
}

test "class parents in later modules" {
    const base = comptime b.class("Base", b.constructor(.{}, .{}), .{}, .{}, .{ .ownership = .unique });
    const child = comptime b.class("Child", b.constructor(.{}, .{}), .{}, .{}, .{
        .ownership = .unique,
        .parent = b.parentClass(base),
        .upcast = "asBase",
    });
    try expectDiagnostic(&.{
        b.moduleWithClasses("child", .{}, .{child}),
        b.moduleWithClasses("base", .{}, .{base}),
    }, "a class parent must belong to an earlier module in the binding schema DAG: Child");
}

const windows_only: b.Exposure = .{ .os = "windows" };

test "exposed bindings referencing hidden classes" {
    const expected = "an exposed binding cannot reference a generated class excluded from the target";
    const hidden = comptime b.class("Hidden", b.constructor(.{}, .{}), .{}, .{}, .{ .ownership = .unique, .exposure = windows_only });
    const nested = comptime b.dictionary("NestedHiddenReference", .{b.dictionaryField(
        "items",
        b.sequence(b.optional(b.classRefByName("hidden_nested_class_reference", "Hidden"))),
        .{ .required = true },
    )});
    try expectDiagnostic(&.{b.moduleWithClasses(
        "hidden_nested_class_reference",
        .{b.function("invalid", .{b.argument("value", nested, .{})}, b.none, .{})},
        .{hidden},
    )}, expected);
    try expectDiagnostic(&.{b.moduleWithClasses(
        "hidden_promise_class_reference",
        .{b.function("invalid", .{}, b.promise(b.classRefByName("hidden_promise_class_reference", "Hidden")), .{})},
        .{hidden},
    )}, expected);
}

fn plainClass(comptime name: []const u8, comptime exposure: b.Exposure) b.Class {
    return b.plainClass(name, b.constructor(.{}, .{ .backend = .cpp }), .{}, .{b.instanceProperty("value", .{ .value = b.retained_any })}, .{
        .backend = .cpp,
        .representation = .plain,
        .plain_reason = "the fixture models a JavaScript field snapshot",
        .exposure = exposure,
    });
}

test "dictionary results naming hidden plain classes" {
    const class_module = comptime b.moduleWithClasses("hidden_result_class", .{}, .{plainClass("HiddenResult", windows_only)});
    const result = comptime b.dictionaryWithOptions(
        "HiddenResultDictionary",
        .{b.dictionaryField("value", b.retained_any, .{ .required = true })},
        .{ .result_class = class_module.class("HiddenResult") },
    );
    try expectDiagnostic(&.{
        class_module,
        b.module("hidden_result_use", .{b.function("invalid", .{}, result, .{})}),
    }, "a dictionary result class must resolve to an exposed plain class");
}

test "ordinary setter-only class accessors are rejected before emission" {
    try expectDiagnostic(&.{b.moduleWithClasses("SetterOnly", .{}, .{
        b.class("Value", b.constructor(.{}, .{ .exposure = .never }), .{
            b.setter("value", b.int32, .{}),
        }, .{}, .{ .ownership = .unique }),
    })}, "setter-only accessors are not supported: value");
}

test "private getters cannot satisfy ordinary setter pairs" {
    try expectDiagnostic(&.{b.moduleWithClasses("AccessorKey", .{}, .{
        b.class("Value", b.constructor(.{}, .{ .exposure = .never }), .{
            b.getter("value", b.int32, .{ .private_symbol = "privateValue" }),
            b.setter("value", b.int32, .{}),
        }, .{}, .{ .ownership = .unique }),
    })}, "setter-only accessors are not supported: value");
}

test "type predicates targeting unbranded plain classes" {
    try expectDiagnostic(&.{b.moduleWithClasses(
        "plain_predicate",
        .{b.typePredicate("isPlain", b.classRefByName("plain_predicate", "Plain"))},
        .{plainClass("Plain", .always)},
    )}, "type predicate plain_predicate.isPlain cannot target unbranded plain class plain_predicate.Plain: plain instances have no generated C++ instance class; declare ClassOptions.brand");
}

// ─── object surfaces ───

test "direct builtin accessors" {
    const declarations = comptime b.module("declarations", .{b.function("getValue", .{}, b.any, .{
        .backend = .builtin,
        .builtin = "directBuiltinSurfaceAccessorCodeGenerator",
        .profile = .exact,
    })});
    const surface = comptime b.objectSurface("DirectBuiltinSurfaceAccessor", .{
        b.surfaceBuiltinGetter("value", declarations.function("getValue"), .{}),
    }, .{ .installation = .direct });
    try expectDiagnostic(&.{ declarations, b.moduleWithSurfaces("owner", .{surface}) }, "direct builtin accessors must use a function accessor: value");
}

test "direct lazy storage members" {
    const surface = comptime b.objectSurface("DirectLazySurfaceStorage", .{
        b.surfaceCellProperty("value", "m_value", .{}),
    }, .{ .installation = .direct, .cpp_class = "DirectLazySurfaceStorageOwner" });
    try expectDiagnostic(&.{b.moduleWithSurfaces("owner", .{surface})}, "direct lazy storage members are not supported: value");
}

test "global-static function accessors" {
    const declarations = comptime b.module("declarations", .{b.function("getValue", .{}, b.any, .{ .backend = .cpp, .profile = .exact })});
    const surface = comptime b.objectSurface("GlobalStaticSurfaceAccessor", .{
        b.surfaceFunctionGetter("value", declarations.function("getValue"), .{ .placement = .global_static }),
    }, .{ .cpp_class = "GlobalStaticSurfaceAccessorOwner" });
    try expectDiagnostic(&.{ declarations, b.moduleWithSurfaces("owner", .{surface}) }, "unsupported global-static surface member: value");
}

test "lazy rest buffers require copies" {
    try expectArgumentDiagnostic(b.argument("values", b.lazy(b.buffer(.lease)), .{
        .rest = true,
        .deferred_reason = "convert rest elements on demand",
    }), "rest arguments require copy ownership for buffers");
}

test "required fields that convert undefined cannot use presence reads" {
    try expectArgumentTypeDiagnostic(b.dictionary("MissingValue", .{
        b.dictionaryField("value", b.uint32, .{ .required = true, .missing_required = .convert_undefined, .missing = .absent }),
    }), "required dictionary fields that convert undefined must read a missing property as undefined: value");
}

test "lazy fields that convert undefined cannot use presence reads" {
    try expectArgumentTypeDiagnostic(b.dictionary("LazyMissingValue", .{
        b.dictionaryField("value", b.lazy(b.uint32), .{
            .required = true,
            .missing_required = .convert_undefined,
            .missing = .absent,
            .deferred_reason = "defer conversion until the value is needed",
        }),
    }), "required dictionary fields that convert undefined must read a missing property as undefined: value");
}

test "lazy dictionary fields cannot be Node-unsupported" {
    try expectArgumentTypeDiagnostic(b.dictionary("LazyUnsupported", .{
        b.dictionaryField("value", b.lazy(b.uint32), .{
            .required = true,
            .node_unsupported = "not implemented",
            .deferred_reason = "defer conversion until the value is needed",
        }),
    }), "lazy dictionary fields cannot be Node-unsupported: value");
}

test "Node sequence validation cannot prepare its elements" {
    const values = comptime b.sequenceWithOptions(b.sequenceWithOptions(b.uint32, .{ .container = .iterable }), .{
        .node_error = .{ .element = .{ .expected = "iterable" } },
    });
    try expectFunctionDiagnostic(b.function("consume", .{b.argument("values", values, .{})}, b.none, .{ .profile = .node }), "sequence elements cannot use prepared conversions");
}

const owned_payload = b.nominalHandle("OwnedPayload", .{
    .cpp_type = .{ .pointer = &.{ .named = "OwnedPayload" } },
    .cpp_declarations = &.{.{ .structure = "OwnedPayload" }},
    .ownership = .owned,
    .cpp_release = "releaseOwnedPayload",
    .access_thread = .any,
    .destroy_thread = .any,
});

test "domain errors cannot own nominal resources" {
    inline for (.{ b.Backend.cpp, b.Backend.zig }) |backend| {
        try expectFunctionDiagnostic(b.function("fail", .{}, b.none, .{
            .backend = backend,
            .errors = b.domainErrors(.{b.builtinError("failed", b.dictionary("FailurePayload", .{
                b.dictionaryField("resource", owned_payload, .{ .required = true }),
            }), .{ .group = "errors", .function = "materialize" })}),
        }), "domain error payloads cannot contain owned nominal handles");
    }
}

test "binding defaults are rejected before C++ lowering" {
    try expectArgumentDiagnostic(b.argument("value", b.int8, .{ .presence = .default_value, .default_value = .{ .signed = 128 } }), "integer binding default is outside the declared type");
    try expectArgumentDiagnostic(b.argument("value", b.double, .{ .presence = .default_value, .default_value = .{ .boolean = true } }), "floating-point binding default has the wrong type");
    try expectArgumentDiagnostic(b.argument("value", b.discardAny(.ignored), .{ .presence = .default_value, .default_value = .null }), "this binding type cannot have a default value");
    try expectArgumentDiagnostic(b.argument("value", b.lazy(b.uint32), .{
        .presence = .default_value,
        .default_value = .{ .unsigned = 0 },
        .deferred_reason = "defer value conversion",
    }), "lazy arguments cannot declare a default value");
}

test "native export argument adapters require allocation propagation" {
    try expectNativeExportDiagnostic(b.nativeExportWithOptions("consume", .{b.argument("values", b.sequence(b.uint8), .{})}, b.none, .{
        .throws = .never,
        .realm = .current,
    }), "native export requires error propagation for allocating C++ adapters");
}

test "native string conversions require JavaScript exception propagation" {
    try expectNativeExportDiagnostic(b.nativeExportWithOptions("consume", .{b.argument("value", b.coerceString(b.dom_string), .{})}, b.none, .{
        .throws = .never,
        .realm = .current,
    }), "coercing string native export arguments require JavaScript exception propagation");
}

test "engine result encoding allocation follows nested C++ facts" {
    inline for (comptime .{ b.buffer(.copy), b.sequence(b.uint32), b.record(b.thread_safe_dom_string, b.uint32) }) |result| {
        try expectEngineShimDiagnostic(b.engineShim("allocate", .{}, b.optional(result), realm_free_any_thread), "requires error propagation for allocating adapters");
    }
}

test "internal module registry output names cannot collide" {
    try expectFunctionDiagnostic(registryFunction(b.enumerationWithOptions("RegistryOutputs", .{
        b.enumerationValueWithOptions("TypeScript", "test:ts", .{ .internal_module = .{ .javascript = "internal/same.ts" } }),
        b.enumerationValueWithOptions("JavaScript", "test:js", .{ .internal_module = .{ .javascript = "internal/same.js" } }),
    }, .{ .internal_module_registry = true })), "internal module sources share a bundle output: internal/same.js");
}

test "engine and native converters cannot depend on a JavaScript receiver" {
    const value = comptime b.converted(b.uint32, b.dictionary("ReceiverMatch", .{
        b.dictionaryField("offset", b.size, .{
            .required = true,
            .profile = .node,
            .integer_conversion = .{ .node_receiver_byte_length = .integer },
        }),
    }), reviewedConverter("convertReceiverOffset"), .{});
    try expectEngineShimDiagnostic(b.engineShim("consume", .{b.argument("value", value, .{})}, b.none, .{
        .throws = .js_exception,
        .realm = .current,
        .affinity = .vm,
    }), "engine shim converters cannot depend on an object receiver: invalid_consume");
    try expectNativeExportDiagnostic(b.nativeExportWithOptions("consume", .{b.argument("value", value, .{})}, b.none, .{
        .throws = .js_exception,
        .realm = .current,
    }), "native export converters cannot depend on an object receiver: invalid_consume");
}
