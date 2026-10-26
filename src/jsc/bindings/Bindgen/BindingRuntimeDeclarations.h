#pragma once

#include "Any.h"
#include "NativeResult.h"
#include "BindingStringLiteral.h"
#include "ErrorBindings.h"
#include <JavaScriptCore/ThrowScope.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <JavaScriptCore/Heap.h>
#include <JavaScriptCore/JSObject.h>
#include <wtf/CheckedArithmetic.h>
#include <wtf/RefCounted.h>
#include <wtf/text/StringView.h>
#include <wtf/unicode/UTF8Conversion.h>
#include <cstring>
#include <limits>
#include <memory>
#include <utility>
#include <span>

struct BindingByteCopyHandle;

inline JSC::JSValue borrowBindingValue(const BindJSValueHandle* handle)
{
    RELEASE_ASSERT_WITH_MESSAGE(handle, "binding wire value handle is null");
    auto value = *reinterpret_cast<const JSC::JSValue*>(handle);
    RELEASE_ASSERT_WITH_MESSAGE(!value.isEmpty(), "binding wire value is empty");
    return value;
}

inline const BindJSValueHandle* bindingValueHandle(const JSC::JSValue& value)
{
    RELEASE_ASSERT_WITH_MESSAGE(!value.isEmpty(), "binding wire value is empty");
    return reinterpret_cast<const BindJSValueHandle*>(&value);
}

const BindJSValueHandle* bindingValueHandle(JSC::JSValue&&) = delete;

inline JSC::JSValue decodeBindingValue(BindEncodedJSValue encoded)
{
    auto value = JSC::JSValue::decode(static_cast<JSC::EncodedJSValue>(encoded));
    RELEASE_ASSERT_WITH_MESSAGE(!value.isEmpty(), "binding wire value is empty");
    return value;
}

inline BindEncodedJSValue encodeBindingValue(JSC::JSValue value)
{
    RELEASE_ASSERT_WITH_MESSAGE(!value.isEmpty(), "binding wire value is empty");
    return static_cast<BindEncodedJSValue>(JSC::JSValue::encode(value));
}

inline bool decodeBindingBoolean(uint8_t value)
{
    RELEASE_ASSERT_WITH_MESSAGE(value <= 1, "binding wire boolean is out of range");
    return value;
}

inline bool decodeBindingPresence(uint8_t present)
{
    RELEASE_ASSERT_WITH_MESSAGE(present <= 1, "binding wire presence byte is out of range");
    return present;
}

inline bool decodeBindingDiscarded(uint8_t value)
{
    RELEASE_ASSERT_WITH_MESSAGE(!value, "binding wire discarded value is not zero");
    return false;
}

template<typename Handle>
Handle* requireBindingHandle(Handle* handle)
{
    RELEASE_ASSERT_WITH_MESSAGE(handle, "binding wire handle is null");
    return handle;
}

template<typename Slice>
void assertCanonicalBindingSlice(const Slice& slice)
{
    RELEASE_ASSERT_WITH_MESSAGE((slice.ptr != nullptr) == (slice.len != 0), "binding wire slice is not canonical");
    RELEASE_ASSERT(slice.len <= std::numeric_limits<size_t>::max() / sizeof(*slice.ptr));
}

template<typename Slice>
auto decodeBindingSlice(const Slice& slice)
{
    assertCanonicalBindingSlice(slice);
    return std::span { slice.ptr, slice.len };
}

template<typename Span, typename Slice>
void encodeBindingSlice(const Span& span, Slice& slice)
{
    RELEASE_ASSERT_WITH_MESSAGE(span.data() || span.empty(), "binding slice source has no data");
    slice = Slice { span.empty() ? nullptr : span.data(), span.size() };
    assertCanonicalBindingSlice(slice);
}

inline void releaseBindingBytes(BindByteSlice& bytes)
{
    auto pending = std::exchange(bytes, {});
    if (pending.owner)
        bun_bindgen_byte_owner_release(pending.owner);
    else
        bun_bindgen_transfer_free(pending.ptr, pending.len);
}

inline bool encodeBindingBytes(std::span<const uint8_t> source, BindByteSlice& out)
{
    out = {};
    if (source.empty())
        return true;
    auto* bytes = bun_bindgen_transfer_alloc(source.size());
    if (!bytes)
        return false;
    memcpy(bytes, source.data(), source.size());
    out = { bytes, source.size(), nullptr };
    return true;
}


namespace Bun::Bindgen {
struct NativeCellIdentityKey {
    uint64_t realmGeneration { 0 };
    uint64_t nativeGeneration { 0 };
};
}

namespace Bun {
struct BindgenWrapperLink {
    BindgenWrapperLink* previous { nullptr };
    BindgenWrapperLink* next { nullptr };
    void* wrapper { nullptr };
    void (*detach)(void*) { nullptr };
};

class BindgenWrapperRegistry final {
public:
    explicit BindgenWrapperRegistry(JSC::VM&);
    ~BindgenWrapperRegistry();
    uint64_t ensureRealm(JSC::JSGlobalObject*);
    JSC::JSObject* get(Bindgen::NativeCellIdentityKey identity) const;
    void set(Bindgen::NativeCellIdentityKey identity, JSC::JSObject*);
    void remove(Bindgen::NativeCellIdentityKey identity, JSC::JSObject*);
    void add(BindgenWrapperLink*, void* wrapper, void (*detach)(void*));
    void remove(BindgenWrapperLink*);
    void detachAll();

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

}

namespace Bun::Bindgen {

class PlainClassPrototype : public JSC::JSNonFinalObject {
public:
    using Base = JSC::JSNonFinalObject;
    DECLARE_INFO;

protected:
    PlainClassPrototype(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }
};

JSC::TypeCountSet heapObjectTypeCounts(JSC::VM&, bool protectedOnly);

inline JSC::JSValue invokePropertyInitializer(JSC::VM& vm, JSC::JSObject* object, JSC::JSValue (*initialize)(JSC::VM&, JSC::JSObject*))
{
    // Static-property lookup has no exception-checking caller for a native initializer.
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    auto value = initialize(vm, object);
    RETURN_IF_EXCEPTION(scope, {});
    return value;
}

namespace Detail {
struct CppAnyAccess;
struct CppArgumentAccess;
struct CppNativeResultAccess;
}

class CppBytes final {
public:
    CppBytes() = default;
    CppBytes(WTF::Vector<uint8_t>&& bytes)
        : m_vector(WTF::move(bytes))
    {
    }
    CppBytes(const CppBytes&) = delete;
    CppBytes& operator=(const CppBytes&) = delete;
    CppBytes(CppBytes&& other) noexcept
        : m_bytes(std::exchange(other.m_bytes, {}))
        , m_vector(WTF::move(other.m_vector))
    {
    }
    CppBytes& operator=(CppBytes&& other) noexcept
    {
        if (this != &other) {
            reset();
            m_bytes = std::exchange(other.m_bytes, {});
            m_vector = WTF::move(other.m_vector);
        }
        return *this;
    }
    ~CppBytes() { reset(); }

