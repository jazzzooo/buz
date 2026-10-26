#pragma once

#include "CppAnyAccess.h"
#include <utility>
#include <algorithm>
#include <limits>
#include <memory>
#include <wtf/Scope.h>
#include "AsyncContextFrame.h"
#include "BunProcess.h"
#include "ErrorBindings.h"
#include "ZigGlobalObject.h"
#include "StringConversion.h"
#include <JavaScriptCore/AggregateError.h>
#include <JavaScriptCore/ErrorInstanceInlines.h>
#include <JavaScriptCore/JSBigIntInlines.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/PropertyNameArray.h>

JSC::JSObject* bindingWeakRefObject(const BindWeakRefHandle*) noexcept;

inline JSC::JSObject* bindingSnapshotOwnEnumerableProperties(JSC::JSGlobalObject* global, JSC::JSObject* source)
{
    if (!source)
        return nullptr;
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* snapshot = JSC::constructEmptyObject(global);
    RETURN_IF_EXCEPTION(scope, nullptr);
    JSC::PropertyNameArrayBuilder keys(vm, JSC::PropertyNameMode::StringsAndSymbols, JSC::PrivateSymbolMode::Exclude);
    source->methodTable()->getOwnPropertyNames(source, global, keys, JSC::DontEnumPropertiesMode::Include);
    RETURN_IF_EXCEPTION(scope, nullptr);
    for (const auto& key : keys) {
        JSC::PropertySlot slot(source, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
        bool exists = source->methodTable()->getOwnPropertySlot(source, global, key, slot);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!exists || (slot.attributes() & JSC::PropertyAttribute::DontEnum))
            continue;
        auto value = source->get(global, key);
        RETURN_IF_EXCEPTION(scope, nullptr);
        snapshot->createDataProperty(global, key, value, true);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return snapshot;
}

inline JSC::JSValue bindingBigIntQuotient(JSC::JSGlobalObject* global, JSC::JSValue numerator, uint64_t divisor)
{
    RELEASE_ASSERT(numerator.isBigInt() && divisor);
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* denominator = JSC::JSBigInt::createFrom(global, divisor);
    RETURN_IF_EXCEPTION(scope, {});
#if USE(BIGINT32)
    if (numerator.isBigInt32())
        RELEASE_AND_RETURN(scope, JSC::JSBigInt::divide(global, numerator.bigInt32AsInt32(), denominator));
#endif
    RELEASE_AND_RETURN(scope, JSC::JSBigInt::divide(global, numerator.asHeapBigInt(), denominator));
}

inline JSC::JSValue bindingCallbackFunction(JSC::JSValue value)
{
    RELEASE_ASSERT(!value.isEmpty());
    if (auto* frame = WTF::dynamicDowncast<AsyncContextFrame>(value))
        value = frame->callback.get();
    RELEASE_ASSERT_WITH_MESSAGE(JSC::getCallData(value).type != JSC::CallData::Type::None, "binding callback does not contain a callable function");
    return value;
}

struct BindByteOwnerHandle {
    uint8_t* externalBytes { nullptr };
    size_t externalLength { 0 };
    void* externalContext { nullptr };
    BindByteOwnerReleaseCallback externalRelease { nullptr };
    BindExternalBytesReleaseCallback opaqueExternalRelease { nullptr };

    ~BindByteOwnerHandle()
    {
        if (externalRelease)
            externalRelease(externalContext, externalBytes, externalLength);
        else if (opaqueExternalRelease)
            opaqueExternalRelease(externalBytes, externalContext);
    }
};

struct BindingExternalStringOwner {
    void* context;
    BindExternalStringReleaseCallback release;
    size_t byteLength;
};

static void releaseBindingExternalString(void* opaqueOwner, void* data, unsigned)
{
    auto* owner = static_cast<BindingExternalStringOwner*>(opaqueOwner);
    auto* context = owner->context;
    auto release = owner->release;
    auto byteLength = owner->byteLength;
    owner->~BindingExternalStringOwner();
    WTF::fastFree(owner);
    release(context, static_cast<uint8_t*>(data), byteLength);
}

namespace Bun::Bindgen::Detail {
struct CppNativeResultAccess final {
    static CppBytes adoptBytes(BindByteSlice& bytes)
    {
        CppBytes result;
        result.m_bytes = std::exchange(bytes, {});
        return result;
    }

    static bool takeBytes(CppBytes& bytes, BindByteSlice& output)
    {
        if (!bytes.m_vector.isEmpty()) {
            if (!encodeBindingBytes(bytes.m_vector.span(), output))
                return false;
            bytes.m_vector.clear();
        } else
            output = std::exchange(bytes.m_bytes, {});
        return true;
    }

    template<typename Collection>
    static decltype(auto) element(Collection& collection, size_t index)
    {
        if constexpr (requires { collection.m_values; })
            return (collection.m_values[index]);
        else
            return (collection[index]);
    }

    template<typename Collection, typename Value>
    static void append(Collection& collection, Value&& value)
    {
        if constexpr (requires { collection.appendAdopted(std::forward<Value>(value)); })
            collection.appendAdopted(std::forward<Value>(value));
        else {
            RELEASE_ASSERT(collection.size() < collection.capacity());
            collection.unsafeAppendWithoutCapacityCheck(std::forward<Value>(value));
        }
    }
};

struct CppArgumentAccess final {
    static BindDeferredConversionsHandle* deferredHandle(const EngineCallContext& context) { return reinterpret_cast<BindDeferredConversionsHandle*>(context.m_deferred); }
    static const BindByteLeaseHandle* handle(const CppScopedBytes& value) { return value.m_handle; }
    static BindByteLeaseHandle* handle(const CppScopedMutableBytes& value) { return value.m_handle; }
    static JSC::JSValue dictionarySource(const CppDictionarySource& value) { return value.m_value.get(); }

    template<typename T>
    static BindLazyArgumentHandle* lazyHandle(const CppLazyArgument<T>& value)
    {
        return reinterpret_cast<BindLazyArgumentHandle*>(static_cast<CppLazyArgumentStateBase*>(&value.state()));
    }

    template<typename T>
    static CppLazyArgument<T> lazyArgument(JSC::JSGlobalObject* global, BindLazyArgumentHandle* handle, BindingDeferredConversions* deferred, uint64_t key)
    {
        RELEASE_ASSERT(handle);
        auto& state = *reinterpret_cast<CppLazyArgumentStateBase*>(handle);
        state.requireContext(global, deferred);
        state.requireWireKey(key);
        return static_cast<CppLazyArgumentState<T>&>(state).view();
    }
};
}

namespace {

using Bun::Bindgen::bindingExceptionAfterDispatch;
using Bun::Bindgen::finishBindingVoidCall;
using Bun::Bindgen::invokeBindingStatusEntry;
using Bun::Bindgen::materializeBindingException;
using Bun::Bindgen::takeBindingCallId;

JSC::JSObject* createBindingError(JSC::JSGlobalObject* global, JSC::ErrorType type, const WTF::String& message)
{
    return JSC::ErrorInstance::create(global->vm(), global->errorStructure(type), message, JSC::JSValue(), nullptr, JSC::TypeNothing, type, true);
}

JSC::JSObject* createBindingAggregateError(JSC::JSGlobalObject* global, JSC::JSValue value, const WTF::String& message)
{
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* errors = dynamicDowncast<JSC::JSArray>(value);
    RELEASE_ASSERT(errors);
    if (message.isNull()) {
        Bun::Bindgen::throwBindingOutOfMemoryError(global, scope);
        return nullptr;
    }
    RELEASE_AND_RETURN(scope, JSC::createAggregateError(vm, global->errorStructure(JSC::ErrorType::AggregateError), errors, message, JSC::jsUndefined(), nullptr, JSC::TypeNothing, false));
}

inline bool checkBindingConversionResult(JSC::ExceptionScope& scope, bool converted)
{
    if (materializeBindingException(scope))
        return false;
    RELEASE_ASSERT_WITH_MESSAGE(converted, "binding conversion failed without an exception");
    return true;
}

inline BindStatus scheduleBindingCallbackNextTick(JSC::JSGlobalObject* global, JSC::JSValue callback, JSC::JSValue receiver, const JSC::ArgList& arguments)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    if (materializeBindingException(scope))
        return BIND_STATUS_PENDING_EXCEPTION;
    auto* defaultGlobal = defaultGlobalObject(global);
    auto prepared = defaultGlobal->processObject()->prepareNextTick(defaultGlobal, callback, arguments, receiver);
    if (materializeBindingException(scope))
        return BIND_STATUS_PENDING_EXCEPTION;
    RELEASE_ASSERT(prepared);
    prepared->commit();
    return BIND_STATUS_OK;
}

inline JSC::EncodedJSValue invokeBindingBuiltinConstructor(JSC::JSGlobalObject* global, JSC::CallFrame* callFrame, JSC::JSFunction* function)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    if (materializeBindingException(scope))
        return {};
    auto result = JSC::call(global, function, JSC::getCallData(function), callFrame->thisValue(), JSC::ArgList(callFrame));
    if (materializeBindingException(scope))
        return {};
    return JSC::JSValue::encode(result);
}

template<typename Invoke>
JSC::EncodedJSValue invokeBindingPromiseEntry(JSC::JSGlobalObject* global, Invoke&& invoke)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto result = std::forward<Invoke>(invoke)();
    if (!materializeBindingException(scope))
        return result;
    auto* promise = JSC::JSPromise::rejectedPromiseWithCaughtException(global, scope);
    if (!promise)
        return {};
    return JSC::JSValue::encode(promise);
}

