#pragma once
#include "BunIDLTypes.h"

namespace WebCore {
class AbortSignal;
class BlobImpl;
struct BlobImplRefDerefTraits {
    static BlobImpl* refIfNotNull(BlobImpl*);
    static BlobImpl& ref(BlobImpl&);
    static void derefIfNotNull(BlobImpl*);
};
class DOMFormData;
class FetchHeaders;
class URLSearchParams;
}

namespace Bun {
struct IDLAbortSignalRef : IDLBunInterface<WebCore::AbortSignal> {};
struct IDLBlobRef : IDLBunInterface<WebCore::BlobImpl, WebCore::BlobImplRefDerefTraits> {};
struct IDLDOMFormDataRef : IDLBunInterface<WebCore::DOMFormData> {};
struct IDLFetchHeadersRef : IDLBunInterface<WebCore::FetchHeaders> {};
struct IDLURLSearchParamsRef : IDLBunInterface<WebCore::URLSearchParams> {};
}
