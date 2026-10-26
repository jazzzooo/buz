#pragma once

#include "BufferEncodingType.h"
#include <optional>
#include <wtf/text/StringView.h>

namespace WebCore {

std::optional<BufferEncodingType> parseBufferEncoding(const WTF::StringView&);

} // namespace WebCore