#define BINDGEN_RETURN_IF_EXCEPTION(scope__, value__)          \
    do {                                                       \
        if (materializeBindingException(scope__)) [[unlikely]] \
            return value__;                                    \
    } while (false)

bool bindingTerminationAfterNonThrowingCall(JSC::ExceptionScope& scope)
{
    auto& vm = scope.vm();
    EXCEPTION_ASSERT(!!scope.exception() == vm.traps().needHandling(JSC::VMTraps::NeedExceptionHandling));
    vm.hasExceptionsAfterHandlingTraps();
    auto* exception = scope.exception();
    if (!exception)
        return false;
    RELEASE_ASSERT_WITH_MESSAGE(vm.isTerminationException(exception), "non-throwing engine shim changed exception state without termination");
    return true;
}

template<typename T, void (*destroy)(T*)>
class BindingResultGuard {
public:
    BindingResultGuard(T& value, bool ownsPayload)
        : m_value(value)
        , m_ownsPayload(ownsPayload)
    {
    }
    BindingResultGuard(const BindingResultGuard&) = delete;
    BindingResultGuard& operator=(const BindingResultGuard&) = delete;
    ~BindingResultGuard()
    {
        if constexpr (destroy != nullptr) {
            if (m_ownsPayload)
                destroy(&m_value);
        }
#if ASSERT_ENABLED
        std::memset(&m_value, 0xA5, sizeof(m_value));
#endif
    }
    void release()
    {
        RELEASE_ASSERT(m_ownsPayload);
        m_ownsPayload = false;
#if ASSERT_ENABLED
        std::memset(&m_value, 0xA5, sizeof(m_value));
#endif
    }

private:
    T& m_value;
    bool m_ownsPayload;
};

template<typename T>
T* movedBindingHandle()
{
    return reinterpret_cast<T*>(static_cast<uintptr_t>(1));
}

struct BindingDomainErrorFactory {
    size_t payloadOffset;
    JSC::JSObject* (*create)(JSC::JSGlobalObject*, void*);
};

struct BindingCompletionCodec {
    size_t resultSize;
    void (*destroy)(void*);
    JSC::JSValue (*decodeValue)(JSC::JSGlobalObject*, void*);
    size_t valueOffset;
    size_t tagOffset;
    std::span<const BindingDomainErrorFactory> errors;
    WTF::String (*dropMessage)();
};

inline void deliverBindingCompletionValue(
    JSC::JSGlobalObject* global, JSC::JSPromise* promise, BindCompletionDisposition disposition,
    void* result, const BindingCompletionCodec& codec)
{
    RELEASE_ASSERT(global && promise && result);
    auto& vm = global->vm();
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto resultGuard = WTF::makeScopeExit([&] {
        if (disposition == BIND_COMPLETION_VALUE || disposition == BIND_COMPLETION_DOMAIN_ERROR)
            codec.destroy(result);
#if ASSERT_ENABLED
        std::memset(result, 0xA5, codec.resultSize);
#endif
    });

    vm.hasExceptionsAfterHandlingTraps();
    if (auto* exception = throwScope.exception()) {
        if (vm.isTerminationException(exception))
            return;
        RELEASE_ASSERT_WITH_MESSAGE(disposition == BIND_COMPLETION_PENDING_EXCEPTION, "completion returned a non-exception disposition with an ordinary pending exception");
    }

    const auto rejectPendingException = [&] {
        RELEASE_ASSERT(throwScope.exception());
        auto value = throwScope.exception()->value();
        if (!throwScope.tryClearException())
            return;
        Bun::attachAsyncStackFromPromise(global, value, promise);
        promise->reject(vm, value);
    };
    const auto reject = [&](JSC::JSObject* error) {
        if (!error && !materializeBindingException(throwScope))
            Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
        if (materializeBindingException(throwScope)) {
            rejectPendingException();
            return;
        }
        RELEASE_ASSERT(error);
        Bun::attachAsyncStackFromPromise(global, error, promise);
        promise->reject(vm, error);
    };

    auto* bytes = static_cast<uint8_t*>(result);
    switch (disposition) {
    case BIND_COMPLETION_VALUE: {
        RELEASE_ASSERT(codec.errors.empty() || bytes[codec.tagOffset] == 0);
        auto value = codec.decodeValue(global, bytes + codec.valueOffset);
        if (materializeBindingException(throwScope)) {
            rejectPendingException();
            return;
        }
        RELEASE_ASSERT_WITH_MESSAGE(!value.isEmpty(), "binding completion returned an empty value without an exception");
        promise->resolve(global, vm, value);
        RETURN_IF_EXCEPTION(throwScope, void());
        return;
    }
    case BIND_COMPLETION_DOMAIN_ERROR: {
        RELEASE_ASSERT_WITH_MESSAGE(!codec.errors.empty(), "completion returned an undeclared domain error");
        auto tag = bytes[codec.tagOffset];
        RELEASE_ASSERT_WITH_MESSAGE(tag > 0 && tag <= codec.errors.size(), "completion returned an unknown domain-error tag");
        const auto& factory = codec.errors[tag - 1];
        auto* error = factory.create(global, bytes + factory.payloadOffset);
        if (!error) {
            RELEASE_ASSERT(materializeBindingException(throwScope));
            rejectPendingException();
            return;
        }
        reject(error);
        return;
    }
    case BIND_COMPLETION_DROP_REJECT: {
        auto message = codec.dropMessage();
        if (message.isNull()) {
            Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
            rejectPendingException();
            return;
        }
        reject(createBindingError(global, JSC::ErrorType::Error, message));
        return;
    }
    case BIND_COMPLETION_OUT_OF_MEMORY:
        reject(Bun::Bindgen::createBindingOutOfMemoryError(global));
        return;
    case BIND_COMPLETION_PENDING_EXCEPTION:
        rejectPendingException();
        return;
    case BIND_COMPLETION_CANCEL:
    case BIND_COMPLETION_LEAVE_PENDING:
        return;
    default:
        RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("binding completion has an unknown disposition");
    }
}

inline void deliverBindingCompletion(
    JSC::JSGlobalObject* global, JSC::JSPromise* promise, BindCompletionDisposition disposition,
    void* result, const BindingCompletionCodec& codec)
{
    auto& vm = global->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    deliverBindingCompletionValue(global, promise, disposition, result, codec);
    auto* exception = scope.exception();
    RELEASE_ASSERT_WITH_MESSAGE(!exception || vm.isTerminationException(exception), "binding completion left an ordinary exception pending instead of rejecting");
}

template<typename T>
T* takeBindingHandle(T*& handle)
{
    RELEASE_ASSERT(handle && handle != movedBindingHandle<T>());
    return std::exchange(handle, movedBindingHandle<T>());
}

std::span<const uint8_t> bindingByteSpan(std::span<const uint8_t> bytes)
{
    return bytes;
}

std::span<const uint8_t> bindingByteSpan(const WTF::Vector<uint8_t>& bytes)
{
    return bytes.span();
}

std::span<const uint8_t> bindingByteSpan(const Bun::Bindgen::CppBytes& bytes)
{
    return bytes.span();
}

class BindingRootedValue {
public:
    BindingRootedValue() = default;
    BindingRootedValue(JSC::VM& vm, JSC::JSValue value)
        : m_root(vm, value)
    {
    }
    BindingRootedValue(const BindingRootedValue&) = delete;
    BindingRootedValue& operator=(const BindingRootedValue&) = delete;
    BindingRootedValue(BindingRootedValue&& other) noexcept
    {
        m_root.swap(other.m_root);
    }
    BindingRootedValue& operator=(BindingRootedValue&& other) noexcept
    {
        if (this == &other)
            return *this;
        m_root.clear();
        m_root.swap(other.m_root);
        return *this;
    }

    void set(JSC::VM& vm, JSC::JSValue next)
    {
        m_root.set(vm, next);
    }

    JSC::JSValue get() const { return m_root.get(); }

    const BindJSValueHandle* borrowHandle() const
    {
        RELEASE_ASSERT(m_root);
        return bindingValueHandle(*static_cast<const JSC::HandleBase&>(m_root).slot());
    }

private:
    JSC::Strong<JSC::Unknown> m_root;
};

class BindingConversionInput {
public:
    BindingConversionInput(JSC::JSValue value)
        : m_value(value)
    {
    }

    BindingConversionInput(BindingConversionInput&& other) noexcept
        : m_value(other.value())
        , m_iteratorMethod(WTF::move(other.m_iteratorMethod))
    {
    }

    JSC::JSValue value() const { return m_value.value(); }

    bool selectIterable(JSC::JSGlobalObject* global) const
    {
        auto scope = DECLARE_THROW_SCOPE(global->vm());
        if (!value().isObject())
            return false;
        auto method = resolveIteratorMethod(global);
        RETURN_IF_EXCEPTION(scope, false);
        return !method.isUndefined();
    }

