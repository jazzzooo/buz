const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const blob_types = @import("binding_schema_BlobTypes");
const std = @import("std");

pub fn initInput(comptime image_ref: b.Type, comptime artifact_ref: b.BoundClass) b.Type {
    return b.unionType("BodyInitValue", .{
        b.unionMember("flag", b.boolean),
        b.unionMember("nulled", b.null_literal),
        b.unionMember("text", b.dom_string),
        b.unionMember("bytes", b.buffer(.lease)),
        b.unionMember("form_data", b.form_data),
        b.unionMember("url_search_params", b.url_search_params),
        b.unionMember("blob", b.blob),
        b.unionMember("image", image_ref),
        b.unionMember("stream", b.readable_stream),
        b.unionMember("artifact", b.classRef(artifact_ref)),
        b.unionMember("parts", b.sequenceWithOptions(
            blob_types.partValue("BodyPartValue", artifact_ref),
            .{ .snapshot_elements = true },
        )),
        b.unionMember("other", b.engine_value),
    }, .{ .ordered = true, .fallback_member = "other" });
}

pub const already_used_error = b.domainError("body_already_used", b.none, .{
    .class = .type_error,
    .code = "ERR_BODY_ALREADY_USED",
    .message = .{ .literal = "Body already used" },
});

const common_error_list = .{
    @import("binding_schema_S3Errors").service_failure,
    b.systemError("system"),
    already_used_error,
    b.domainError("body_error", b.thread_safe_dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.domainError("body_type_error", b.thread_safe_dom_string, .{
        .class = .type_error,
        .message = .payload,
    }),
};

const form_data_error_list = .{
    b.domainError("invalid_form_data_encoding", b.none, .{
        .class = .type_error,
        .code = "ERR_FORMDATA_PARSE_ERROR",
        .message = .{ .literal = "Can't decode form data from body because of incorrect MIME type/boundary" },
    }),
    b.domainError("form_data_parse_failed", b.thread_safe_dom_string, .{
        .class = .type_error,
        .code = "ERR_FORMDATA_PARSE_ERROR",
        .message = .payload,
    }),
};

fn resultType(comptime name: []const u8) b.Type {
    if (std.mem.eql(u8, name, "arrayBuffer")) return b.array_buffer_result;
    if (std.mem.eql(u8, name, "blob")) return b.classRefByName("Blob", "Blob");
    if (std.mem.eql(u8, name, "bytes")) return b.uint8_array_result;
    if (std.mem.eql(u8, name, "formData")) return b.classRefByName("WebCoreFormData", "FormData");
    if (std.mem.eql(u8, name, "json")) return b.any;
    if (std.mem.eql(u8, name, "text")) return b.dom_string;
    @compileError("unknown body consumption method");
}

pub fn consumptionMethod(
    comptime owner_module: []const u8,
    comptime owner_class: []const u8,
    comptime name: []const u8,
    comptime implementation: []const u8,
) b.ClassMember {
    return b.method(name, .{}, resultType(name), .{
        .implementation = implementation,
        .length = 0,
        .this_value_type = b.classRefByName(owner_module, owner_class),
        .completion = archetypes.vmCompletion(.ready_at_return),
        .errors = blob_types.readErrors(name, common_error_list ++ if (std.mem.eql(u8, name, "formData")) form_data_error_list else .{}),
    });
}

const functions = .{
    b.function("blobCompletion", .{}, b.classRefByName("Blob", "Blob"), .{
        .exposure = .never,
        .completion = archetypes.vmCompletion(.ready_at_return),
        .errors = b.domainErrors(common_error_list),
    }),
};

pub const schema = b.module("Body", functions);
