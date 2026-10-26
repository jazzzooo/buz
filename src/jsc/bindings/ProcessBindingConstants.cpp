#include "NodeConstantsModule.h"
#include "ProcessBindingConstants.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include <brotli/encode.h>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>

namespace Bun {
using namespace JSC;

static JSValue processBindingConstantsGetTrace(VM& vm, JSObject* bindingObject)
{
    auto globalObject = bindingObject->globalObject();
    auto object = JSC::constructEmptyObject(vm, globalObject->nullPrototypeObjectStructure());
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_BEGIN"_s)), jsNumber(66));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_END"_s)), jsNumber(69));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_COMPLETE"_s)), jsNumber(88));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_INSTANT"_s)), jsNumber(73));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_ASYNC_BEGIN"_s)), jsNumber(83));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_ASYNC_STEP_INTO"_s)), jsNumber(84));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_ASYNC_STEP_PAST"_s)), jsNumber(112));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_ASYNC_END"_s)), jsNumber(70));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_NESTABLE_ASYNC_BEGIN"_s)), jsNumber(98));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_NESTABLE_ASYNC_END"_s)), jsNumber(101));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_NESTABLE_ASYNC_INSTANT"_s)), jsNumber(110));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_FLOW_BEGIN"_s)), jsNumber(115));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_FLOW_STEP"_s)), jsNumber(116));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_FLOW_END"_s)), jsNumber(102));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_METADATA"_s)), jsNumber(77));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_COUNTER"_s)), jsNumber(67));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_SAMPLE"_s)), jsNumber(80));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_CREATE_OBJECT"_s)), jsNumber(78));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_SNAPSHOT_OBJECT"_s)), jsNumber(79));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_DELETE_OBJECT"_s)), jsNumber(68));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_MEMORY_DUMP"_s)), jsNumber(118));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_MARK"_s)), jsNumber(82));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_CLOCK_SYNC"_s)), jsNumber(99));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_ENTER_CONTEXT"_s)), jsNumber(40));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_LEAVE_CONTEXT"_s)), jsNumber(41));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "TRACE_EVENT_PHASE_LINK_IDS"_s)), jsNumber(61));
    return object;
}