    template<typename Callback>
    void forEachInIterable(JSC::JSGlobalObject* global, NOESCAPE const Callback& callback) const
    {
        if (!value().isObject()) {
            JSC::forEachInIterable(global, value(), callback);
            return;
        }
        auto scope = DECLARE_THROW_SCOPE(global->vm());
        auto method = resolveIteratorMethod(global);
        RETURN_IF_EXCEPTION(scope, void());
        scope.release();
        JSC::forEachInIterable(*global, JSC::asObject(value()), method,
            [&](JSC::VM& vm, JSC::JSGlobalObject& realm, JSC::JSValue item) {
                callback(vm, &realm, item);
            });
    }

private:
    JSC::JSValue resolveIteratorMethod(JSC::JSGlobalObject* global) const
    {
        if (auto method = m_iteratorMethod.get())
            return method;
        auto scope = DECLARE_THROW_SCOPE(global->vm());
        auto method = JSC::iteratorMethod(global, JSC::asObject(value()));
        RETURN_IF_EXCEPTION(scope, JSC::jsUndefined());
        m_iteratorMethod.set(global->vm(), method);
        return method;
    }

    JSC::EnsureStillAliveScope m_value;
    mutable BindingRootedValue m_iteratorMethod;
};

const JSC::JSValue& bindingValue(const JSC::JSValue& value)
{
    return value;
}

JSC::JSValue bindingValue(const BindingRootedValue& value)
{
    return value.get();
}

const BindJSValueHandle* bindingValueHandle(const BindingRootedValue& value)
{
    return value.borrowHandle();
}

const BindJSValueHandle* bindingValueHandle(BindingRootedValue&&) = delete;

void setBindingValue(JSC::VM&, JSC::JSValue& destination, JSC::JSValue value)
{
    destination = value;
}

void setBindingValue(JSC::VM& vm, BindingRootedValue& destination, JSC::JSValue value)
{
    destination.set(vm, value);
}

template<typename T>
T* allocateBindingTransferItems(size_t length)
{
    static_assert(std::is_trivially_copyable_v<T> && std::is_standard_layout_v<T>);
    if (!length || length > std::numeric_limits<size_t>::max() / sizeof(T))
        return nullptr;
    auto* bytes = bun_bindgen_transfer_alloc_aligned(length * sizeof(T), alignof(T));
    if (!bytes)
        return nullptr;
    auto* items = reinterpret_cast<T*>(bytes);
    std::memset(items, 0, length * sizeof(T));
    return items;
}

class BindingTemporaryWireStorage {
public:
    BindingTemporaryWireStorage() = default;
    BindingTemporaryWireStorage(const BindingTemporaryWireStorage&) = delete;
    BindingTemporaryWireStorage& operator=(const BindingTemporaryWireStorage&) = delete;
    BindingTemporaryWireStorage(BindingTemporaryWireStorage&&) noexcept = default;
    BindingTemporaryWireStorage& operator=(BindingTemporaryWireStorage&&) noexcept = default;

    template<typename T>
    T* allocate(size_t length)
    {
        static_assert(alignof(T) <= alignof(std::max_align_t));
        if (!length)
            return nullptr;
        constexpr size_t overhead = sizeof(Allocation) + alignof(T) - 1;
        if (length > (std::numeric_limits<size_t>::max() - overhead) / sizeof(T))
            return nullptr;
        void* memory = nullptr;
        if (!WTF::tryFastMalloc(overhead + length * sizeof(T)).getValue(memory))
            return nullptr;
        auto* allocation = new (NotNull, memory) Allocation { m_allocations.release() };
        m_allocations.reset(allocation);
        auto address = reinterpret_cast<uintptr_t>(allocation + 1);
        address = (address + alignof(T) - 1) & ~(static_cast<uintptr_t>(alignof(T)) - 1);
        return reinterpret_cast<T*>(address);
    }
    template<typename T>
    T* allocateZeroed(size_t length)
    {
        static_assert(std::is_trivially_copyable_v<T> && std::is_standard_layout_v<T>);
        auto* items = allocate<T>(length);
        if (items)
            std::memset(items, 0, length * sizeof(T));
        return items;
    }
    template<typename T>
    T* copy(const T& value)
    {
        static_assert(std::is_trivially_destructible_v<T>);
        auto* item = allocate<T>(1);
        return item ? new (NotNull, item) T(value) : nullptr;
    }
    template<typename T>
    T* create()
    {
        auto* item = allocate<T>(1);
        if (!item)
            return nullptr;
        auto* allocation = m_allocations.get();
        new (NotNull, item) T();
        allocation->value = item;
        allocation->destroy = [](void* value) { static_cast<T*>(value)->~T(); };
        return item;
    }

private:
    struct Allocation {
        Allocation* next;
        void* value { nullptr };
        void (*destroy)(void*) { nullptr };
    };
    struct Release {
        void operator()(Allocation* allocation) const
        {
            while (allocation) {
                auto* current = std::exchange(allocation, allocation->next);
                if (current->destroy)
                    current->destroy(current->value);
                WTF::fastFree(current);
            }
        }
    };
    std::unique_ptr<Allocation, Release> m_allocations;
};

class BindingBufferSource {
public:
    static bool isIntegerTypedArray(JSC::JSValue value)
    {
        if (!value.isCell())
            return false;
        switch (value.asCell()->type()) {
        case JSC::JSType::Int8ArrayType:
        case JSC::JSType::Uint8ArrayType:
        case JSC::JSType::Uint8ClampedArrayType:
        case JSC::JSType::Int16ArrayType:
        case JSC::JSType::Uint16ArrayType:
        case JSC::JSType::Int32ArrayType:
        case JSC::JSType::Uint32ArrayType:
        case JSC::JSType::BigInt64ArrayType:
        case JSC::JSType::BigUint64ArrayType:
            return true;
        default:
            return false;
        }
    }
    static bool matchesTypedArrayRequirement(JSC::JSValue value, bool requireIntegerTypedArray, uint8_t requiredTypedArray)
    {
        if (requiredTypedArray == 1 && (!value.isCell() || value.asCell()->type() != JSC::JSType::Uint32ArrayType))
            return false;
        if (requiredTypedArray == 2 && (!value.isCell() || value.asCell()->type() != JSC::JSType::Uint8ArrayType))
            return false;
        if (requireIntegerTypedArray && !isIntegerTypedArray(value))
            return false;
        return true;
    }
    static bool isDetachedOrOutOfBoundsSource(JSC::JSValue value, bool allowArrayBuffer, bool requireIntegerTypedArray, uint8_t requiredTypedArray)
    {
        if (!matchesTypedArrayRequirement(value, requireIntegerTypedArray, requiredTypedArray))
            return false;
        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value))
            return view->isOutOfBounds();
        if (allowArrayBuffer) {
            if (auto* wrapper = dynamicDowncast<JSC::JSArrayBuffer>(value))
                return wrapper->impl()->isDetached();
        }
        return false;
    }
    bool initialize(JSC::JSValue value, bool allowDetached = false, bool allowArrayBuffer = true, bool requireIntegerTypedArray = false, uint8_t requiredTypedArray = 0, bool allowShared = true)
    {
        RELEASE_ASSERT(!m_view && !m_buffer);
        if (!matchesTypedArrayRequirement(value, requireIntegerTypedArray, requiredTypedArray))
            return false;
        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
            m_source = value;
            m_elementSize = JSC::elementSize(view->type());
            if (view->isDetached()) {
                m_detached = allowDetached;
                return allowDetached;
            }
            if (!allowDetached && view->isOutOfBounds())
                return false;
            m_view = view;
            m_buffer = view->mode() == JSC::FastTypedArray ? nullptr : view->possiblySharedBuffer();
            m_data = static_cast<uint8_t*>(view->vector());
            m_byteOffset = view->byteOffset();
            m_byteLength = view->byteLength();
            return allowShared || !isShared();
        }
        if (!allowArrayBuffer)
            return false;
        auto* wrapper = dynamicDowncast<JSC::JSArrayBuffer>(value);
        if (!wrapper)
            return false;
        m_source = value;
        if (wrapper->impl()->isDetached()) {
            m_detached = allowDetached;
            return allowDetached;
        }
        m_buffer = wrapper->impl();
        m_data = static_cast<uint8_t*>(m_buffer->data());
        m_byteLength = m_buffer->byteLength();
        return allowShared || !isShared();
    }
    JSC::JSArrayBufferView* view() const { return m_view; }
    JSC::ArrayBuffer* buffer() const { return m_buffer; }
    uint8_t* data() const { return m_data; }
    size_t byteOffset() const { return m_byteOffset; }
    size_t byteLength() const { return m_byteLength; }
    size_t elementSize() const { return m_elementSize; }
    JSC::JSValue source() const { return m_source; }
    bool isDetached() const { return m_detached; }
    bool isShared() const
    {
        auto* buffer = m_buffer ? m_buffer : m_view && m_view->hasArrayBuffer() ? m_view->possiblySharedBuffer()
                                                                             : nullptr;
        return buffer && buffer->isShared();
    }

private:
    JSC::JSArrayBufferView* m_view { nullptr };
    JSC::ArrayBuffer* m_buffer { nullptr };
    uint8_t* m_data { nullptr };
    size_t m_byteOffset { 0 };
    size_t m_byteLength { 0 };
    size_t m_elementSize { 1 };
    JSC::JSValue m_source;
    bool m_detached { false };
};

static void copyBindingBufferBytes(std::span<uint8_t> destination, uint8_t* source, bool shared)
{
    RELEASE_ASSERT(source || destination.empty());
    if (shared) {
        for (size_t index = 0; index < destination.size(); ++index)
            destination[index] = std::atomic_ref<uint8_t>(source[index]).load(std::memory_order_relaxed);
    } else if (!destination.empty())
        memcpy(destination.data(), source, destination.size());
}

