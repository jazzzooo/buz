#pragma once

#include <span>
#include <wtf/Expected.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace JSC {
class JSGlobalObject;
class JSValue;
}

namespace Bun {

size_t stringSyntheticAllocationLimit();

JSC::JSValue toJSArray(JSC::JSGlobalObject*, std::span<const WTF::String>);

enum class UTF8Termination : uint8_t { None,
    Null };

Expected<WTF::String, WTF::UTF8ConversionError> decodeUTF8ReplacingInvalidSequences(std::span<const uint8_t>);

// Null termination includes the trailing zero in the returned vector.
Expected<WTF::Vector<uint8_t>, WTF::UTF8ConversionError> encodeUTF8ReplacingInvalidSequences(
    WTF::StringView, UTF8Termination = UTF8Termination::None);

}
