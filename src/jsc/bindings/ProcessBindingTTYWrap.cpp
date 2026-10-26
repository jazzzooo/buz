#include "root.h"
#include "SchemaBindings.h"

#include "JavaScriptCore/JSDestructibleObject.h"
#include "JavaScriptCore/ExceptionScope.h"
#include "JavaScriptCore/Identifier.h"

#include <JavaScriptCore/ObjectConstructor.h>

#include "ProcessBindingTTYWrap.h"
#include <cmath>
#include "wtf-bindings.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/FunctionPrototype.h>

#ifndef WIN32
#include <errno.h>
#include <dlfcn.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/utsname.h>
#else
#include <uv.h>
#include <io.h>
#include <fcntl.h>

#endif

#if OS(WINDOWS)

namespace UV {

class TTY {
public:
    uv_tty_t handle {};

    uv_tty_t* tty() { return &handle; }

    void close()
    {
        uv_close((uv_handle_t*)(tty()), [](uv_handle_t* handle) -> void {
            uv_tty_t* ttyHandle = (uv_tty_t*)handle;
            ptrdiff_t offset = offsetof(UV::TTY, handle);

            UV::TTY* tty = (UV::TTY*)((char*)ttyHandle - offset);
            delete tty;
        });
    }
};

}

#endif

namespace Bun {

using namespace JSC;

static bool getWindowSize(int fd, size_t* width, size_t* height)
{
#if OS(WINDOWS)
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    HANDLE handle = INVALID_HANDLE_VALUE;
    switch (fd) {
    case 0:
        handle = GetStdHandle(STD_INPUT_HANDLE);
        break;
    case 1:
        handle = GetStdHandle(STD_OUTPUT_HANDLE);
        break;
    case 2:
        handle = GetStdHandle(STD_ERROR_HANDLE);
        break;
    default:
        break;
    }
    if (handle == INVALID_HANDLE_VALUE)
        return false;

    if (!GetConsoleScreenBufferInfo(handle, &csbi))
        return false;

    *width = csbi.srWindow.Right - csbi.srWindow.Left + 1;
    *height = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
    return true;
#else
    struct winsize ws;
    int err;
    do
        err = ioctl(fd, TIOCGWINSZ, &ws);
    while (err == -1 && errno == EINTR);

    if (err == -1)
        return false;

    *width = ws.ws_col;
    *height = ws.ws_row;

    return true;
#endif
}

class TTYWrapObject final : public JSC::JSDestructibleObject {
public:
    using Base = JSC::JSDestructibleObject;
    static constexpr unsigned StructureFlags = Base::StructureFlags;

    static TTYWrapObject* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, int fd)
    {

        TTYWrapObject* object = new (NotNull, JSC::allocateCell<TTYWrapObject>(vm)) TTYWrapObject(vm, structure, fd);
        object->finishCreation(vm);

        return object;
    }

    DECLARE_INFO;

    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;

        return WebCore::subspaceForImpl<TTYWrapObject, UseCustomHeapCellType::No>(
            vm,
            [](auto& spaces) { return spaces.m_clientSubspaceForTTYWrapObject.get(); },
            [](auto& spaces, auto&& space) { spaces.m_clientSubspaceForTTYWrapObject = std::forward<decltype(space)>(space); },
            [](auto& spaces) { return spaces.m_subspaceForTTYWrapObject.get(); },
            [](auto& spaces, auto&& space) { spaces.m_subspaceForTTYWrapObject = std::forward<decltype(space)>(space); });
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSObject* prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<TTYWrapObject*>(cell)->TTYWrapObject::~TTYWrapObject();
    }

    ~TTYWrapObject()
    {
#if OS(WINDOWS)
        if (handle) {
            handle->close();
        }
#endif
    }

    int fd = -1;

#if OS(WINDOWS)
    UV::TTY* handle;
#endif

private:
    TTYWrapObject(JSC::VM& vm, JSC::Structure* structure, const int fd)
        : Base(vm, structure)
        , fd(fd)

    {
#if OS(WINDOWS)
        handle = nullptr;
#endif
    }

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);

        ASSERT(inherits(info()));
    }
};