    bool tryAllocate(size_t length, std::span<uint8_t>& storage)
    {
        storage = {};
        if (!tryAllocate(length))
            return false;
        storage = { m_bytes.ptr, m_bytes.len };
        return true;
    }

    bool tryCopy(std::span<const uint8_t> bytes)
    {
        if (!tryAllocate(bytes.size()))
            return false;
        if (!bytes.empty())
            memcpy(m_bytes.ptr, bytes.data(), bytes.size());
        return true;
    }
    bool tryEncodeUTF8(WTF::StringView text)
    {
        if (!text.length())
            return tryAllocate(0);
        if (text.is8Bit() && text.containsOnlyASCII()) {
            auto characters = text.span8();
            return tryCopy({ reinterpret_cast<const uint8_t*>(characters.data()), characters.size() });
        }
        if (WTF::productOverflows<size_t>(text.length(), 3))
            return false;
        size_t length = 0;
        // Unpaired surrogates need three replacement bytes when sizing the allocation.
        for (auto codePoint : text.codePoints())
            length += codePoint < 0x80 ? 1 : codePoint < 0x800 ? 2
                : codePoint < 0x10000                          ? 3
                                                               : 4;
        if (!tryAllocate(length))
            return false;
        std::span<char8_t> output { reinterpret_cast<char8_t*>(m_bytes.ptr), m_bytes.len };
        auto converted = text.is8Bit()
            ? WTF::Unicode::convert(text.span8(), output)
            : WTF::Unicode::convertReplacingInvalidSequences(text.span16(), output);
        RELEASE_ASSERT(converted.code == WTF::Unicode::ConversionResultCode::Success && converted.buffer.size() == length);
        return true;
    }
    std::span<const uint8_t> span() const { return m_bytes.ptr ? std::span<const uint8_t> { m_bytes.ptr, m_bytes.len } : m_vector.span(); }
    const uint8_t* data() const { return span().data(); }
    size_t size() const { return span().size(); }
    bool isEmpty() const { return !size(); }

private:
    friend struct Detail::CppNativeResultAccess;
    bool tryAllocate(size_t length)
    {
        RELEASE_ASSERT(!m_bytes.ptr && !m_bytes.owner && m_vector.isEmpty());
        if (!length)
            return true;
        auto* bytes = bun_bindgen_transfer_alloc(length);
        if (!bytes)
            return false;
        m_bytes = { bytes, length, nullptr };
        return true;
    }
    void reset()
    {
        releaseBindingBytes(m_bytes);
    }
    BindByteSlice m_bytes {};
    WTF::Vector<uint8_t> m_vector;
};

using BindingNativeWrap = BindStatus (*)(BindGlobalObjectHandle*, BindNativeHandle*, BindEncodedJSValue*) noexcept;
JSC::JSValue bindingClassWrapValue(JSC::JSGlobalObject*, BindNativeHandle*, BindingNativeWrap);

inline bool bindingExceptionAfterDispatch(JSC::ExceptionScope& scope, BindStatus status)
{
    RELEASE_ASSERT_WITH_MESSAGE(status <= BIND_STATUS_FAILED, "binding dispatch returned an unknown status");
    auto& vm = scope.vm();
    EXCEPTION_ASSERT(!!scope.exception() == vm.traps().needHandling(JSC::VMTraps::NeedExceptionHandling));
    vm.hasExceptionsAfterHandlingTraps();
    if (auto* exception = scope.exception()) {
        RELEASE_ASSERT_WITH_MESSAGE(status == BIND_STATUS_PENDING_EXCEPTION || vm.isTerminationException(exception), "binding dispatch returned a non-exception status with an ordinary pending exception");
        return true;
    }
    RELEASE_ASSERT_WITH_MESSAGE(status != BIND_STATUS_PENDING_EXCEPTION, "binding dispatch returned pending-exception status without an exception");
    return false;
}

inline bool bindingExceptionAfterNonThrowingDispatch(JSC::ExceptionScope& scope, BindStatus status)
{
    const bool pending = bindingExceptionAfterDispatch(scope, status);
    RELEASE_ASSERT_WITH_MESSAGE(!pending || scope.vm().hasPendingTerminationException(), "non-throwing native export raised an ordinary exception");
    return pending;
}

template<typename Scope>
bool materializeBindingException(Scope& scope)
{
    EXCEPTION_ASSERT(!!scope.exception() == scope.vm().traps().needHandling(JSC::VMTraps::NeedExceptionHandling));
    scope.vm().hasExceptionsAfterHandlingTraps();
    return scope.exception();
}

template<typename Function>
BindStatus invokeBindingStatusEntry(JSC::JSGlobalObject* global, Function&& function)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(global->vm());
    const auto status = function();
    const bool hasException = scope.exception();
    RELEASE_ASSERT_WITH_MESSAGE(hasException == (status == BIND_STATUS_PENDING_EXCEPTION), "binding status does not match its exception state");
    return status;
}

inline void finishBindingVoidCall(JSC::JSGlobalObject* global, BindStatus status)
{
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(global));
    if (bindingExceptionAfterDispatch(scope, status))
        return;
    if (status == BIND_STATUS_OUT_OF_MEMORY) {
        throwBindingOutOfMemoryError(global, scope);
        return;
    }
    RELEASE_ASSERT_WITH_MESSAGE(status == BIND_STATUS_OK, "void binding returned a domain failure");
}

