#include "root.h"
#include "SchemaBindings.h"
#include "wtf/text/StringView.h"
#include "JavaScriptCore/JSGlobalObjectFunctions.h"

using namespace WTF;

/// This is the equivalent of the unary '+' operator on a JS string
/// See https://262.ecma-international.org/14.0/#sec-stringtonumber
/// Grammar: https://262.ecma-international.org/14.0/#prod-StringNumericLiteral
double Bun::Bindgen::Engine::bunBindgenEngine_js_strings_jsStringToNumber(
    const Bun::Bindgen::Engine::BunBindgenEngine_js_strings_jsStringToNumber_Arguments& args)
{
    return JSC::jsToNumber(WTF::StringView(reinterpret_cast<const char*>(args.bytes.data()), args.bytes.size(), true));
}
