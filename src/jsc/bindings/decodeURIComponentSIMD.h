#pragma once

#include <span>
#include <wtf/Expected.h>
#include <wtf/text/WTFString.h>

namespace Bun {

Expected<WTF::String, WTF::UTF8ConversionError> decodeURIComponentSIMD(std::span<const uint8_t> input);

}