inline uint64_t takeBindingCallId()
{
    return bun_bindgen_take_call_id();
}

class BindingDeferredState {
public:
    bool pending() const { return m_phase == Phase::pending; }
    bool succeeded() const { return m_phase == Phase::completed && m_status == BIND_STATUS_OK; }
    bool discarded() const { return m_phase == Phase::discarded; }

    void discard()
    {
        RELEASE_ASSERT(pending());
        m_phase = Phase::discarded;
    }

    template<typename Convert>
    BindStatus force(JSC::JSGlobalObject& global, Convert&& convert)
    {
        RELEASE_ASSERT_WITH_MESSAGE(!discarded(), "discarded deferred value cannot be converted");
        auto& vm = global.vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (m_phase == Phase::completed) {
            if (m_status == BIND_STATUS_PENDING_EXCEPTION && !scope.exception())
                scope.throwException(&global, m_exception.get());
            return bindingExceptionAfterDispatch(scope, m_status) ? BIND_STATUS_PENDING_EXCEPTION : m_status;
        }
        RELEASE_ASSERT_WITH_MESSAGE(pending(), "recursive deferred conversion");
        m_phase = Phase::forcing;
        auto status = convert();
        if (bindingExceptionAfterDispatch(scope, status)) {
            m_exception.set(vm, scope.exception());
            status = BIND_STATUS_PENDING_EXCEPTION;
        }
        RELEASE_ASSERT(status == BIND_STATUS_OK || status == BIND_STATUS_PENDING_EXCEPTION || status == BIND_STATUS_OUT_OF_MEMORY);
        m_status = status;
        m_phase = Phase::completed;
        return status;
    }

private:
    JSC::Strong<JSC::Exception> m_exception;
    enum class Phase : uint8_t { pending, forcing, discarded, completed };
    Phase m_phase { Phase::pending };
    BindStatus m_status { BIND_STATUS_OK };
};

template<BindingFixedString... Parts>
consteval auto concatenateBindingStrings()
{
    constexpr size_t length = (Parts.length + ... + 0) + 1;
    BindingFixedString<length> result;
    size_t offset = 0;
    auto append = [&](auto part) {
        for (size_t index = 0; index < part.length; ++index)
            result.value[offset++] = part.value[index];
    };
    (append(Parts), ...);
    result.value[offset] = '\0';
    return result;
}

template<BindingFixedString... Parts>
inline constexpr auto bindingPathCharacters = concatenateBindingStrings<Parts...>();

template<BindingFixedString... Parts>
constexpr WTF::ASCIILiteral bindingPath()
{
    return WTF::ASCIILiteral::fromLiteralUnsafe(bindingPathCharacters<Parts...>.value);
}

struct BindingConversionPaths {};

class BindingDeferredConversions;

class CppDeferredLeaseProof final {
public:
    CppDeferredLeaseProof() = default;
    explicit operator bool() const { return m_state; }
    bool belongsTo(const BindingDeferredConversions* state) const { return m_state == state; }

private:
    BindingDeferredConversions* m_state { nullptr };
    friend class BindingDeferredConversions;
};

class BindingDeferredConversions final {
public:
    struct Lease {
        void* value;
        bool (*validate)(const void*);
        void (*acquire)(void*);
        BindingByteCopyHandle* (*copy)(void*);
    };

    explicit BindingDeferredConversions(JSC::JSGlobalObject&);
    void addDeferred()
    {
        RELEASE_ASSERT(!m_acquired);
        ++m_remaining;
        RELEASE_ASSERT(m_remaining);
    }
    bool addLease(Lease);
    void removeLease(void*);
    bool seal();
    void complete(bool last, CppDeferredLeaseProof* proof)
    {
        RELEASE_ASSERT(m_sealed && m_remaining && !m_acquired);
        if (last) {
            RELEASE_ASSERT(proof && !proof->m_state);
            RELEASE_ASSERT_WITH_MESSAGE(m_remaining == 1, "last deferred conversion forced before earlier conversions were resolved");
            m_remaining = 0;
            proof->m_state = this;
            return;
        }
        RELEASE_ASSERT_WITH_MESSAGE(m_remaining > 1, "the last deferred conversion must yield a lease proof");
        --m_remaining;
    }
    void completeAndMaybeYieldProof(CppDeferredLeaseProof& proof)
    {
        RELEASE_ASSERT(!proof.m_state);
        complete(m_remaining == 1, &proof);
    }
    bool acquire(const CppDeferredLeaseProof&);
    bool acquireFromWire();
    JSC::JSGlobalObject& globalObject() const { return m_global; }

private:
    JSC::JSGlobalObject& m_global;
    WTF::Vector<Lease, 4> m_leases;
    size_t m_remaining { 0 };
    bool m_sealed { false };
    bool m_acquired { false };
};

WTF::Vector<uint8_t> convertNodePath(JSC::JSGlobalObject&, JSC::JSValue, WTF::ASCIILiteral, bool fileURLStrings, bool boxedStrings);
RefPtr<JSC::ArrayBuffer> adoptByteOwner(BindByteOwnerHandle*);

class ByteOwner final {
    struct Release {
        void operator()(BindByteOwnerHandle* owner) const { bun_bindgen_byte_owner_release(owner); }
    };

public:
    explicit ByteOwner(BindByteOwnerHandle* owner)
        : m_owner(owner)
    {
        RELEASE_ASSERT(m_owner);
    }
    ByteOwner(const ByteOwner&) = delete;
    ByteOwner& operator=(const ByteOwner&) = delete;
    ByteOwner(ByteOwner&&) = delete;
    ByteOwner& operator=(ByteOwner&&) = delete;

    std::span<const uint8_t> bytes() const
    {
        RELEASE_ASSERT(m_owner);
        BindConstByteSlice result {};
        bun_bindgen_byte_owner_view(m_owner.get(), &result);
        return decodeBindingSlice(result);
    }
    BindByteOwnerHandle* release()
    {
        RELEASE_ASSERT(m_owner);
        return m_owner.release();
    }

private:
    std::unique_ptr<BindByteOwnerHandle, Release> m_owner;
};

class CppAnySequenceView;

