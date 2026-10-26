#include "root.h"

#include <JavaScriptCore/CallData.h>
#include "JavaScriptCore/HeapProfiler.h"
#include <JavaScriptCore/HeapSnapshotBuilder.h>
#include "ZigGlobalObject.h"
#include "JavaScriptCore/ArgList.h"
#include "helpers.h"
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSBase.h>
#include <JavaScriptCore/BuiltinNames.h>
#include "ScriptExecutionContext.h"
#include "WebCoreJSClientData.h"
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/LazyClassStructure.h>
#include <JavaScriptCore/LazyClassStructureInlines.h>
#include <JavaScriptCore/FunctionPrototype.h>
#include <JavaScriptCore/JSONObject.h>
#include "wtf/SIMDUTF.h"
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include "BunObject.h"
#include "WebCoreJSBuiltins.h"
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/Symbol.h>
#include "Exception.h"
#include "JSDOMException.h"
#include "wtf/Compiler.h"
#include "PathInlines.h"
#include "Bindgen/FileURL.h"
#include "JSDOMURL.h"
#include "JSDOMExceptionHandling.h"
#include <wtf/URL.h>
#include "wtf/text/ASCIILiteral.h"
#include "SchemaBindings.h"
#include "ErrorCode.h"
#include "JavaScriptCore/BunV8HeapSnapshotBuilder.h"

#ifdef WIN32
#include <ws2def.h>
#else
#include <netdb.h>
#endif

using namespace JSC;
using namespace WebCore;

