#include "root.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "ScriptExecutionContext.h"
#include "NativeEventLoopTarget.h"
#include "napi.h"
#include "napi_handle_scope.h"
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/ArgList.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <atomic>
#include <ffi.h>
#include <limits>
#include <memory>
#include <new>
#include <thread>
#include <wtf/Lock.h>
#include <wtf/Locker.h>
#include <wtf/Scope.h>

using Bun::Bindgen::FFIABIType;

#if !CPU(X86_64) || FFI_VERSION_NUMBER != 30800
#error Audit libffi closure retirement before changing the callback ABI implementation
#endif

static ffi_type* ffiType(FFIABIType type)
{
    switch (type) {
    case FFIABIType::char_type:
    case FFIABIType::int8:
        return &ffi_type_sint8;
    case FFIABIType::uint8:
    case FFIABIType::boolean:
        return &ffi_type_uint8;
    case FFIABIType::int16:
        return &ffi_type_sint16;
    case FFIABIType::uint16:
        return &ffi_type_uint16;
    case FFIABIType::int32:
        return &ffi_type_sint32;
    case FFIABIType::uint32:
        return &ffi_type_uint32;
    case FFIABIType::int64:
    case FFIABIType::int64_fast:
        return &ffi_type_sint64;
    case FFIABIType::uint64:
    case FFIABIType::uint64_fast:
        return &ffi_type_uint64;
    case FFIABIType::double_type:
        return &ffi_type_double;
    case FFIABIType::float_type:
        return &ffi_type_float;
    case FFIABIType::void_type:
        return &ffi_type_void;
    case FFIABIType::pointer:
    case FFIABIType::c_string:
    case FFIABIType::function_pointer:
    case FFIABIType::napi_env:
    case FFIABIType::napi_value:
    case FFIABIType::buffer:
        return &ffi_type_pointer;
    }
    return nullptr;
}

class FFIFunctionData {
public:
    ~FFIFunctionData()
    {
        if (plan)
            ffi_call_plan_free(plan);
    }

    ffi_cif cif {};
    ffi_call_plan* plan { nullptr };
    void* symbol { nullptr };
    WTF::Vector<ffi_type*> nativeArgumentTypes;
    WTF::Vector<FFIABIType> argumentTypes;
    FFIABIType returnType { FFIABIType::void_type };
};

class FFIEnvironment {
public:
    explicit FFIEnvironment(NapiEnv* environment)
        : m_environment(adoptRef(*environment))
    {
    }

    ~FFIEnvironment() { close(); }

    NapiEnv* get() const { return m_environment.ptr(); }

    void close()
    {
        if (m_closed)
            return;
        m_closed = true;
        m_environment->cleanup();
    }

private:
    Ref<NapiEnv> m_environment;
    bool m_closed { false };
};

void Bun::Bindgen::Engine::releaseFFIFunctionData(FFIFunctionData* function)
{
    delete function;
}

void Bun::Bindgen::Engine::releaseFFIEnvironment(FFIEnvironment* environment)
{
    delete environment;
}

FFIEnvironment* Bun::Bindgen::Engine::bunBindgenEngine_FFI_createEnvironment(
    EngineCallContext& context,
    const BunBindgenEngine_FFI_createEnvironment_Arguments&)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto* global = defaultGlobalObject(&context.globalObject);
    auto environment = adoptRef(*global->makeNapiEnvForFFI());
    auto* result = new (std::nothrow) FFIEnvironment(&environment.leakRef());
    if (!result) {
        JSC::throwOutOfMemoryError(&context.globalObject, scope);
        return nullptr;
    }
    return result;
}

union FFIScalar {
    int8_t int8;
    uint8_t uint8;
    int16_t int16;
    uint16_t uint16;
    int32_t int32;
    uint32_t uint32;
    int64_t int64;
    uint64_t uint64;
    double doubleValue;
    float floatValue;
    void* pointer;
    ffi_arg unsignedResult;
    ffi_sarg signedResult;
};

class FFIInvocationScope {
public:
    enum class Retention { unavailable, retained, outOfMemory };

    explicit FFIInvocationScope(JSC::VM& vm)
        : m_vm(vm)
        , m_previous(std::exchange(s_current, this))
    {
    }

    ~FFIInvocationScope() { s_current = m_previous; }
    FFIInvocationScope(const FFIInvocationScope&) = delete;
    FFIInvocationScope& operator=(const FFIInvocationScope&) = delete;

    static Retention retainNapiResult(JSC::VM& vm, JSC::JSValue value)
    {
        if (!s_current || &s_current->m_vm != &vm)
            return Retention::unavailable;
        s_current->m_napiResults.append(value);
        return s_current->m_napiResults.hasOverflowed() ? Retention::outOfMemory : Retention::retained;
    }

private:
    static inline thread_local FFIInvocationScope* s_current { nullptr };
    JSC::VM& m_vm;
    FFIInvocationScope* m_previous;
    JSC::MarkedArgumentBuffer m_napiResults;
};

class FFICallbackEndpoint;

class FFICallbackControl final : public Bun::NativeEventLoopTarget {
public:
    explicit FFICallbackControl(bool threadsafe)
        : thread(std::this_thread::get_id())
        , threadsafe(threadsafe)
    {
    }