class CppResultContext final {
public:
    explicit CppResultContext(JSC::JSGlobalObject& global)
        : m_global(global)
    {
    }

    bool tryProtect(JSC::JSValue value)
    {
        if (m_failed)
            return false;
        m_roots.append(value);
        m_failed = m_roots.hasOverflowed();
        return !m_failed;
    }

    bool protect(JSC::JSValue value)
    {
        if (m_failed)
            return false;
        return tryProtect(value) || outOfMemory();
    }

    bool outOfMemory()
    {
        m_failed = true;
        auto& vm = m_global.vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        vm.hasExceptionsAfterHandlingTraps();
        RETURN_IF_EXCEPTION(scope, false);
        Bun::Bindgen::throwBindingOutOfMemoryError(&m_global, scope);
        return false;
    }

private:
    JSC::JSGlobalObject& m_global;
    JSC::MarkedArgumentBuffer m_roots;
    bool m_failed { false };
};

class CppTransferredRoots final {
public:
    bool tryAdopt(Bun::StrongRef root)
    {
        if (!m_roots) {
            void* allocation;
            if (!WTF::tryFastMalloc(sizeof(Storage)).getValue(allocation))
                return false;
            m_roots = adoptRef(*new (NotNull, allocation) Storage);
        }
        return m_roots->values.tryAppend(WTF::move(root));
    }

private:
    struct Storage final : public WTF::RefCounted<Storage> {
        WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Storage);

    public:
        WTF::Vector<Bun::StrongRef> values;
    };
    RefPtr<Storage> m_roots;
};

inline bool CppAny::protectResult(CppResultContext& context) const
{
    RELEASE_ASSERT(!m_value.isEmpty());
    return context.protect(m_value);
}

inline void CppAny::defineOwnDataProperty(JSC::VM& vm, JSC::JSObject& object, JSC::PropertyName name, unsigned attributes) const
{
    RELEASE_ASSERT(!m_value.isEmpty());
    object.putDirect(vm, name, m_value, attributes);
}

inline void CppAny::storeIn(JSC::VM& vm, JSC::JSCell& owner, JSC::WriteBarrier<JSC::Unknown>& slot) const
{
    RELEASE_ASSERT(!m_value.isEmpty());
    slot.set(vm, &owner, m_value);
}

class CppAnySequenceView final {
public:
    class Iterator final {
    public:
        CppAny operator*() const { return CppAnySequenceView::wrap(*m_cursor); }
        Iterator& operator++()
        {
            ++m_cursor;
            return *this;
        }
        bool operator==(const Iterator&) const = default;

    private:
        explicit Iterator(const JSC::JSValue* cursor)
            : m_cursor(cursor)
        {
        }
        const JSC::JSValue* m_cursor { nullptr };
        friend class CppAnySequenceView;
    };

    CppAnySequenceView() = default;
    size_t size() const { return m_values.size(); }
    bool empty() const { return m_values.empty(); }
    CppAny operator[](size_t index) const { return wrap(m_values[index]); }
    Iterator begin() const { return Iterator(m_values.data()); }
    Iterator end() const { return Iterator(m_values.empty() ? m_values.data() : m_values.data() + m_values.size()); }

private:
    explicit CppAnySequenceView(std::span<const JSC::JSValue> values)
        : m_values(values)
    {
    }
    static CppAny wrap(JSC::JSValue value) { return CppAny(value); }
    std::span<const JSC::JSValue> m_values;
    friend struct Detail::CppAnyAccess;
};

inline bool protectCppResult(CppResultContext& context, JSC::JSValue value)
{
    return context.protect(value);
}

template<typename T>
    requires requires(const T& value, CppResultContext& context) { value.protectResult(context); }
inline bool protectCppResult(CppResultContext& context, const T& value)
{
    return value.protectResult(context);
}

template<typename T>
inline bool protectCppResult(CppResultContext& context, const std::optional<T>& value)
{
    return !value || protectCppResult(context, *value);
}

template<typename T>
inline bool protectCppResult(CppResultContext& context, const std::pair<WTF::String, T>& entry)
{
    return protectCppResult(context, entry.second);
}

template<typename T>
class CppResultSequence final {
public:
    bool tryReserveCapacity(size_t capacity) { return m_values.tryReserveCapacity(capacity); }
    bool reserveCapacity(CppResultContext& context, size_t capacity) { return tryReserveCapacity(capacity) || context.outOfMemory(); }
    bool append(CppResultContext& context, T value)
    {
        if (!protectCppResult(context, value))
            return false;
        return m_values.tryAppend(std::move(value)) || context.outOfMemory();
    }
    bool tryAdoptRoot(Bun::StrongRef root) { return m_bindingRoots.tryAdopt(WTF::move(root)); }
    size_t size() const { return m_values.size(); }
    const T& operator[](size_t index) const { return m_values[index]; }
    bool protectResult(CppResultContext&) const { return true; }

private:
    void appendAdopted(T value)
    {
        RELEASE_ASSERT(m_values.size() < m_values.capacity());
        m_values.unsafeAppendWithoutCapacityCheck(std::move(value));
    }
    WTF::Vector<T> m_values;
    CppTransferredRoots m_bindingRoots;
    friend struct Detail::CppNativeResultAccess;
};

struct CppContext {
    JSC::JSGlobalObject& globalObject;
    CppResultContext* resultContext;
    BindingDeferredConversions* deferredConversions;

    CppResultContext& results() const
    {
        RELEASE_ASSERT(resultContext);
        return *resultContext;
    }
    bool lease(const CppDeferredLeaseProof& proof) const
    {
        RELEASE_ASSERT(deferredConversions && proof.belongsTo(deferredConversions));
        return bun_bindgen_deferred_leases_acquire(reinterpret_cast<BindGlobalObjectHandle*>(&globalObject), reinterpret_cast<BindDeferredConversionsHandle*>(deferredConversions)) == BIND_STATUS_OK;
    }
};

struct CppCallContext : CppContext {
    BindNativeHandle* nativeReceiver;
    std::optional<JSC::SourceOrigin> callerSourceOrigin;
};

