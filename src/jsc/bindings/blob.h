#pragma once

#include "root.h"
#include "BunClientData.h"
#include "BunIDLExternalRefs.h"
#include "ExceptionOr.h"

struct BunBindgen_Blob_Blob_Native;

namespace Zig {
class GlobalObject;
}

namespace WebCore {

// Opaque type corresponding to `bun.webcore.Blob`.
class BlobImpl;

using BlobRef = Ref<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>;
using BlobRefPtr = RefPtr<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>;

class Blob : public RefCounted<Blob> {
    WTF_MAKE_NONCOPYABLE(Blob);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Blob);

public:
    BlobImpl* impl() const
    {
        return m_impl.ptr();
    }

    static ExceptionOr<Ref<Blob>> create(BunBindgen_Blob_Blob_Native*);
    static bool isInstance(JSC::JSValue) noexcept;
    static BlobRefPtr retain(JSC::JSValue);

    static RefPtr<Blob> create(std::span<const uint8_t> bytes, JSC::JSGlobalObject*);
    static RefPtr<Blob> create(std::span<const uint8_t> bytes, JSC::JSGlobalObject*, const String& contentType);

    String fileName()
    {
        return m_fileName;
    }

    ExceptionOr<Ref<Blob>> withFileName(const String&) const;

    size_t memoryCost() const;

private:
    static BlobImpl* retainImpl(JSC::JSValue);

    explicit Blob(BlobRef&& impl)
        : m_impl(WTF::move(impl))
    {
    }

    static ExceptionOr<Ref<Blob>> createAdopted(BlobRef&&);

    BlobRef m_impl;
    String m_fileName;
};

JSC::JSValue toJS(JSC::JSGlobalObject*, Zig::GlobalObject*, Blob&);
inline JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, Zig::GlobalObject* globalObject, Blob* impl) { return impl ? toJS(lexicalGlobalObject, globalObject, *impl) : JSC::jsNull(); }
JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject*, Zig::GlobalObject*, Ref<Blob>&&);
inline JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject* lexicalGlobalObject, Zig::GlobalObject* globalObject, RefPtr<Blob>&& impl) { return impl ? toJSNewlyCreated(lexicalGlobalObject, globalObject, impl.releaseNonNull()) : JSC::jsNull(); }
JSC::JSValue adoptBlobImpl(JSC::JSGlobalObject*, BlobImpl*);

}
