#pragma once

#include <JavaScriptCore/ErrorType.h>
#include <wtf/text/ASCIILiteral.h>

namespace Bun::Bindgen {

struct ErrorCodeInfo {
    JSC::ErrorType type;
    WTF::ASCIILiteral name;
    WTF::ASCIILiteral code;
};

}
