

#include "root.h"

#include "SchemaBindings.h"
#include "JavaScriptCore/JSGlobalObject.h"
#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/JSGlobalObjectInlines.h"
#include "JSEventTarget.h"
#include "JavaScriptCore/JSArray.h"
#include "wtf/text/MakeString.h"

namespace Bun {

using namespace JSC;
using namespace WebCore;

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_EventTarget_getEventListeners(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_EventTarget_getEventListeners_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto* thisObject = dynamicDowncast<JSEventTarget>(args.target);
    RELEASE_ASSERT(thisObject);
    const auto& eventType = args.event_type;

    MarkedArgumentBuffer values;
    auto& listeners = thisObject->wrapped().eventListeners(WTF::makeAtomString(eventType));
    for (auto& listener : listeners) {
        auto* function = listener->callback().jsFunction();
        if (function) {
            values.append(function);
        }
    }

    RELEASE_AND_RETURN(throwScope, constructArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), values));
}

}
