#include "root.h"

#include "TextCodec.h"
#include "TextCodecCJK.h"
#include "TextCodecSingleByte.h"
#include "TextCodecUserDefined.h"
#include "SchemaBindings.h"
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>
#include <memory>
#include <span>

using namespace PAL;

Bun::Bindgen::Engine::BunBindgenEngine_text_codecs_textCodecCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_text_codecs_textCodecCreate(
    const BunBindgenEngine_text_codecs_textCodecCreate_Arguments& args)
{
    auto codec = [&]() -> std::unique_ptr<TextCodec> {
        using Encoding = decltype(args.encoding);
        switch (args.encoding) {
        case Encoding::ibm866:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::IBM866);
        case Encoding::iso_8859_3:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::ISO_8859_3);
        case Encoding::iso_8859_6:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::ISO_8859_6);
        case Encoding::iso_8859_7:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::ISO_8859_7);
        case Encoding::iso_8859_8:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::ISO_8859_8);
        case Encoding::koi8_u:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::KOI8U);
        case Encoding::windows_874:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::Windows_874);
        case Encoding::windows_1253:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::Windows_1253);
        case Encoding::windows_1255:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::Windows_1255);
        case Encoding::windows_1257:
            return TextCodec::create<TextCodecSingleByte>(TextCodecSingleByte::Encoding::Windows_1257);
        case Encoding::big5:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::Big5);
        case Encoding::euc_jp:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::EUC_JP);
        case Encoding::iso_2022_jp:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::ISO2022JP);
        case Encoding::shift_jis:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::Shift_JIS);
        case Encoding::euc_kr:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::EUC_KR);
        case Encoding::gbk:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::GBK);
        case Encoding::gb18030:
            return TextCodec::create<TextCodecCJK>(TextCodecCJK::Encoding::GB18030);
        case Encoding::user_defined:
            return TextCodec::create<TextCodecUserDefined>();
        }
        RELEASE_ASSERT_NOT_REACHED();
    }();
    if (!codec)
        return Bun::Bindgen::nativeAllocationFailure();
    return codec.release();
}

void Bun::Bindgen::Engine::releaseTextCodec(PAL::TextCodec* codec)
{
    delete codec;
}

void Bun::Bindgen::Engine::bunBindgenEngine_text_codecs_textCodecReset(
    const BunBindgenEngine_text_codecs_textCodecReset_Arguments& args)
{
    args.codec->reset();
}

Bun::Bindgen::Engine::BunBindgenEngine_text_codecs_textCodecDecode_Return Bun::Bindgen::Engine::bunBindgenEngine_text_codecs_textCodecDecode(
    const BunBindgenEngine_text_codecs_textCodecDecode_Arguments& args)
{
    bool sawError = false;
    String result = args.codec->decode(args.data, args.flush, args.stopOnError, sawError);
    if (result.isNull())
        return Bun::Bindgen::nativeAllocationFailure();
    return BunBindgenEngine_text_codecs_textCodecDecode_Return::value_type { .result = WTF::move(result), .sawError = sawError };
}