    ~FFICallbackControl()
    {
        RELEASE_ASSERT(!endpoint);
        stop();
        if (sender)
            Bun::Bindgen::Engine::releaseNativeEventLoopSignal(sender);
        if (closure)
            ffi_closure_free(closure);
    }

    void enqueue(void** arguments, bool wrongThread) noexcept;
    void run(JSC::JSGlobalObject*) noexcept final;
    void stop() noexcept final;

    // Returns true when no accepted work remains.
    bool closeInput() noexcept
    {
        WTF::Locker locker { m_queueLock };
        accepting.store(false, std::memory_order_release);
        return !m_head && !m_outOfMemory;
    }

    FFIFunctionData signature;
    ffi_closure* closure { nullptr };
    void* code { nullptr };
    const std::thread::id thread;
    const bool threadsafe;
    std::atomic<bool> accepting { false };
    FFICallbackEndpoint* endpoint { nullptr };
    Bun::NativeEventLoopSignal* sender { nullptr };

private:
    struct Invocation {
        Invocation* next { nullptr };
        WTF::Vector<FFIScalar, 16> arguments;
        bool wrongThread { false };
    };
    WTF::Lock m_queueLock;
    Invocation* m_head { nullptr };
    Invocation* m_tail { nullptr };
    bool m_outOfMemory { false };
};

class FFICallbackEndpoint final : public RefCounted<FFICallbackEndpoint>, public WebCore::ScriptExecutionContext::NativeLifetime {
public:
    explicit FFICallbackEndpoint(Ref<FFICallbackControl>&& control)
        : m_control(WTF::move(control))
    {
        m_control->endpoint = this;
    }

    ~FFICallbackEndpoint() { close(); }

    void publish(JSC::VM& vm, JSC::JSObject* wrapper)
    {
        if (!context())
            return;
        RELEASE_ASSERT(!m_wrapper || m_wrapper.get() == wrapper);
        // Published native addresses outlive JavaScript references until close or VM shutdown.
        m_wrapper.set(vm, wrapper);
        m_control->accepting.store(true, std::memory_order_release);
    }

    void requestClose() noexcept
    {
        // The rooted wrapper owns this endpoint and callback until accepted invocations drain.
        if (m_control->closeInput())
            close();
    }

    void close() noexcept
    {
        m_control->closeInput();
        m_control->endpoint = nullptr;
        if (m_wrapper)
            uncheckedDowncast<Bun::BunBindgen_FFI_FFICallbackContext>(m_wrapper.get())->clear_slot_callbackValue();
        m_wrapper.clear();
        detach();
        if (auto* signal = std::exchange(m_signal, nullptr))
            Bun::Bindgen::Engine::releaseNativeEventLoopSignalOwner(signal);
        else
            m_control->stop();
    }

    void setSignal(Bun::NativeEventLoopSignal* signal)
    {
        RELEASE_ASSERT(!m_signal && !m_control->sender);
        m_signal = signal;
        m_control->sender = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_retainNativeEventSignal(signal);
    }

    void* code() const { return m_control->code; }

    size_t memoryUsage() const
    {
        return sizeof(*this) + sizeof(FFICallbackControl) + sizeof(ffi_closure)
            + m_control->signature.argumentTypes.capacity() * sizeof(FFIABIType)
            + m_control->signature.nativeArgumentTypes.capacity() * sizeof(ffi_type*);
    }

    void invoke(std::span<void* const> arguments, void* result);
    void invokeQueued(std::span<const FFIScalar> arguments, bool outOfMemory, bool wrongThread);

private:
    void contextClosed() noexcept final { close(); }
    JSC::JSGlobalObject* globalObject() const
    {
        auto* scriptContext = context();
        if (!scriptContext || !m_wrapper || scriptContext->isJSExecutionForbidden())
            return nullptr;
        return scriptContext->jsGlobalObject();
    }

    JSC::Strong<JSC::JSObject> m_wrapper;
    Ref<FFICallbackControl> m_control;
    Bun::NativeEventLoopSignal* m_signal { nullptr };
};

static FFIScalar copyCallbackArgument(FFIABIType type, const void* argument)
{
    FFIScalar value {};
    switch (type) {
    case FFIABIType::char_type:
    case FFIABIType::int8: value.int8 = *static_cast<const int8_t*>(argument); break;
    case FFIABIType::uint8:
    case FFIABIType::boolean: value.uint8 = *static_cast<const uint8_t*>(argument); break;
    case FFIABIType::int16: value.int16 = *static_cast<const int16_t*>(argument); break;
    case FFIABIType::uint16: value.uint16 = *static_cast<const uint16_t*>(argument); break;
    case FFIABIType::int32: value.int32 = *static_cast<const int32_t*>(argument); break;
    case FFIABIType::uint32: value.uint32 = *static_cast<const uint32_t*>(argument); break;
    case FFIABIType::int64:
    case FFIABIType::int64_fast: value.int64 = *static_cast<const int64_t*>(argument); break;
    case FFIABIType::uint64:
    case FFIABIType::uint64_fast: value.uint64 = *static_cast<const uint64_t*>(argument); break;
    case FFIABIType::double_type: value.doubleValue = *static_cast<const double*>(argument); break;
    case FFIABIType::float_type: value.floatValue = *static_cast<const float*>(argument); break;
    case FFIABIType::pointer:
    case FFIABIType::c_string:
    case FFIABIType::function_pointer:
    case FFIABIType::napi_env:
    case FFIABIType::napi_value: value.pointer = *static_cast<void* const*>(argument); break;
    case FFIABIType::buffer:
    case FFIABIType::void_type: RELEASE_ASSERT_NOT_REACHED();
    }
    return value;
}

