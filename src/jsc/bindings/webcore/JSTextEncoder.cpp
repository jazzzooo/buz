#include "config.h"

#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>

namespace Bun {
namespace Bindgen {
namespace Cpp {

using namespace JSC;
using namespace WebCore;

WTF::String bunBindgenCpp_WebCoreStreams_TextEncoder_getter_encoding(
    CppCallContext&,
    const BunBindgenCpp_WebCoreStreams_TextEncoder_getter_encoding_Arguments&)
{
    return "utf-8"_s;
}

JSValue bunBindgenCpp_WebCoreStreams_TextEncoder_method_encode(
    CppCallContext& ctx,
    const BunBindgenCpp_WebCoreStreams_TextEncoder_method_encode_Arguments& args)
{
    auto* lexicalGlobalObject = &ctx.globalObject;
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    JSC::JSValue res;
    StringView str { args.input };
    if (str.is8Bit()) {
        res = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_textEncoderEncodeLatin1(lexicalGlobalObject, str.span8());
    } else {
        const auto span = str.span16();
        res = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_textEncoderEncodeUTF16(
            lexicalGlobalObject,
            { reinterpret_cast<const uint16_t*>(span.data()), span.size() });
    }

    RETURN_IF_EXCEPTION(throwScope, {});
    RELEASE_AND_RETURN(throwScope, res);
}

TextEncoderEncodeIntoDictionaryResult bunBindgenCpp_WebCoreStreams_TextEncoder_method_encodeInto(
    CppCallContext&,
    const BunBindgenCpp_WebCoreStreams_TextEncoder_method_encodeInto_Arguments& args)
{
    StringView source { args.source };
    std::span destination { args.destination.unsafePtr("The entry frame holds the destination lease through synchronous text encoding"_s), args.destination.size() };
    uint64_t res = 0;
    if (!source.is8Bit()) {
        const auto span = source.span16();
        res = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_textEncoderEncodeIntoUTF16(
            { reinterpret_cast<const uint16_t*>(span.data()), span.size() }, destination);
    } else {
        const auto span = source.span8();
        res = Bun::Bindgen::ZigExports::bunBindgenZig_text_codecs_textEncoderEncodeIntoLatin1(span, destination);
    }

    return {
        .read = static_cast<uint32_t>(res),
        .written = static_cast<uint32_t>(res >> 32),
    };
}

} // namespace Cpp
} // namespace Bindgen
} // namespace Bun