const ClassInfo TTYWrapObject::s_info = {
    "LibuvStreamWrap"_s,

    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(TTYWrapObject)
};

TTYWrapObject* ttyWrapObjectCast(JSC::JSValue value)
{
    return dynamicDowncast<TTYWrapObject>(value);
}

bool isTTYWrapObject(JSC::JSValue value) noexcept
{
    return !!ttyWrapObjectCast(value);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessTTY_setMode(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_setMode_Arguments& args)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_ProcessTTY_setModeNative(args.fd, args.mode ? 1 : 0);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessTTY_wrapSetMode(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_wrapSetMode_Arguments& args)
{
    auto* wrap = ttyWrapObjectCast(args.bindingThis);
    RELEASE_ASSERT(wrap);
    int fd = wrap->fd;

#if OS(WINDOWS)
    if (!args.mode) {
        Bun::Bindgen::ZigExports::bunBindgenZig_ProcessTTY_enableConsoleControlHandler();
    }

    int err = uv_tty_set_mode(wrap->handle->tty(), args.mode);
#else
    // Node.js emits an Error event instead of throwing when ttySetMode fails.
    int err = Bun::Bindgen::ZigExports::bunBindgenZig_ProcessTTY_setModeNative(fd, args.mode);
#endif
    return err;
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessTTY_wrapGetWindowSize(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_wrapGetWindowSize_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* wrap = ttyWrapObjectCast(args.bindingThis);
    RELEASE_ASSERT(wrap);
    int fd = wrap->fd;
    JSC::JSArray* array = dynamicDowncast<JSC::JSArray>(args.array);
    if (!array || array->length() < 2) {
        JSC::throwTypeError(globalObject, throwScope, "getWindowSize expects an array"_s);
        return {};
    }

    size_t width, height;
    if (!getWindowSize(fd, &width, &height)) {
        return false;
    }

    array->putDirectIndex(globalObject, 0, jsNumber(width));
    array->putDirectIndex(globalObject, 1, jsNumber(height));

    return true;
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessTTY_getWindowSize(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_getWindowSize_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    int fd = args.fd;
    JSC::JSArray* array = dynamicDowncast<JSC::JSArray>(args.array);
    if (!array || array->length() < 2) {
        JSC::throwTypeError(globalObject, throwScope, "getWindowSize requires 2 argument (an array)"_s);
        return {};
    }

    size_t width, height;
    if (!getWindowSize(fd, &width, &height)) {
        return false;
    }

    array->putDirectIndex(globalObject, 0, jsNumber(width));
    RETURN_IF_EXCEPTION(throwScope, {});
    array->putDirectIndex(globalObject, 1, jsNumber(height));
    RETURN_IF_EXCEPTION(throwScope, {});

    return true;
}

#define BUN_BINDGEN_OBJECT_SURFACE_TTYWrapPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_TTYWrapPrototype

class TTYWrapPrototype final : public JSC::JSNonFinalObject {
public:
    DECLARE_INFO;
    using Base = JSC::JSNonFinalObject;

    static Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        return Structure::create(vm, globalObject, globalObject->objectPrototype(), TypeInfo(ObjectType, StructureFlags), info());
    }

    static TTYWrapPrototype* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure)
    {
        TTYWrapPrototype* prototype = new (NotNull, JSC::allocateCell<TTYWrapPrototype>(vm)) TTYWrapPrototype(vm, structure);
        prototype->finishCreation(vm, globalObject);
        return prototype;
    }

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(TTYWrapPrototype, Base);
        return &vm.plainObjectSpace();
    }

    void finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject)
    {
        Base::finishCreation(vm);

        bunBindgenObjectSurface_TTYWrapPrototype_install(vm, TTYWrapObject::info(), *this);
    }

    TTYWrapPrototype(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }
};

const ClassInfo TTYWrapPrototype::s_info = {
    "LibuvStreamWrap"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(TTYWrapPrototype)
};

class TTYWrapConstructor final : public JSC::InternalFunction {
public:
    using Base = JSC::InternalFunction;
    static TTYWrapConstructor* create(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::Structure* structure, JSObject* prototype)
    {
        TTYWrapConstructor* constructor = new (NotNull, JSC::allocateCell<TTYWrapConstructor>(vm)) TTYWrapConstructor(vm, structure);
        constructor->finishCreation(vm, globalObject, prototype);
        return constructor;
    }

