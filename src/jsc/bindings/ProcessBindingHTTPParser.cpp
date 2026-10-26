#include "ProcessBindingHTTPParser.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "llhttp/llhttp.h"

namespace Bun {

using namespace JSC;

static JSValue ProcessBindingHTTPParser_methods(VM& vm, JSObject* binding)
{
    JSGlobalObject* globalObject = binding->globalObject();

    JSArray* methods = constructEmptyArray(globalObject, nullptr, 35);

    int index = 0;
#define FOR_EACH_METHOD(num, name, string) \
    methods->putDirectIndex(globalObject, index++, jsString(vm, #string##_str));
    HTTP_METHOD_MAP(FOR_EACH_METHOD)
#undef FOR_EACH_METHOD

    return methods;
}

static JSValue ProcessBindingHTTPParser_allMethods(VM& vm, JSObject* binding)
{
    JSGlobalObject* globalObject = binding->globalObject();

    JSArray* methods = constructEmptyArray(globalObject, nullptr, 47);

    int index = 0;
#define FOR_EACH_METHOD(num, name, string) \
    methods->putDirectIndex(globalObject, index++, jsString(vm, #string##_str));
    HTTP_ALL_METHOD_MAP(FOR_EACH_METHOD)
#undef FOR_EACH_METHOD

    return methods;
}

static JSValue ProcessBindingHTTPParser_HTTPParser(VM& vm, JSObject* binding)
{
    auto* lexicalGlobalObject = binding->globalObject();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    return globalObject->m_JSHTTPParserClassStructure.constructor(lexicalGlobalObject);
}

static JSValue ProcessBindingHTTPParser_ConnectionsList(VM& vm, JSObject* binding)
{
    auto* lexicalGlobalObject = binding->globalObject();
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    return globalObject->m_JSConnectionsListClassStructure.constructor(lexicalGlobalObject);
}


#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingHTTPParser
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingHTTPParser

const ClassInfo ProcessBindingHTTPParser::s_info = { "ProcessBindingHTTPParser"_s, &Base::s_info, &bunBindgenObjectSurface_ProcessBindingHTTPParserTable, nullptr, CREATE_METHOD_TABLE(ProcessBindingHTTPParser) };

ProcessBindingHTTPParser* ProcessBindingHTTPParser::create(VM& vm, Structure* structure)
{
    ProcessBindingHTTPParser* binding = new (NotNull, allocateCell<ProcessBindingHTTPParser>(vm)) ProcessBindingHTTPParser(vm, structure);
    binding->finishCreation(vm);
    return binding;
}

Structure* ProcessBindingHTTPParser::createStructure(VM& vm, JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(ObjectType, StructureFlags), info());
}

void ProcessBindingHTTPParser::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, Callback)                                      \
    JSC::JSValue Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                                      \
        Bindgen::CppCallContext& context,                                                               \
        const Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)                       \
    {                                                                                                   \
        return Callback(context.globalObject.vm(), JSC::asObject(args.bindingThis));                     \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingHTTPParser_methods, ProcessBindingHTTPParser_methods)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingHTTPParser_allMethods, ProcessBindingHTTPParser_allMethods)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingHTTPParser_HTTPParser, ProcessBindingHTTPParser_HTTPParser)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingHTTPParser_ConnectionsList, ProcessBindingHTTPParser_ConnectionsList)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

} // namespace Bun