static Bun::Bindgen::FFICallbackValue callbackArgumentValue(FFIABIType type, const FFIScalar& value)
{
    Bun::Bindgen::FFICallbackValue result;
    switch (type) {
    case FFIABIType::char_type:
    case FFIABIType::int8: result.set_number(value.int8); break;
    case FFIABIType::uint8: result.set_number(value.uint8); break;
    case FFIABIType::int16: result.set_number(value.int16); break;
    case FFIABIType::uint16: result.set_number(value.uint16); break;
    case FFIABIType::int32: result.set_number(value.int32); break;
    case FFIABIType::uint32: result.set_number(value.uint32); break;
    case FFIABIType::int64: result.set_signed_wide(value.int64); break;
    case FFIABIType::uint64: result.set_unsigned_wide(value.uint64); break;
    case FFIABIType::int64_fast: result.set_signed_fast(value.int64); break;
    case FFIABIType::uint64_fast: result.set_unsigned_fast(value.uint64); break;
    case FFIABIType::double_type: result.set_number(value.doubleValue); break;
    case FFIABIType::float_type: result.set_number(value.floatValue); break;
    case FFIABIType::boolean: result.set_boolean(value.uint8 != 0); break;
    case FFIABIType::pointer:
    case FFIABIType::c_string:
    case FFIABIType::function_pointer:
        result.set_pointer(value.pointer ? std::optional<uintptr_t>(reinterpret_cast<uintptr_t>(value.pointer)) : std::nullopt);
        break;
    case FFIABIType::napi_env:
        result.set_undefined_value({});
        break;
    case FFIABIType::napi_value:
        result.set_napi_value(value.pointer ? Zig::toJS(static_cast<napi_value>(value.pointer)) : JSC::jsUndefined());
        break;
    case FFIABIType::buffer:
    case FFIABIType::void_type:
        RELEASE_ASSERT_NOT_REACHED();
    }
    return result;
}