namespace Bun {

#define BUN_BINDGEN_OBJECT_SURFACE_BunPluginFunction
#define BUN_BINDGEN_OBJECT_SURFACE_BunFetchFunction
#define BUN_BINDGEN_OBJECT_SURFACE_BunShellObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunJSONLObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunPeekFunction
#define BUN_BINDGEN_OBJECT_SURFACE_BunHashFunction
#define BUN_BINDGEN_OBJECT_SURFACE_BunCSRFObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunDNSObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunPasswordObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunSecretsObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunCronFunction
#define BUN_BINDGEN_OBJECT_SURFACE_BunFFIObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunFFIReader
#define BUN_BINDGEN_OBJECT_SURFACE_BunInspectFunction
#define BUN_BINDGEN_OBJECT_SURFACE_BunJSONCObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunJSON5Object
#define BUN_BINDGEN_OBJECT_SURFACE_BunMarkdownObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunSemverObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunTOMLObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunUnsafeObject
#define BUN_BINDGEN_OBJECT_SURFACE_BunYAMLObject
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_BunSecretsObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunPasswordObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunDNSObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunYAMLObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunUnsafeObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunTOMLObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunSemverObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunMarkdownObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunJSON5Object
#undef BUN_BINDGEN_OBJECT_SURFACE_BunJSONCObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunInspectFunction
#undef BUN_BINDGEN_OBJECT_SURFACE_BunFFIReader
#undef BUN_BINDGEN_OBJECT_SURFACE_BunFFIObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunCronFunction
#undef BUN_BINDGEN_OBJECT_SURFACE_BunCSRFObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunHashFunction
#undef BUN_BINDGEN_OBJECT_SURFACE_BunPeekFunction
#undef BUN_BINDGEN_OBJECT_SURFACE_BunJSONLObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunShellObject
#undef BUN_BINDGEN_OBJECT_SURFACE_BunFetchFunction
#undef BUN_BINDGEN_OBJECT_SURFACE_BunPluginFunction

static JSValue constructEnvObject(VM& vm, JSObject* object)
{
    return uncheckedDowncast<Zig::GlobalObject>(object->globalObject())->processEnvObject();
}

template<typename Buffer>
static inline JSC::EncodedJSValue flattenArrayOfBuffersIntoArrayBufferOrUint8Array(JSGlobalObject* lexicalGlobalObject, std::span<const Buffer> buffers, size_t maxLength, bool asUint8Array)
{
    auto& vm = JSC::getVM(lexicalGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    const auto returnEmptyArrayBufferView = [&]() -> EncodedJSValue {
        if (asUint8Array) {
            RELEASE_AND_RETURN(throwScope, JSValue::encode(JSC::JSUint8Array::create(lexicalGlobalObject, lexicalGlobalObject->m_typedArrayUint8.get(lexicalGlobalObject), 0)));
        }

        RELEASE_AND_RETURN(throwScope, JSValue::encode(JSC::JSArrayBuffer::create(vm, lexicalGlobalObject->arrayBufferStructure(), JSC::ArrayBuffer::create(static_cast<size_t>(0), 1))));
    };

    size_t byteLength = 0;
    for (const auto& bytes : buffers) {
        if (bytes.size() >= maxLength - byteLength) {
            byteLength = maxLength;
            break;
        }
        byteLength += bytes.size();
    }

    if (byteLength == 0) {
        return returnEmptyArrayBufferView();
    }

    auto buffer = JSC::ArrayBuffer::tryCreateUninitialized(byteLength, 1);
    if (!buffer) [[unlikely]] {
        throwTypeError(lexicalGlobalObject, throwScope, "Failed to allocate ArrayBuffer"_s);
        return {};
    }

    size_t remain = byteLength;
    auto* head = reinterpret_cast<char*>(buffer->data());

    for (const auto& bytes : buffers) {
        const size_t length = std::min(remain, bytes.size());
        if (length > 0)
            memcpy(head, bytes.unsafePtr("The entry frame holds the source lease through synchronous concatenation"_s), length);
        remain -= length;
        head += length;
        if (remain == 0)
            break;
    }

    ASSERT(remain == 0);

    if (asUint8Array) {
        auto uint8array = JSC::JSUint8Array::create(lexicalGlobalObject, lexicalGlobalObject->m_typedArrayUint8.get(lexicalGlobalObject), WTF::move(buffer), 0, byteLength);
        RETURN_IF_EXCEPTION(throwScope, {});
        return JSValue::encode(uint8array);
    }

    RELEASE_AND_RETURN(throwScope, JSValue::encode(JSC::JSArrayBuffer::create(vm, lexicalGlobalObject->arrayBufferStructure(), WTF::move(buffer))));
}

Bindgen::BunConcatArrayBuffersResult Bindgen::Cpp::bunBindgenCpp_BunObject_concatArrayBuffers(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_concatArrayBuffers_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    size_t maxLength = std::numeric_limits<size_t>::max();
    if (args.maxLength && args.maxLength->is_number()) {
        const double number = args.maxLength->number();
        if (std::isnan(number) || number < 0) {
            throwRangeError(globalObject, throwScope, "Maximum length must be >= 0"_s);
            return {};
        }
        if (!std::isinf(number))
            maxLength = JSC::toUInt32(number);
    }

    std::span<const Bindgen::CppScopedBytes> buffers;
    if (args.buffers)
        buffers = args.buffers->span();
    auto value = JSC::JSValue::decode(flattenArrayOfBuffersIntoArrayBufferOrUint8Array(globalObject, buffers, maxLength, args.asUint8Array));
    RETURN_IF_EXCEPTION(throwScope, {});
    Bindgen::BunConcatArrayBuffersResult result;
    if (args.asUint8Array)
        result.set_uint8_array(value);
    else
        result.set_array_buffer(value);
    throwScope.release();
    return result;
}

static WTF::String constructBunVersion(VM&, JSObject*)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_Process_version().substring(1);
}

static WTF::String constructBunRevision(VM&, JSObject*)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_Process_revision();
}

static WTF::String constructBunVersionWithSha(VM&, JSObject*)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_Process_versionWithSha();
}

static bool constructIsMainThread(VM&, JSObject* object)
{
    return uncheckedDowncast<Zig::GlobalObject>(object->globalObject())->scriptExecutionContext()->isMainThread();
}

static JSValue defaultBunSQLObject(VM& vm, JSObject* bunObject)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(bunObject->globalObject());
    JSValue sqlValue = globalObject->internalModuleRegistry()->requireId(globalObject, vm, InternalModuleRegistry::Field::BunSql);