template<typename Wrapper>
struct CppEngineCallContext : CppContext {
    Wrapper& wrapper;
    typename Wrapper::DOMWrapped& wrapped() const { return wrapper.wrapped(); }
};

template<typename Wrapper>
struct CppEngineConstructContext : CppContext {
    JSC::Structure* structure;
};

struct CppPlainConstructContext : CppContext {
    JSC::Structure* structure;
    JSC::JSObject* (*allocateObject)(JSC::JSGlobalObject*, JSC::Structure*);
    JSC::JSObject* createObject() const
    {
        return allocateObject(&globalObject, structure);
    }
};

class CppDictionarySource final {
public:
    CppDictionarySource() = default;
    CppDictionarySource(JSC::JSGlobalObject& global, JSC::JSValue value)
        : m_value(global.vm(), value)
    {
    }

    void appendTo(JSC::MarkedArgumentBuffer& arguments) const
    {
        RELEASE_ASSERT(m_value);
        arguments.append(m_value.get());
    }

    JSC::JSObject* object() const
    {
        RELEASE_ASSERT(m_value);
        auto* object = m_value.get().getObject();
        RELEASE_ASSERT(object);
        return object;
    }

private:
    JSC::Strong<JSC::Unknown> m_value;
    friend struct Detail::CppArgumentAccess;
};

class CppLazyPropertyStorage {
public:
    CppLazyPropertyStorage() = default;
    CppLazyPropertyStorage(const CppLazyPropertyStorage&) = delete;
    CppLazyPropertyStorage& operator=(const CppLazyPropertyStorage&) = delete;
    CppLazyPropertyStorage(CppLazyPropertyStorage&&) noexcept = default;
    CppLazyPropertyStorage& operator=(CppLazyPropertyStorage&&) noexcept = default;

    template<typename Storage>
    Storage* create() noexcept
    {
        RELEASE_ASSERT(!m_storage);
        auto* storage = new (std::nothrow) Storage;
        if (!storage)
            return nullptr;
        m_storage = { storage, +[](void* value) noexcept { delete static_cast<Storage*>(value); } };
        m_copyWire = +[](const void* value, void* output) noexcept {
            using Wire = typename Storage::Wire;
            static_assert(std::is_trivially_copyable_v<Wire> && std::is_standard_layout_v<Wire>);
            *static_cast<Wire*>(output) = static_cast<const Storage*>(value)->wireValue;
        };
        return storage;
    }

    void copyWire(void* output) const
    {
        RELEASE_ASSERT(m_storage && m_copyWire && output);
        m_copyWire(m_storage.get(), output);
    }

private:
    std::unique_ptr<void, void (*)(void*) noexcept> m_storage { nullptr, nullptr };
    void (*m_copyWire)(const void*, void*) noexcept { nullptr };
};

template<typename T> class CppLazyArgument;

namespace Detail {

class CppLazyArgumentStateBase {
public:
    void requireContext(JSC::JSGlobalObject* global, BindingDeferredConversions* deferred) const
    {
        RELEASE_ASSERT(m_global == global && m_deferred == deferred);
    }
    void requireWireKey(uint64_t key) const
    {
        RELEASE_ASSERT(key && m_wireKey == key);
    }

protected:
    CppLazyArgumentStateBase(JSC::JSGlobalObject& global, BindingDeferredConversions* deferred, uint64_t key)
        : m_global(&global)
        , m_deferred(deferred)
        , m_wireKey(key)
    {
        RELEASE_ASSERT(key);
        if (m_deferred)
            m_deferred->addDeferred();
    }
    ~CppLazyArgumentStateBase() = default;
    JSC::JSGlobalObject* m_global;
    BindingDeferredConversions* m_deferred;
    uint64_t m_wireKey;
};

template<typename T>
class CppLazyArgumentState : public CppLazyArgumentStateBase {
public:
    using PropertyReader = bool (*)(JSC::JSGlobalObject&, JSC::JSObject*, JSC::JSValue&) noexcept;
    using PropertyConverter = bool (*)(const BindingConversionPaths*, JSC::JSGlobalObject&, JSC::JSValue, JSC::JSValue, T&, CppLazyPropertyStorage&, BindingDeferredConversions*) noexcept;

    template<typename Converter>
    CppLazyArgumentState(JSC::JSGlobalObject& global, Converter& converter, BindingDeferredConversions* deferred, uint64_t key)
        : CppLazyArgumentStateBase(global, deferred, key)
        , m_context(&converter)
        , m_convert([](void* context) noexcept -> T const* {
            return (*static_cast<Converter*>(context))();
        })
    {
        if constexpr (requires(const Converter& value, void* output) { value.copyWire(output); }) {
            m_copyWire = +[](const CppLazyArgumentState& state, void* output) noexcept {
                static_cast<const Converter*>(state.m_context)->copyWire(output);
            };
        }
    }

    CppLazyArgumentState(JSC::JSGlobalObject& global, JSC::JSObject* object, uint64_t wireKey, const BindingConversionPaths* paths, PropertyReader reader, PropertyConverter converter, BindingDeferredConversions* deferred = nullptr, JSC::JSValue receiver = JSC::jsUndefined())
        : CppLazyArgumentState(global, wireKey, paths, converter, deferred, receiver)
    {
        RELEASE_ASSERT(object && reader);
        m_object.set(global.vm(), object);
        m_propertyRead = reader;
    }

    template<typename Source>
    CppLazyArgumentState(JSC::JSGlobalObject& global, const CppLazyArgumentState<Source>& source, uint64_t wireKey, const BindingConversionPaths* paths, PropertyConverter converter, BindingDeferredConversions* deferred = nullptr, JSC::JSValue receiver = JSC::jsUndefined())
        : CppLazyArgumentState(global, wireKey, paths, converter, deferred, receiver)
    {
        source.requireContext(&global, deferred);
        m_projectionContext = &source;
        m_projectionRead = +[](const void* context, JSC::JSValue& value) noexcept {
            return static_cast<const CppLazyArgumentState<Source>*>(context)->readPropertyInput(value);
        };
    }

    CppLazyArgumentState(JSC::JSGlobalObject& global, JSC::JSValue input, uint64_t wireKey, const BindingConversionPaths* paths, PropertyConverter converter, BindingDeferredConversions* deferred = nullptr, JSC::JSValue receiver = JSC::jsUndefined())
        : CppLazyArgumentState(global, wireKey, paths, converter, deferred, receiver)
    {
        m_propertyInput.set(global.vm(), input);
    }

