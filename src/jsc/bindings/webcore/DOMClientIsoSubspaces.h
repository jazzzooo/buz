#pragma once

#include "root.h"

#include <wtf/FastMalloc.h>
#include <wtf/Noncopyable.h>

namespace WebCore {
using namespace JSC;

class DOMClientIsoSubspaces {
    WTF_MAKE_NONCOPYABLE(DOMClientIsoSubspaces);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(DOMClientIsoSubspaces);

public:
    DOMClientIsoSubspaces() = default;

    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForFFIFunction;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForWrappingFunction;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNapiClass;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForStringDecoder;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForCallSite;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForImportMeta;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNapiExternal;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForBundlerPlugin;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNodeVMGlobalObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNodeVMSpecialSandbox;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNodeVMScript;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNodeVMSourceTextModule;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNodeVMSyntheticModule;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSCommonJSModule;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSCommonJSExtensions;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSEnvironmentVariableMap;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSMockImplementation;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSMockFunction;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForAsyncContextFrame;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForMockWithImplementationCleanupData;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForProcessObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForInternalModuleRegistry;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForErrorCodeCache;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSNextTickQueue;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSDiffieHellman;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSDiffieHellmanGroup;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForTTYWrapObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNapiHandleScopeImpl;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForNapiTypeTag;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForObjectTemplate;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForInternalFieldObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForV8GlobalInternals;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForHandleScopeBuffer;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForFunctionTemplate;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForV8Function;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSNodeHTTPServerSocket;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSX509Certificate;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSNodePerformanceHooksHistogram;

#include "SchemaBindings+DOMClientIsoSubspaces.h"

    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForWorkerGlobalScope;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForBakeGlobalScope;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSHash;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSCipher;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSKeyObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSSecretKeyObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSPublicKeyObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSPrivateKeyObject;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForServerRouteList;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForBunRequest;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForBakeResponse;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSConnectionsList;
    std::unique_ptr<GCClient::IsoSubspace> m_clientSubspaceForJSHTTPParser;
};

} // namespace WebCore
