#include "root.h"

#include "Bindgen/IDLConvertBase.h"
#include "JSBufferEncodingType.h"
#include "NodeValidator.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSGlobalObjectFunctions.h>
#include <JavaScriptCore/ParseInt.h>
#include <cmath>
#include <limits>
#include <optional>

namespace Bun::Bindgen::Custom {

template<typename Input>
static WTF::String stringLikeValue(JSC::JSGlobalObject& global, const Input& input)
{
    if (input.is_string())
        return input.string();

    RELEASE_ASSERT(input.is_boxed());
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto result = input.boxed().toWTFString(&global);
    RETURN_IF_EXCEPTION(scope, {});
    scope.release();
    return result;
}

WTF::String bunBindgenStringLikeDOMString(JSC::JSGlobalObject& global, const StringLikeInput& input, WTF::ASCIILiteral)
{
    return stringLikeValue(global, input);
}

BufferEncoding bunBindgenSocketEncoding(const std::optional<WTF::String>& value, WTF::ASCIILiteral)
{
    if (!value)
        return BufferEncoding::utf8;
    if (WTF::equalIgnoringASCIICase(*value, "buffer"_s))
        return BufferEncoding::buffer;
    return WebCore::parseBufferEncoding(*value).value_or(BufferEncoding::utf8);
}

BufferEncoding bunBindgenSocketEncoding(WTF::String const& value, WTF::ASCIILiteral)
{
    if (WTF::equalIgnoringASCIICase(value, "buffer"_s))
        return BufferEncoding::buffer;
    return WebCore::parseBufferEncoding(value).value_or(BufferEncoding::utf8);
}

uint16_t bunBindgenNodePort(JSC::JSGlobalObject& global, const Bun::Bindgen::NodePortInput& input, WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    RELEASE_ASSERT(input.is_number() || input.is_string());
    auto throwBadPort = [&]() -> uint16_t {
        JSC::JSValue value = input.is_number()
            ? JSC::jsNumber(input.number())
            : JSC::JSValue(JSC::jsString(global.vm(), input.string()));
        RETURN_IF_EXCEPTION(scope, 0);
        auto argumentName = JSC::jsString(global.vm(), WTF::String(name));
        RETURN_IF_EXCEPTION(scope, 0);
        Bun::ERR::SOCKET_BAD_PORT(scope, &global, argumentName, value, true);
        return 0;
    };

    if (input.is_string()) {
        auto trimmed = WTF::StringView(input.string()).trim([](auto character) {
            return JSC::isStrWhiteSpace(character);
        });
        if (trimmed.isEmpty())
            return throwBadPort();
    }

    auto port = input.is_number() ? input.number() : JSC::jsToNumber(WTF::StringView(input.string()));
    if (!std::isfinite(port) || std::trunc(port) != port || port < 0 || port > std::numeric_limits<uint16_t>::max())
        return throwBadPort();

    scope.release();
    return static_cast<uint16_t>(port);
}

}
