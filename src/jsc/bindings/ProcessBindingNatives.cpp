#include "ProcessBindingNatives.h"
#include "SchemaBindings.h"

namespace Bun {
using namespace JSC;

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingNatives
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingNatives

const ClassInfo ProcessBindingNatives::s_info = { "ProcessBindingNatives"_s, &Base::s_info, &bunBindgenObjectSurface_ProcessBindingNativesTable, nullptr, CREATE_METHOD_TABLE(ProcessBindingNatives) };

ProcessBindingNatives* ProcessBindingNatives::create(VM& vm, Structure* structure)
{
    ProcessBindingNatives* obj = new (NotNull, allocateCell<ProcessBindingNatives>(vm)) ProcessBindingNatives(vm, structure);
    obj->finishCreation(vm);
    return obj;
}

Structure* ProcessBindingNatives::createStructure(VM& vm, JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(ObjectType, StructureFlags), ProcessBindingNatives::info());
}

void ProcessBindingNatives::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

template<typename Visitor>
void ProcessBindingNatives::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    ProcessBindingNatives* thisObject = uncheckedDowncast<ProcessBindingNatives>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(ProcessBindingNatives);

} // namespace Bun
