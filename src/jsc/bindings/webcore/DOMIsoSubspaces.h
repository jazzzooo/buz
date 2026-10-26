#pragma once

#include "root.h"

#include <wtf/FastMalloc.h>
#include <wtf/Noncopyable.h>

namespace WebCore {
using namespace JSC;

class DOMIsoSubspaces {
    WTF_MAKE_NONCOPYABLE(DOMIsoSubspaces);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(DOMIsoSubspaces);

public:
    DOMIsoSubspaces() = default;

    std::unique_ptr<IsoSubspace> m_subspaceForFFIFunction;
    std::unique_ptr<IsoSubspace> m_subspaceForWrappingFunction;
    std::unique_ptr<IsoSubspace> m_subspaceForNapiClass;
    std::unique_ptr<IsoSubspace> m_subspaceForStringDecoder;
    std::unique_ptr<IsoSubspace> m_subspaceForCallSite;
    std::unique_ptr<IsoSubspace> m_subspaceForNapiExternal;
    std::unique_ptr<IsoSubspace> m_subspaceForImportMeta;
    std::unique_ptr<IsoSubspace> m_subspaceForBundlerPlugin;
    std::unique_ptr<IsoSubspace> m_subspaceForNodeVMGlobalObject;
    std::unique_ptr<IsoSubspace> m_subspaceForNodeVMSpecialSandbox;
    std::unique_ptr<IsoSubspace> m_subspaceForNodeVMScript;
    std::unique_ptr<IsoSubspace> m_subspaceForNodeVMSourceTextModule;
    std::unique_ptr<IsoSubspace> m_subspaceForNodeVMSyntheticModule;
    std::unique_ptr<IsoSubspace> m_subspaceForJSCommonJSModule;
    std::unique_ptr<IsoSubspace> m_subspaceForJSCommonJSExtensions;
    std::unique_ptr<IsoSubspace> m_subspaceForJSEnvironmentVariableMap;
    std::unique_ptr<IsoSubspace> m_subspaceForJSMockImplementation;
    std::unique_ptr<IsoSubspace> m_subspaceForJSMockFunction;
    std::unique_ptr<IsoSubspace> m_subspaceForAsyncContextFrame;
    std::unique_ptr<IsoSubspace> m_subspaceForMockWithImplementationCleanupData;
    std::unique_ptr<IsoSubspace> m_subspaceForProcessObject;
    std::unique_ptr<IsoSubspace> m_subspaceForInternalModuleRegistry;
    std::unique_ptr<IsoSubspace> m_subspaceForErrorCodeCache;
    std::unique_ptr<IsoSubspace> m_subspaceForJSNextTickQueue;
    std::unique_ptr<IsoSubspace> m_subspaceForTTYWrapObject;
    std::unique_ptr<IsoSubspace> m_subspaceForNapiHandleScopeImpl;
    std::unique_ptr<IsoSubspace> m_subspaceForNapiTypeTag;
    std::unique_ptr<IsoSubspace> m_subspaceForObjectTemplate;
    std::unique_ptr<IsoSubspace> m_subspaceForInternalFieldObject;
    std::unique_ptr<IsoSubspace> m_subspaceForV8GlobalInternals;
    std::unique_ptr<IsoSubspace> m_subspaceForHandleScopeBuffer;
    std::unique_ptr<IsoSubspace> m_subspaceForFunctionTemplate;
    std::unique_ptr<IsoSubspace> m_subspaceForV8Function;
    std::unique_ptr<IsoSubspace> m_subspaceForJSNodeHTTPServerSocket;
    std::unique_ptr<IsoSubspace> m_subspaceForJSX509Certificate;
    std::unique_ptr<IsoSubspace> m_subspaceForJSNodePerformanceHooksHistogram;

#include "SchemaBindings+DOMIsoSubspaces.h"

    std::unique_ptr<IsoSubspace> m_subspaceForWorkerGlobalScope;
    std::unique_ptr<IsoSubspace> m_subspaceForBakeGlobalScope;
    std::unique_ptr<IsoSubspace> m_subspaceForJSHash;
    std::unique_ptr<IsoSubspace> m_subspaceForServerRouteList;
    std::unique_ptr<IsoSubspace> m_subspaceForBunRequest;
    std::unique_ptr<IsoSubspace> m_subspaceForBakeResponse;
    std::unique_ptr<IsoSubspace> m_subspaceForJSDiffieHellman;
    std::unique_ptr<IsoSubspace> m_subspaceForJSDiffieHellmanGroup;
    std::unique_ptr<IsoSubspace> m_subspaceForJSCipher;
    std::unique_ptr<IsoSubspace> m_subspaceForJSKeyObject;
    std::unique_ptr<IsoSubspace> m_subspaceForJSSecretKeyObject;
    std::unique_ptr<IsoSubspace> m_subspaceForJSPublicKeyObject;
    std::unique_ptr<IsoSubspace> m_subspaceForJSPrivateKeyObject;
    std::unique_ptr<IsoSubspace> m_subspaceForJSConnectionsList;
    std::unique_ptr<IsoSubspace> m_subspaceForJSHTTPParser;
};

} // namespace WebCore