    CppLazyArgumentState(JSC::JSGlobalObject& global, JSC::JSObject* object, uint32_t index, uint64_t wireKey, const BindingConversionPaths* paths, PropertyConverter converter, BindingDeferredConversions* deferred = nullptr, JSC::JSValue receiver = JSC::jsUndefined())
        : CppLazyArgumentState(global, wireKey, paths, converter, deferred, receiver)
    {
        RELEASE_ASSERT(object);
        m_object.set(global.vm(), object);
        m_propertyIndex = index;
        m_indexedProperty = true;
    }

    CppLazyArgumentState(const CppLazyArgumentState&) = delete;
    CppLazyArgumentState& operator=(const CppLazyArgumentState&) = delete;
    CppLazyArgumentState(CppLazyArgumentState&&) = delete;
    CppLazyArgumentState& operator=(CppLazyArgumentState&&) = delete;

    CppLazyArgument<T> view();

    template<typename Wire>
    void copyWire(uint64_t key, Wire& output) const
    {
        requireWireKey(key);
        RELEASE_ASSERT(m_copyWire);
        m_copyWire(*this, &output);
    }

    bool prefetch() const
    {
        RELEASE_ASSERT(!m_conversionState.discarded());
        if (!m_propertyRead && !m_projectionRead && !m_indexedProperty)
            return true;
        JSC::JSValue ignored;
        return readPropertyInput(ignored);
    }

    bool prefetchedIsUndefinedOrNull() const
    {
        auto value = prefetchedValue();
        return !value || value.isUndefinedOrNull();
    }

    bool prefetchedIsUndefined() const
    {
        auto value = prefetchedValue();
        return !value || value.isUndefined();
    }

    T const* convert() const
    {
        return convertImpl(CompletionMode::ordinary, nullptr);
    }

    T const* convertLast(CppDeferredLeaseProof& proof) const
    {
        return convertImpl(CompletionMode::last, &proof);
    }

    T const* convertAndMaybeYieldProof(CppDeferredLeaseProof& proof) const
    {
        return convertImpl(CompletionMode::opportunistic, &proof);
    }

    void discard() const
    {
        discardImpl(CompletionMode::ordinary, nullptr);
    }

    void discardLast(CppDeferredLeaseProof& proof) const
    {
        RELEASE_ASSERT(m_deferred);
        discardImpl(CompletionMode::last, &proof);
    }

    bool deferredPending() const
    {
        return m_deferred && !m_deferredCompleted;
    }

    void discardIfPending() const
    {
        if (deferredPending())
            discard();
    }

    void discardAndMaybeYieldProof(CppDeferredLeaseProof& proof) const
    {
        if (!deferredPending())
            return;
        discardImpl(CompletionMode::opportunistic, &proof);
    }

private:
    template<typename> friend class CppLazyArgumentState;

    JSC::JSValue prefetchedValue() const
    {
        RELEASE_ASSERT(m_propertyRead || m_projectionRead || m_indexedProperty);
        RELEASE_ASSERT(m_readState.succeeded());
        return m_propertyInput.get();
    }

    CppLazyArgumentState(JSC::JSGlobalObject& global, uint64_t wireKey, const BindingConversionPaths* paths, PropertyConverter converter, BindingDeferredConversions* deferred, JSC::JSValue receiver)
        : CppLazyArgumentStateBase(global, deferred, wireKey)
        , m_conversionPaths(paths)
        , m_propertyConvert(converter)
        , m_receiver(global.vm(), receiver)
    {
        RELEASE_ASSERT(converter);
        m_copyWire = +[](const CppLazyArgumentState& state, void* output) noexcept {
            state.m_propertyStorage.copyWire(output);
        };
    }

    bool readPropertyInput(JSC::JSValue& value) const
    {
        RELEASE_ASSERT(m_propertyRead || m_projectionRead || m_indexedProperty);
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(m_global->vm());
        auto status = m_readState.force(*m_global, [&] {
            JSC::JSValue input;
            bool read;
            if (m_indexedProperty) {
                input = m_object->get(m_global, m_propertyIndex);
                read = true;
            } else {
                read = m_projectionRead
                    ? m_projectionRead(m_projectionContext, input)
                    : m_propertyRead(*m_global, m_object.get(), input);
            }
            RETURN_IF_EXCEPTION(scope, BIND_STATUS_PENDING_EXCEPTION);
            RELEASE_ASSERT(read);
            m_propertyInput.set(m_global->vm(), input);
            return BIND_STATUS_OK;
        });
        RETURN_IF_EXCEPTION(scope, false);
        RELEASE_ASSERT(status == BIND_STATUS_OK);
        value = m_propertyInput.get();
        return true;
    }

    enum class CompletionMode { ordinary, last, opportunistic };

    void discardImpl(CompletionMode mode, CppDeferredLeaseProof* proof) const
    {
        RELEASE_ASSERT(!m_deferredCompleted && m_conversionState.pending());
        m_conversionState.discard();
        completeDeferred(mode, proof);
    }

    void completeDeferred(CompletionMode mode, CppDeferredLeaseProof* proof) const
    {
        RELEASE_ASSERT((mode == CompletionMode::ordinary) == !proof);
        if (!deferredPending())
            return;
        if (mode == CompletionMode::opportunistic)
            m_deferred->completeAndMaybeYieldProof(*proof);
        else
            m_deferred->complete(mode == CompletionMode::last, proof);
        m_deferredCompleted = true;
    }

