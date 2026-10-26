
#include "ProcessBindingBuffer.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include "JSBuffer.h"

namespace Bun {
using namespace JSC;

namespace Bindgen::Cpp {

static void throwBufferBindingNotImplemented(CppCallContext& context, ASCIILiteral name)
{
    auto* globalObject = &context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto message = makeString(
        "process.binding('buffer')."_s,
        name,
        " is not implemented in Bun. If that breaks something, please file an issue and include a reproducible code sample."_s);
    throwScope.throwException(globalObject, createError(globalObject, message));
}

#define PROCESS_BINDING_NOT_IMPLEMENTED(str)                                                                                                                             \
    void bunBindgenCpp_ProcessBindingStubs_buffer_##str(CppCallContext& context, const BunBindgenCpp_ProcessBindingStubs_buffer_##str##_Arguments&)                       \
    {                                                                                                                                                                    \
        throwBufferBindingNotImplemented(context, #str##_s);                                                                                                             \
    }

PROCESS_BINDING_NOT_IMPLEMENTED(asciiSlice)

PROCESS_BINDING_NOT_IMPLEMENTED(asciiWriteStatic)

PROCESS_BINDING_NOT_IMPLEMENTED(atob)

PROCESS_BINDING_NOT_IMPLEMENTED(base64Slice)

PROCESS_BINDING_NOT_IMPLEMENTED(base64Write)

PROCESS_BINDING_NOT_IMPLEMENTED(base64urlSlice)

PROCESS_BINDING_NOT_IMPLEMENTED(base64urlWrite)

PROCESS_BINDING_NOT_IMPLEMENTED(btoa)

PROCESS_BINDING_NOT_IMPLEMENTED(byteLengthUtf8)

PROCESS_BINDING_NOT_IMPLEMENTED(compare)

PROCESS_BINDING_NOT_IMPLEMENTED(compareOffset)

PROCESS_BINDING_NOT_IMPLEMENTED(copy)

PROCESS_BINDING_NOT_IMPLEMENTED(copyArrayBuffer)

PROCESS_BINDING_NOT_IMPLEMENTED(detachArrayBuffer)

PROCESS_BINDING_NOT_IMPLEMENTED(fill)

PROCESS_BINDING_NOT_IMPLEMENTED(getZeroFillToggle)

PROCESS_BINDING_NOT_IMPLEMENTED(hexSlice)

PROCESS_BINDING_NOT_IMPLEMENTED(hexWrite)

PROCESS_BINDING_NOT_IMPLEMENTED(indexOfBuffer)

PROCESS_BINDING_NOT_IMPLEMENTED(indexOfNumber)

PROCESS_BINDING_NOT_IMPLEMENTED(indexOfString)

PROCESS_BINDING_NOT_IMPLEMENTED(isAscii)

PROCESS_BINDING_NOT_IMPLEMENTED(isUtf8)

PROCESS_BINDING_NOT_IMPLEMENTED(latin1Slice)

PROCESS_BINDING_NOT_IMPLEMENTED(latin1WriteStatic)

PROCESS_BINDING_NOT_IMPLEMENTED(swap16)

PROCESS_BINDING_NOT_IMPLEMENTED(swap32)

PROCESS_BINDING_NOT_IMPLEMENTED(swap64)

PROCESS_BINDING_NOT_IMPLEMENTED(ucs2Slice)

PROCESS_BINDING_NOT_IMPLEMENTED(ucs2Write)

PROCESS_BINDING_NOT_IMPLEMENTED(utf8Slice)

PROCESS_BINDING_NOT_IMPLEMENTED(utf8WriteStatic)

#undef PROCESS_BINDING_NOT_IMPLEMENTED

}

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingBuffer
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingBuffer

const ClassInfo ProcessBindingBuffer::s_info = { "ProcessBindingBuffer"_s, &Base::s_info, &bunBindgenObjectSurface_ProcessBindingBufferTable, nullptr, CREATE_METHOD_TABLE(ProcessBindingBuffer) };

ProcessBindingBuffer* ProcessBindingBuffer::create(VM& vm, Structure* structure)
{
    ProcessBindingBuffer* obj = new (NotNull, allocateCell<ProcessBindingBuffer>(vm)) ProcessBindingBuffer(vm, structure);
    obj->finishCreation(vm);
    return obj;
}

Structure* ProcessBindingBuffer::createStructure(VM& vm, JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(ObjectType, StructureFlags), ProcessBindingBuffer::info());
}

void ProcessBindingBuffer::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

template<typename Visitor>
void ProcessBindingBuffer::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    ProcessBindingBuffer* thisObject = uncheckedDowncast<ProcessBindingBuffer>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
}

DEFINE_VISIT_CHILDREN(ProcessBindingBuffer);

} // namespace Bun