static JSValue processBindingConstantsGetZlib(VM& vm, JSObject* bindingObject)
{
    auto globalObject = bindingObject->globalObject();
    auto object = JSC::constructEmptyObject(vm, globalObject->nullPrototypeObjectStructure());
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_NO_FLUSH"_s)), jsNumber(Z_NO_FLUSH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_PARTIAL_FLUSH"_s)), jsNumber(Z_PARTIAL_FLUSH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_SYNC_FLUSH"_s)), jsNumber(Z_SYNC_FLUSH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_FULL_FLUSH"_s)), jsNumber(Z_FULL_FLUSH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_FINISH"_s)), jsNumber(Z_FINISH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_BLOCK"_s)), jsNumber(Z_BLOCK));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_OK"_s)), jsNumber(Z_OK));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_STREAM_END"_s)), jsNumber(Z_STREAM_END));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_NEED_DICT"_s)), jsNumber(Z_NEED_DICT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_ERRNO"_s)), jsNumber(Z_ERRNO));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_STREAM_ERROR"_s)), jsNumber(Z_STREAM_ERROR));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DATA_ERROR"_s)), jsNumber(Z_DATA_ERROR));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MEM_ERROR"_s)), jsNumber(Z_MEM_ERROR));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_BUF_ERROR"_s)), jsNumber(Z_BUF_ERROR));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_VERSION_ERROR"_s)), jsNumber(Z_VERSION_ERROR));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_NO_COMPRESSION"_s)), jsNumber(Z_NO_COMPRESSION));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_BEST_SPEED"_s)), jsNumber(Z_BEST_SPEED));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_BEST_COMPRESSION"_s)), jsNumber(Z_BEST_COMPRESSION));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DEFAULT_COMPRESSION"_s)), jsNumber(Z_DEFAULT_COMPRESSION));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_FILTERED"_s)), jsNumber(Z_FILTERED));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_HUFFMAN_ONLY"_s)), jsNumber(Z_HUFFMAN_ONLY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_RLE"_s)), jsNumber(Z_RLE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_FIXED"_s)), jsNumber(Z_FIXED));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DEFAULT_STRATEGY"_s)), jsNumber(Z_DEFAULT_STRATEGY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZLIB_VERNUM"_s)), jsNumber(ZLIB_VERNUM));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "DEFLATE"_s)), jsNumber(1));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "INFLATE"_s)), jsNumber(2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "GZIP"_s)), jsNumber(3));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "GUNZIP"_s)), jsNumber(4));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "DEFLATERAW"_s)), jsNumber(5));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "INFLATERAW"_s)), jsNumber(6));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "UNZIP"_s)), jsNumber(7));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODE"_s)), jsNumber(8));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_ENCODE"_s)), jsNumber(9));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_COMPRESS"_s)), jsNumber(10));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_DECOMPRESS"_s)), jsNumber(11));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MIN_WINDOWBITS"_s)), jsNumber(8));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MAX_WINDOWBITS"_s)), jsNumber(15));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DEFAULT_WINDOWBITS"_s)), jsNumber(15));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MIN_CHUNK"_s)), jsNumber(64));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MAX_CHUNK"_s)), jsNumber(std::numeric_limits<double>::infinity()));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DEFAULT_CHUNK"_s)), jsNumber(16 * 1024));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MIN_MEMLEVEL"_s)), jsNumber(1));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MAX_MEMLEVEL"_s)), jsNumber(9));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DEFAULT_MEMLEVEL"_s)), jsNumber(8));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MIN_LEVEL"_s)), jsNumber(-1));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_MAX_LEVEL"_s)), jsNumber(9));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "Z_DEFAULT_LEVEL"_s)), jsNumber(Z_DEFAULT_COMPRESSION));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_OPERATION_PROCESS"_s)), jsNumber(BROTLI_OPERATION_PROCESS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_OPERATION_FLUSH"_s)), jsNumber(BROTLI_OPERATION_FLUSH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_OPERATION_FINISH"_s)), jsNumber(BROTLI_OPERATION_FINISH));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_OPERATION_EMIT_METADATA"_s)), jsNumber(BROTLI_OPERATION_EMIT_METADATA));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_MODE"_s)), jsNumber(BROTLI_PARAM_MODE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MODE_GENERIC"_s)), jsNumber(BROTLI_MODE_GENERIC));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MODE_TEXT"_s)), jsNumber(BROTLI_MODE_TEXT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MODE_FONT"_s)), jsNumber(BROTLI_MODE_FONT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DEFAULT_MODE"_s)), jsNumber(BROTLI_DEFAULT_MODE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_QUALITY"_s)), jsNumber(BROTLI_PARAM_QUALITY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MIN_QUALITY"_s)), jsNumber(BROTLI_MIN_QUALITY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MAX_QUALITY"_s)), jsNumber(BROTLI_MAX_QUALITY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DEFAULT_QUALITY"_s)), jsNumber(BROTLI_DEFAULT_QUALITY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_LGWIN"_s)), jsNumber(BROTLI_PARAM_LGWIN));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MIN_WINDOW_BITS"_s)), jsNumber(BROTLI_MIN_WINDOW_BITS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MAX_WINDOW_BITS"_s)), jsNumber(BROTLI_MAX_WINDOW_BITS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_LARGE_MAX_WINDOW_BITS"_s)), jsNumber(BROTLI_LARGE_MAX_WINDOW_BITS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DEFAULT_WINDOW"_s)), jsNumber(BROTLI_DEFAULT_WINDOW));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_LGBLOCK"_s)), jsNumber(BROTLI_PARAM_LGBLOCK));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MIN_INPUT_BLOCK_BITS"_s)), jsNumber(BROTLI_MIN_INPUT_BLOCK_BITS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_MAX_INPUT_BLOCK_BITS"_s)), jsNumber(BROTLI_MAX_INPUT_BLOCK_BITS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_DISABLE_LITERAL_CONTEXT_MODELING"_s)), jsNumber(BROTLI_PARAM_DISABLE_LITERAL_CONTEXT_MODELING));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_SIZE_HINT"_s)), jsNumber(BROTLI_PARAM_SIZE_HINT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_LARGE_WINDOW"_s)), jsNumber(BROTLI_PARAM_LARGE_WINDOW));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_NPOSTFIX"_s)), jsNumber(BROTLI_PARAM_NPOSTFIX));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_PARAM_NDIRECT"_s)), jsNumber(BROTLI_PARAM_NDIRECT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_RESULT_ERROR"_s)), jsNumber(BROTLI_DECODER_RESULT_ERROR));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_RESULT_SUCCESS"_s)), jsNumber(BROTLI_DECODER_RESULT_SUCCESS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT"_s)), jsNumber(BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT"_s)), jsNumber(BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_PARAM_DISABLE_RING_BUFFER_REALLOCATION"_s)), jsNumber(BROTLI_DECODER_PARAM_DISABLE_RING_BUFFER_REALLOCATION));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_PARAM_LARGE_WINDOW"_s)), jsNumber(BROTLI_DECODER_PARAM_LARGE_WINDOW));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_NO_ERROR"_s)), jsNumber(BROTLI_DECODER_NO_ERROR));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_SUCCESS"_s)), jsNumber(BROTLI_DECODER_SUCCESS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_NEEDS_MORE_INPUT"_s)), jsNumber(BROTLI_DECODER_NEEDS_MORE_INPUT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_NEEDS_MORE_OUTPUT"_s)), jsNumber(BROTLI_DECODER_NEEDS_MORE_OUTPUT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_RESERVED"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_RESERVED));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_CL_SPACE"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_CL_SPACE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_TRANSFORM"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_TRANSFORM));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_DICTIONARY"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_DICTIONARY));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_PADDING_1"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_PADDING_1));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_PADDING_2"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_PADDING_2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_FORMAT_DISTANCE"_s)), jsNumber(BROTLI_DECODER_ERROR_FORMAT_DISTANCE));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET"_s)), jsNumber(BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_INVALID_ARGUMENTS"_s)), jsNumber(BROTLI_DECODER_ERROR_INVALID_ARGUMENTS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES"_s)), jsNumber(BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS"_s)), jsNumber(BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP"_s)), jsNumber(BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1"_s)), jsNumber(BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2"_s)), jsNumber(BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES"_s)), jsNumber(BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "BROTLI_DECODER_ERROR_UNREACHABLE"_s)), jsNumber(BROTLI_DECODER_ERROR_UNREACHABLE));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_e_continue"_s)), jsNumber(ZSTD_e_continue));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_e_flush"_s)), jsNumber(ZSTD_e_flush));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_e_end"_s)), jsNumber(ZSTD_e_end));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_fast"_s)), jsNumber(ZSTD_fast));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_dfast"_s)), jsNumber(ZSTD_dfast));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_greedy"_s)), jsNumber(ZSTD_greedy));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_lazy"_s)), jsNumber(ZSTD_lazy));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_lazy2"_s)), jsNumber(ZSTD_lazy2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_btlazy2"_s)), jsNumber(ZSTD_btlazy2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_btopt"_s)), jsNumber(ZSTD_btopt));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_btultra"_s)), jsNumber(ZSTD_btultra));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_btultra2"_s)), jsNumber(ZSTD_btultra2));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_compressionLevel"_s)), jsNumber(ZSTD_c_compressionLevel));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_windowLog"_s)), jsNumber(ZSTD_c_windowLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_hashLog"_s)), jsNumber(ZSTD_c_hashLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_chainLog"_s)), jsNumber(ZSTD_c_chainLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_searchLog"_s)), jsNumber(ZSTD_c_searchLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_minMatch"_s)), jsNumber(ZSTD_c_minMatch));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_targetLength"_s)), jsNumber(ZSTD_c_targetLength));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_strategy"_s)), jsNumber(ZSTD_c_strategy));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_enableLongDistanceMatching"_s)), jsNumber(ZSTD_c_enableLongDistanceMatching));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_ldmHashLog"_s)), jsNumber(ZSTD_c_ldmHashLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_ldmMinMatch"_s)), jsNumber(ZSTD_c_ldmMinMatch));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_ldmBucketSizeLog"_s)), jsNumber(ZSTD_c_ldmBucketSizeLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_ldmHashRateLog"_s)), jsNumber(ZSTD_c_ldmHashRateLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_contentSizeFlag"_s)), jsNumber(ZSTD_c_contentSizeFlag));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_checksumFlag"_s)), jsNumber(ZSTD_c_checksumFlag));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_dictIDFlag"_s)), jsNumber(ZSTD_c_dictIDFlag));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_nbWorkers"_s)), jsNumber(ZSTD_c_nbWorkers));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_jobSize"_s)), jsNumber(ZSTD_c_jobSize));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_c_overlapLog"_s)), jsNumber(ZSTD_c_overlapLog));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_d_windowLogMax"_s)), jsNumber(ZSTD_d_windowLogMax));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_CLEVEL_DEFAULT"_s)), jsNumber(ZSTD_CLEVEL_DEFAULT));

    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_no_error"_s)), jsNumber(ZSTD_error_no_error));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_GENERIC"_s)), jsNumber(ZSTD_error_GENERIC));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_prefix_unknown"_s)), jsNumber(ZSTD_error_prefix_unknown));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_version_unsupported"_s)), jsNumber(ZSTD_error_version_unsupported));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_frameParameter_unsupported"_s)), jsNumber(ZSTD_error_frameParameter_unsupported));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_frameParameter_windowTooLarge"_s)), jsNumber(ZSTD_error_frameParameter_windowTooLarge));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_corruption_detected"_s)), jsNumber(ZSTD_error_corruption_detected));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_checksum_wrong"_s)), jsNumber(ZSTD_error_checksum_wrong));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_literals_headerWrong"_s)), jsNumber(ZSTD_error_literals_headerWrong));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_dictionary_corrupted"_s)), jsNumber(ZSTD_error_dictionary_corrupted));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_dictionary_wrong"_s)), jsNumber(ZSTD_error_dictionary_wrong));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_dictionaryCreation_failed"_s)), jsNumber(ZSTD_error_dictionaryCreation_failed));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_parameter_unsupported"_s)), jsNumber(ZSTD_error_parameter_unsupported));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_parameter_combination_unsupported"_s)), jsNumber(ZSTD_error_parameter_combination_unsupported));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_parameter_outOfBound"_s)), jsNumber(ZSTD_error_parameter_outOfBound));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_tableLog_tooLarge"_s)), jsNumber(ZSTD_error_tableLog_tooLarge));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_maxSymbolValue_tooLarge"_s)), jsNumber(ZSTD_error_maxSymbolValue_tooLarge));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_maxSymbolValue_tooSmall"_s)), jsNumber(ZSTD_error_maxSymbolValue_tooSmall));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_stabilityCondition_notRespected"_s)), jsNumber(ZSTD_error_stabilityCondition_notRespected));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_stage_wrong"_s)), jsNumber(ZSTD_error_stage_wrong));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_init_missing"_s)), jsNumber(ZSTD_error_init_missing));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_memory_allocation"_s)), jsNumber(ZSTD_error_memory_allocation));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_workSpace_tooSmall"_s)), jsNumber(ZSTD_error_workSpace_tooSmall));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_dstSize_tooSmall"_s)), jsNumber(ZSTD_error_dstSize_tooSmall));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_srcSize_wrong"_s)), jsNumber(ZSTD_error_srcSize_wrong));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_dstBuffer_null"_s)), jsNumber(ZSTD_error_dstBuffer_null));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_noForwardProgress_destFull"_s)), jsNumber(ZSTD_error_noForwardProgress_destFull));
    object->putDirect(vm, PropertyName(Identifier::fromString(vm, "ZSTD_error_noForwardProgress_inputEmpty"_s)), jsNumber(ZSTD_error_noForwardProgress_inputEmpty));

    return object;
}

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingConstants
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingConstants

const ClassInfo ProcessBindingConstants::s_info = { "ProcessBindingConstants"_s, &Base::s_info, &bunBindgenObjectSurface_ProcessBindingConstantsTable, nullptr, CREATE_METHOD_TABLE(ProcessBindingConstants) };

ProcessBindingConstants* ProcessBindingConstants::create(VM& vm, Structure* structure)
{
    ProcessBindingConstants* obj = new (NotNull, allocateCell<ProcessBindingConstants>(vm)) ProcessBindingConstants(vm, structure);
    obj->finishCreation(vm);
    return obj;
}

Structure* ProcessBindingConstants::createStructure(VM& vm, JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(ObjectType, StructureFlags), ProcessBindingConstants::info());
}

void ProcessBindingConstants::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

template<typename Visitor>
void ProcessBindingConstants::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    ProcessBindingConstants* thisObject = uncheckedDowncast<ProcessBindingConstants>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(ProcessBindingConstants);

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, Callback)                                      \
    JSC::JSValue Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                                      \
        Bindgen::CppCallContext& context,                                                               \
        const Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)                       \
    {                                                                                                   \
        return Callback(context.globalObject.vm(), JSC::asObject(args.bindingThis));                     \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, processBindingConstantsGetZlib, processBindingConstantsGetZlib)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, processBindingConstantsGetTrace, processBindingConstantsGetTrace)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

} // namespace Bun
