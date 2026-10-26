#include "root.h"

#include "BunBuiltinNames.h"
#include "SchemaBindings.h"
#include "StringConversion.h"
#include "webcore/JSWritableStream.h"
#include <JavaScriptCore/JSArrayBuffer.h>
#include <span>

namespace Bun::Bindgen::Custom {

bool bunBindgenIsWritableStream(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<WebCore::JSWritableStream>(value);
}

bool bunBindgenIsTransformStream(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    if (!object)
        return false;
    auto readable = object->getDirect(object->vm(), WebCore::builtinNames(object->vm()).readablePrivateName());
    return readable && readable.isObject();
}

bool bunBindgenIsArrayBuffer(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<JSC::JSArrayBuffer>(value);
}

bool bunBindgenIsCompressionStream(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    return object && object->getDirect(object->vm(), WebCore::builtinNames(object->vm()).compressionStreamReadablePrivateName());
}

bool bunBindgenIsDecompressionStream(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    return object && object->getDirect(object->vm(), WebCore::builtinNames(object->vm()).decompressionStreamReadablePrivateName());
}

bool bunBindgenIsSubtleCrypto(JSC::JSValue value) noexcept
{
    auto* object = value.getObject();
    return object && object->getDirect(object->vm(), WebCore::builtinNames(object->vm()).subtleCryptoBrandPrivateName());
}

std::optional<HTTPMethodKind> bunBindgenHTTPMethodOrIgnored(JSC::JSGlobalObject& global, const std::optional<WTF::String>& name, WTF::ASCIILiteral)
{
    if (!name)
        return std::nullopt;
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto utf8 = Bun::encodeUTF8ReplacingInvalidSequences(*name);
    if (!utf8) {
        JSC::throwOutOfMemoryError(&global, scope);
        return std::nullopt;
    }
    return Bun::Bindgen::ZigExports::bunBindgenZig_HTTPMethod_from(utf8->span());
}

}