static void* callbackPointerValue(const Bun::Bindgen::FFICallbackPointerResult& value)
{
    switch (value.tag()) {
    case Bun::Bindgen::FFICallbackPointerResult::Tag::address: return reinterpret_cast<void*>(value.address());
    case Bun::Bindgen::FFICallbackPointerResult::Tag::object: return reinterpret_cast<void*>(value.object().ptr);
    case Bun::Bindgen::FFICallbackPointerResult::Tag::null_value:
    case Bun::Bindgen::FFICallbackPointerResult::Tag::undefined_value: return nullptr;
    case Bun::Bindgen::FFICallbackPointerResult::Tag::none: RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static bool writeCallbackReturn(JSC::JSGlobalObject* global, FFIABIType type, const Bun::Bindgen::FFICallbackReturnResult& value, void* destination, NapiEnv* environment)
{
    switch (type) {
    case FFIABIType::char_type:
        if (!value.is_char_type()) break;
        *static_cast<int8_t*>(destination) = value.char_type();
        return true;
    case FFIABIType::int8:
        if (!value.is_int8()) break;
        *static_cast<int8_t*>(destination) = value.int8();
        return true;
    case FFIABIType::uint8:
        if (!value.is_uint8()) break;
        *static_cast<uint8_t*>(destination) = value.uint8();
        return true;
    case FFIABIType::int16:
        if (!value.is_int16()) break;
        *static_cast<int16_t*>(destination) = value.int16();
        return true;
    case FFIABIType::uint16:
        if (!value.is_uint16()) break;
        *static_cast<uint16_t*>(destination) = value.uint16();
        return true;
    case FFIABIType::int32:
        if (!value.is_int32()) break;
        *static_cast<int32_t*>(destination) = value.int32();
        return true;
    case FFIABIType::uint32:
        if (!value.is_uint32()) break;
        *static_cast<uint32_t*>(destination) = value.uint32();
        return true;
    case FFIABIType::int64:
        if (!value.is_int64()) break;
        *static_cast<int64_t*>(destination) = value.int64();
        return true;
    case FFIABIType::uint64:
        if (!value.is_uint64()) break;
        *static_cast<uint64_t*>(destination) = value.uint64();
        return true;
    case FFIABIType::int64_fast:
        if (!value.is_int64_fast()) break;
        *static_cast<int64_t*>(destination) = value.int64_fast();
        return true;
    case FFIABIType::uint64_fast:
        if (!value.is_uint64_fast()) break;
        *static_cast<uint64_t*>(destination) = value.uint64_fast();
        return true;
    case FFIABIType::double_type:
        if (!value.is_double_type()) break;
        *static_cast<double*>(destination) = value.double_type();
        return true;
    case FFIABIType::float_type:
        if (!value.is_float_type()) break;
        *static_cast<float*>(destination) = static_cast<float>(value.float_type());
        return true;
    case FFIABIType::boolean:
        if (!value.is_boolean()) break;
        *static_cast<uint8_t*>(destination) = value.boolean();
        return true;
    case FFIABIType::pointer:
        if (!value.is_pointer()) break;
        *static_cast<void**>(destination) = callbackPointerValue(value.pointer());
        return true;
    case FFIABIType::c_string:
        if (!value.is_c_string()) break;
        *static_cast<void**>(destination) = callbackPointerValue(value.c_string());
        return true;
    case FFIABIType::function_pointer:
        if (!value.is_function_pointer()) break;
        *static_cast<void**>(destination) = callbackPointerValue(value.function_pointer());
        return true;
    case FFIABIType::void_type:
        if (!value.is_void_type()) break;
        return true;
    case FFIABIType::napi_value: {
        if (!value.is_napi_value()) break;
        auto scope = DECLARE_THROW_SCOPE(global->vm());
        if (environment && &environment->vm() != &global->vm()) {
            JSC::throwTypeError(global, scope, "A callback's napi_env must belong to its VM"_s);
            return false;
        }
        auto* napiGlobal = environment ? environment->globalObject() : defaultGlobalObject(global);
        const auto retention = FFIInvocationScope::retainNapiResult(global->vm(), value.napi_value());
        if (retention == FFIInvocationScope::Retention::outOfMemory) {
            JSC::throwOutOfMemoryError(global, scope);
            return false;
        }
        if (retention == FFIInvocationScope::Retention::unavailable && !napiGlobal->m_currentNapiHandleScopeImpl.get()) {
            JSC::throwTypeError(global, scope, "A napi_value callback result requires an active FFI call or Node-API handle scope"_s);
            return false;
        }
        *static_cast<napi_value*>(destination) = Zig::toNapi(value.napi_value(), napiGlobal);
        return true;
    }
    case FFIABIType::napi_env:
    case FFIABIType::buffer:
        RELEASE_ASSERT_NOT_REACHED();
    }
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    JSC::throwTypeError(global, scope, "Callback return type does not match its native signature"_s);
    return false;
}

void FFICallbackEndpoint::invoke(std::span<void* const> nativeArguments, void* destination)
{
    auto* global = globalObject();
    if (!global)
        return;
    JSC::JSLockHolder lock(global->vm());
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    JSC::Strong<JSC::JSObject> wrapper = m_wrapper;
    global = wrapper->globalObject();

    WTF::Vector<Bun::Bindgen::FFICallbackValue, 16> arguments;
    if (!arguments.tryReserveCapacity(nativeArguments.size())) {
        JSC::throwOutOfMemoryError(global, scope);
        return;
    }
    JSC::MarkedArgumentBuffer napiRoots;
    NapiEnv* environment = nullptr;
    for (size_t i = 0; i < nativeArguments.size(); ++i) {
        auto type = m_control->signature.argumentTypes[i];
        auto native = copyCallbackArgument(type, nativeArguments[i]);
        if (type == FFIABIType::napi_env)
            environment = static_cast<NapiEnv*>(native.pointer);
        auto value = callbackArgumentValue(type, native);
        if (value.is_napi_value()) {
            napiRoots.append(value.napi_value());
            if (napiRoots.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global, scope);
                return;
            }
        }
        arguments.unsafeAppendWithoutCapacityCheck(WTF::move(value));
    }
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_FFI_invokeCallback(global, wrapper.get(), arguments.span());
    RETURN_IF_EXCEPTION(scope, void());
    writeCallbackReturn(global, m_control->signature.returnType, result, destination, environment);
    RETURN_IF_EXCEPTION(scope, void());
}

void FFICallbackEndpoint::invokeQueued(std::span<const FFIScalar> nativeArguments, bool outOfMemory, bool wrongThread)
{
    auto* global = globalObject();
    if (!global)
        return;
    JSC::JSLockHolder lock(global->vm());
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
    if (outOfMemory || wrongThread) {
        auto throwScope = DECLARE_THROW_SCOPE(global->vm());
        if (outOfMemory)
            JSC::throwOutOfMemoryError(global, throwScope);
        else
            JSC::throwTypeError(global, throwScope, "A callback invoked on another thread must declare threadsafe: true"_s);
    } else {
        WTF::Vector<void*, 16> addresses;
        if (!addresses.tryReserveCapacity(nativeArguments.size())) {
            auto throwScope = DECLARE_THROW_SCOPE(global->vm());
            JSC::throwOutOfMemoryError(global, throwScope);
        } else {
            for (const auto& value : nativeArguments)
                addresses.unsafeAppendWithoutCapacityCheck(const_cast<FFIScalar*>(&value));
            invoke(addresses.span(), nullptr);
        }
    }
    if (auto* exception = scope.exception()) {
        if (!scope.clearExceptionExceptTermination())
            return;
        Zig::GlobalObject::reportUncaughtExceptionAtEventLoop(global, exception);
    }
}

void FFICallbackControl::enqueue(void** nativeArguments, bool wrongThread) noexcept
{
    auto invocation = std::unique_ptr<Invocation>(new (std::nothrow) Invocation);
    bool outOfMemory = !invocation;
    if (invocation) {
        invocation->wrongThread = wrongThread;
        if (!wrongThread) {
            outOfMemory = !invocation->arguments.tryGrow(signature.argumentTypes.size());
            if (!outOfMemory) {
                for (size_t i = 0; i < invocation->arguments.size(); ++i)
                    invocation->arguments[i] = copyCallbackArgument(signature.argumentTypes[i], nativeArguments[i]);
            }
        }
    }
    {
        WTF::Locker locker { m_queueLock };
        if (!accepting.load(std::memory_order_acquire))
            return;
        if (outOfMemory) {
            m_outOfMemory = true;
        } else {
            auto* pending = invocation.release();
            if (m_tail)
                m_tail->next = pending;
            else
                m_head = pending;
            m_tail = pending;
        }
    }
    Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_notifyNativeEventSignal(sender);
}

void FFICallbackControl::run(JSC::JSGlobalObject*) noexcept
{
    std::unique_ptr<Invocation> invocation;
    bool outOfMemory;
    bool hasMore;
    {
        WTF::Locker locker { m_queueLock };
        outOfMemory = std::exchange(m_outOfMemory, false);
        if (!outOfMemory && m_head) {
            invocation.reset(m_head);
            m_head = m_head->next;
            if (!m_head)
                m_tail = nullptr;
        }
        hasMore = m_head != nullptr;
    }
    if (hasMore)
        Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_notifyNativeEventSignal(sender);
    if (RefPtr protectedEndpoint = endpoint) {
        if (outOfMemory)
            protectedEndpoint->invokeQueued({}, true, false);
        else if (invocation)
            protectedEndpoint->invokeQueued(invocation->arguments.span(), false, invocation->wrongThread);
        if (!accepting.load(std::memory_order_acquire))
            protectedEndpoint->requestClose();
    }
}

void FFICallbackControl::stop() noexcept
{
    Invocation* pending;
    {
        WTF::Locker locker { m_queueLock };
        accepting.store(false, std::memory_order_release);
        pending = std::exchange(m_head, nullptr);
        m_tail = nullptr;
        m_outOfMemory = false;
    }
    while (pending) {
        auto* next = pending->next;
        delete pending;
        pending = next;
    }
}

static void dispatchFFICallback(ffi_cif* cif, void* result, void** nativeArguments, void* context) noexcept
{
    auto& control = *static_cast<FFICallbackControl*>(context);
    // The pinned x86-64 libffi dispatcher consumes closure metadata before entering this handler.
    Ref protectedControl { control };
    if (control.signature.returnType != FFIABIType::void_type)
        memset(result, 0, cif->rtype->size);
    if (!control.accepting.load(std::memory_order_acquire))
        return;

    const bool wrongThread = !control.threadsafe && control.thread != std::this_thread::get_id();
    if (!control.threadsafe && !wrongThread) {
        if (auto* endpoint = control.endpoint) {
            Ref protectedEndpoint { *endpoint };
            endpoint->invoke({ nativeArguments, control.signature.argumentTypes.size() }, result);
        }
        return;
    }

    control.enqueue(nativeArguments, wrongThread);
}

void Bun::Bindgen::Engine::releaseFFICallbackEndpoint(FFICallbackEndpoint* endpoint)
{
    endpoint->close();
    endpoint->deref();
}

void Bun::Bindgen::Engine::bunBindgenEngine_FFI_closeCallback(
    const BunBindgenEngine_FFI_closeCallback_Arguments& args)
{
    args.endpoint->requestClose();
}

void Bun::Bindgen::Engine::bunBindgenEngine_FFI_publishCallback(
    EngineCallContext& context,
    const BunBindgenEngine_FFI_publishCallback_Arguments& args)
{
    args.endpoint->publish(context.globalObject.vm(), args.context.getObject());
}

FFICallbackEndpoint* Bun::Bindgen::Engine::bunBindgenEngine_FFI_createCallback(
    EngineCallContext& context,
    const BunBindgenEngine_FFI_createCallback_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* scriptContext = defaultGlobalObject(global)->scriptExecutionContext();
    if (!scriptContext || args.argumentTypes.size() > std::numeric_limits<unsigned>::max()
        || !ffiType(args.returnType) || args.returnType == FFIABIType::napi_env || args.returnType == FFIABIType::buffer
        || (args.threadsafe && args.returnType != FFIABIType::void_type)) {
        JSC::throwTypeError(global, scope, "Invalid native callback signature or execution context"_s);
        return nullptr;
    }
    void* controlMemory;
    if (!WTF::tryFastMalloc(sizeof(FFICallbackControl)).getValue(controlMemory)) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    auto* allocation = new (NotNull, controlMemory) FFICallbackControl(args.threadsafe);
    auto control = adoptRef(*allocation);
    auto& signature = control->signature;
    if (!signature.argumentTypes.tryGrow(args.argumentTypes.size()) || !signature.nativeArgumentTypes.tryGrow(args.argumentTypes.size())) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    for (size_t i = 0; i < args.argumentTypes.size(); ++i) {
        auto type = args.argumentTypes[i];
        if (!ffiType(type) || type == FFIABIType::void_type || type == FFIABIType::buffer
            || (args.threadsafe && (type == FFIABIType::napi_env || type == FFIABIType::napi_value))) {
            JSC::throwTypeError(global, scope, "Unsupported native callback argument type"_s);
            return nullptr;
        }
        signature.argumentTypes[i] = type;
        signature.nativeArgumentTypes[i] = ffiType(type);
    }
    signature.returnType = args.returnType;
    if (ffi_prep_cif(&signature.cif, FFI_DEFAULT_ABI, static_cast<unsigned>(args.argumentTypes.size()), ffiType(args.returnType), signature.nativeArgumentTypes.mutableSpan().data()) != FFI_OK) {
        JSC::throwTypeError(global, scope, "The native ABI cannot represent this callback signature"_s);
        return nullptr;
    }
    control->closure = static_cast<ffi_closure*>(ffi_closure_alloc(sizeof(ffi_closure), &control->code));
    if (!control->closure) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    if (ffi_prep_closure_loc(control->closure, &signature.cif, dispatchFFICallback, control.ptr(), control->code) != FFI_OK) {
        JSC::throwTypeError(global, scope, "The native ABI cannot create this callback closure"_s);
        return nullptr;
    }
    void* endpointMemory;
    if (!WTF::tryFastMalloc(sizeof(FFICallbackEndpoint)).getValue(endpointMemory)) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    auto endpoint = adoptRef(*new (NotNull, endpointMemory) FFICallbackEndpoint(WTF::move(control)));
    if (!endpoint->attach(*scriptContext)) {
        JSC::throwTypeError(global, scope, "The callback's execution context is closed"_s);
        return nullptr;
    }
    auto signal = Bun::Bindgen::ZigExports::bunBindgenZig_EventLoop_createNativeEventSignal(global, allocation);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!signal) {
        JSC::throwTypeError(global, scope, "The callback's event loop is closed"_s);
        return nullptr;
    }
    endpoint->setSignal(*signal);
    return &endpoint.leakRef();
}