#if BUN_DEBUG
    if (scope.exception()) globalObject->reportUncaughtExceptionAtEventLoop(globalObject, scope.exception());
#endif
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, sqlValue.getObject()->get(globalObject, vm.propertyNames->defaultKeyword));
}

static JSValue constructBunSQLObject(VM& vm, JSObject* bunObject)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(bunObject->globalObject());
    JSValue sqlValue = globalObject->internalModuleRegistry()->requireId(globalObject, vm, InternalModuleRegistry::Field::BunSql);
#if BUN_DEBUG
    if (scope.exception()) globalObject->reportUncaughtExceptionAtEventLoop(globalObject, scope.exception());
#endif
    RETURN_IF_EXCEPTION(scope, {});
    auto clientData = WebCore::clientData(vm);
    RELEASE_AND_RETURN(scope, sqlValue.getObject()->get(globalObject, clientData->builtinNames().SQLPublicName()));
}

static JSValue constructBunShell(VM& vm, JSObject* bunObject)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(bunObject->globalObject());
    JSFunction* createParsedShellScript = JSFunction::create(vm, bunObject->globalObject(), 2, "createParsedShellScript"_s, bun_bindgen_host_BunObject_createParsedShellScript, ImplementationVisibility::Private, NoIntrinsic);
    JSFunction* createShellInterpreterFunction = JSFunction::create(vm, bunObject->globalObject(), 1, "createShellInterpreter"_s, bun_bindgen_host_BunObject_createShellInterpreter, ImplementationVisibility::Private, NoIntrinsic);
    JSC::JSFunction* createShellFn = JSC::JSFunction::create(vm, globalObject, shellCreateBunShellTemplateFunctionCodeGenerator(vm), globalObject);

    auto scope = DECLARE_THROW_SCOPE(vm);
    auto args = JSC::MarkedArgumentBuffer();
    args.append(createShellInterpreterFunction);
    args.append(createParsedShellScript);
    JSC::JSValue shell = JSC::call(globalObject, createShellFn, args, "BunShell"_s);
    RETURN_IF_EXCEPTION(scope, {});

    if (!shell.isObject()) [[unlikely]] {
        throwTypeError(globalObject, scope, "Internal error: BunShell constructor did not return an object"_s);
        return {};
    }

    auto* bunShell = shell.getObject();

    bunBindgenObjectSurface_BunShellObject_install(vm, bunShell->classInfo(), *bunShell);

    return bunShell;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunObject_jsonlParse(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_jsonlParse_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.input) {
        throwTypeError(globalObject, scope, "JSONL.parse requires a string argument"_s);
        return {};
    }
    const auto& input = *args.input;

    MarkedArgumentBuffer values;
    JSC::StreamingJSONParseResult result;

    if (input.is_buffer()) {
        const auto& buffer = input.buffer();
        auto* data = buffer.unsafePtr("The entry frame holds the input lease through synchronous JSON parsing"_s);
        size_t length = buffer.size();

        // Skip UTF-8 BOM if present
        if (length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
            data += 3;
            length -= 3;
        }

        if (length <= String::MaxLength && simdutf::validate_ascii(reinterpret_cast<const char*>(data), length)) {
            auto chars = std::span { reinterpret_cast<const char8_t*>(data), length };
            result = JSC::streamingJSONParse(globalObject, StringView(chars), values);
        } else {
            size_t u16Length = simdutf::utf16_length_from_utf8(reinterpret_cast<const char*>(data), length);
            if (u16Length > String::MaxLength) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            auto str = WTF::String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const char8_t*>(data), length });
            if (str.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            result = JSC::streamingJSONParse(globalObject, str, values);
        }
    } else {
        result = JSC::streamingJSONParse(globalObject, input.string(), values);
    }

    RETURN_IF_EXCEPTION(scope, {});

    if (result.status == JSC::StreamingJSONParseResult::Status::Error && values.isEmpty()) {
        throwSyntaxError(globalObject, scope, "Failed to parse JSONL"_s);
        return {};
    }

    RELEASE_AND_RETURN(scope, constructArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), values));
}

