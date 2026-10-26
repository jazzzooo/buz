#include "blob.h"
#include "SchemaBindings.h"
#include "JSDOMExceptionHandling.h"

void Bun::Bindgen::Engine::releaseNativeBlob(WebCore::BlobImpl* blob)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobDeref(blob);
}

namespace WebCore {

BlobImpl* BlobImplRefDerefTraits::refIfNotNull(BlobImpl* impl)
{
    if (impl) [[likely]]
        Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobRef(impl);
    return impl;
}

BlobImpl& BlobImplRefDerefTraits::ref(BlobImpl& impl)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobRef(&impl);
    return impl;
}

void BlobImplRefDerefTraits::derefIfNotNull(BlobImpl* impl)
{
    if (impl) [[likely]]
        Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobDeref(impl);
}

ExceptionOr<Ref<Blob>> Blob::createAdopted(BlobRef&& impl)
{
    auto* memory = WTF::FastMalloc::tryMalloc(sizeof(Blob));
    if (!memory)
        return Exception { OutOfMemoryError };
    return adoptRef(*new (memory) Blob(WTF::move(impl)));
}

ExceptionOr<Ref<Blob>> Blob::create(BunBindgen_Blob_Blob_Native* binding)
{
    auto* resource = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobRetainFromBinding(binding);
    return createAdopted(adoptRef<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>(*resource));
}

ExceptionOr<Ref<Blob>> Blob::withFileName(const String& name) const
{
    auto clone = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobCloneAsFile(impl(), name);
    if (!clone)
        return Exception { OutOfMemoryError };
    auto created = createAdopted(adoptRef<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>(*clone.value()));
    if (created.hasException())
        return created.releaseException();
    auto file = created.releaseReturnValue();
    file->m_fileName = name;
    return file;
}

RefPtr<Blob> Blob::create(std::span<const uint8_t> bytes, JSC::JSGlobalObject* global)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* impl = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobCreateFromBytes(global, bytes);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto result = createAdopted(adoptRef<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>(*impl));
    if (result.hasException()) {
        propagateException(*global, scope, result.releaseException());
        return nullptr;
    }
    return result.releaseReturnValue();
}

RefPtr<Blob> Blob::create(std::span<const uint8_t> bytes, JSC::JSGlobalObject* global, const String& contentType)
{
    auto scope = DECLARE_THROW_SCOPE(global->vm());
    auto* impl = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobCreateFromBytesWithType(global, bytes, contentType);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto result = createAdopted(adoptRef<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>(*impl));
    if (result.hasException()) {
        propagateException(*global, scope, result.releaseException());
        return nullptr;
    }
    return result.releaseReturnValue();
}

bool Blob::isInstance(JSC::JSValue value) noexcept
{
    return !!dynamicDowncast<Bun::BunBindgen_Blob_Blob>(value);
}

BlobRefPtr Blob::retain(JSC::JSValue value)
{
    return adoptRef<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>(retainImpl(value));
}

BlobImpl* Blob::retainImpl(JSC::JSValue value)
{
    auto* binding = bun_bindgen_class_Blob_Blob_try_cast_value(value);
    return binding ? Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobRetainFromBinding(binding) : nullptr;
}

JSC::JSValue adoptBlobImpl(JSC::JSGlobalObject* globalObject, BlobImpl* impl)
{
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobAdopt(globalObject, impl);
    switch (result.tag()) {
    case decltype(result)::Tag::blob:
        return result.blob();
    case decltype(result)::Tag::file:
        return result.file();
    case decltype(result)::Tag::s3_file:
        return result.s3_file();
    case decltype(result)::Tag::none:
        return {};
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSValue toJS(JSC::JSGlobalObject* lexicalGlobalObject, JSDOMGlobalObject*, WebCore::Blob& impl)
{
    auto scope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    auto clone = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobClone(impl.impl());
    BlobRefPtr owned;
    if (clone)
        owned = adoptRef<BlobImpl, RawPtrTraits<BlobImpl>, BlobImplRefDerefTraits>(clone.value());
    RETURN_IF_EXCEPTION(scope, {});
    if (!owned) {
        JSC::throwOutOfMemoryError(lexicalGlobalObject, scope);
        return {};
    }
    RELEASE_AND_RETURN(scope, adoptBlobImpl(lexicalGlobalObject, owned.leakRef()));
}

JSC::JSValue toJSNewlyCreated(JSC::JSGlobalObject* lexicalGlobalObject, JSDOMGlobalObject* globalObject, Ref<WebCore::Blob>&& impl)
{
    return toJS(lexicalGlobalObject, globalObject, impl.get());
}

size_t Blob::memoryCost() const
{
    return sizeof(Blob) + Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobEstimatedSize(impl());
}

}
