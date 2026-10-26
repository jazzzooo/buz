const b = @import("bindgen_schema");
const streams = @import("binding_schema_WebCoreStreams");
const stream_iterator = @import("binding_schema_ReadableStreamIterator");

const functions = .{
    b.typePredicate("isBlob", b.classRefByName("Blob", "Blob")),
    b.typePredicate("isReadableStream", b.readable_stream),
    b.typePredicate("isWritableStream", b.writable_stream),
    b.typePredicate("isTransformStream", b.transform_stream),
    b.typePredicate("isInternalWritableStream", streams.internal_writable_stream_value),
    b.typePredicate("isWritableStreamDefaultWriter", b.classValue(streams.writable_stream_default_writer)),
    b.typePredicate("isWritableStreamDefaultController", b.classValue(streams.writable_stream_default_controller)),
    b.typePredicate("isTransformStreamDefaultController", b.classValue(streams.transform_stream_default_controller)),
    b.typePredicate("isReadableStreamDefaultReader", b.classValue(streams.readable_stream_default_reader)),
    b.typePredicate("isReadableStreamBYOBReader", b.classValue(streams.readable_stream_byob_reader)),
    b.typePredicate("isReadableStreamBYOBRequest", b.classValue(streams.readable_stream_byob_request)),
    b.typePredicate("isReadableStreamDefaultController", b.classValue(streams.readable_stream_default_controller)),
    b.typePredicate("isReadableByteStreamController", b.classValue(streams.readable_byte_stream_controller)),
    b.typePredicate("isReadableStreamIterator", stream_iterator.value),
    b.typePredicate("isArrayBuffer", b.array_buffer_object),
    b.typePredicate("isCompressionStream", b.classValue(streams.compression_stream)),
    b.typePredicate("isDecompressionStream", b.classValue(streams.decompression_stream)),
};

pub const schema = b.module("NativeTypePredicates", functions);