Bindgen::BunJSONLParseChunkResult Bindgen::Cpp::bunBindgenCpp_BunObject_jsonlParseChunk(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_jsonlParseChunk_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.input) {
        throwTypeError(globalObject, scope, "JSONL.parseChunk requires a string argument"_s);
        return {};
    }
    const auto& input = *args.input;

    MarkedArgumentBuffer values;
    JSC::StreamingJSONParseResult result;
    size_t readBytes = 0;
    bool isBuffer = input.is_buffer();

    // Apply optional start/end offsets (byte offsets for buffers, character offsets for strings).
    // Populates start/end clamped to [0, length], with start <= end.
    size_t start;
    size_t end;
    const auto parseOffsets = [&](size_t length) {
        start = 0;
        end = length;

        if (args.start && args.start->is_number()) {
            double s = args.start->number();
            if (s > 0)
                start = static_cast<size_t>(std::min(s, static_cast<double>(length)));
        }

        if (args.end && args.end->is_number()) {
            double e = args.end->number();
            if (e >= 0)
                end = static_cast<size_t>(std::min(e, static_cast<double>(length)));
        }

        if (start > end)
            start = end;
    };

    if (isBuffer) {
        const auto& buffer = input.buffer();
        auto* data = buffer.unsafePtr("The entry frame holds the input lease through synchronous JSON parsing"_s);
        size_t length = buffer.size();
        parseOffsets(length);

        const uint8_t* sliceData = data + start;
        size_t sliceLen = end - start;

        // Skip UTF-8 BOM if present at the start of the slice
        size_t bomOffset = 0;
        if (start == 0 && sliceLen >= 3 && sliceData[0] == 0xEF && sliceData[1] == 0xBB && sliceData[2] == 0xBF) {
            sliceData += 3;
            sliceLen -= 3;
            bomOffset = 3;
        }

        if (sliceLen <= String::MaxLength && simdutf::validate_ascii(reinterpret_cast<const char*>(sliceData), sliceLen)) {
            auto chars = std::span { reinterpret_cast<const char8_t*>(sliceData), sliceLen };
            result = JSC::streamingJSONParse(globalObject, StringView(chars), values);
            // For ASCII, byte offset = character offset
            readBytes = start + bomOffset + result.charactersConsumed;
        } else {
            size_t u16Length = simdutf::utf16_length_from_utf8(reinterpret_cast<const char*>(sliceData), sliceLen);
            if (u16Length > String::MaxLength) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            auto str = WTF::String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const char8_t*>(sliceData), sliceLen });
            if (str.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return {};
            }
            result = JSC::streamingJSONParse(globalObject, str, values);
            // Convert character offset back to UTF-8 byte offset
            if (str.is8Bit()) {
                readBytes = start + bomOffset + simdutf::utf8_length_from_latin1(reinterpret_cast<const char*>(str.span8().data()), result.charactersConsumed);
            } else {
                readBytes = start + bomOffset + simdutf::utf8_length_from_utf16le(reinterpret_cast<const char16_t*>(str.span16().data()), result.charactersConsumed);
            }
        }
    } else {
        StringView view(input.string());

        size_t length = view.length();
        parseOffsets(length);

        if (start != 0 || end != length) {
            result = JSC::streamingJSONParse(globalObject, view.substring(start, end - start), values);
        } else {
            result = JSC::streamingJSONParse(globalObject, view, values);
        }
        readBytes = start + result.charactersConsumed;
    }

    RETURN_IF_EXCEPTION(scope, {});

    JSArray* array = constructArray(globalObject, static_cast<ArrayAllocationProfile*>(nullptr), values);
    RETURN_IF_EXCEPTION(scope, {});

    std::optional<JSValue> errorValue;
    if (result.status == JSC::StreamingJSONParseResult::Status::Error) {
        errorValue = createSyntaxError(globalObject, "Failed to parse JSONL"_s);
    }

    scope.release();
    return {
        .values = array,
        .read = readBytes,
        .done = result.status == JSC::StreamingJSONParseResult::Status::Complete,
        .error = errorValue,
    };
}

