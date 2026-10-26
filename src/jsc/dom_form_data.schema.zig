const b = @import("bindgen_schema");
const engine_types = @import("binding_schema_engine_types");

pub const dom_form_data = b.nominalHandle("DOMFormData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::DOMFormData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::DOMFormData" }},
    .zig_type = "jsc.DOMFormData",
    .access_thread = .vm,
});

pub const owned_form_data = b.nominalHandle("OwnedDOMFormData", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::DOMFormData" } },
    .cpp_declarations = &.{.{ .class = "WebCore::DOMFormData" }},
    .zig_type = "jsc.DOMFormData",
    .ownership = .owned,
    .cpp_release = "releaseDOMFormData",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

pub const iterator_handle = b.nominalHandle("DOMFormDataIterator", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::DOMFormData::Iterator" } },
    .cpp_declarations = &.{.{ .include = .{ .path = "DOMFormData.h", .system = false } }},
    .ownership = .owned,
    .cpp_release = "releaseDOMFormDataIterator",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

const file_entry = b.dictionary("DOMFormDataFileEntry", .{
    b.dictionaryField("blob", engine_types.native_blob, .{ .required = true }),
    b.dictionaryField("filename", b.dom_string, .{ .required = true }),
});
const entry_value = b.unionType("DOMFormDataEntryValue", .{
    b.unionMember("string", b.dom_string),
    b.unionMember("file", file_entry),
}, .{});
const entry = b.dictionary("DOMFormDataEntry", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("value", entry_value, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim("domFormDataRetain", .{b.argument("form", dom_form_data, .{})}, owned_form_data, .vm_thread_nonthrowing),
    b.engineShim("domFormDataMemoryCost", .{b.argument("form", dom_form_data, .{})}, b.size, .vm_thread_nonthrowing),
    b.engineShim("domFormDataIteratorCreate", .{b.argument("form", dom_form_data, .{})}, iterator_handle, .vm_thread_allocating),
    b.engineShim(
        "domFormDataEntry",
        .{
            b.argument("form", dom_form_data, .{}),
            b.argument("index", b.size, .{}),
        },
        b.optional(entry),
        .vm_thread_nonthrowing,
    ),
};

pub const schema = b.moduleWithDeclarations("dom_form_data", .{}, .{}, engine_shims, .{
    b.nativeExportWithOptions("formDataRetainFromWrapper", .{
        b.argument("value", b.classRefByName("WebCoreFormData", "FormData"), .{}),
    }, owned_form_data, .current_realm_throwing),
});
