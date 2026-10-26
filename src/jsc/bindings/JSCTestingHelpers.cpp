#include "root.h"

#include "SchemaBindings.h"
#include <JavaScriptCore/JSGlobalObject.h>

#include <JavaScriptCore/JSString.h>
#include "ZigGlobalObject.h"

namespace Bun::Bindgen::Cpp {
using namespace JSC;

bool bunBindgenCpp_JSCTestingHelpers_isUTF16String(
    CppCallContext&,
    const BunBindgenCpp_JSCTestingHelpers_isUTF16String_Arguments& args)
{
    return !args.value.is8Bit();
}

bool bunBindgenCpp_JSCTestingHelpers_isLatin1String(
    CppCallContext&,
    const BunBindgenCpp_JSCTestingHelpers_isLatin1String_Arguments& args)
{
    return args.value.is8Bit();
}

} // namespace Bun::Bindgen::Cpp