static JSC_DECLARE_JIT_OPERATION_WITHOUT_WTF_INTERNAL(functionBunEscapeHTMLWithoutTypeCheck, JSC::EncodedJSValue, (JSC::JSGlobalObject*, JSObject*, JSString*));

WTF::String Bindgen::Cpp::bunBindgenCpp_BunObject_escapeHTML(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_escapeHTML_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    if (args.input.isEmpty())
        return WTF::emptyString();

    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(lexicalGlobalObject));
    StringView resolvedString(args.input);

    if (!resolvedString.is8Bit()) {
        const auto span = resolvedString.span16();
        auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_escapeHTMLUTF16(
            lexicalGlobalObject,
            { reinterpret_cast<const uint16_t*>(span.data()), span.size() });
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, result);
    } else {
        const auto span = resolvedString.span8();
        auto result = Bun::Bindgen::ZigExports::bunBindgenZig_BunObject_escapeHTMLLatin1(lexicalGlobalObject, span);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, result);
    }
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunObject_pathToFileURL(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_pathToFileURL_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto throwScope = DECLARE_THROW_SCOPE(lexicalGlobalObject->vm());
    WTF::String pathString = pathResolveWTFString(lexicalGlobalObject, args.path);
    RETURN_IF_EXCEPTION(throwScope, {});
    RELEASE_AND_RETURN(throwScope, Bindgen::ZigExports::bunBindgenZig_urls_domURLFromFileSystemPath(lexicalGlobalObject, pathString));
}

Bindgen::BunHeapSnapshotResult Bindgen::Cpp::bunBindgenCpp_BunObject_generateHeapSnapshot(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_generateHeapSnapshot_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    vm.ensureHeapProfiler();
    auto& heapProfiler = *vm.heapProfiler();
    heapProfiler.clearSnapshots();

    Bun::Bindgen::ZigExports::bunBindgenZig_Analytics_recordHeapSnapshot();

    auto throwScope = DECLARE_THROW_SCOPE(vm);
    bool useV8 = args.format == BunHeapSnapshotFormat::v8;
    bool useArrayBuffer = args.output == BunHeapSnapshotOutput::arraybuffer;
    Bindgen::BunHeapSnapshotResult result;

    if (useV8) {
        if (useArrayBuffer) {
            JSC::BunV8HeapSnapshotBuilder builder(heapProfiler);
            auto bytes = builder.jsonBytes();
            auto released = bytes.releaseBuffer();
            auto span = released.leakSpan();
            auto buffer = ArrayBuffer::createFromBytes(std::span<const uint8_t> { span.data(), span.size() }, createSharedTask<void(void*)>([](void* p) {
                fastFree(p);
            }));
            result.set_array_buffer(JSC::JSArrayBuffer::create(vm, globalObject->arrayBufferStructure(), WTF::move(buffer)));
            throwScope.release();
            return result;
        }

        JSC::BunV8HeapSnapshotBuilder builder(heapProfiler);
        result.set_text(builder.json());
        throwScope.release();
        return result;
    }

    JSC::HeapSnapshotBuilder builder(heapProfiler);
    builder.buildSnapshot();
    auto json = builder.json();
    JSC::JSValue jsonValue = JSONParseWithException(globalObject, json);
    RETURN_IF_EXCEPTION(throwScope, {});
    RELEASE_ASSERT(jsonValue.isObject());
    result.set_snapshot(jsonValue);
    throwScope.release();
    return result;
}

WTF::String Bindgen::Cpp::bunBindgenCpp_BunObject_fileURLToPath(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_fileURLToPath_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (args.url.is_string()) {
        WTF::URL url { args.url.string() };
        if (!url.protocolIsFile()) {
            Bun::ERR::INVALID_URL_SCHEME(scope, globalObject, "file"_s);
            return {};
        }
        RELEASE_AND_RETURN(scope, Bun::Bindgen::fileURLToPath(*globalObject, url));
    }

    auto domURL = WebCore::protectedDOMURL(globalObject, args.url.object());
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(domURL);
    auto snapshot = domURL->href();
    if (snapshot.hasException()) {
        WebCore::propagateException(*globalObject, scope, snapshot.releaseException());
        return {};
    }
    RELEASE_AND_RETURN(scope, Bun::Bindgen::fileURLToPath(*globalObject, snapshot.releaseReturnValue()));
}

