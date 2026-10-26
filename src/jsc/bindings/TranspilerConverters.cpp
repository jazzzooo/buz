#include "root.h"

#include "Bindgen/IDLConvertBase.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSONObject.h>

namespace Bun::Bindgen::Custom {

WTF::String bunBindgenJSONStringifiedString(JSC::JSGlobalObject& global, const JSONStringifiedInput& value, WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (value.is_text())
        return value.text();

    RELEASE_ASSERT(value.is_object());
    auto object = value.object();
    bool isJSArray = JSC::isArray(&global, object);
    RETURN_IF_EXCEPTION(scope, {});
    if (!isJSArray) {
        auto result = JSC::JSONStringify(&global, object, 0);
        RETURN_IF_EXCEPTION(scope, {});
        if (result.isNull())
            return WTF::emptyString();
        return result;
    }
    LiteralConversionContext context { name };
    context.setValue(object);
    context.throwTypeMustBe(global, scope, "a string or object"_s);
    return {};
}

}
