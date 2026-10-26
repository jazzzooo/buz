
#include "ProcessBindingFs.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include "ZigGlobalObject.h"

namespace Bun {
using namespace JSC;

static WTF::String makeNotImplementedError(const ASCIILiteral name)
{
    return makeString("process.binding('fs')."_s, name, " is not implemented in Bun. If that breaks something, please file an issue and include a reproducible code sample."_s);
}

namespace Bindgen::Cpp {

static void throwFsBindingNotImplemented(CppCallContext& context, ASCIILiteral name)
{
    auto* globalObject = &context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(globalObject->vm());
    throwScope.throwException(globalObject, createError(globalObject, makeNotImplementedError(name)));
}

#define PROCESS_BINDING_NOT_IMPLEMENTED(str)                                                                                                                     \
    void bunBindgenCpp_ProcessBindingStubs_fs_##str(CppCallContext& context, const BunBindgenCpp_ProcessBindingStubs_fs_##str##_Arguments&)                       \
    {                                                                                                                                                            \
        throwFsBindingNotImplemented(context, #str##_s);                                                                                                         \
    }

PROCESS_BINDING_NOT_IMPLEMENTED(access)

PROCESS_BINDING_NOT_IMPLEMENTED(chmod)

PROCESS_BINDING_NOT_IMPLEMENTED(chown)

PROCESS_BINDING_NOT_IMPLEMENTED(close)

PROCESS_BINDING_NOT_IMPLEMENTED(copyFile)

PROCESS_BINDING_NOT_IMPLEMENTED(cpSyncCheckPaths)

PROCESS_BINDING_NOT_IMPLEMENTED(existsSync)

PROCESS_BINDING_NOT_IMPLEMENTED(fchmod)

PROCESS_BINDING_NOT_IMPLEMENTED(fchown)

PROCESS_BINDING_NOT_IMPLEMENTED(fdatasync)

PROCESS_BINDING_NOT_IMPLEMENTED(fstat)

PROCESS_BINDING_NOT_IMPLEMENTED(fsync)

PROCESS_BINDING_NOT_IMPLEMENTED(ftruncate)

PROCESS_BINDING_NOT_IMPLEMENTED(futimes)

PROCESS_BINDING_NOT_IMPLEMENTED(getFormatOfExtensionlessFile)

PROCESS_BINDING_NOT_IMPLEMENTED(internalModuleStat)

PROCESS_BINDING_NOT_IMPLEMENTED(lchown)

PROCESS_BINDING_NOT_IMPLEMENTED(legacyMainResolve)

PROCESS_BINDING_NOT_IMPLEMENTED(link)

PROCESS_BINDING_NOT_IMPLEMENTED(lstat)

PROCESS_BINDING_NOT_IMPLEMENTED(lutimes)

PROCESS_BINDING_NOT_IMPLEMENTED(mkdir)

PROCESS_BINDING_NOT_IMPLEMENTED(mkdtemp)

PROCESS_BINDING_NOT_IMPLEMENTED(open)

PROCESS_BINDING_NOT_IMPLEMENTED(openFileHandle)

PROCESS_BINDING_NOT_IMPLEMENTED(read)

PROCESS_BINDING_NOT_IMPLEMENTED(readBuffers)

PROCESS_BINDING_NOT_IMPLEMENTED(readdir)

PROCESS_BINDING_NOT_IMPLEMENTED(readFileUtf8)

PROCESS_BINDING_NOT_IMPLEMENTED(readlink)

PROCESS_BINDING_NOT_IMPLEMENTED(realpath)

PROCESS_BINDING_NOT_IMPLEMENTED(rename)

PROCESS_BINDING_NOT_IMPLEMENTED(rmdir)

PROCESS_BINDING_NOT_IMPLEMENTED(rmSync)

PROCESS_BINDING_NOT_IMPLEMENTED(stat)

PROCESS_BINDING_NOT_IMPLEMENTED(statfs)

PROCESS_BINDING_NOT_IMPLEMENTED(StatWatcher)

PROCESS_BINDING_NOT_IMPLEMENTED(symlink)

PROCESS_BINDING_NOT_IMPLEMENTED(unlink)

PROCESS_BINDING_NOT_IMPLEMENTED(utimes)

PROCESS_BINDING_NOT_IMPLEMENTED(writeBuffer)

PROCESS_BINDING_NOT_IMPLEMENTED(writeBuffers)

PROCESS_BINDING_NOT_IMPLEMENTED(writeFileUtf8)

PROCESS_BINDING_NOT_IMPLEMENTED(writeString)

#undef PROCESS_BINDING_NOT_IMPLEMENTED

}

static JSValue ProcessBindingFs_statValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSFloat64Array::create(globalObject, globalObject->m_typedArrayFloat64.get(globalObject), 36);
}

static JSValue ProcessBindingFs_bigintStatValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSBigInt64Array::create(globalObject, globalObject->m_typedArrayBigInt64.get(globalObject), 36);
}

static JSValue ProcessBindingFs_statFsValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSFloat64Array::create(globalObject, globalObject->m_typedArrayFloat64.get(globalObject), 7);
}

static JSValue ProcessBindingFs_bigintStatFsValues(VM& vm, JSObject* object)
{
    auto* globalObject = object->globalObject();
    return JSC::JSBigInt64Array::create(globalObject, globalObject->m_typedArrayBigInt64.get(globalObject), 7);
}

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingFs
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingFs

const ClassInfo ProcessBindingFs::s_info = { "ProcessBindingFs"_s, &Base::s_info, &bunBindgenObjectSurface_ProcessBindingFsTable, nullptr, CREATE_METHOD_TABLE(ProcessBindingFs) };

ProcessBindingFs* ProcessBindingFs::create(VM& vm, Structure* structure)
{
    ProcessBindingFs* obj = new (NotNull, allocateCell<ProcessBindingFs>(vm)) ProcessBindingFs(vm, structure);
    obj->finishCreation(vm);
    return obj;
}

Structure* ProcessBindingFs::createStructure(VM& vm, JSGlobalObject* globalObject)
{
    return Structure::create(vm, globalObject, jsNull(), TypeInfo(ObjectType, StructureFlags), ProcessBindingFs::info());
}

void ProcessBindingFs::finishCreation(JSC::VM& vm)
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

BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingFs_bigintStatFsValues, ProcessBindingFs_bigintStatFsValues)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingFs_bigintStatValues, ProcessBindingFs_bigintStatValues)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingFs_statFsValues, ProcessBindingFs_statFsValues)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessBindingStubs, ProcessBindingFs_statValues, ProcessBindingFs_statValues)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

} // namespace Bun