    static constexpr unsigned StructureFlags = Base::StructureFlags;
    static constexpr JSC::DestructionMode needsDestruction = DoesNotNeedDestruction;

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::InternalFunctionType, StructureFlags), info());
    }

    template<typename, JSC::SubspaceAccess mode> static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        if constexpr (mode == JSC::SubspaceAccess::Concurrently)
            return nullptr;
        return &vm.internalFunctionSpace();
    }

    DECLARE_EXPORT_INFO;

private:
    TTYWrapConstructor(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure, bun_bindgen_host_ProcessTTY_ttyWrapConstructorCall, bun_bindgen_host_ProcessTTY_ttyWrapConstructorConstruct)
    {
    }

    void finishCreation(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSObject* prototype)
    {
        Base::finishCreation(vm, 1, "TTYWrap"_s);
        putDirectWithoutTransition(vm, vm.propertyNames->prototype, prototype, JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete);
    }
};

void Bindgen::Cpp::bunBindgenCpp_ProcessTTY_ttyWrapConstructorCall(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_ttyWrapConstructorCall_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    throwTypeError(globalObject, scope, "TTYWrapConstructor cannot be called as a function"_s);
}

TTYWrapConstructor* ttyWrapConstructorCast(JSC::JSValue value)
{
    return dynamicDowncast<TTYWrapConstructor>(value);
}

bool isTTYWrapConstructor(JSC::JSValue value) noexcept
{
    return !!ttyWrapConstructorCast(value);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessTTY_ttyWrapConstructorConstruct(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_ttyWrapConstructorConstruct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.fd) {
        throwTypeError(globalObject, scope, "Expected at least 1 argument"_s);
        return {};
    }
    int32_t fd = *args.fd;

    if (fd < 0) {
        throwTypeError(globalObject, scope, "fd must be a positive number"_s);
        return {};
    }

    auto* constructor = ttyWrapConstructorCast(args.bindingCallee);
    RELEASE_ASSERT(constructor);
    auto prototypeValue = constructor->get(globalObject, vm.propertyNames->prototype);
    RETURN_IF_EXCEPTION(scope, {});
    if (!prototypeValue.isObject()) {
        throwTypeError(globalObject, scope, "TTYWrapConstructor prototype is not an object"_s);
        return {};
    }

#if OS(WINDOWS)
    auto* handle = new UV::TTY();
    memset(handle, 0, sizeof(UV::TTY));
    int rc = uv_tty_init(uncheckedDowncast<Zig::GlobalObject>(globalObject)->uvLoop(), handle->tty(), fd, 0);
    if (rc < 0) {
        delete handle;
        throwTypeError(globalObject, scope, "Failed to initialize TTY handle"_s);
        return {};
    }
    ASSERT(handle->tty()->loop);
#else
    if (!isatty(fd)) {
        throwTypeError(globalObject, scope, makeString("fd"_s, fd, " is not a tty"_s));
        return {};
    }
#endif

    auto* structure = TTYWrapObject::createStructure(vm, globalObject, prototypeValue.getObject());
    auto* object = TTYWrapObject::create(vm, globalObject, structure, fd);

#if OS(WINDOWS)
    object->handle = handle;
#endif

    return object;
}

const ClassInfo TTYWrapConstructor::s_info = { "TTY"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(TTYWrapConstructor) };

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessTTY_constructTTYWrapConstructor(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessTTY_constructTTYWrapConstructor_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    TTYWrapPrototype* prototype = TTYWrapPrototype::create(vm, globalObject, TTYWrapPrototype::createStructure(vm, globalObject));
    return TTYWrapConstructor::create(vm, globalObject, TTYWrapConstructor::createStructure(vm, globalObject, globalObject->functionPrototype()), prototype);
}

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessTTYBinding
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessTTYBinding

JSValue createNodeTTYWrapObject(JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    auto* obj = constructEmptyObject(globalObject);
    bunBindgenObjectSurface_ProcessTTYBinding_install(vm, obj->classInfo(), *obj);
    return obj;
}
}
