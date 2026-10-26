const b = @import("bindgen_schema");

pub const module_object = b.brandedValueWithBrand(b.cppBrand("CommonJSModuleObject", .{
    .symbol = "Bun::Bindgen::TypePredicates::isCommonJSModule",
    .header = "BindgenTypePredicates.h",
}, "object"), .{
    .error_kind = .instance,
    .expectation = "a CommonJS module object",
    .node_requirement = "CommonJSModule",
});

pub const non_empty_resolve_specifier = b.coerceStringWithOptions(b.dom_string, .{
    .empty_rejection = .{
        .code = "ERR_INVALID_ARG_VALUE",
        .message = "The argument 'id' must be a non-empty string. Received ''",
    },
});

pub const schema = b.module("NodeModuleTypes", .{});
