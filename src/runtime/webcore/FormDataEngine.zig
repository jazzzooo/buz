pub fn fromMultipartData(
    context: bun.bindgen.CallContext(FromMultipartDataSchema),
    args: bun.bindgen.Args(FromMultipartDataSchema),
) bun.bindgen.CallError(FromMultipartDataSchema)!bun.bindgen.ClassRef(FormDataSchema) {
    const input_value = args.input orelse return context.fail(.empty_input, {});
    var boundary_slice = bun.String.Slice.empty;
    defer boundary_slice.deinit();

    var encoding: FormData.Encoding = .{ .URLEncoded = {} };
    if (args.boundary) |boundary| switch (boundary) {
        .value => |value| switch (value) {
            .buffer => |buffer| {
                const bytes = buffer.unsafePtr("The generated entry frame owns the boundary lease until FormData parsing and entry creation finish before dispatch returns");
                if (bytes.len > 0) encoding = .{ .Multipart = bytes };
            },
            .string => |boundary_string| {
                boundary_slice = try boundary_string.toUTF8(bun.default_allocator);
                if (boundary_slice.length() > 0) encoding = .{ .Multipart = boundary_slice.slice() };
            },
        },
        .invalid => return context.fail(.invalid_boundary, {}),
    };

    var input_slice = bun.String.Slice.empty;
    defer input_slice.deinit();
    const input = switch (input_value) {
        .value => |value| switch (value) {
            .blob => |blob| blob.get().sharedView(),
            .buffer => |buffer| buffer.unsafePtr("The generated entry frame owns the input lease until FormData parsing and entry creation finish before dispatch returns"),
            .string => |input_string| input: {
                input_slice = try input_string.toUTF8(bun.default_allocator);
                break :input input_slice.slice();
            },
        },
        .invalid => return context.fail(.invalid_input, {}),
    };

    if (encoding == .URLEncoded and input.len > bun.JavaScriptLimits.stringAllocationLimit()) {
        return context.fail(.string_too_long, {});
    }

    return toClassRef(context, input, encoding) catch |err| switch (err) {
        error.JSError => return error.JSError,
        error.JSTerminated => return error.JSTerminated,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const message_bytes = try std.fmt.allocPrint(
                bun.default_allocator,
                "{s} while parsing FormData",
                .{@errorName(err)},
            );
            defer bun.default_allocator.free(message_bytes);
            return context.fail(.parse_failed, try bun.bindgen.DOMString.fromUTF8(message_bytes));
        },
    };
}

pub fn toClassRef(
    context: anytype,
    input: []const u8,
    encoding: FormData.Encoding,
) (FormData.MultipartParseError || bun.JSError)!bun.bindgen.ClassRef(FormDataSchema) {
    return switch (encoding) {
        .URLEncoded => result: {
            const resource = try context.engineIn("WebCoreFormData", "formDataCreateFromURLQuery").call(.{
                .query = bun.bindgen.BytesOperand.fromSlice(bun.strings.withoutUTF8BOM(input)),
            });
            break :result FormDataObject.Binding.adoptResult(try FormDataObject.create(resource), context);
        },
        .Multipart => |boundary| toClassRefFromMultipartData(context, input, boundary),
    };
}

fn toClassRefFromMultipartData(
    context: anytype,
    input: []const u8,
    boundary: []const u8,
) (FormData.MultipartParseError || bun.JSError)!bun.bindgen.ClassRef(FormDataSchema) {
    var resource = try context.engineIn("WebCoreFormData", "formDataCreate").call(.{});
    errdefer resource.deinit();

    const Wrapper = struct {
        context: @TypeOf(context),
        form: *bun.jsc.DOMFormData,

        pub fn onEntry(wrap: *@This(), name: []const u8, field: FormData.Field) bun.JSError!void {
            if (field.filename) |filename| {
                try wrap.context.engineIn("WebCoreFormData", "formDataAppendFile").call(.{
                    .form = wrap.form,
                    .name = bun.bindgen.BytesOperand.fromSlice(name),
                    .value = bun.bindgen.BytesOperand.fromSlice(field.value),
                    .filename = bun.bindgen.BytesOperand.fromSlice(filename),
                    .contentType = bun.bindgen.BytesOperand.fromSlice(FormData.fileContentType(field)),
                });
            } else {
                try wrap.context.engineIn("WebCoreFormData", "formDataAppend").call(.{
                    .form = wrap.form,
                    .name = bun.bindgen.BytesOperand.fromSlice(name),
                    .value = bun.bindgen.BytesOperand.fromSlice(bun.strings.withoutUTF8BOM(field.value)),
                });
            }
        }
    };

    var wrapper = Wrapper{ .context = context, .form = resource.get() };
    try FormData.forEachMultipartEntry(input, boundary, *Wrapper, &wrapper, Wrapper.onEntry);
    const object = try FormDataObject.create(resource.take());
    return FormDataObject.Binding.adoptResult(object, context);
}

const std = @import("std");
const bun = @import("bun");
const FormData = @import("./FormData.zig").FormData;
const FormDataObject = @import("../../jsc/DOMFormData.zig").FormDataObject;
const WebCoreBindings = bun.bindgen.Module("WebCoreFormData");
const FormDataSchema = WebCoreBindings.class("FormData");
const FromMultipartDataSchema = FormDataSchema.member("from");