    T const* convertImpl(CompletionMode mode, CppDeferredLeaseProof* proof) const
    {
        if (mode != CompletionMode::ordinary)
            RELEASE_ASSERT(m_deferred && !m_deferredCompleted);
        RELEASE_ASSERT(m_global);
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(m_global->vm());
        auto status = m_conversionState.force(*m_global, [&] {
            if (m_propertyConvert) {
                bool prefetched = prefetch();
                RETURN_IF_EXCEPTION(scope, BIND_STATUS_PENDING_EXCEPTION);
                RELEASE_ASSERT(prefetched);
                m_propertyValue.emplace();
                if (!m_propertyConvert(m_conversionPaths, *m_global, m_propertyInput.get(), m_receiver.get(), m_propertyValue.value(), m_propertyStorage, m_deferred)) {
                    m_propertyValue.reset();
                    return BIND_STATUS_PENDING_EXCEPTION;
                }
            } else {
                RELEASE_ASSERT(m_context && m_convert);
                m_converted = m_convert(m_context);
                if (!m_converted)
                    return BIND_STATUS_PENDING_EXCEPTION;
            }
            return BIND_STATUS_OK;
        });
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (status != BIND_STATUS_OK)
            return nullptr;
        completeDeferred(mode, proof);
        return m_propertyConvert ? &m_propertyValue.value() : m_converted;
    }

    void* m_context { nullptr };
    T const* (*m_convert)(void*) noexcept { nullptr };
    JSC::Strong<JSC::JSObject> m_object;
    const BindingConversionPaths* m_conversionPaths { nullptr };
    PropertyReader m_propertyRead { nullptr };
    PropertyConverter m_propertyConvert { nullptr };
    const void* m_projectionContext { nullptr };
    bool (*m_projectionRead)(const void*, JSC::JSValue&) noexcept { nullptr };
    uint32_t m_propertyIndex { 0 };
    bool m_indexedProperty { false };
    JSC::Strong<JSC::Unknown> m_receiver;
    void (*m_copyWire)(const CppLazyArgumentState&, void*) noexcept { nullptr };
    mutable JSC::Strong<JSC::Unknown> m_propertyInput;
    mutable CppLazyPropertyStorage m_propertyStorage;
    mutable std::optional<T> m_propertyValue;
    mutable BindingDeferredState m_readState;
    mutable BindingDeferredState m_conversionState;
    mutable T const* m_converted { nullptr };
    mutable bool m_deferredCompleted { false };
};

}

template<typename T>
class CppLazyArgument {
public:
    CppLazyArgument() = default;
    CppLazyArgument(const CppLazyArgument&) = delete;
    CppLazyArgument& operator=(const CppLazyArgument&) = delete;
    CppLazyArgument(CppLazyArgument&& other) noexcept
        : m_state(std::exchange(other.m_state, nullptr))
    {
    }
    CppLazyArgument& operator=(CppLazyArgument&& other) noexcept
    {
        m_state = std::exchange(other.m_state, nullptr);
        return *this;
    }

    bool prefetch() const { return state().prefetch(); }
    bool prefetchedIsUndefinedOrNull() const { return state().prefetchedIsUndefinedOrNull(); }
    bool prefetchedIsUndefined() const { return state().prefetchedIsUndefined(); }
    T const* convert() const { return state().convert(); }
    T const* convertLast(CppDeferredLeaseProof& proof) const { return state().convertLast(proof); }
    T const* convertAndMaybeYieldProof(CppDeferredLeaseProof& proof) const { return state().convertAndMaybeYieldProof(proof); }
    void discard() const { state().discard(); }
    void discardLast(CppDeferredLeaseProof& proof) const { state().discardLast(proof); }
    bool deferredPending() const { return state().deferredPending(); }
    void discardIfPending() const { state().discardIfPending(); }
    void discardAndMaybeYieldProof(CppDeferredLeaseProof& proof) const { state().discardAndMaybeYieldProof(proof); }

private:
    friend class Detail::CppLazyArgumentState<T>;
    friend struct Detail::CppArgumentAccess;
    explicit CppLazyArgument(Detail::CppLazyArgumentState<T>& state)
        : m_state(&state)
    {
    }
    Detail::CppLazyArgumentState<T>& state() const
    {
        RELEASE_ASSERT(m_state);
        return *m_state;
    }
    Detail::CppLazyArgumentState<T>* m_state { nullptr };
};

template<typename T>
CppLazyArgument<T> Detail::CppLazyArgumentState<T>::view()
{
    return CppLazyArgument<T>(*this);
}

template<typename T>
bool deferredPending(const CppLazyArgument<T>& value)
{
    return value.deferredPending();
}

template<typename T>
bool deferredPending(const std::optional<T>& value)
{
    return value && deferredPending(*value);
}

template<typename T>
void discardDeferred(const CppLazyArgument<T>& value)
{
    value.discardIfPending();
}

template<typename T>
void discardDeferred(const std::optional<T>& value)
{
    if (value)
        discardDeferred(*value);
}

template<typename T>
void discardDeferredLast(const CppLazyArgument<T>& value, CppDeferredLeaseProof& proof)
{
    value.discardLast(proof);
}

template<typename T>
void discardDeferredLast(const std::optional<T>& value, CppDeferredLeaseProof& proof)
{
    RELEASE_ASSERT(value);
    discardDeferredLast(*value, proof);
}

template<typename T>
void discardDeferredAndMaybeYieldProof(const CppLazyArgument<T>& value, CppDeferredLeaseProof& proof)
{
    value.discardAndMaybeYieldProof(proof);
}

template<typename T>
void discardDeferredAndMaybeYieldProof(const std::optional<T>& value, CppDeferredLeaseProof& proof)
{
    if (value)
        discardDeferredAndMaybeYieldProof(*value, proof);
}

template<typename... Values>
void discardPendingDeferred(const Values&... values)
{
    (discardDeferred(values), ...);
}

template<typename... Values>
void discardPendingDeferredAndMaybeYieldProof(CppDeferredLeaseProof& proof, const Values&... values)
{
    (discardDeferredAndMaybeYieldProof(values, proof), ...);
}

template<typename Context, typename T>
const T* convertLastAndLease(Context& context, const CppLazyArgument<T>& value)
{
    CppDeferredLeaseProof proof;
    const auto* result = value.convertLast(proof);
    if (!result || !context.lease(proof))
        return nullptr;
    return result;
}

template<typename Context, typename T>
bool convertOptionalLastAndLease(Context& context, const std::optional<CppLazyArgument<T>>& input, T& output)
{
    if (!input)
        return true;
    const auto* converted = convertLastAndLease(context, *input);
    if (!converted)
        return false;
    output = *converted;
    return true;
}