uintptr_t Bun::Bindgen::Engine::bunBindgenEngine_FFI_callbackPointer(const BunBindgenEngine_FFI_callbackPointer_Arguments& args)
{
    return reinterpret_cast<uintptr_t>(args.endpoint->code());
}

size_t Bun::Bindgen::Engine::bunBindgenEngine_FFI_callbackMemoryUsage(const BunBindgenEngine_FFI_callbackMemoryUsage_Arguments& args)
{
    return args.endpoint->memoryUsage();
}

FFIFunctionData* Bun::Bindgen::Engine::bunBindgenEngine_FFI_prepareFunction(
    EngineCallContext& context,
    const BunBindgenEngine_FFI_prepareFunction_Arguments& args)
{
    auto* global = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* resultType = ffiType(args.returnType);
    if (!args.symbol || !resultType || args.returnType == FFIABIType::napi_env || args.returnType == FFIABIType::buffer
        || args.argumentTypes.size() > std::numeric_limits<unsigned>::max()) {
        JSC::throwTypeError(global, scope, "Invalid foreign function signature"_s);
        return nullptr;
    }

    auto data = std::unique_ptr<FFIFunctionData>(new (std::nothrow) FFIFunctionData);
    if (!data || !data->nativeArgumentTypes.tryGrow(args.argumentTypes.size()) || !data->argumentTypes.tryGrow(args.argumentTypes.size())) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    for (size_t i = 0; i < args.argumentTypes.size(); ++i) {
        auto type = args.argumentTypes[i];
        auto* nativeType = ffiType(type);
        if (!nativeType || type == FFIABIType::void_type) {
            JSC::throwTypeError(global, scope, "Invalid foreign function argument type"_s);
            return nullptr;
        }
        data->nativeArgumentTypes[i] = nativeType;
        data->argumentTypes[i] = type;
    }
    data->symbol = args.symbol;
    data->returnType = args.returnType;
    if (ffi_prep_cif(&data->cif, FFI_DEFAULT_ABI, static_cast<unsigned>(args.argumentTypes.size()), resultType, data->nativeArgumentTypes.mutableSpan().data()) != FFI_OK) {
        JSC::throwTypeError(global, scope, "The native ABI cannot represent this foreign function signature"_s);
        return nullptr;
    }
    data->plan = ffi_call_plan_alloc(&data->cif);
    if (!data->plan) {
        JSC::throwOutOfMemoryError(global, scope);
        return nullptr;
    }
    return data.release();
}

