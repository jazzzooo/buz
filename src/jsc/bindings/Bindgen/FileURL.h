#pragma once

#include <wtf/Forward.h>

namespace JSC {
class JSGlobalObject;
}

namespace Bun::Bindgen {

WTF::String fileURLToPath(JSC::JSGlobalObject&, const WTF::URL&);

}
