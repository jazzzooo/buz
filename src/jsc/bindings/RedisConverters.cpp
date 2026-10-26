#include "root.h"

#include "SchemaBindings.h"
#include "StringConversion.h"

namespace Bun::Bindgen::Custom {

WTF::Vector<uint8_t> bunBindgenRedisScalarBytes(
    JSC::JSGlobalObject& global,
    const Bun::Bindgen::RedisScalarInput& value,
    WTF::ASCIILiteral)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    WTF::String string;
    if (value.is_string())
        string = value.string();
    else {
        RELEASE_ASSERT(value.is_number());
        string = JSC::jsNumber(value.number()).toWTFString(&global);
        RETURN_IF_EXCEPTION(scope, {});
    }
    auto bytes = Bun::encodeUTF8ReplacingInvalidSequences(string);
    if (!bytes) {
        JSC::throwOutOfMemoryError(&global, scope);
        return {};
    }
    return WTF::move(*bytes);
}

}
