#include "root.h"

#include "JSNodePerformanceHooksHistogramConstructor.h"
#include "JSNodePerformanceHooksHistogram.h"
#include "JSNodePerformanceHooksHistogramPrototype.h"
#include "ZigGlobalObject.h"
#include "ErrorCode.h"
#include "wtf/text/ASCIILiteral.h"
#include "wtf/Vector.h"
#include <wtf/MathExtras.h>

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/ThrowScope.h>
#include <JavaScriptCore/Options.h>
#include <JavaScriptCore/JSBigInt.h>

namespace Bun {

using namespace JSC;

const ClassInfo JSNodePerformanceHooksHistogramConstructor::s_info = { "Histogram"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSNodePerformanceHooksHistogramConstructor) };

void JSNodePerformanceHooksHistogramConstructor::finishCreation(VM& vm, JSGlobalObject* globalObject, JSObject* prototype)
{
    Base::finishCreation(vm, 3, "Histogram"_s, PropertyAdditionMode::WithStructureTransition); // lowest, highest, figures
    putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly);
}

void Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramConstructorCall_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    Bun::throwError(globalObject, scope, ErrorCode::ERR_ILLEGAL_CONSTRUCTOR, "Histogram constructor cannot be invoked without 'new'"_s);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_PerformanceHistogram_histogramConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_PerformanceHistogram_histogramConstructorConstruct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* zigGlobalObject = defaultGlobalObject(globalObject);
    Structure* structure = zigGlobalObject->m_JSNodePerformanceHooksHistogramClassStructure.get(zigGlobalObject);
    RETURN_IF_EXCEPTION(scope, {});

    JSNodePerformanceHooksHistogram* histogram = JSNodePerformanceHooksHistogram::create(
        vm,
        structure,
        globalObject,
        args.lowest ? (args.lowest->is_number() ? args.lowest->number() : args.lowest->bigint()) : 1,
        args.highest ? (args.highest->is_number() ? args.highest->number() : args.highest->bigint()) : std::numeric_limits<int64_t>::max(),
        args.figures.value_or(3));
    RETURN_IF_EXCEPTION(scope, {});
    return histogram;
}

void setupJSNodePerformanceHooksHistogramClassStructure(LazyClassStructure::Initializer& init)
{
    auto* prototypeStructure = JSNodePerformanceHooksHistogramPrototype::createStructure(init.vm, init.global, init.global->objectPrototype());
    auto* prototype = JSNodePerformanceHooksHistogramPrototype::create(init.vm, init.global, prototypeStructure);

    auto* constructorStructure = JSNodePerformanceHooksHistogramConstructor::createStructure(init.vm, init.global, init.global->functionPrototype());
    auto* constructor = JSNodePerformanceHooksHistogramConstructor::create(init.vm, init.global, constructorStructure, prototype);

    auto* structure = JSNodePerformanceHooksHistogram::createStructure(init.vm, init.global, prototype);

    init.setPrototype(prototype);
    init.setStructure(structure);
    init.setConstructor(constructor);
}

} // namespace Bun