static void* ffiReturnStorage(FFIABIType type, FFIScalar& value)
{
    switch (type) {
    case FFIABIType::char_type:
    case FFIABIType::int8:
    case FFIABIType::int16:
    case FFIABIType::int32:
        value.signedResult = 0;
        return &value.signedResult;
    case FFIABIType::uint8:
    case FFIABIType::uint16:
    case FFIABIType::uint32:
    case FFIABIType::boolean:
        value.unsignedResult = 0;
        return &value.unsignedResult;
    case FFIABIType::int64:
    case FFIABIType::int64_fast:
        value.int64 = 0;
        return &value.int64;
    case FFIABIType::uint64:
    case FFIABIType::uint64_fast:
        value.uint64 = 0;
        return &value.uint64;
    case FFIABIType::double_type:
        value.doubleValue = 0;
        return &value.doubleValue;
    case FFIABIType::float_type:
        value.floatValue = 0;
        return &value.floatValue;
    case FFIABIType::pointer:
    case FFIABIType::c_string:
    case FFIABIType::function_pointer:
    case FFIABIType::napi_value:
        value.pointer = nullptr;
        return &value.pointer;
    case FFIABIType::void_type:
        return nullptr;
    case FFIABIType::napi_env:
    case FFIABIType::buffer:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static void* ffiPointer(const Bun::Bindgen::FFIPointerInput& input)
{
    switch (input.tag()) {
    case Bun::Bindgen::FFIPointerInput::Tag::buffer:
        return input.buffer().unsafePtr("The entry frame holds the buffer lease through the synchronous foreign call; the FFI callee must not retain it"_s);
    case Bun::Bindgen::FFIPointerInput::Tag::address:
        return reinterpret_cast<void*>(input.address());
    case Bun::Bindgen::FFIPointerInput::Tag::object:
        return reinterpret_cast<void*>(input.object().ptr);
    case Bun::Bindgen::FFIPointerInput::Tag::null_value:
    case Bun::Bindgen::FFIPointerInput::Tag::undefined_value:
        return nullptr;
    case Bun::Bindgen::FFIPointerInput::Tag::none:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static void* ffiFunctionPointer(const Bun::Bindgen::FFIFunctionPointerInput& input)
{
    switch (input.tag()) {
    case Bun::Bindgen::FFIFunctionPointerInput::Tag::address:
        return reinterpret_cast<void*>(input.address());
    case Bun::Bindgen::FFIFunctionPointerInput::Tag::object:
        return reinterpret_cast<void*>(input.object().ptr);
    case Bun::Bindgen::FFIFunctionPointerInput::Tag::none:
        RELEASE_ASSERT_NOT_REACHED();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static bool ffiArgumentMatches(FFIABIType type, const Bun::Bindgen::FFICallArgument& input)
{
    switch (type) {
    case FFIABIType::char_type: return input.is_char_type();
    case FFIABIType::int8: return input.is_int8();
    case FFIABIType::uint8: return input.is_uint8();
    case FFIABIType::int16: return input.is_int16();
    case FFIABIType::uint16: return input.is_uint16();
    case FFIABIType::int32: return input.is_int32();
    case FFIABIType::uint32: return input.is_uint32();
    case FFIABIType::int64: return input.is_int64();
    case FFIABIType::uint64: return input.is_uint64();
    case FFIABIType::double_type: return input.is_double_type();
    case FFIABIType::float_type: return input.is_float_type();
    case FFIABIType::boolean: return input.is_boolean();
    case FFIABIType::pointer: return input.is_pointer();
    case FFIABIType::void_type: return input.is_void_type();
    case FFIABIType::c_string: return input.is_c_string();
    case FFIABIType::int64_fast: return input.is_int64_fast();
    case FFIABIType::uint64_fast: return input.is_uint64_fast();
    case FFIABIType::function_pointer: return input.is_function_pointer();
    case FFIABIType::napi_env: return input.is_napi_env();
    case FFIABIType::napi_value: return input.is_napi_value();
    case FFIABIType::buffer: return input.is_buffer();
    }
    return false;
}

Bun::Bindgen::FFICallValueResult Bun::Bindgen::Cpp::bunBindgenCpp_FFI_invoke(
    CppCallContext& context,
    const BunBindgenCpp_FFI_invoke_Arguments& args)
{
    auto* global = &context.globalObject;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* data = ZigExports::bunBindgenZig_FFI_beginForeignCall(args.function).value_or(nullptr);
    if (!data) {
        JSC::throwTypeError(global, scope, "The foreign function's library is closed"_s);
        return {};
    }
    auto finishCall = WTF::makeScopeExit([&] { ZigExports::bunBindgenZig_FFI_endForeignCall(args.function); });

    if (args.arguments.size() != data->argumentTypes.size()) {
        JSC::throwTypeError(global, scope, "Foreign function argument count does not match its signature"_s);
        return {};
    }
    WTF::Vector<FFIScalar, 16> storage;
    WTF::Vector<void*, 16> addresses;
    if (!storage.tryGrow(args.arguments.size()) || !addresses.tryGrow(args.arguments.size())) {
        JSC::throwOutOfMemoryError(global, scope);
        return {};
    }
    auto* environment = ZigExports::bunBindgenZig_FFI_foreignEnvironment(args.function).value_or(nullptr);
    NapiEnv* napiEnvironment = environment ? environment->get() : nullptr;
    std::optional<Bun::NapiHandleScope> handles;
    if (napiEnvironment) {
        handles.emplace(napiEnvironment->globalObject());
        RETURN_IF_EXCEPTION(scope, {});
    }

    for (size_t i = 0; i < args.arguments.size(); ++i) {
        const auto& input = args.arguments[i];
        auto& value = storage[i];
        auto type = data->argumentTypes[i];
        if (!ffiArgumentMatches(type, input)) {
            JSC::throwTypeError(global, scope, "Foreign function argument type does not match its signature"_s);
            return {};
        }
        switch (type) {
        case FFIABIType::char_type:
            value.int8 = input.char_type();
            addresses[i] = &value.int8;
            break;
        case FFIABIType::int8:
            value.int8 = input.int8();
            addresses[i] = &value.int8;
            break;
        case FFIABIType::uint8:
            value.uint8 = input.uint8();
            addresses[i] = &value.uint8;
            break;
        case FFIABIType::int16:
            value.int16 = input.int16();
            addresses[i] = &value.int16;
            break;
        case FFIABIType::uint16:
            value.uint16 = input.uint16();
            addresses[i] = &value.uint16;
            break;
        case FFIABIType::int32:
            value.int32 = input.int32();
            addresses[i] = &value.int32;
            break;
        case FFIABIType::uint32:
            value.uint32 = input.uint32();
            addresses[i] = &value.uint32;
            break;
        case FFIABIType::int64:
        case FFIABIType::int64_fast:
            value.int64 = type == FFIABIType::int64 ? input.int64() : input.int64_fast();
            addresses[i] = &value.int64;
            break;
        case FFIABIType::uint64:
        case FFIABIType::uint64_fast:
            value.uint64 = type == FFIABIType::uint64 ? input.uint64() : input.uint64_fast();
            addresses[i] = &value.uint64;
            break;
        case FFIABIType::double_type:
            value.doubleValue = input.double_type();
            addresses[i] = &value.doubleValue;
            break;
        case FFIABIType::float_type:
            value.floatValue = static_cast<float>(input.float_type());
            addresses[i] = &value.floatValue;
            break;
        case FFIABIType::boolean:
            value.uint8 = input.boolean();
            addresses[i] = &value.uint8;
            break;
        case FFIABIType::pointer:
        case FFIABIType::c_string:
            value.pointer = ffiPointer(type == FFIABIType::pointer ? input.pointer() : input.c_string());
            addresses[i] = &value.pointer;
            break;
        case FFIABIType::function_pointer:
            value.pointer = ffiFunctionPointer(input.function_pointer());
            if (!value.pointer) {
                JSC::throwTypeError(global, scope, "A foreign function pointer cannot be null"_s);
                return {};
            }
            addresses[i] = &value.pointer;
            break;
        case FFIABIType::napi_env:
            RELEASE_ASSERT(napiEnvironment);
            value.pointer = napiEnvironment;
            addresses[i] = &value.pointer;
            break;
        case FFIABIType::napi_value:
            RELEASE_ASSERT(napiEnvironment);
            value.pointer = Zig::toNapi(input.napi_value(), napiEnvironment->globalObject());
            RETURN_IF_EXCEPTION(scope, {});
            addresses[i] = &value.pointer;
            break;
        case FFIABIType::buffer:
            value.pointer = input.buffer().unsafePtr("The entry frame holds the buffer lease through the synchronous foreign call; the FFI callee must not retain it"_s);
            addresses[i] = &value.pointer;
            break;
        case FFIABIType::void_type:
            RELEASE_ASSERT_NOT_REACHED();
        }
    }

    // libffi widens integral returns smaller than ffi_arg, but arguments use their declared C storage types.
    FFIScalar nativeResult {};
    auto* returnStorage = ffiReturnStorage(data->returnType, nativeResult);
    FFIInvocationScope invocation(vm);
    ffi_call_plan_invoke(data->plan, FFI_FN(data->symbol), returnStorage, addresses.mutableSpan().data());
    RETURN_IF_EXCEPTION(scope, {});

    FFICallValueResult result;
    switch (data->returnType) {
    case FFIABIType::char_type:
    case FFIABIType::int8:
    case FFIABIType::int16:
    case FFIABIType::int32:
        result.set_signed_integer(static_cast<int32_t>(nativeResult.signedResult));
        break;
    case FFIABIType::uint8:
    case FFIABIType::uint16:
    case FFIABIType::uint32:
        result.set_unsigned_integer(static_cast<uint32_t>(nativeResult.unsignedResult));
        break;
    case FFIABIType::int64:
        result.set_signed_wide(nativeResult.int64);
        break;
    case FFIABIType::uint64:
        result.set_unsigned_wide(nativeResult.uint64);
        break;
    case FFIABIType::int64_fast:
        result.set_signed_fast(nativeResult.int64);
        break;
    case FFIABIType::uint64_fast:
        result.set_unsigned_fast(nativeResult.uint64);
        break;
    case FFIABIType::double_type:
        result.set_number(nativeResult.doubleValue);
        break;
    case FFIABIType::float_type:
        result.set_number(nativeResult.floatValue);
        break;
    case FFIABIType::boolean:
        result.set_boolean(nativeResult.unsignedResult != 0);
        break;
    case FFIABIType::pointer:
    case FFIABIType::function_pointer:
        result.set_pointer(nativeResult.pointer ? std::optional<uintptr_t>(reinterpret_cast<uintptr_t>(nativeResult.pointer)) : std::nullopt);
        break;
    case FFIABIType::c_string: {
        FFICStringResult string;
        if (nativeResult.pointer) {
            const auto* text = static_cast<const char8_t*>(nativeResult.pointer);
            string.value = WTF::String::fromUTF8ReplacingInvalidSequences(std::span<const char8_t> { text, strlen(reinterpret_cast<const char*>(text)) });
            if (string.value.isNull()) {
                JSC::throwOutOfMemoryError(global, scope);
                return {};
            }
            string.ptr = reinterpret_cast<uintptr_t>(nativeResult.pointer);
        } else
            string.value = WTF::emptyString();
        result.set_c_string(WTF::move(string));
        break;
    }
    case FFIABIType::napi_value:
        result.set_napi_value(nativeResult.pointer ? Zig::toJS(static_cast<napi_value>(nativeResult.pointer)) : JSC::jsUndefined());
        break;
    case FFIABIType::void_type:
        result.set_void_value({});
        break;
    case FFIABIType::napi_env:
    case FFIABIType::buffer:
        RELEASE_ASSERT_NOT_REACHED();
    }
    return result;
}
