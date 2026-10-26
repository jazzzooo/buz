// clang-format off
#pragma once

#include "root.h"

#include <JavaScriptCore/VM.h>
#include <JavaScriptCore/Identifier.h>
#include <JavaScriptCore/BuiltinUtils.h>
#include "BunBuiltinNames+extras.h"

namespace WebCore {

using namespace JSC;

// Keep this list sorted.
#define BUN_COMMON_PRIVATE_IDENTIFIERS_EACH_PROPERTY_NAME(macro) \
    macro(AbortSignal) \
    macro(Buffer) \
    macro(Loader) \
    macro(ReadableByteStreamController) \
    macro(ReadableStream) \
    macro(ReadableStreamBYOBReader) \
    macro(ReadableStreamDefaultController) \
    macro(ReadableStreamDefaultReader) \
    macro(SQL) \
    macro(TextEncoderStreamEncoder) \
    macro(TransformStream) \
    macro(TransformStreamDefaultController) \
    macro(WritableStream) \
    macro(WritableStreamDefaultController) \
    macro(WritableStreamDefaultWriter) \
    macro(_events) \
    macro(addAbortAlgorithmToSignal) \
    macro(atimeMs) \
    macro(attributes) \
    macro(backpressure) \
    macro(backpressureChangePromise) \
    macro(basename) \
    macro(bindingFactory) \
    macro(birthtimeMs) \
    macro(body) \
    macro(bunTestScopeConcurrent) \
    macro(bunTestScopeFailing) \
    macro(bunTestScopeOnly) \
    macro(bunTestScopeSerial) \
    macro(bunTestScopeSkip) \
    macro(bunTestScopeState) \
    macro(bunTestScopeTodo) \
    macro(checks) \
    macro(checkBufferRead) \
    macro(cloneArrayBuffer) \
    macro(close) \
    macro(closeRequest) \
    macro(cmd) \
    macro(code) \
    macro(controller) \
    macro(createCommonJSModule) \
    macro(createInternalModuleById) \
    macro(createUninitializedArrayBuffer) \
    macro(createWritableStreamFromInternal) \
    macro(ctimeMs) \
    macro(dataView) \
    macro(decode) \
    macro(deferredNativeSource) \
    macro(dest) \
    macro(dirname) \
    macro(domain) \
    macro(encoding) \
    macro(errno) \
    macro(evaluateCommonJSModule) \
    macro(evictIsolationSourceProviderCache) \
    macro(expires) \
    macro(exports) \
    macro(extname) \
    macro(fastPath) \
    macro(fatal) \
    macro(fd) \
    macro(filename) \
    macro(format) \
    macro(fulfillModuleSync) \
    macro(esmNamespaceForCjs) \
    macro(esmRegistryDelete) \
    macro(esmRegistryEvaluatedKeys) \
    macro(esmLoadSync) \
    macro(getInternalWritableStream) \
    macro(handleEvent) \
    macro(headers) \
    macro(host) \
    macro(hostDefinedImportType) \
    macro(hostname) \
    macro(httpOnly) \
    macro(ignoreBOM) \
    macro(importer) \
    macro(inFlightCloseRequest) \
    macro(inFlightWriteRequest) \
    macro(internalModuleRegistry) \
    macro(internalRequire) \
    macro(internalWritable) \
    macro(isAbortSignal) \
    macro(isAbsolute) \
    macro(join) \
    macro(lazyStreamPrototypeMap) \
    macro(lineText) \
    macro(loadEsmIntoCjs) \
    macro(main) \
    macro(makeAbortError) \
    macro(makeDOMException) \
    macro(makeErrorWithCode) \
    macro(makeGetterTypeError) \
    macro(maxAge) \
    macro(method) \
    macro(mockedFunction) \
    macro(mode) \
    macro(mtimeMs) \
    macro(napiDlopenHandle) \
    macro(napiWrappedContents) \
    macro(normalize) \
    macro(originalColumn) \
    macro(originalLine) \
    macro(overridableRequire) \
    macro(parse) \
    macro(partitioned) \
    macro(path) \
    macro(paths) \
    macro(peekPromiseSettledValue) \
    macro(peekPromiseStatus) \
    macro(pendingAbortRequest) \
    macro(pokePromiseAsHandled) \
    macro(port) \
    macro(post) \
    macro(prepareStackTrace) \
    macro(processBindingConstants) \
    macro(read) \
    macro(readable) \
    macro(redirect) \
    macro(relative) \
    macro(removeAbortAlgorithmFromSignal) \
    macro(require) \
    macro(requireESM) \
    macro(requireMap) \
    macro(requireNativeModule) \
    macro(resume) \
    macro(sameSite) \
    macro(secure) \
    macro(self) \
    macro(signal) \
    macro(sink) \
    macro(size) \
    macro(specifier) \
    macro(startDirectStream) \
    macro(status) \
    macro(statusText) \
    macro(structuredCloneForStream) \
    macro(syscall) \
    macro(textDecoder) \
    macro(textDecoderStreamTransform) \
    macro(textEncoderStreamEncoder) \
    macro(textEncoderStreamTransform) \
    macro(toClass) \
    macro(toNamespacedPath) \
    macro(underlyingByteSource) \
    macro(underlyingSink) \
    macro(url) \
    macro(warning) \
    macro(writable) \
    macro(writableStreamBrand) \
    macro(writeRequests) \
    macro(writer) \
    macro(written) \
    macro($$typeof) \
    macro(type) \
    macro(key) \
    macro(props) \
    macro(validated) \
    macro(_store) \
    macro(_owner) \
    macro(_debugInfo) \
    macro(_debugStack) \
    macro(_debugTask) \
    BUN_ADDITIONAL_BUILTIN_NAMES(macro)
// --- END of BUN_COMMON_PRIVATE_IDENTIFIERS_EACH_PROPERTY_NAME ---

class BunBuiltinNames {
    WTF_MAKE_NONCOPYABLE(BunBuiltinNames);
    friend class JSVMClientData;
    explicit BunBuiltinNames(JSC::VM&);
    ~BunBuiltinNames();

public:
    BUN_COMMON_PRIVATE_IDENTIFIERS_EACH_PROPERTY_NAME(DECLARE_BUILTIN_IDENTIFIER_ACCESSOR)

    const JSC::Identifier& resolvePublicName() const { return m_vm.propertyNames->resolve;}
    const JSC::Identifier& inspectCustomPublicName() {
        if (m_inspectCustomPublicName.isEmpty()) [[unlikely]] {
            m_inspectCustomPublicName = Identifier::fromUid(m_vm.symbolRegistry().symbolForKey("nodejs.util.inspect.custom"_s));
        }
        return m_inspectCustomPublicName;
    }

private:
    JSC::VM& m_vm;
    JSC::Identifier m_inspectCustomPublicName {};
    BUN_COMMON_PRIVATE_IDENTIFIERS_EACH_PROPERTY_NAME(DECLARE_BUILTIN_NAMES)
};

} // namespace WebCore