template<typename Context, typename... Values>
bool discardPendingDeferredAndLease(Context& context, const Values&... values)
{
    CppDeferredLeaseProof proof;
    (discardDeferredAndMaybeYieldProof(values, proof), ...);
    RELEASE_ASSERT(proof);
    return context.lease(proof);
}

class BindingNativeBorrow final {
    struct Release {
        void* owner { nullptr };
        void (*release)(void*) { nullptr };

        void operator()(void*) const { release(owner); }
    };

public:
    BindingNativeBorrow() = default;
    BindingNativeBorrow(void* owner, void* native, void (*release)(void*))
        : m_native(native, Release { owner, release })
    {
        RELEASE_ASSERT(owner);
        RELEASE_ASSERT(native);
        RELEASE_ASSERT(release);
    }
    BindingNativeBorrow(const BindingNativeBorrow&) = delete;
    BindingNativeBorrow& operator=(const BindingNativeBorrow&) = delete;
    BindingNativeBorrow(BindingNativeBorrow&&) noexcept = default;
    BindingNativeBorrow& operator=(BindingNativeBorrow&&) noexcept = default;

private:
    friend class EngineCallContext;
    void* get() const { return m_native.get(); }
    std::unique_ptr<void, Release> m_native { nullptr, Release {} };
};

struct EngineNativeClassReference {
    BindingNativeBorrow borrow;
    JSC::JSValue wrapper;
};

class EngineCallContext final {
public:
    explicit EngineCallContext(JSC::JSGlobalObject& global, BindingDeferredConversions* deferred)
        : globalObject(global)
        , m_results(global)
        , m_deferred(deferred)
    {
    }
    template<typename Native, typename Owner>
    Native* borrowNative(Owner& owner, JSC::JSValue wrapper)
    {
        auto borrow = owner.bindingBorrowNative();
        auto* native = static_cast<Native*>(borrow.get());
        if (!m_nativeClassReferences.tryAppend({ WTF::move(borrow), wrapper }))
            return nullptr;
        return native;
    }
    template<typename Native>
    JSC::JSValue classValue(Native* native) const
    {
        for (const auto& reference : m_nativeClassReferences) {
            if (reference.borrow.get() == native)
                return reference.wrapper;
        }
        RELEASE_ASSERT_NOT_REACHED_WITH_MESSAGE("native class reference does not belong to this engine call");
    }
    CppResultContext& results() { return m_results; }
    bool lease(const CppDeferredLeaseProof& proof) const
    {
        RELEASE_ASSERT(m_deferred && proof.belongsTo(m_deferred));
        return bun_bindgen_deferred_leases_acquire(
                   reinterpret_cast<BindGlobalObjectHandle*>(&globalObject),
                   reinterpret_cast<BindDeferredConversionsHandle*>(m_deferred))
            == BIND_STATUS_OK;
    }
    JSC::JSGlobalObject& globalObject;

private:
    CppResultContext m_results;
    BindingDeferredConversions* m_deferred { nullptr };
    WTF::Vector<EngineNativeClassReference, 1> m_nativeClassReferences;
    friend struct Detail::CppArgumentAccess;
};

template<typename Vector>
bool tryEnsureBindingCapacity(Vector& vector, size_t required)
{
    if (required <= vector.capacity())
        return true;
    size_t capacity = vector.capacity() ? vector.capacity() : 8;
    while (capacity < required) {
        if (capacity > std::numeric_limits<size_t>::max() / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }
    return vector.tryReserveCapacity(capacity);
}

template<bool writable>
class CppScopedByteView final {
    using Byte = std::conditional_t<writable, uint8_t, const uint8_t>;
    using Handle = std::conditional_t<writable, BindByteLeaseHandle, const BindByteLeaseHandle>;

public:
    CppScopedByteView() = default;
    explicit CppScopedByteView(Handle* handle)
        : m_handle(const_cast<BindByteLeaseHandle*>(handle))
    {
        RELEASE_ASSERT(m_handle);
        bun_bindgen_byte_lease_bind_view(m_handle, &m_handle);
    }
    CppScopedByteView(const CppScopedByteView&) = delete;
    CppScopedByteView& operator=(const CppScopedByteView&) = delete;
    CppScopedByteView(CppScopedByteView&& other) noexcept
        : m_handle(other.m_handle)
    {
        if (m_handle)
            bun_bindgen_byte_lease_move_view(m_handle, &other.m_handle, &m_handle);
    }
    CppScopedByteView& operator=(CppScopedByteView&& other) noexcept
    {
        if (this == &other)
            return *this;
        if (m_handle)
            bun_bindgen_byte_lease_unbind_view(m_handle, &m_handle);
        m_handle = other.m_handle;
        if (m_handle)
            bun_bindgen_byte_lease_move_view(m_handle, &other.m_handle, &m_handle);
        return *this;
    }
    ~CppScopedByteView()
    {
        if (m_handle)
            bun_bindgen_byte_lease_unbind_view(m_handle, &m_handle);
    }
    size_t preparedSize() const { return bun_bindgen_byte_lease_prepared_length(m_handle); }
    size_t size() const { return bytes().size(); }
    bool empty() const { return !size(); }
    uint8_t operator[](size_t index) const
    {
        auto value = bytes();
        RELEASE_ASSERT(index < value.size());
        return value[index];
    }
    void set(size_t index, uint8_t byte) const
        requires writable
    {
        auto value = bytes();
        RELEASE_ASSERT(index < value.size());
        value[index] = byte;
    }
    Byte* unsafePtr(ASCIILiteral reason) const
    {
        RELEASE_ASSERT(reason.length());
        return bytes().data();
    }

private:
    std::span<Byte> bytes() const
    {
        size_t length = 0;
        if constexpr (writable) {
            auto* data = bun_bindgen_byte_lease_mutable_data(m_handle, &length);
            return { data, length };
        } else {
            auto* data = bun_bindgen_byte_lease_data(m_handle, &length);
            return { data, length };
        }
    }
    BindByteLeaseHandle* m_handle { nullptr };
    friend struct Detail::CppArgumentAccess;
};

using CppScopedBytes = CppScopedByteView<false>;
using CppScopedMutableBytes = CppScopedByteView<true>;
}
