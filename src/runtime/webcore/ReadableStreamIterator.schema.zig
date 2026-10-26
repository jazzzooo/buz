const b = @import("bindgen_schema");

const brand = b.cppBrand("ReadableStreamIterator", .{
    .symbol = "Bun::Bindgen::TypePredicates::isReadableStreamIterator",
    .header = "BindgenTypePredicates.h",
}, "AsyncIterableIterator<unknown>");

pub const value = b.brandedValueWithBrand(brand, .{});
pub const reader_brand = b.cppBrand("ReadableStreamDefaultReader", .{
    .symbol = "Bun::Bindgen::TypePredicates::isReadableStreamDefaultReader",
    .header = "BindgenTypePredicates.h",
}, "ReadableStreamDefaultReader");
pub const reader_value = b.brandedValueWithBrand(reader_brand, .{});
const reader = b.optional(reader_value);
const iteration_result = b.promise(b.dictionary("ReadableStreamIterationResult", .{
    b.dictionaryField("value", b.any, .{ .required = true }),
    b.dictionaryField("done", b.boolean, .{ .required = true }),
}));

pub const schema = b.moduleWithClasses("ReadableStreamIterator", .{}, .{
    b.plainClassWithDataProperties(
        "ReadableStreamIterator",
        b.constructor(.{}, .{ .exposure = .never }),
        .{
            b.method("next", .{}, iteration_result, .{
                .backend = .builtin,
                .builtin = "readableStreamInternalsReadableStreamIteratorNextCodeGenerator",
                .length = 0,
                .configurable = true,
            }),
            b.method("return", .{
                b.argument("value", b.any, .{ .presence = .optional, .missing = .undefined }),
            }, iteration_result, .{
                .backend = .builtin,
                .builtin = "readableStreamInternalsReadableStreamIteratorReturnCodeGenerator",
                .length = 1,
                .configurable = true,
            }),
        },
        .{
            b.instanceProperty("brand", .{ .value = b.boolean, .private_symbol = "readableStreamIteratorBrand" }),
            b.instanceProperty("reader", .{ .value = reader, .private_symbol = "readableStreamIteratorReader" }),
            b.instanceProperty("preventCancel", .{ .value = b.boolean, .private_symbol = "readableStreamIteratorPreventCancel" }),
            b.instanceProperty("ongoing", .{ .value = b.optional(b.js_promise), .private_symbol = "readableStreamIteratorOngoing" }),
            b.instanceProperty("finished", .{ .value = b.boolean, .private_symbol = "readableStreamIteratorFinished" }),
        },
        .{b.dataProperty("toStringTag", .{ .string = "ReadableStream AsyncIterator" }, .{
            .symbol = .to_string_tag,
            .enumerable = false,
        })},
        .{
            .backend = .cpp,
            .profile = .exact,
            .representation = .plain,
            .brand = brand,
            .display_name = "ReadableStream AsyncIterator",
            .prototype_base = .async_iterator,
            .plain_reason = "Iterator progress and reader ownership are JavaScript properties; promise chaining serializes operations without native state",
        },
    ),
});

pub const readable_stream_iterator = schema.class("ReadableStreamIterator");
pub const state = b.dictionaryWithOptions(
    "ReadableStreamIteratorState",
    b.plainClassResult(readable_stream_iterator).dictionary.fields,
    .{ .cpp_name = "ReadableStreamIteratorState", .result_class = readable_stream_iterator },
);