class BindingByteCopyStorage final : public WTF::RefCounted<BindingByteCopyStorage> {
public:
    static RefPtr<BindingByteCopyStorage> tryCreate(size_t length)
    {
        void* allocation;
        if (!WTF::tryFastMalloc(sizeof(BindingByteCopyStorage)).getValue(allocation))
            return nullptr;
        auto* storage = new (NotNull, allocation) BindingByteCopyStorage;
        RefPtr<BindingByteCopyStorage> result = adoptRef(*storage);
        if (!result->m_bytes.tryGrow(length))
            return nullptr;
        return result;
    }
    ~BindingByteCopyStorage() = default;
    std::span<uint8_t> span() { return m_bytes.mutableSpan(); }

private:
    BindingByteCopyStorage() = default;
    WTF::Vector<uint8_t> m_bytes;
};

class BindingByteCopy {
public:
    static RefPtr<BindingByteCopy> createSnapshot(std::span<const uint8_t> bytes)
    {
        auto result = allocate(bytes.size());
        if (!result)
            return nullptr;
        result->m_snapshot = true;
        if (!bytes.empty())
            memcpy(result->mutableSpan().data(), bytes.data(), bytes.size());
        return result;
    }
    static RefPtr<BindingByteCopy> create(const BindingBufferSource& source, JSC::VM& vm, bool writable)
    {
        auto result = allocate(source.byteLength());
        if (!result)
            return nullptr;
        result->m_view = source.view();
        result->m_buffer = source.buffer();
        result->m_rootedSource.set(vm, source.source().getObject());
        result->m_writable = writable;
        result->m_detached = source.isDetached();
        return result;
    }
    void ref()
    {
        RELEASE_ASSERT(m_refCount);
        ++m_refCount;
        RELEASE_ASSERT(m_refCount);
    }
    void deref()
    {
        RELEASE_ASSERT(m_refCount);
        if (!--m_refCount)
            delete this;
    }
    std::span<const uint8_t> span() const { return m_storage->span().subspan(m_storageOffset, m_byteLength); }
    std::span<uint8_t> mutableSpan() { return m_storage->span().subspan(m_storageOffset, m_byteLength); }

    static bool coalesce(const WTF::Vector<BindingByteCopy*, 4>& copies)
    {
        struct Entry {
            BindingByteCopy* copy;
            uintptr_t start;
            uintptr_t end;
        };
        WTF::Vector<Entry, 4> entries;
        for (auto* copy : copies) {
            RELEASE_ASSERT(!copy->m_writeBack);
            if (!copy->m_byteLength)
                continue;
            auto start = reinterpret_cast<uintptr_t>(copy->currentData());
            RELEASE_ASSERT(start && copy->m_byteLength <= std::numeric_limits<uintptr_t>::max() - start);
            if (!entries.tryAppend(Entry { copy, start, start + copy->m_byteLength }))
                return false;
        }
        if (entries.size() < 2)
            return true;
        std::sort(entries.begin(), entries.end(), [](const Entry& left, const Entry& right) { return left.start < right.start; });
        for (size_t first = 0; first < entries.size();) {
            size_t next = first + 1;
            uintptr_t end = entries[first].end;
            while (next < entries.size() && entries[next].start < end) {
                end = std::max(end, entries[next].end);
                ++next;
            }
            if (next > first + 1) {
                auto storage = BindingByteCopyStorage::tryCreate(end - entries[first].start);
                if (!storage)
                    return false;
                for (size_t index = first; index < next; ++index) {
                    auto* copy = entries[index].copy;
                    copy->m_storage = storage;
                    copy->m_storageOffset = entries[index].start - entries[first].start;
                }
            }
            first = next;
        }
        return true;
    }
    void prepareForDispatch()
    {
        RELEASE_ASSERT(!m_snapshot);
        RELEASE_ASSERT(validate());
        if (m_detached)
            return;
        if (m_view) {
            m_originalData = m_view->vector();
            if (m_view->hasArrayBuffer())
                m_buffer = m_view->possiblySharedBuffer();
        } else
            m_originalData = m_buffer->data();
        copyBindingBufferBytes(mutableSpan(), static_cast<uint8_t*>(m_originalData), m_buffer && m_buffer->isShared());
        m_writeBack = m_writable;
    }
    bool validate() const
    {
        if (m_detached || m_snapshot)
            return true;
        if (m_view) {
            if (m_view->isDetached())
                return false;
            auto* currentBuffer = m_view->hasArrayBuffer() ? m_view->possiblySharedBuffer() : nullptr;
            if (m_buffer && currentBuffer != m_buffer.get())
                return false;
            if (m_writeBack && (currentBuffer != m_buffer.get() || m_view->vector() != m_originalData))
                return false;
            return currentBuffer && currentBuffer->isShared()
                ? m_view->byteLength() >= m_byteLength
                : m_view->byteLength() == m_byteLength;
        }
        if (!m_buffer || m_buffer->isDetached() || (m_writeBack && m_buffer->data() != m_originalData))
            return false;
        size_t currentLength = m_buffer->byteLength();
        return m_buffer->isShared() ? currentLength >= m_byteLength : currentLength == m_byteLength;
    }

private:
    static RefPtr<BindingByteCopy> allocate(size_t length)
    {
        auto storage = BindingByteCopyStorage::tryCreate(length);
        if (!storage)
            return nullptr;
        return adoptRef(new (std::nothrow) BindingByteCopy(WTF::move(storage), length));
    }
    BindingByteCopy(RefPtr<BindingByteCopyStorage>&& storage, size_t length)
        : m_storage(WTF::move(storage))
        , m_byteLength(length)
    {
    }
    void* currentData() const { return m_view ? m_view->vector() : m_buffer ? m_buffer->data() : nullptr; }
    ~BindingByteCopy()
    {
        if (!m_writeBack || !validate())
            return;
        auto bytes = span();
        size_t length = bytes.size();
        if (!length)
            return;
        auto* destination = static_cast<uint8_t*>(m_originalData);
        if (m_buffer && m_buffer->isShared()) {
            for (size_t index = 0; index < length; ++index)
                std::atomic_ref<uint8_t>(destination[index]).store(bytes[index], std::memory_order_relaxed);
        } else
            memcpy(destination, bytes.data(), length);
    }
    unsigned m_refCount { 1 };
    JSC::Strong<JSC::JSObject> m_rootedSource;
    RefPtr<JSC::ArrayBuffer> m_buffer;
    JSC::JSArrayBufferView* m_view { nullptr };
    void* m_originalData { nullptr };
    RefPtr<BindingByteCopyStorage> m_storage;
    size_t m_storageOffset { 0 };
    size_t m_byteLength { 0 };
    bool m_writable { false };
    bool m_writeBack { false };
    bool m_detached { false };
    bool m_snapshot { false };
};

class BindingByteLease {
public:
    BindingByteLease() = default;
    BindingByteLease(const BindingByteLease&) = delete;
    BindingByteLease& operator=(const BindingByteLease&) = delete;
    BindingByteLease(BindingByteLease&& other) noexcept
    {
        RELEASE_ASSERT(!other.m_deferred);
        m_buffer = std::move(other.m_buffer);
        m_copy = std::move(other.m_copy);
        m_view = std::exchange(other.m_view, nullptr);
        m_byteOffset = std::exchange(other.m_byteOffset, 0);
        m_byteLength = std::exchange(other.m_byteLength, 0);
        m_elementSize = std::exchange(other.m_elementSize, 1);
        m_source.swap(other.m_source);
        m_committed = std::exchange(other.m_committed, false);
        m_deferred = nullptr;
        m_viewHandle = std::exchange(other.m_viewHandle, nullptr);
        if (m_viewHandle)
            *m_viewHandle = reinterpret_cast<BindByteLeaseHandle*>(this);
        m_writable = std::exchange(other.m_writable, false);
        m_copyTransfers = other.m_copyTransfers;
        m_snapshotResizableOnRetention = other.m_snapshotResizableOnRetention;
        m_vm = std::exchange(other.m_vm, nullptr);
        m_threadUID = std::exchange(other.m_threadUID, 0);
        m_data = std::exchange(other.m_data, nullptr);
        if (m_copy)
            m_data = m_copy->span().data();
    }
    BindingByteLease& operator=(BindingByteLease&& other) noexcept
    {
        if (this == &other)
            return *this;
        this->~BindingByteLease();
        new (this) BindingByteLease(std::move(other));
        return *this;
    }
    ~BindingByteLease()
    {
        if (m_viewHandle)
            unbindView(m_viewHandle);
        if (!m_vm)
            return;
        assertVMThread();
        if (m_deferred)
            m_deferred->removeLease(this);
        m_copy = nullptr;
        if (m_committed && pinsBuffer())
            m_buffer->releaseByteLease(m_copyTransfers);
    }
    enum class PrepareResult { ready, outOfMemory, copyRequired, attachmentUnavailable };

    struct Options {
        bool writable;
        bool allowCopy;
        bool requireSourceAttachment;
        bool copyTransfers;
        bool snapshotResizableOnRetention;
    };