class JSBunObject : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    JSBunObject(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    DECLARE_INFO;

    static constexpr JSC::DestructionMode needsDestruction = DoesNotNeedDestruction;
    static constexpr unsigned StructureFlags = Base::StructureFlags | HasStaticPropertyTable;

    template<typename CellType, JSC::SubspaceAccess>
    static JSC::GCClient::IsoSubspace* subspaceFor(JSC::VM& vm)
    {
        STATIC_ASSERT_ISO_SUBSPACE_SHARABLE(JSBunObject, Base);
        return &vm.plainObjectSpace();
    }
    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue prototype)
    {
        return JSC::Structure::create(vm, globalObject, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    void finishCreation(JSC::VM& vm);

    static JSBunObject* create(JSC::VM& vm, JSGlobalObject* globalObject)
    {
        auto structure = createStructure(vm, globalObject, globalObject->objectPrototype());
        auto* object = new (NotNull, JSC::allocateCell<JSBunObject>(vm)) JSBunObject(vm, structure);
        object->finishCreation(vm);
        return object;
    }
};

#define BUN_BINDGEN_OBJECT_SURFACE_BunObject
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_BunObject

const JSC::ClassInfo JSBunObject::s_info = { "Bun"_s, &Base::s_info, &bunBindgenObjectSurface_BunObjectTable, nullptr, CREATE_METHOD_TABLE(JSBunObject) };

void JSBunObject::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_BunObject_install(vm, info(), *this);
    JSC_TO_STRING_TAG_WITHOUT_TRANSITION();
}

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, ReturnType, Callback)     \
    ReturnType Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                    \
        Bindgen::CppCallContext& context,                                            \
        const Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)   \
    {                                                                                \
        return Callback(context.globalObject.vm(), JSC::asObject(args.bindingThis)); \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructBunShell, JSC::JSValue, constructBunShell)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructEnvObject, JSC::JSValue, constructEnvObject)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructIsMainThread, bool, constructIsMainThread)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructBunVersionWithSha, WTF::String, constructBunVersionWithSha)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructBunRevision, WTF::String, constructBunRevision)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, defaultBunSQLObject, JSC::JSValue, defaultBunSQLObject)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructBunSQLObject, JSC::JSValue, constructBunSQLObject)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(BunObject, constructBunVersion, WTF::String, constructBunVersion)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunObject_bunStderr(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_bunStderr_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->bunStderr();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunObject_bunStdin(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_bunStdin_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->bunStdin();
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_BunObject_bunStdout(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_BunObject_bunStdout_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->bunStdout();
}

void Bindgen::Engine::bunBindgenEngine_BunObject_preconnectDefaultSQL(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunObject_preconnectDefaultSQL_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto sqlValue = defaultBunSQLObject(vm, globalObject->bunObject());
    RETURN_IF_EXCEPTION(scope, );
    RELEASE_ASSERT(sqlValue.isObject());
    auto* sqlObject = sqlValue.getObject();
    auto connect = sqlObject->get(globalObject, Identifier::fromString(vm, "connect"_s));
    RETURN_IF_EXCEPTION(scope, );
    auto callData = JSC::getCallData(connect);
    RELEASE_ASSERT_WITH_MESSAGE(connect.isCallable() && callData.type != JSC::CallData::Type::None, "Bun.sql.connect must be callable");
    JSC::profiledCall(globalObject, ProfilingReason::API, connect, callData, sqlObject, ArgList());
    RETURN_IF_EXCEPTION(scope, );
}

JSC::JSValue Bindgen::Engine::bunBindgenEngine_BunObject_defaultRedisClient(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_BunObject_defaultRedisClient_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    return bunBindgenObjectSurface_BunObject_defaultRedisClient(globalObject->vm(), globalObject->bunObject());
}

JSC::JSObject* createBunObject(VM& vm, JSObject* globalObject)
{
    return JSBunObject::create(vm, uncheckedDowncast<Zig::GlobalObject>(globalObject));
}

} // namespace Bun
