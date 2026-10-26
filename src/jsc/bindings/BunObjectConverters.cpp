#include "root.h"

#include "ErrorCode.h"
#include "SchemaBindings.h"
#include <wtf/URL.h>

namespace Bun::Bindgen::Custom {

WTF::String bunBindgenURLHref(JSC::JSGlobalObject& global, WTF::String const& string, WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    WTF::URL url { string };
    if (!url.isValid()) {
        auto value = JSC::jsString(global.vm(), string);
        RETURN_IF_EXCEPTION(scope, {});
        Bun::ERR::INVALID_ARG_VALUE(scope, &global, name, value, "must be a valid non-empty URL"_s);
        return {};
    }

    scope.release();
    return url.string();
}

}