    PrepareResult prepare(const BindingBufferSource& source, JSC::VM& vm, Options options)
    {
        RELEASE_ASSERT(!m_vm && !m_committed);
        RELEASE_ASSERT(!options.snapshotResizableOnRetention || (!options.writable && options.allowCopy && !options.requireSourceAttachment));
        RELEASE_ASSERT_WITH_MESSAGE(WTF::Thread::currentSingleton().isJSThread(), "byte lease created outside a JavaScript thread");
        RELEASE_ASSERT_WITH_MESSAGE(vm.currentThreadIsHoldingAPILock(), "byte lease created outside its VM thread");
        m_vm = &vm;
        m_threadUID = WTF::Thread::currentSingleton().uid();
        m_byteLength = source.byteLength();
        m_elementSize = source.elementSize();
        m_source.set(vm, source.source());
        m_writable = options.writable;
        m_copyTransfers = options.copyTransfers;
        m_snapshotResizableOnRetention = options.snapshotResizableOnRetention;
        m_view = source.view();
        auto* buffer = source.buffer();
        if (!buffer && m_view && (options.writable || !options.allowCopy || options.requireSourceAttachment)) {
            buffer = m_view->possiblySharedBuffer();
            if (!buffer)
                return PrepareResult::outOfMemory;
        }
        if (!buffer || !buffer->canAcquireByteLease()) {
            if (options.requireSourceAttachment)
                return PrepareResult::attachmentUnavailable;
            if (!options.allowCopy)
                return PrepareResult::copyRequired;
            m_copy = BindingByteCopy::create(source, vm, options.writable);
            if (!m_copy)
                return PrepareResult::outOfMemory;
            m_data = m_copy->span().data();
            m_byteOffset = 0;
            return PrepareResult::ready;
        }
        m_buffer = buffer;
        m_byteOffset = m_view ? m_view->byteOffset() : source.byteOffset();
        m_data = m_view ? static_cast<uint8_t*>(m_view->vector()) : source.data();
        return PrepareResult::ready;
    }
    bool validate() const
    {
        if (!m_vm)
            return true;
        if (m_copy)
            return m_copy->validate();
        if (!m_buffer)
            return true;
        if (m_view) {
            if (m_view->isDetached() || m_view->possiblySharedBuffer() != m_buffer.get())
                return false;
            return m_view->byteOffset() == m_byteOffset
                && m_view->byteLength() == m_byteLength
                && m_view->vector() == m_data;
        }
        if (m_buffer->isDetached() || m_buffer->data() != m_data)
            return false;
        size_t currentLength = m_buffer->byteLength();
        return m_buffer->isShared() ? currentLength >= m_byteLength : currentLength == m_byteLength;
    }
    void acquire()
    {
        if (m_committed)
            return;
        RELEASE_ASSERT(validate());
        if (m_copy) {
            m_copy->prepareForDispatch();
            m_data = m_copy->span().data();
        } else if (m_vm && pinsBuffer())
            m_buffer->acquireByteLease(m_copyTransfers);
        m_committed = true;
    }
    bool defer(Bun::Bindgen::BindingDeferredConversions& deferred)
    {
        if (!m_vm)
            return true;
        RELEASE_ASSERT(!m_committed);
        RELEASE_ASSERT(!m_deferred);
        if (!deferred.addLease({
                this,
                +[](const void* value) { return static_cast<const BindingByteLease*>(value)->validate(); },
                +[](void* value) { static_cast<BindingByteLease*>(value)->acquire(); },
                +[](void* value) { return reinterpret_cast<BindingByteCopyHandle*>(static_cast<BindingByteLease*>(value)->m_copy.get()); },
            }))
            return false;
        m_deferred = &deferred;
        return true;
    }
    BindingByteLease* clone() const
    {
        RELEASE_ASSERT_WITH_MESSAGE(m_vm && m_committed, "a byte lease can escape only after deferred conversions finish and pins are acquired");
        assertVMThread();
        auto result = std::unique_ptr<BindingByteLease>(new (std::nothrow) BindingByteLease);
        if (!result)
            return nullptr;
        result->m_vm = m_vm;
        result->m_threadUID = m_threadUID;
        result->m_byteOffset = m_byteOffset;
        result->m_byteLength = m_byteLength;
        result->m_elementSize = m_elementSize;
        result->m_source.set(*m_vm, m_source.get());
        result->m_view = m_view;
        result->m_writable = m_writable;
        result->m_copyTransfers = m_copyTransfers;
        result->m_snapshotResizableOnRetention = m_snapshotResizableOnRetention;
        result->m_copy = m_copy;
        if (!m_copy) {
            RELEASE_ASSERT(m_buffer);
            if (m_snapshotResizableOnRetention && m_buffer->isResizableNonShared()) {
                result->m_copy = BindingByteCopy::createSnapshot(leasedSpan());
                if (!result->m_copy)
                    return nullptr;
                result->m_byteOffset = 0;
            } else
                result->m_buffer = m_buffer;
        }
        result->m_data = result->m_copy ? result->m_copy->span().data() : m_data;
        if (result->pinsBuffer())
            result->m_buffer->acquireByteLease(result->m_copyTransfers);
        result->m_committed = true;
        return result.release();
    }
    std::span<const uint8_t> leasedSpan() const
    {
        RELEASE_ASSERT(m_committed);
        return { m_data, m_byteLength };
    }
    std::span<uint8_t> mutableLeasedSpan()
    {
        RELEASE_ASSERT(m_committed && m_writable);
        if (m_copy)
            return m_copy->mutableSpan();
        return { const_cast<uint8_t*>(m_data), m_byteLength };
    }
    JSC::ArrayBuffer* buffer() const { return m_buffer.get(); }
    JSC::JSArrayBufferView* view() const { return m_view; }
    size_t byteOffset() const { return m_byteOffset; }
    size_t byteLength() const { return m_byteLength; }
    size_t elementSize() const { return m_elementSize; }
    JSC::JSValue source() const { return m_source.get(); }
    void assertVMThread() const
    {
        RELEASE_ASSERT(m_vm);
        RELEASE_ASSERT_WITH_MESSAGE(WTF::Thread::currentSingleton().isJSThread(), "byte lease lifecycle used outside a JavaScript thread");
        RELEASE_ASSERT_WITH_MESSAGE(m_vm->currentThreadIsHoldingAPILock(), "byte lease lifecycle used outside its VM thread");
        RELEASE_ASSERT_WITH_MESSAGE(m_threadUID == WTF::Thread::currentSingleton().uid(), "byte lease lifecycle moved to another thread");
    }

public:
    void bindView(BindByteLeaseHandle** handle)
    {
        RELEASE_ASSERT(m_vm && handle && *handle == reinterpret_cast<BindByteLeaseHandle*>(this));
        RELEASE_ASSERT(!m_viewHandle);
        m_viewHandle = handle;
    }
    void moveView(BindByteLeaseHandle** previous, BindByteLeaseHandle** next)
    {
        RELEASE_ASSERT(m_viewHandle == previous && previous && next);
        RELEASE_ASSERT(*previous == reinterpret_cast<BindByteLeaseHandle*>(this));
        m_viewHandle = next;
        *next = reinterpret_cast<BindByteLeaseHandle*>(this);
        *previous = nullptr;
    }
    void unbindView(BindByteLeaseHandle** handle)
    {
        RELEASE_ASSERT(m_viewHandle == handle && handle);
        RELEASE_ASSERT(*handle == reinterpret_cast<BindByteLeaseHandle*>(this));
        *handle = nullptr;
        m_viewHandle = nullptr;
    }

private:
    bool pinsBuffer() const { return m_buffer && !m_buffer->isShared(); }


    RefPtr<JSC::ArrayBuffer> m_buffer;
    RefPtr<BindingByteCopy> m_copy;
    JSC::JSArrayBufferView* m_view { nullptr };
    const uint8_t* m_data { nullptr };
    size_t m_byteOffset { 0 };
    size_t m_byteLength { 0 };
    size_t m_elementSize { 1 };
    JSC::Strong<JSC::Unknown> m_source;
    bool m_committed { false };
    bool m_writable { false };
    bool m_copyTransfers { false };
    bool m_snapshotResizableOnRetention { false };
    Bun::Bindgen::BindingDeferredConversions* m_deferred { nullptr };
    BindByteLeaseHandle** m_viewHandle { nullptr };
    JSC::VM* m_vm { nullptr };
    uint32_t m_threadUID { 0 };

    template<bool> friend class Bun::Bindgen::CppScopedByteView;
};
}

namespace Bun::Bindgen {

inline BindingDeferredConversions::BindingDeferredConversions(JSC::JSGlobalObject& global)
    : m_global(global)
{
}

inline bool BindingDeferredConversions::addLease(Lease lease)
{
    RELEASE_ASSERT(lease.value && lease.validate && lease.acquire && lease.copy);
    RELEASE_ASSERT(!m_acquired);
    return m_leases.tryAppend(lease);
}

inline void BindingDeferredConversions::removeLease(void* value)
{
    for (size_t index = 0; index < m_leases.size(); ++index) {
        if (m_leases[index].value != value)
            continue;
        m_leases.removeAt(index);
        return;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

inline bool BindingDeferredConversions::seal()
{
    RELEASE_ASSERT(!m_sealed);
    m_sealed = true;
    return m_remaining ? true : acquireFromWire();
}

inline bool BindingDeferredConversions::acquire(const CppDeferredLeaseProof& proof)
{
    RELEASE_ASSERT(proof.m_state == this && m_sealed && !m_remaining);
    return acquireFromWire();
}

inline bool BindingDeferredConversions::acquireFromWire()
{
    RELEASE_ASSERT(m_sealed && !m_remaining);
    if (m_acquired)
        return true;
    for (const auto& lease : m_leases) {
        if (!lease.validate(lease.value)) {
            auto scope = DECLARE_THROW_SCOPE(m_global.vm());
            JSC::throwTypeError(&m_global, scope, "ArrayBuffer changed while preparing byte lease"_s);
            return false;
        }
    }
    WTF::Vector<BindingByteCopy*, 4> copies;
    for (const auto& lease : m_leases) {
        if (auto* copy = reinterpret_cast<BindingByteCopy*>(lease.copy(lease.value))) {
            if (!copies.tryAppend(copy)) {
                auto scope = DECLARE_THROW_SCOPE(m_global.vm());
                Bun::Bindgen::throwBindingOutOfMemoryError(&m_global, scope);
                return false;
            }
        }
    }
    if (!BindingByteCopy::coalesce(copies)) {
        auto scope = DECLARE_THROW_SCOPE(m_global.vm());
        Bun::Bindgen::throwBindingOutOfMemoryError(&m_global, scope);
        return false;
    }
    for (const auto& lease : m_leases)
        lease.acquire(lease.value);
    m_acquired = true;
    return true;
}

}

static BindStatus checkBindingTraps(BindGlobalObjectHandle* globalHandle, BindStatus status, const JSC::Exception* inherited = nullptr)
{
    RELEASE_ASSERT(globalHandle);
    RELEASE_ASSERT_WITH_MESSAGE(status <= BIND_STATUS_FAILED, "binding returned an unknown status");
    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
    auto& vm = JSC::getVM(global);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    vm.hasExceptionsAfterHandlingTraps();
    if (auto* exception = scope.exception()) {
        if (vm.isTerminationException(exception))
            return BIND_STATUS_PENDING_EXCEPTION;
        if (inherited) {
            RELEASE_ASSERT_WITH_MESSAGE(exception == inherited, "native export replaced its inherited exception");
            return BIND_STATUS_PENDING_EXCEPTION;
        }
        RELEASE_ASSERT_WITH_MESSAGE(status == BIND_STATUS_PENDING_EXCEPTION, "binding returned a non-exception status with an ordinary pending exception");
        return status;
    }
    RELEASE_ASSERT_WITH_MESSAGE(!inherited, "native export cleared its inherited exception");
    RELEASE_ASSERT_WITH_MESSAGE(status != BIND_STATUS_PENDING_EXCEPTION, "binding returned pending_exception without an exception");
    return status;
}

#if defined(BUN_BINDGEN_SHARD) && BUN_BINDGEN_SHARD == 0
namespace Bun::Bindgen {
JSC::JSValue bindingClassWrapValue(JSC::JSGlobalObject* global, BindNativeHandle* native, BindingNativeWrap wrap)
{
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    BindEncodedJSValue encoded = 0;
    auto status = wrap(reinterpret_cast<BindGlobalObjectHandle*>(global), native, &encoded);
    RELEASE_ASSERT(status == BIND_STATUS_OK || status == BIND_STATUS_PENDING_EXCEPTION || status == BIND_STATUS_OUT_OF_MEMORY);
    RELEASE_ASSERT(status == BIND_STATUS_OK || !encoded);
    if (bindingExceptionAfterDispatch(throwScope, status))
        return {};
    switch (status) {
    case BIND_STATUS_OK:
        return decodeBindingValue(encoded);
    case BIND_STATUS_OUT_OF_MEMORY:
        Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
        return {};
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}
}

extern "C" BindStatus bun_bindgen_check_traps(BindGlobalObjectHandle* globalHandle, BindStatus status) noexcept
{
    return checkBindingTraps(globalHandle, status);
}

extern "C" const BindExceptionHandle* bun_bindgen_current_exception(BindGlobalObjectHandle* globalHandle) noexcept
{
    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
    RELEASE_ASSERT(global);
    return reinterpret_cast<const BindExceptionHandle*>(JSC::getVM(global).exceptionForInspection());
}

extern "C" BindStatus bun_bindgen_check_traps_inheriting(BindGlobalObjectHandle* globalHandle, BindStatus status, const BindExceptionHandle* inherited) noexcept
{
    return checkBindingTraps(globalHandle, status, reinterpret_cast<const JSC::Exception*>(inherited));
}

extern "C" BindStatus bun_bindgen_check_post_call_traps(BindGlobalObjectHandle* globalHandle, BindStatus status) noexcept
{
    return checkBindingTraps(globalHandle, status);
}

extern "C" BindByteOwnerHandle* bun_bindgen_byte_owner_create(uint8_t* ptr, size_t len, void* context, BindByteOwnerReleaseCallback release) noexcept
{
    RELEASE_ASSERT(ptr || !len);
    RELEASE_ASSERT(release);
    void* allocation = nullptr;
    if (!WTF::tryFastMalloc(sizeof(BindByteOwnerHandle)).getValue(allocation))
        return nullptr;
    auto* owner = new (NotNull, allocation) BindByteOwnerHandle;
    owner->externalBytes = ptr;
    owner->externalLength = len;
    owner->externalContext = context;
    owner->externalRelease = release;
    return owner;
}

extern "C" BindByteOwnerHandle* bun_bindgen_external_byte_owner_adopt(uint8_t* ptr, size_t len, void* context, BindExternalBytesReleaseCallback release) noexcept
{
    // Empty views can retain an allocation whose original address must reach the deallocator.
    RELEASE_ASSERT(ptr || !len);
    RELEASE_ASSERT(release);
    void* allocation = nullptr;
    if (!WTF::tryFastMalloc(sizeof(BindByteOwnerHandle)).getValue(allocation))
        return nullptr;
    auto* owner = new (NotNull, allocation) BindByteOwnerHandle;
    owner->externalBytes = ptr;
    owner->externalLength = len;
    owner->externalContext = context;
    owner->opaqueExternalRelease = release;
    return owner;
}

extern "C" void bun_bindgen_byte_owner_release(BindByteOwnerHandle* owner) noexcept
{
    RELEASE_ASSERT(owner);
    owner->~BindByteOwnerHandle();
    WTF::fastFree(owner);
}

extern "C" void bun_bindgen_byte_owner_view(const BindByteOwnerHandle* owner, BindConstByteSlice* out) noexcept
{
    RELEASE_ASSERT(owner && out);
    RELEASE_ASSERT(owner->externalBytes || !owner->externalLength);
    *out = { owner->externalLength ? owner->externalBytes : nullptr, owner->externalLength };
}

extern "C" void bun_bindgen_string_view(const BindStringHandle* handle, BindStringView* out) noexcept
{
    RELEASE_ASSERT(out);
    auto* string = reinterpret_cast<const WTF::StringImpl*>(handle);
    if (!string || string->length() == 0) {
        *out = { nullptr, 0, BIND_STRING_LATIN1 };
        return;
    }
    if (string->is8Bit()) {
        auto span = string->span8();
        *out = { reinterpret_cast<const uint8_t*>(span.data()), span.size(), BIND_STRING_LATIN1 };
        return;
    }
    auto span = string->span16();
    *out = { reinterpret_cast<const uint8_t*>(span.data()), span.size(), BIND_STRING_UTF16 };
}

extern "C" void bun_bindgen_string_release(BindStringHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    reinterpret_cast<WTF::StringImpl*>(handle)->deref();
}

extern "C" void bun_bindgen_string_retain(BindStringHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    reinterpret_cast<WTF::StringImpl*>(handle)->ref();
}

extern "C" BindStatus bun_bindgen_string_create_uninitialized(size_t length, BindStringEncoding encoding, BindStringHandle** outHandle, uint8_t** outData) noexcept
{
    RELEASE_ASSERT(length);
    RELEASE_ASSERT(outHandle);
    RELEASE_ASSERT(outData);
    *outHandle = nullptr;
    *outData = nullptr;
    RELEASE_ASSERT(encoding == BIND_STRING_LATIN1 || encoding == BIND_STRING_UTF16);
    if (length > Bun::stringSyntheticAllocationLimit())
        return BIND_STATUS_OUT_OF_MEMORY;
    if (encoding == BIND_STRING_LATIN1) {
        std::span<Latin1Character> units;
        auto impl = WTF::StringImpl::tryCreateUninitialized(length, units);
        if (!impl)
            return BIND_STATUS_OUT_OF_MEMORY;
        *outData = reinterpret_cast<uint8_t*>(units.data());
        *outHandle = reinterpret_cast<BindStringHandle*>(impl.leakRef());
        return BIND_STATUS_OK;
    }
    std::span<char16_t> units;
    auto impl = WTF::StringImpl::tryCreateUninitialized(length, units);
    if (!impl)
        return BIND_STATUS_OUT_OF_MEMORY;
    *outData = reinterpret_cast<uint8_t*>(units.data());
    *outHandle = reinterpret_cast<BindStringHandle*>(impl.leakRef());
    return BIND_STATUS_OK;
}

extern "C" BindStatus bun_bindgen_string_create_external(const uint8_t* data, size_t length, BindStringEncoding encoding, void* context, BindExternalStringReleaseCallback release, BindStringHandle** outHandle) noexcept
{
    RELEASE_ASSERT(data);
    RELEASE_ASSERT(length);
    RELEASE_ASSERT(release);
    RELEASE_ASSERT(outHandle);
    *outHandle = nullptr;
    RELEASE_ASSERT(encoding == BIND_STRING_LATIN1 || encoding == BIND_STRING_UTF16);
    CheckedSize byteLength = length;
    byteLength *= encoding == BIND_STRING_LATIN1 ? sizeof(Latin1Character) : sizeof(char16_t);
    if (byteLength.hasOverflowed())
        return BIND_STATUS_OUT_OF_MEMORY;
    void* allocation = nullptr;
    if (!WTF::tryFastMalloc(sizeof(BindingExternalStringOwner)).getValue(allocation))
        return BIND_STATUS_OUT_OF_MEMORY;
    auto* owner = new (NotNull, allocation) BindingExternalStringOwner { context, release, byteLength.value() };
    if (encoding == BIND_STRING_LATIN1) {
        auto impl = WTF::ExternalStringImpl::create({ reinterpret_cast<const Latin1Character*>(data), length }, owner, releaseBindingExternalString);
        *outHandle = reinterpret_cast<BindStringHandle*>(&impl.leakRef());
        return BIND_STATUS_OK;
    }
    RELEASE_ASSERT(!(reinterpret_cast<uintptr_t>(data) % alignof(char16_t)));
    auto impl = WTF::ExternalStringImpl::create({ reinterpret_cast<const char16_t*>(data), length }, owner, releaseBindingExternalString);
    *outHandle = reinterpret_cast<BindStringHandle*>(&impl.leakRef());
    return BIND_STATUS_OK;
}

extern "C" BindStatus bun_bindgen_string_create_static_external(const uint8_t* data, size_t length, BindStringEncoding encoding, BindStringHandle** outHandle) noexcept
{
    RELEASE_ASSERT(data);
    RELEASE_ASSERT(length);
    RELEASE_ASSERT(outHandle);
    if (encoding == BIND_STRING_LATIN1) {
        auto impl = WTF::ExternalStringImpl::createStatic({ reinterpret_cast<const Latin1Character*>(data), length });
        *outHandle = reinterpret_cast<BindStringHandle*>(&impl.leakRef());
        return BIND_STATUS_OK;
    }
    RELEASE_ASSERT(encoding == BIND_STRING_UTF16);
    RELEASE_ASSERT(!(reinterpret_cast<uintptr_t>(data) % alignof(char16_t)));
    auto impl = WTF::ExternalStringImpl::createStatic({ reinterpret_cast<const char16_t*>(data), length });
    *outHandle = reinterpret_cast<BindStringHandle*>(&impl.leakRef());
    return BIND_STATUS_OK;
}

extern "C" void bun_bindgen_string_ensure_hash(BindStringHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    reinterpret_cast<WTF::StringImpl*>(handle)->hash();
}
#endif

static JSC::JSValue readBindingJSValue(const BindJSValueHandle* handle)
{
    RELEASE_ASSERT(handle);
    return *reinterpret_cast<const JSC::JSValue*>(handle);
}

static JSC::JSValue readBindingRootValue(JSC::JSGlobalObject* global, const BindRootHandle* handle)
{
    RELEASE_ASSERT(handle);
    auto* root = reinterpret_cast<const Bun::StrongRefStorage*>(handle);
    RELEASE_ASSERT(&root->globalObject()->vm() == &global->vm());
    auto value = root->value();
    RELEASE_ASSERT(!value.isEmpty());
    return value;
}

static JSC::JSValue readBindingJSValueSlice(const BindJSValueSliceHandle* handle, size_t index)
{
    RELEASE_ASSERT(handle);
    auto* values = reinterpret_cast<const WTF::Vector<JSC::JSValue>*>(handle);
    RELEASE_ASSERT(index < values->size());
    return (*values)[index];
}

#if defined(BUN_BINDGEN_SHARD) && BUN_BINDGEN_SHARD == 0
extern "C" const BindJSValueHandle* bun_bindgen_root_borrow(const BindRootHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    return reinterpret_cast<const BindJSValueHandle*>(reinterpret_cast<const Bun::StrongRefStorage*>(handle)->slot());
}

extern "C" BindGlobalObjectHandle* bun_bindgen_root_global(const BindRootHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    return reinterpret_cast<BindGlobalObjectHandle*>(reinterpret_cast<const Bun::StrongRefStorage*>(handle)->globalObject());
}

extern "C" void bun_bindgen_js_value_read(const BindJSValueHandle* handle, BindEncodedJSValue* outValue) noexcept
{
    RELEASE_ASSERT(outValue);
    *outValue = static_cast<BindEncodedJSValue>(JSC::JSValue::encode(readBindingJSValue(handle)));
}

extern "C" void bun_bindgen_js_value_slice_read(const BindJSValueSliceHandle* handle, size_t index, BindEncodedJSValue* outValue) noexcept
{
    RELEASE_ASSERT(outValue);
    *outValue = static_cast<BindEncodedJSValue>(JSC::JSValue::encode(readBindingJSValueSlice(handle, index)));
}

extern "C" const BindJSValueHandle* bun_bindgen_js_value_slice_at(const BindJSValueSliceHandle* handle, size_t index) noexcept
{
    RELEASE_ASSERT(handle);
    auto* values = reinterpret_cast<const WTF::Vector<JSC::JSValue>*>(handle);
    RELEASE_ASSERT(index < values->size());
    return reinterpret_cast<const BindJSValueHandle*>(&(*values)[index]);
}

extern "C" const uint8_t* bun_bindgen_byte_lease_data(const BindByteLeaseHandle* handle, size_t* length) noexcept
{
    RELEASE_ASSERT(handle);
    RELEASE_ASSERT(length);
    auto span = reinterpret_cast<const BindingByteLease*>(handle)->leasedSpan();
    *length = span.size();
    return span.data();
}

extern "C" uint8_t* bun_bindgen_byte_lease_mutable_data(BindByteLeaseHandle* handle, size_t* length) noexcept
{
    RELEASE_ASSERT(handle);
    RELEASE_ASSERT(length);
    auto span = reinterpret_cast<BindingByteLease*>(handle)->mutableLeasedSpan();
    *length = span.size();
    return span.data();
}

extern "C" void bun_bindgen_byte_lease_source(const BindByteLeaseHandle* handle, BindEncodedJSValue* outValue) noexcept
{
    RELEASE_ASSERT(handle);
    RELEASE_ASSERT(outValue);
    *outValue = encodeBindingValue(reinterpret_cast<const BindingByteLease*>(handle)->source());
}

extern "C" size_t bun_bindgen_byte_lease_element_size(const BindByteLeaseHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    return reinterpret_cast<const BindingByteLease*>(handle)->elementSize();
}

extern "C" size_t bun_bindgen_byte_lease_prepared_length(const BindByteLeaseHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    return reinterpret_cast<const BindingByteLease*>(handle)->byteLength();
}

extern "C" BindByteLeaseHandle* bun_bindgen_byte_lease_clone(const BindByteLeaseHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    auto* lease = reinterpret_cast<const BindingByteLease*>(handle);
    lease->assertVMThread();
    return reinterpret_cast<BindByteLeaseHandle*>(lease->clone());
}

extern "C" void bun_bindgen_byte_lease_bind_view(BindByteLeaseHandle* handle, BindByteLeaseHandle** slot) noexcept
{
    RELEASE_ASSERT(handle);
    reinterpret_cast<BindingByteLease*>(handle)->bindView(slot);
}

extern "C" void bun_bindgen_byte_lease_move_view(BindByteLeaseHandle* handle, BindByteLeaseHandle** previous, BindByteLeaseHandle** next) noexcept
{
    RELEASE_ASSERT(handle);
    reinterpret_cast<BindingByteLease*>(handle)->moveView(previous, next);
}

extern "C" void bun_bindgen_byte_lease_unbind_view(BindByteLeaseHandle* handle, BindByteLeaseHandle** slot) noexcept
{
    RELEASE_ASSERT(handle);
    reinterpret_cast<BindingByteLease*>(handle)->unbindView(slot);
}

extern "C" BindStatus bun_bindgen_deferred_leases_acquire(BindGlobalObjectHandle* globalHandle, BindDeferredConversionsHandle* deferredHandle) noexcept
{
    RELEASE_ASSERT(globalHandle && deferredHandle);
    auto* global = reinterpret_cast<JSC::JSGlobalObject*>(globalHandle);
    auto& deferred = *reinterpret_cast<Bun::Bindgen::BindingDeferredConversions*>(deferredHandle);
    RELEASE_ASSERT(&deferred.globalObject() == global);
    return invokeBindingStatusEntry(global, [&]() -> BindStatus {
        return deferred.acquireFromWire() ? BIND_STATUS_OK : BIND_STATUS_PENDING_EXCEPTION;
    });
}

extern "C" void bun_bindgen_byte_lease_release(BindByteLeaseHandle* handle) noexcept
{
    RELEASE_ASSERT(handle);
    auto* lease = reinterpret_cast<BindingByteLease*>(handle);
    lease->assertVMThread();
    delete lease;
}

extern "C" BindStatus bun_bindgen_clone_write(BindCloneSerializerHandle* serializer, const uint8_t* ptr, uint32_t length) noexcept
{
    RELEASE_ASSERT(serializer);
    RELEASE_ASSERT(ptr || !length);
    return WebCore::SerializedScriptValue::writeBytesForBindgen(reinterpret_cast<WebCore::CloneSerializer*>(serializer), ptr, length)
        ? BIND_STATUS_OK
        : BIND_STATUS_OUT_OF_MEMORY;
}
#endif

static WTF::String decodeBindingString(const BindStringHandle* handle)
{
    if (!handle)
        return WTF::emptyString();
    return WTF::String(const_cast<WTF::StringImpl*>(reinterpret_cast<const WTF::StringImpl*>(handle)));
}

static Expected<WTF::String, WTF::UTF8ConversionError> decodeBindingUTF8Bytes(const BindByteSlice& bytes)
{
    return Bun::decodeUTF8ReplacingInvalidSequences(decodeBindingSlice(bytes));
}

static JSC::JSObject* createBindingSystemError(
    JSC::JSGlobalObject* global,
    int32_t errorNumber,
    const WTF::String& code,
    const WTF::String& message,
    const WTF::String& path,
    const WTF::String& syscall,
    const WTF::String& hostname,
    int32_t fd,
    const WTF::String& dest,
    const WTF::String& address,
    std::optional<uint16_t> port,
    const JSC::Identifier& addressKey,
    const JSC::Identifier& portKey,
    unsigned attributes)
{
    auto& vm = JSC::getVM(global);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto& names = WebCore::builtinNames(vm);
    auto* clientData = WebCore::clientData(vm);
    auto* result = createBindingError(global, JSC::ErrorType::Error, message);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!code.isEmpty())
        result->putDirect(vm, clientData->builtinNames().codePublicName(), JSC::jsString(vm, code), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!path.isEmpty())
        result->putDirect(vm, clientData->builtinNames().pathPublicName(), JSC::jsString(vm, path), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!dest.isEmpty())
        result->putDirect(vm, clientData->builtinNames().destPublicName(), JSC::jsString(vm, dest), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (fd >= 0)
        result->putDirect(vm, names.fdPublicName(), JSC::jsNumber(fd), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!syscall.isEmpty())
        result->putDirect(vm, names.syscallPublicName(), JSC::jsString(vm, syscall), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!hostname.isEmpty())
        result->putDirect(vm, names.hostnamePublicName(), JSC::jsString(vm, hostname), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (!address.isEmpty())
        result->putDirect(vm, addressKey, JSC::jsString(vm, address));
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    if (port)
        result->putDirect(vm, portKey, JSC::jsNumber(*port));
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    result->putDirect(vm, names.errnoPublicName(), JSC::jsNumber(errorNumber), attributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    return result;
}

static JSC::JSObject* createBindingSystemErrorWithInfoObject(
    JSC::JSGlobalObject* global,
    int32_t errorNumber,
    const WTF::String& code,
    const WTF::String& message,
    const WTF::String& syscall,
    const JSC::Identifier& infoKey)
{
    auto& vm = JSC::getVM(global);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* clientData = WebCore::clientData(vm);
    auto decoratedMessage = WTF::tryMakeString("A system error occurred: "_s, syscall, " returned "_s, code, " ("_s, message, ")"_s);
    if (decoratedMessage.isNull()) {
        Bun::Bindgen::throwBindingOutOfMemoryError(global, throwScope);
        return nullptr;
    }
    auto* result = createBindingError(global, JSC::ErrorType::Error, decoratedMessage);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    auto* info = JSC::constructEmptyObject(global, global->objectPrototype(), 0);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    constexpr unsigned hiddenAttributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum);
    constexpr unsigned fixedAttributes = static_cast<unsigned>(JSC::PropertyAttribute::DontDelete);
    result->putDirect(vm, vm.propertyNames->name, JSC::jsString(vm, WTF::String("SystemError"_s)), hiddenAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    result->putDirect(vm, clientData->builtinNames().codePublicName(), JSC::jsString(vm, WTF::String("ERR_SYSTEM_ERROR"_s)), hiddenAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    result->putDirect(vm, infoKey, info, fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    auto syscallValue = JSC::jsString(vm, syscall);
    result->putDirect(vm, clientData->builtinNames().syscallPublicName(), syscallValue, fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    info->putDirect(vm, clientData->builtinNames().syscallPublicName(), syscallValue, fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    info->putDirect(vm, clientData->builtinNames().codePublicName(), JSC::jsString(vm, code), fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    info->putDirect(vm, vm.propertyNames->message, JSC::jsString(vm, message), fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    info->putDirect(vm, clientData->builtinNames().errnoPublicName(), JSC::jsNumber(errorNumber), fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    result->putDirect(vm, clientData->builtinNames().errnoPublicName(), JSC::jsNumber(errorNumber), fixedAttributes);
    RETURN_IF_EXCEPTION(throwScope, nullptr);
    return result;
}

static WTF::String takeBindingString(BindStringHandle*& handle)
{
    if (!handle)
        return WTF::emptyString();
    auto* impl = reinterpret_cast<WTF::StringImpl*>(takeBindingHandle(handle));
    return WTF::String(WTF::adoptRef(*impl));
}

static RefPtr<JSC::ArrayBuffer> copyBindingBufferBacking(std::span<const uint8_t> bytes)
{
    if (bytes.empty())
        return JSC::ArrayBuffer::tryCreate(0, 1);
    return JSC::ArrayBuffer::tryCreate(bytes);
}

static RefPtr<JSC::ArrayBuffer> copyBindingBufferBacking(const BindByteSlice& bytes)
{
    return copyBindingBufferBacking(decodeBindingSlice(bytes));
}

static RefPtr<JSC::ArrayBuffer> takeBindingBufferBacking(BindByteSlice& bytes)
{
    assertCanonicalBindingSlice(bytes);
    auto transferred = std::exchange(bytes, {});
    auto [ptr, length, owner] = transferred;
    if (!length) {
        releaseBindingBytes(transferred);
        return JSC::ArrayBuffer::tryCreate(0, 1);
    }
    if (owner) {
        RELEASE_ASSERT(owner->externalBytes == ptr);
        RELEASE_ASSERT(owner->externalLength == length);
    }
    auto release = [transferred](void*) mutable {
        releaseBindingBytes(transferred);
    };
    using ReleaseTask = SharedTaskFunctor<void(void*), decltype(release)>;
    void* allocation;
    if (!WTF::tryFastMalloc(sizeof(ReleaseTask)).getValue(allocation)) {
        releaseBindingBytes(transferred);
        return nullptr;
    }
    auto* task = new (NotNull, allocation) ReleaseTask(WTF::move(release));
    return JSC::ArrayBuffer::tryCreateFromBytes({ ptr, length }, adoptRef(*task));
}

#if defined(BUN_BINDGEN_SHARD) && BUN_BINDGEN_SHARD == 0
RefPtr<JSC::ArrayBuffer> Bun::Bindgen::adoptByteOwner(BindByteOwnerHandle* owner)
{
    RELEASE_ASSERT(owner);
    BindByteSlice bytes { owner->externalLength ? owner->externalBytes : nullptr, owner->externalLength, owner };
    return takeBindingBufferBacking(bytes);
}
#endif

template<typename Buffer, bool nodeBuffer = false>
static Buffer* materializeBindingBuffer(JSC::JSGlobalObject* global, RefPtr<JSC::ArrayBuffer>&& backing)
{
    static_assert(!nodeBuffer || std::is_same_v<Buffer, JSC::JSUint8Array>);
    if (!backing)
        return nullptr;
    if constexpr (std::is_same_v<Buffer, JSC::JSArrayBuffer>)
        return Buffer::create(global->vm(), global->arrayBufferStructure(), WTF::move(backing));
    else {
        auto scope = DECLARE_THROW_SCOPE(global->vm());
        auto* structure = nodeBuffer
            ? defaultGlobalObject(global)->JSBufferSubclassStructure()
            : global->typedArrayStructure(Buffer::Adaptor::typeValue, false);
        RETURN_IF_EXCEPTION(scope, nullptr);
        // A byte payload can end with an incomplete element; retain those bytes in the backing buffer.
        size_t length = backing->byteLength() / Buffer::elementSize;
        RELEASE_AND_RETURN(scope, Buffer::create(global, structure, WTF::move(backing), 0, length));
    }
}

template<typename Buffer, bool nodeBuffer = false, typename Bytes>
static Buffer* copyBindingBuffer(JSC::JSGlobalObject* global, const Bytes& bytes)
{
    return materializeBindingBuffer<Buffer, nodeBuffer>(global, copyBindingBufferBacking(bytes));
}

template<typename Buffer, bool nodeBuffer = false>
static Buffer* takeBindingBuffer(JSC::JSGlobalObject* global, BindByteSlice& bytes)
{
    return materializeBindingBuffer<Buffer, nodeBuffer>(global, takeBindingBufferBacking(bytes));
}


static bool encodeBindingBytes(const BindingBufferSource& source, BindByteSlice& out)
{
    out = { nullptr, 0, nullptr };
    size_t length = source.byteLength();
    if (!length)
        return true;
    auto* bytes = bun_bindgen_transfer_alloc(length);
    if (!bytes)
        return false;
    copyBindingBufferBytes({ bytes, length }, source.data(), source.isShared());
    out = { bytes, length, nullptr };
    return true;
}

static bool encodeBindingString(const WTF::String& value, bool isolate, BindStringHandle*& out)
{
    out = nullptr;
    auto* impl = value.impl();
    if (!impl)
        return true;
    if (!isolate) {
        impl->ref();
        out = reinterpret_cast<BindStringHandle*>(impl);
        return true;
    }
    if (!value.length())
        return true;

    BindStringHandle* isolated = nullptr;
    uint8_t* bytes = nullptr;
    auto status = bun_bindgen_string_create_uninitialized(
        value.length(), value.is8Bit() ? BIND_STRING_LATIN1 : BIND_STRING_UTF16,
        &isolated, &bytes);
    if (status == BIND_STATUS_OUT_OF_MEMORY)
        return false;
    RELEASE_ASSERT(status == BIND_STATUS_OK);
    if (value.is8Bit())
        memcpy(bytes, value.span8().data(), value.span8().size_bytes());
    else
        memcpy(bytes, value.span16().data(), value.span16().size_bytes());
    out = isolated;
    return true;
}
