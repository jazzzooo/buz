#include "ModuleLoader.h"
#include "napi.h"

#include "BunProcess.h"
#include "../../libc_sys/BunCloseRange.h"
#include "../../libc_sys/BunProcessMemory.h"
#include "DLHandleMap.h"
#include "WebCoreJSBuiltins.h"
#include "v8/node.h"

// Include the CMake-generated dependency versions header
#include "bun_dependency_versions.h"
#include <JavaScriptCore/InternalFieldTuple.h>
#include <JavaScriptCore/JSMicrotask.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/NumberPrototype.h>
#include <JavaScriptCore/OperationsInlines.h>
#include "JSCommonJSModule.h"
#include "SchemaBindingsErrorCodes.h"
#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/CallData.h"
#include "JavaScriptCore/TopExceptionScope.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSCast.h"
#include "JavaScriptCore/JSMap.h"
#include "JavaScriptCore/JSMapInlines.h"
#include "JavaScriptCore/JSObjectInlines.h"
#include "JavaScriptCore/JSString.h"
#include "JavaScriptCore/JSType.h"
#include "JavaScriptCore/MathCommon.h"
#include "JavaScriptCore/Protect.h"
#include "JavaScriptCore/PutPropertySlot.h"
#include "ScriptExecutionContext.h"
#include "ZigGlobalObject.h"
#include "FormatStackTraceForJS.h"
#include "JSEnvironmentVariableMap.h"
#include "ImportMetaObject.h"
#include "JSDOMOperation.h"
#include "JavaScriptCore/ScriptCallStackFactory.h"
#include "JavaScriptCore/ConsoleMessage.h"
#include "JavaScriptCore/InspectorConsoleAgent.h"
#include "JavaScriptCore/JSGlobalObjectDebuggable.h"
#include <JavaScriptCore/StackFrame.h>
#include <sys/stat.h>
#include <limits>
#include "ConsoleObject.h"
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/LazyProperty.h>
#include <JavaScriptCore/LazyPropertyInlines.h>
#include <JavaScriptCore/VMTrapsInlines.h>
#include "wtf-bindings.h"
#include "EventLoopTask.h"
#include <JavaScriptCore/StructureCache.h>

#include <webcore/SerializedScriptValue.h>
#include "ProcessBindingTTYWrap.h"
#include "wtf/text/ASCIILiteral.h"
#include "wtf/text/StringToIntegerConversion.h"
#include "wtf/text/OrdinalNumber.h"
#include "NodeValidator.h"
#include "NodeModuleModule.h"
#include "JSX509Certificate.h"
#include "SchemaBindings.h"
#include "StringConversion.h"
#include <wtf/Scope.h>
#include <memory>
#include <new>

#include "AsyncContextFrame.h"
#include "ErrorBindings.h"
#include "ErrorCode.h"

#include "napi_handle_scope.h"
#include "napi_external.h"

#ifndef WIN32
#include <errno.h>
#include <dlfcn.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/utsname.h>
#include <sys/types.h>
#include <grp.h>
#include <pwd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#else
#include <uv.h>
#include <io.h>
#include <fcntl.h>
// Using the same typedef and define for `mode_t` and `umask` as node on windows.
// https://github.com/nodejs/node/blob/ad5e2dab4c8306183685973387829c2f69e793da/src/node_process_methods.cc#L29
#define umask _umask
typedef int mode_t;
#endif
#include "JSNextTickQueue.h"
#include "ProcessBindingUV.h"
#include "ProcessBindingNatives.h"

#if OS(LINUX)
#include <features.h>
#ifdef __GNU_LIBRARY__
#include <gnu/libc-version.h>
#endif
#endif

#if ASSERT_ENABLED
#include <JavaScriptCore/IntegrityInlines.h>
#endif

#pragma mark - Node.js Process

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <spawn.h>
#endif

#if defined(__linux__) || defined(__FreeBSD__)
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <fcntl.h>
#endif

#if defined(__FreeBSD__)
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#endif

#if !defined(_MSC_VER)
#include <unistd.h> // setuid, getuid
#endif

#include <cstring>
#include <atomic>

namespace Bun {

static std::atomic_bool processNoDeprecationFlag { false };
static std::atomic_bool processThrowDeprecationFlag { false };

bool Process::noDeprecation()
{
    return processNoDeprecationFlag.load(std::memory_order_relaxed);
}

void Process::setNoDeprecation(bool value)
{
    processNoDeprecationFlag.store(value, std::memory_order_relaxed);
}

bool Process::throwDeprecation()
{
    return processThrowDeprecationFlag.load(std::memory_order_relaxed);
}

void Process::setThrowDeprecation(bool value)
{
    processThrowDeprecationFlag.store(value, std::memory_order_relaxed);
}

void Bindgen::Engine::bunBindgenEngine_Process_setProcessNoDeprecation(
    const BunBindgenEngine_Process_setProcessNoDeprecation_Arguments& args)
{
    Process::setNoDeprecation(args.value);
}

void Bindgen::Engine::bunBindgenEngine_Process_setProcessThrowDeprecation(
    const BunBindgenEngine_Process_setProcessThrowDeprecation_Arguments& args)
{
    Process::setThrowDeprecation(args.value);
}

using namespace JSC;

#define processObjectBindingCodeGenerator processObjectInternalsBindingCodeGenerator
#define setProcessObjectInternalsMainModuleCodeGenerator processObjectInternalsSetMainModuleCodeGenerator
#define setProcessObjectMainModuleCodeGenerator setMainModuleCodeGenerator

#if !defined(BUN_WEBKIT_VERSION)
#define BUN_WEBKIT_VERSION "unknown"
#endif

using JSGlobalObject = JSC::JSGlobalObject;
using Exception = JSC::Exception;
using JSValue = JSC::JSValue;
using JSString = JSC::JSString;
using JSModuleLoader = JSC::JSModuleLoader;
using JSModuleRecord = JSC::JSModuleRecord;
using Identifier = JSC::Identifier;
using SourceOrigin = JSC::SourceOrigin;
using JSObject = JSC::JSObject;
using JSNonFinalObject = JSC::JSNonFinalObject;
namespace JSCastingHelpers = JSC::JSCastingHelpers;

static void processEmitErrorEvent(Zig::GlobalObject*, JSValue);

static Process* processObject(JSValue value);
static Process* processObject(const std::optional<JSValue>& value);
static Process* getProcessObject(JSC::JSGlobalObject* lexicalGlobalObject, const Bindgen::ProcessObjectReceiverInput& input);

static ASCIILiteral processArch()
{
#if CPU(X86_64)
    return "x64"_s;
#elif CPU(ARM64)
    return "arm64"_s;
#else
#error "Unknown architecture"
#endif
}

static ASCIILiteral processPlatform()
{
#if defined(__APPLE__)
    return "darwin"_s;
#elif defined(__ANDROID__)
    return "android"_s;
#elif defined(__linux__)
    return "linux"_s;
#elif defined(__FreeBSD__)
    return "freebsd"_s;
#elif OS(WINDOWS)
    return "win32"_s;
#else
#error "Unknown platform"
#endif
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructArch(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructArch_Arguments&)
{
    return processArch();
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructPlatform(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructPlatform_Arguments&)
{
    return processPlatform();
}

static constexpr auto processVersionNode = ASCIILiteral::fromLiteralUnsafe(REPORTED_NODEJS_VERSION);
static const auto processVersionBoringSSL = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_BORINGSSL);
static const auto processVersionLibarchive = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_LIBARCHIVE);
static const auto processVersionMimalloc = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_MIMALLOC);
static const auto processVersionPicoHTTPParser = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_PICOHTTPPARSER);
static const auto processVersionUWebSockets = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_UWS);
static const auto processVersionWebKit = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_WEBKIT);
static const auto processVersionZig = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_ZIG);
static const auto processVersionZlib = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_ZLIB_HASH);
static const auto processVersionTinyCC = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_TINYCC);
static const auto processVersionLOLHTML = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_LOLHTML);
static const auto processVersionCAres = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_C_ARES);
static const auto processVersionLibdeflate = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_LIBDEFLATE_HASH);
static const auto processVersionUSockets = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_USOCKETS);
static const auto processVersionLSHPack = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_LSHPACK);
static const auto processVersionZstd = ASCIILiteral::fromLiteralUnsafe(BUN_VERSION_ZSTD_HASH);
static constexpr auto processVersionV8 = ASCIILiteral::fromLiteralUnsafe(REPORTED_NODEJS_V8_VERSION);
static constexpr auto processVersionICU = ASCIILiteral::fromLiteralUnsafe(U_ICU_VERSION);
static constexpr auto processVersionUnicode = ASCIILiteral::fromLiteralUnsafe(U_UNICODE_VERSION);
#define BUN_PROCESS_STRINGIFY_IMPL(value) #value
#define BUN_PROCESS_STRINGIFY(value) BUN_PROCESS_STRINGIFY_IMPL(value)
static constexpr auto processVersionModules = ASCIILiteral::fromLiteralUnsafe(BUN_PROCESS_STRINGIFY(REPORTED_NODEJS_ABI_VERSION));
#undef BUN_PROCESS_STRINGIFY
#undef BUN_PROCESS_STRINGIFY_IMPL
static constexpr auto processHeadersURL = "https://nodejs.org/download/release/v" REPORTED_NODEJS_VERSION "/node-v" REPORTED_NODEJS_VERSION "-headers.tar.gz"_s;

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_processVersionsBun(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processVersionsBun_Arguments&)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_Process_version().substring(1);
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_processVersionsUV(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processVersionsUV_Arguments&)
{
#if OS(WINDOWS)
    return String::fromLatin1(uv_version_string());
#else
    return "1.48.0"_s;
#endif
}

static constexpr bool processDebugFeature =
#ifdef BUN_DEBUG
    true;
#else
    false;
#endif

static constexpr int processConfigNodeModuleVersion = REPORTED_NODEJS_ABI_VERSION;
static constexpr int processConfigNapiBuildVersion = Napi::DEFAULT_NAPI_VERSION;
static const auto processConfigArchitecture = processArch();
#if OS(MACOS)
static constexpr int processConfigClang = 1;
#else
static constexpr int processConfigClang = 0;
#endif

#define BUN_BINDGEN_OBJECT_SURFACE_BunProcess
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_BunProcess

static void dispatchExitInternal(JSC::JSGlobalObject* globalObject, Process* process, int exitCode)
{
    static bool processIsExiting = false;
    if (processIsExiting)
        return;
    processIsExiting = true;
    auto& emitter = process->wrapped();
    auto& vm = JSC::getVM(globalObject);

    if (vm.hasTerminationRequest() || vm.hasExceptionsAfterHandlingTraps())
        return;

    auto event = Identifier::fromString(vm, "exit"_s);
    if (!emitter.hasEventListeners(event)) {
        return;
    }
    process->putDirect(vm, Identifier::fromString(vm, "_exiting"_s), jsBoolean(true), 0);

    MarkedArgumentBuffer arguments;
    arguments.append(jsNumber(exitCode));
    emitter.emit(event, arguments);
}

static Expected<std::unique_ptr<char[]>, WTF::UTF8ConversionError> toFileURI(std::span<const uint8_t> path)
{
    auto needs_escape = [](char ch) {
        return !(('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ('0' <= ch && ch <= '9')
            || ch == '_' || ch == '-' || ch == '.' || ch == '!' || ch == '~' || ch == '*' || ch == '\'' || ch == '(' || ch == ')' || ch == '/' || ch == ':');
    };

    auto to_hex = [](uint8_t nybble) -> char {
        if (nybble < 0xa) {
            return '0' + nybble;
        }

        return 'a' + (nybble - 0xa);
    };

#if OS(WINDOWS)
    constexpr auto prefix = "file:///"_s;
#else
    constexpr auto prefix = "file://"_s;
#endif
    WTF::CheckedSize stringSize = path.size();
    stringSize += prefix.length();
    stringSize += size_t { 1 };
    for (char ch : path) {
#if OS(WINDOWS)
        if (needs_escape(ch) && ch != '\\') {
#else
        if (needs_escape(ch)) {
#endif
            stringSize += size_t { 2 };
        }
    }

    if (stringSize.hasOverflowed())
        return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
    std::unique_ptr<char[]> characters(new (std::nothrow) char[stringSize.value()]);
    if (!characters)
        return WTF::makeUnexpected(WTF::UTF8ConversionError::OutOfMemory);
    memcpy(characters.get(), prefix.span().data(), prefix.length());
    size_t i = prefix.length();
    for (char ch : path) {
#if OS(WINDOWS)
        if (ch == '\\') {
            characters[i++] = '/';
            continue;
        }
#endif
        if (needs_escape(ch)) {
            characters[i++] = '%';
            characters[i++] = to_hex(static_cast<uint8_t>(ch) >> 4);
            characters[i++] = to_hex(ch & 0xf);
        } else {
            characters[i++] = ch;
        }
    }

    characters[i] = '\0';
    ASSERT(i + 1 == stringSize.value());
    return characters;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_dlopen(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_dlopen_Arguments& args)
{
    auto* globalObject_ = &context.globalObject;
    Zig::GlobalObject* globalObject = static_cast<Zig::GlobalObject*>(globalObject_);
    auto callCountAtStart = globalObject->napiModuleRegisterCallCount;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(globalObject));
    auto& vm = JSC::getVM(globalObject);

    if (!Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineAllowAddons(globalObject->bunVM())) {
        return JSValue::decode(ERR::DLOPEN_DISABLED(scope, globalObject, "Cannot load native addon because loading addons is disabled."_s));
    }

    if (!args.module || !args.filename) {
        JSC::throwTypeError(globalObject, scope, "dlopen requires 2 arguments"_s);
        return {};
    }

    const auto* module = args.module->convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!module)
        return {};
    JSC::JSObject* moduleObject = module->getObject();

    JSValue exports = moduleObject->getIfPropertyExists(globalObject, builtinNames(vm).exportsPublicName());
    RETURN_IF_EXCEPTION(scope, {});

    if (!exports) [[unlikely]] {
        JSC::throwTypeError(globalObject, scope, "dlopen requires an object with an exports property"_s);
        return {};
    }

    Strong<JSC::Unknown> strongExports;

    if (exports.isCell()) {
        strongExports = { vm, exports.asCell() };
    }

    Strong<JSC::JSObject> strongModule = { vm, moduleObject };

    const auto* convertedFilename = args.filename->convert();
    RETURN_IF_EXCEPTION(scope, {});
    if (!convertedFilename)
        return {};
    WTF::String filename = *convertedFilename;

    if (filename.isEmpty() && !scope.exception()) {
        JSC::throwTypeError(globalObject, scope, "dlopen requires a non-empty string as the second argument"_s);
    }

    RETURN_IF_EXCEPTION(scope, {});

    if (filename.startsWith("file://"_s)) {
        WTF::URL fileURL = WTF::URL(filename);
        if (!fileURL.isValid() || !fileURL.protocolIsFile()) {
            JSC::throwTypeError(globalObject, scope, "invalid file: URL passed to dlopen"_s);
            return {};
        }

        filename = fileURL.fileSystemPath();
    }

    globalObject->m_pendingNapiModuleAndExports[0].set(vm, globalObject, moduleObject);
    globalObject->m_pendingNapiModuleAndExports[1].set(vm, globalObject, exports);

    Vector<uint8_t> utf8;

    // Support embedded .node files
    // See StandaloneModuleGraph.zig for what this "$bunfs" thing is
#if OS(WINDOWS)
#define StandaloneModuleGraph__base_path "B:/~BUN/"_s
#else
#define StandaloneModuleGraph__base_path "/$bunfs/"_s
#endif
    bool deleteAfter = false;
    if (filename.startsWith(StandaloneModuleGraph__base_path)) {
        auto resolved = Bun::Bindgen::ZigExports::bunBindgenZig_ModuleLoader_resolveEmbeddedNodeFile(globalObject->bunVM(), filename);
        RETURN_IF_EXCEPTION(scope, {});
        if (!resolved) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        if (*resolved) {
            filename = WTF::move(**resolved);
            deleteAfter = !filename.startsWith("/proc/"_s);
        }
    }

    RETURN_IF_EXCEPTION(scope, {});

    // For bun build --compile, we copy the .node file to a temp directory.
    // It's best to delete it as soon as we can.
    // https://github.com/oven-sh/bun/issues/19550
    const auto tryToDeleteIfNecessary = [&]() {
#if OS(WINDOWS)
        if (deleteAfter) {
            // Only call it once
            deleteAfter = false;
            if (filename.is8Bit()) {
                filename.convertTo16Bit();
            }

            // Convert to 16-bit with a sentinel zero value.
            auto span = filename.span16();
            auto dupeZ = new wchar_t[span.size() + 1];
            if (dupeZ) {
                memcpy(dupeZ, span.data(), span.size_bytes());
                dupeZ[span.size()] = L'\0';

                // We can't immediately delete the file on Windows.
                // Instead, we mark it for deletion on reboot.
                MoveFileExW(
                    dupeZ,
                    NULL, // NULL destination means delete
                    MOVEFILE_DELAY_UNTIL_REBOOT);
                delete[] dupeZ;
            }
        }
#else
        if (deleteAfter) {
            deleteAfter = false;
            (void)::unlink(reinterpret_cast<const char*>(utf8.span().data()));
        }
#endif
    };

    // Handle known yet-to-be-working in Bun
    {
        static constexpr ASCIILiteral better_sqlite3_node = "better_sqlite3.node"_s;
        static constexpr ASCIILiteral better_sqlite3_message = "'better-sqlite3' is not yet supported in Bun.\nTrack the status in https://github.com/oven-sh/bun/issues/4290\nIn the meantime, you could try bun:sqlite which has a similar API."_s;
        if (filename.endsWith(better_sqlite3_node)) {
            return JSValue::decode(throwError(globalObject, scope, ErrorCode::ERR_DLOPEN_FAILED,
                better_sqlite3_message));
        }
    }

    {
        auto utf8_filename = encodeUTF8ReplacingInvalidSequences(filename, UTF8Termination::Null);
        if (!utf8_filename) [[unlikely]] {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        utf8 = WTF::move(*utf8_filename);
    }
    auto deleteEmbeddedFileOnExit = WTF::makeScopeExit(tryToDeleteIfNecessary);
    auto filenameURI = toFileURI(utf8.span().first(utf8.size() - 1));
    if (!filenameURI) {
        JSC::throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    Bun::Bindgen::ZigExports::bunBindgenZig_Analytics_recordProcessDlopen();

#if OS(WINDOWS)
    HMODULE handle = reinterpret_cast<HMODULE>(
        Bun::Bindgen::ZigExports::bunBindgenZig_windows_dynamic_library_windowsLoadLibrary(filename).value_or(nullptr));

// On Windows, we use GetLastError() for error messages, so we can only delete after checking for errors
#else
    void* handle;
    {
        auto crashScopeResult = Bun::Bindgen::ZigExports::bunBindgenZig_CrashHandlerBindings_crashHandlerBeginDlopen(
            utf8.span().first(utf8.size() - 1));
        if (!crashScopeResult) {
            JSC::throwOutOfMemoryError(globalObject, scope);
            return {};
        }
        Bun::Bindgen::ByteOwner crashScope { std::exchange(*crashScopeResult, nullptr) };
        handle = dlopen(reinterpret_cast<const char*>(utf8.span().data()), RTLD_LAZY);
    }

    tryToDeleteIfNecessary();
#endif

    globalObject->m_pendingNapiModuleDlopenHandle = handle;

    if (!handle) {
#if OS(WINDOWS)
        DWORD errorId = GetLastError();
        LPWSTR messageBuffer = nullptr;
        DWORD charCount = FormatMessageW(
            FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | FORMAT_MESSAGE_MAX_WIDTH_MASK, // Prevents automatic line breaks
            NULL, // No source needed when using FORMAT_MESSAGE_FROM_SYSTEM
            errorId,
            MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), // Default language
            (LPWSTR)&messageBuffer, // Buffer will be allocated by the function
            0, // Minimum size to allocate - 0 means "determine size automatically"
            NULL // No arguments since we're using FORMAT_MESSAGE_IGNORE_INSERTS
        );

        WTF::StringBuilder errorBuilder;
        errorBuilder.append("LoadLibrary failed: "_s);
        if (messageBuffer && charCount > 0) {
            // Trim trailing whitespace, carriage returns, and newlines that FormatMessageW often includes
            while (charCount > 0 && (messageBuffer[charCount - 1] == L'\r' || messageBuffer[charCount - 1] == L'\n' || messageBuffer[charCount - 1] == L' '))
                charCount--;

            errorBuilder.append(WTF::StringView(messageBuffer, charCount, false));
        } else {
            errorBuilder.append("error code "_s);
            errorBuilder.append(WTF::String::number(errorId));
        }

        WTF::String msg = errorBuilder.toString();
        if (messageBuffer)
            LocalFree(messageBuffer); // Free the buffer allocated by FormatMessageW

        // Since we're relying on LastError(), we have to delete after checking for errors
        tryToDeleteIfNecessary();
#else
        WTF::String msg = WTF::String::fromUTF8(dlerror());
#endif
        return JSValue::decode(throwError(globalObject, scope, ErrorCode::ERR_DLOPEN_FAILED, msg));
    }

#if OS(WINDOWS)
    tryToDeleteIfNecessary();
#endif

    if (callCountAtStart != globalObject->napiModuleRegisterCallCount) {
        // Module self-registered via static constructor(s).
        // Move pending registrations into locals before iterating: an
        // nm_register_func can itself call napi_module_register(), which
        // appends to m_pendingNapiModules. Appending to a WTF::Vector while
        // range-for iterating it reallocates the buffer and leaves the
        // iterator dangling.
        auto pendingNapiModules = std::exchange(globalObject->m_pendingNapiModules, {});
        auto pendingV8Modules = std::exchange(globalObject->m_pendingV8Modules, {});

        if (handle) {
            // Save all NAPI module registrations
            for (auto& mod : pendingNapiModules) {
                auto* heapModule = new napi_module(mod);
                Bun::DLHandleMap::singleton().add(handle, heapModule);
            }

            // Save all V8 C++ module registrations
            for (auto* mod : pendingV8Modules) {
                Bun::DLHandleMap::singleton().add(handle, mod);
            }
        }

        // Execute all NAPI modules. If an nm_register_func registers more
        // modules re-entrantly, they accumulate back in m_pendingNapiModules;
        // drain those too once the current batch is done.
        for (;;) {
            for (auto& mod : pendingNapiModules) {
                // Restore dlopen handle for this module before execution
                // executePendingNapiModule clears it, so we must set it for each module
                globalObject->m_pendingNapiModuleDlopenHandle = handle;
                globalObject->m_pendingNapiModule = mod;
                Napi::executePendingNapiModule(globalObject);
                globalObject->m_pendingNapiModule = {};
            }
            if (globalObject->m_pendingNapiModules.isEmpty())
                break;
            pendingNapiModules = std::exchange(globalObject->m_pendingNapiModules, {});
        }

        // Clear any re-entrant V8 registrations (not executed here).
        globalObject->m_pendingV8Modules.clear();

        JSValue resultValue = globalObject->m_pendingNapiModuleAndExports[0].get();
        globalObject->napiModuleRegisterCallCount = 0;
        globalObject->m_pendingNapiModuleAndExports[0].clear();
        globalObject->m_pendingNapiModuleAndExports[1].clear();

        RETURN_IF_EXCEPTION(scope, {});

        if (resultValue && resultValue != strongModule.get()) {
            if (resultValue.isCell() && resultValue.getObject()->isErrorInstance()) {
                JSC::throwException(globalObject, scope, resultValue);
                return {};
            }
        }

        return jsUndefined();
    }

    // Module didn't self-register on this load. Check if we have cached registrations.
    if (auto cachedModules = Bun::DLHandleMap::singleton().get(handle)) {
        // Replay all registrations from this handle
        // This will populate the vectors again via register functions
        for (auto& registration : *cachedModules) {
            std::visit([](auto&& mod) {
                using T = std::decay_t<decltype(mod)>;
                if constexpr (std::is_same_v<T, node::node_module*>) {
                    node::node_module_register(mod);
                } else if constexpr (std::is_same_v<T, napi_module*>) {
                    napi_module_register(mod);
                }
            },
                registration);
        }

        // Execute all NAPI modules that were just registered. Move to a
        // local first and drain so re-entrant napi_module_register() calls
        // from inside nm_register_func can't invalidate our iterator.
        while (!globalObject->m_pendingNapiModules.isEmpty()) {
            auto pendingNapiModules = std::exchange(globalObject->m_pendingNapiModules, {});
            for (auto& mod : pendingNapiModules) {
                // Restore dlopen handle for this module before execution
                // executePendingNapiModule clears it, so we must set it for each module
                globalObject->m_pendingNapiModuleDlopenHandle = handle;
                globalObject->m_pendingNapiModule = mod;
                Napi::executePendingNapiModule(globalObject);
                globalObject->m_pendingNapiModule = {};
            }
        }

        // Clear the V8 vector (no need to save again since already in DLHandleMap)
        globalObject->m_pendingV8Modules.clear();

        JSValue resultValue = globalObject->m_pendingNapiModuleAndExports[0].get();
        globalObject->napiModuleRegisterCallCount = 0;
        globalObject->m_pendingNapiModuleAndExports[0].clear();
        globalObject->m_pendingNapiModuleAndExports[1].clear();

        RETURN_IF_EXCEPTION(scope, {});

        if (resultValue && resultValue != strongModule.get()) {
            if (resultValue.isCell() && resultValue.getObject()->isErrorInstance()) {
                JSC::throwException(globalObject, scope, resultValue);
                return {};
            }
        }

        return jsUndefined();
    }

#if OS(WINDOWS)
#define dlsym GetProcAddress
#endif

    // TODO(@190n) look for node_register_module_vXYZ according to BuildOptions.reported_nodejs_version
    // (bun/src/env.zig:36) and the table at https://github.com/nodejs/node/blob/main/doc/abi_version_registry.json
    auto napi_register_module_v1 = reinterpret_cast<napi_value (*)(napi_env, napi_value)>(dlsym(handle, "napi_register_module_v1"));

    auto node_api_module_get_api_version_v1 = reinterpret_cast<int32_t (*)()>(dlsym(handle, "node_api_module_get_api_version_v1"));

#if OS(WINDOWS)
#undef dlsym
#endif

    if (!napi_register_module_v1) {
#if OS(WINDOWS)
        FreeLibrary(handle);
#else
        dlclose(handle);
#endif

        if (!scope.exception()) [[likely]] {
            JSC::throwTypeError(globalObject, scope, "symbol 'napi_register_module_v1' not found in native module. Is this a Node API (napi) module?"_s);
        }
        return {};
    }

    // TODO(@heimskr): get the API version without node_api_module_get_api_version_v1 a different way
    int module_version = 8;
    if (node_api_module_get_api_version_v1) {
        module_version = node_api_module_get_api_version_v1();
    }

    NapiHandleScope handleScope(globalObject);

    EncodedJSValue exportsValue = JSC::JSValue::encode(exports);

    napi_module nmodule {
        .nm_version = module_version,
        .nm_flags = 0,
        .nm_filename = filenameURI->get(),
        .nm_register_func = nullptr,
        .nm_modname = "[no modname]",
        .nm_priv = nullptr,
        .reserved = {},
    };

    static_assert(sizeof(napi_value) == sizeof(EncodedJSValue), "EncodedJSValue must be reinterpretable as a pointer");

    auto env = globalObject->makeNapiEnv(nmodule);
    env->filename = filenameURI->release();

    auto encoded = reinterpret_cast<EncodedJSValue>(napi_register_module_v1(env.ptr(), reinterpret_cast<napi_value>(exportsValue)));
    if (env->throwPendingException()) {
        return {};
    }
    RETURN_IF_EXCEPTION(scope, {});
    JSC::JSValue resultValue = encoded == 0 ? exports : JSValue::decode(encoded);

    if (auto resultObject = resultValue.getObject()) {
#if OS(DARWIN) || OS(LINUX) || OS(FREEBSD)
        // If this is a native bundler plugin we want to store the handle from dlopen
        // as we are going to call `dlsym()` on it later to get the plugin implementation.
        const char** pointer_to_plugin_name = (const char**)dlsym(handle, "BUN_PLUGIN_NAME");
#elif OS(WINDOWS)
        const char** pointer_to_plugin_name = (const char**)GetProcAddress(handle, "BUN_PLUGIN_NAME");
#endif
        if (pointer_to_plugin_name) {
            // TODO: think about the finalizer here
            // currently we do not dealloc napi modules so we don't have to worry about it right now
            auto* meta = new Bun::NapiModuleMeta(globalObject->m_pendingNapiModuleDlopenHandle);
            Bun::NapiExternal* napi_external = Bun::NapiExternal::create(vm, globalObject->NapiExternalStructure(), meta, nullptr, nullptr, env.ptr());
            bool success = resultObject->putDirect(vm, WebCore::builtinNames(vm).napiDlopenHandlePrivateName(), napi_external, JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly);
            ASSERT(success);
            RETURN_IF_EXCEPTION(scope, {});
        }
    }

    globalObject->m_pendingNapiModuleAndExports[0].clear();
    globalObject->m_pendingNapiModuleAndExports[1].clear();
    globalObject->m_pendingNapiModuleDlopenHandle = nullptr;

    // https://github.com/nodejs/node/blob/2eff28fb7a93d3f672f80b582f664a7c701569fb/src/node_api.cc#L734-L742
    // https://github.com/oven-sh/bun/issues/1288
    if (!resultValue.isEmpty() && !scope.exception() && (!strongExports || resultValue != strongExports.get())) {
        PutPropertySlot slot(strongModule.get(), false);
        strongModule->put(strongModule.get(), globalObject, builtinNames(vm).exportsPublicName(), resultValue, slot);
    }

    return resultValue;
}

uint32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_umask(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_umask_Arguments& args)
{
    if (!args.mask.has_value()) {
        mode_t currentMask = umask(0);
        umask(currentMask);
        return currentMask;
    }
    return umask(args.mask.value());
}

// https://github.com/nodejs/node/blob/1936160c31afc9780e4365de033789f39b7cbc0c/src/api/hooks.cc#L49
static void processDispatchOnBeforeExit(Zig::GlobalObject* globalObject, uint8_t exitCode)
{
    if (!globalObject->hasProcessObject()) {
        return;
    }
    auto& vm = JSC::getVM(globalObject);
    auto* process = globalObject->processObject();
    MarkedArgumentBuffer arguments;
    arguments.append(jsNumber(exitCode));
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineExitDuringUncaughtException(bunVM(vm));
    auto fired = process->wrapped().emit(Identifier::fromString(vm, "beforeExit"_s), arguments);
    if (fired) {
        if (globalObject->m_nextTickQueue) {
            auto nextTickQueue = globalObject->m_nextTickQueue.get();
            nextTickQueue->drain(vm, globalObject);
        }
    }
}

static void processDispatchOnExit(Zig::GlobalObject* globalObject, uint8_t exitCode)
{
    if (!globalObject->hasProcessObject()) {
        return;
    }

    auto* process = globalObject->processObject();
    if (exitCode > 0)
        process->m_isExitCodeObservable = true;
    dispatchExitInternal(globalObject, process, exitCode);
}

static void applyProcessExitCode(Process* process, uint8_t code)
{
    process->m_isExitCodeObservable = true;
    Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineSetExitCode(process->globalObject()->bunVM(), code);
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_exit(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_exit_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(globalObject);
    auto process = zigGlobal->processObject();

    if (args.code)
        applyProcessExitCode(process, *args.code);

    auto exitCode = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineGetExitCode(bunVM(zigGlobal));
    processDispatchOnExit(zigGlobal, exitCode);

    // process.reallyExit(exitCode);
    auto reallyExitVal = process->get(globalObject, Identifier::fromString(vm, "reallyExit"_s));
    RETURN_IF_EXCEPTION(throwScope, void());
    exitCode = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineGetExitCode(bunVM(zigGlobal));
    MarkedArgumentBuffer callArgs;
    callArgs.append(jsNumber(exitCode));
    JSC::call(globalObject, reallyExitVal, callArgs, ""_s);
    RETURN_IF_EXCEPTION(throwScope, void());

    throwScope.release();
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_setUncaughtExceptionCaptureCallback(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setUncaughtExceptionCaptureCallback_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(JSC::getVM(globalObject));
    auto process = globalObject->processObject();

    if (!args.fn) {
        process->setUncaughtExceptionCaptureCallback(JSC::jsNull());
        process->m_reportOnUncaughtException = false;
        return;
    }
    if (process->m_reportOnUncaughtException) {
        Bun::ERR::UNCAUGHT_EXCEPTION_CAPTURE_ALREADY_SET(throwScope, globalObject);
        return;
    }

    process->setUncaughtExceptionCaptureCallback(*args.fn);
    process->m_reportOnUncaughtException = true;
}

WTF::Vector<double> Bindgen::Cpp::bunBindgenCpp_ProcessHost_hrtime(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_hrtime_Arguments& args)
{
    Zig::GlobalObject* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    uint64_t time = Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_readOriginTimer(globalObject->bunVM());
    double seconds = static_cast<double>(time / 1000000000);
    double nanoseconds = static_cast<double>(time % 1000000000);

    if (args.time.has_value()) {
        JSArray* relativeArray = uncheckedDowncast<JSC::JSArray>(args.time.value());
        if (relativeArray->length() != 2) {
            (void)Bun::ERR::OUT_OF_RANGE(throwScope, globalObject, "time"_s, "2"_s, jsNumber(relativeArray->length()));
            return {};
        }

        JSValue relativeSecondsValue = relativeArray->getIndex(globalObject, 0);
        RETURN_IF_EXCEPTION(throwScope, {});
        JSValue relativeNanosecondsValue = relativeArray->getIndex(globalObject, 1);
        RETURN_IF_EXCEPTION(throwScope, {});

        double relativeSeconds = relativeSecondsValue.toNumber(globalObject);
        RETURN_IF_EXCEPTION(throwScope, {});
        double relativeNanoseconds = relativeNanosecondsValue.toNumber(globalObject);
        RETURN_IF_EXCEPTION(throwScope, {});
        seconds -= relativeSeconds;
        nanoseconds -= relativeNanoseconds;
        if (nanoseconds < 0) {
            seconds--;
            nanoseconds += 1000000000;
        }
    }

    WTF::Vector<double> result;
    result.reserveInitialCapacity(2);
    result.append(seconds);
    result.append(nanoseconds);
    return result;
}

uint64_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_hrtimeBigInt(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_hrtimeBigInt_Arguments&)
{
    Zig::GlobalObject* globalObject = defaultGlobalObject(&context.globalObject);
    return Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_readOriginTimer(globalObject->bunVM());
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_chdir(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_chdir_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto cwd = Bun::Bindgen::ZigExports::bunBindgenZig_Process_setCwd(globalObject, args.directory);
    RETURN_IF_EXCEPTION(scope, void());

    auto* processObject = defaultGlobalObject(globalObject)->processObject();
    processObject->setCachedCwd(vm, JSC::jsString(vm, WTF::move(cwd)));
    RELEASE_AND_RETURN(scope, void());
}

// On windows, signals need to have a handle to the uv_signal_t. When sigaction is used, this is kept track globally for you.
struct SignalHandleValue {
#if OS(WINDOWS)
    uv_signal_t* handle;
#endif
};
static HashMap<int, SignalHandleValue>* signalToContextIdsMap = nullptr;

static constexpr struct {
    ASCIILiteral name;
    uint8_t number;
} signalNames[] = {
#ifdef SIGHUP
    { "SIGHUP"_s, SIGHUP },
#endif
#ifdef SIGINT
    { "SIGINT"_s, SIGINT },
#endif
#ifdef SIGQUIT
    { "SIGQUIT"_s, SIGQUIT },
#endif
#ifdef SIGILL
    { "SIGILL"_s, SIGILL },
#endif
#ifdef SIGTRAP
    { "SIGTRAP"_s, SIGTRAP },
#endif
#ifdef SIGABRT
    { "SIGABRT"_s, SIGABRT },
#endif
#ifdef SIGIOT
    { "SIGIOT"_s, SIGIOT },
#endif
#ifdef SIGBUS
    { "SIGBUS"_s, SIGBUS },
#endif
#ifdef SIGFPE
    { "SIGFPE"_s, SIGFPE },
#endif
#ifdef SIGKILL
    { "SIGKILL"_s, SIGKILL },
#endif
#ifdef SIGUSR1
    { "SIGUSR1"_s, SIGUSR1 },
#endif
#ifdef SIGSEGV
    { "SIGSEGV"_s, SIGSEGV },
#endif
#ifdef SIGUSR2
    { "SIGUSR2"_s, SIGUSR2 },
#endif
#ifdef SIGPIPE
    { "SIGPIPE"_s, SIGPIPE },
#endif
#ifdef SIGALRM
    { "SIGALRM"_s, SIGALRM },
#endif
#ifdef SIGTERM
    { "SIGTERM"_s, SIGTERM },
#endif
#ifdef SIGCHLD
    { "SIGCHLD"_s, SIGCHLD },
#endif
#ifdef SIGCONT
    { "SIGCONT"_s, SIGCONT },
#endif
#ifdef SIGSTOP
    { "SIGSTOP"_s, SIGSTOP },
#endif
#ifdef SIGTSTP
    { "SIGTSTP"_s, SIGTSTP },
#endif
#ifdef SIGTTIN
    { "SIGTTIN"_s, SIGTTIN },
#endif
#ifdef SIGTTOU
    { "SIGTTOU"_s, SIGTTOU },
#endif
#ifdef SIGURG
    { "SIGURG"_s, SIGURG },
#endif
#ifdef SIGXCPU
    { "SIGXCPU"_s, SIGXCPU },
#endif
#ifdef SIGXFSZ
    { "SIGXFSZ"_s, SIGXFSZ },
#endif
#ifdef SIGVTALRM
    { "SIGVTALRM"_s, SIGVTALRM },
#endif
#ifdef SIGPROF
    { "SIGPROF"_s, SIGPROF },
#endif
#ifdef SIGWINCH
    { "SIGWINCH"_s, SIGWINCH },
#endif
#ifdef SIGIO
    { "SIGIO"_s, SIGIO },
#endif
#ifdef SIGINFO
    { "SIGINFO"_s, SIGINFO },
#endif
#ifdef SIGSYS
    { "SIGSYS"_s, SIGSYS },
#endif
#ifdef SIGBREAK
    { "SIGBREAK"_s, SIGBREAK },
#endif
#ifdef SIGPWR
    { "SIGPWR"_s, SIGPWR },
#endif
#ifdef SIGSTKFLT
    { "SIGSTKFLT"_s, SIGSTKFLT },
#endif
#ifdef SIGPOLL
    { "SIGPOLL"_s, SIGPOLL },
#endif
};

std::optional<uint8_t> signalNumberForName(WTF::StringView name)
{
    for (const auto& signal : signalNames) {
        if (name == signal.name)
            return signal.number;
    }
    return std::nullopt;
}

bool isSignalName(WTF::String input)
{
    return signalNumberForName(input).has_value();
}

static void emitSignalForJS(int signalNumber, Zig::GlobalObject* globalObject)
{
    Process* process = globalObject->processObject();
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    for (const auto& signal : signalNames) {
        if (signal.number != signalNumber)
            continue;
        auto identifier = Identifier::fromString(vm, signal.name);
        if (!process->wrapped().hasEventListeners(identifier))
            continue;
        MarkedArgumentBuffer args;
        args.append(jsString(vm, identifier.string()));
        args.append(jsNumber(signalNumber));
        process->wrapped().emitForBindings(identifier, args);
        RETURN_IF_EXCEPTION(scope, void());
    }
}

static bool hasSignalListeners(EventEmitter& eventEmitter, int signalNumber)
{
    auto& vm = JSC::getVM(eventEmitter.scriptExecutionContext()->jsGlobalObject());
    for (const auto& signal : signalNames) {
        if (signal.number == signalNumber && eventEmitter.listenerCount(Identifier::fromString(vm, signal.name)))
            return true;
    }
    return false;
}

void Bun::Bindgen::Engine::bunBindgenEngine_ProcessHost_processEmitSignal(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_ProcessHost_processEmitSignal_Arguments& args)
{
    emitSignalForJS(args.signal, uncheckedDowncast<Zig::GlobalObject>(&context.globalObject));
}

#if OS(WINDOWS)
void signalHandler(uv_signal_t* signal, int signalNumber)
{
    auto* context = ScriptExecutionContext::getMainThreadScriptExecutionContext();
    if (!context) [[unlikely]]
        return;
    // uv_signal_t callbacks fire on the uv_run thread (JS thread), but defer to avoid
    // re-entering JS from inside the libuv poll loop
    context->postTaskConcurrently([signalNumber](ScriptExecutionContext& context) {
        emitSignalForJS(signalNumber, uncheckedDowncast<Zig::GlobalObject>(context.jsGlobalObject()));
    });
}
#endif

static bool processHandleUncaughtException(JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSValue exception, bool isRejection)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(lexicalGlobalObject->vm());
    if (!lexicalGlobalObject->inherits(Zig::GlobalObject::info()))
        return false;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto* process = globalObject->processObject();
    auto& wrapped = process->wrapped();
    auto& vm = JSC::getVM(globalObject);

    MarkedArgumentBuffer args;
    args.append(exception);
    if (isRejection) {
        args.append(jsString(vm, String("unhandledRejection"_s)));
    } else {
        args.append(jsString(vm, String("uncaughtException"_s)));
    }
    RETURN_IF_EXCEPTION(scope, true);

    auto uncaughtExceptionMonitor = Identifier::fromString(JSC::getVM(globalObject), "uncaughtExceptionMonitor"_s);
    if (wrapped.listenerCount(uncaughtExceptionMonitor) > 0) {
        wrapped.emit(uncaughtExceptionMonitor, args);
        RETURN_IF_EXCEPTION(scope, true);
    }

    auto uncaughtExceptionIdent = Identifier::fromString(JSC::getVM(globalObject), "uncaughtException"_s);

    // if there is an uncaughtExceptionCaptureCallback, call it and consider the exception handled
    auto capture = process->getUncaughtExceptionCaptureCallback();
    if (!capture.isEmpty() && !capture.isUndefinedOrNull()) {
        (void)call(lexicalGlobalObject, capture, args, "uncaughtExceptionCaptureCallback"_s);
        if (auto ex = scope.exception()) {
            TRY_CLEAR_EXCEPTION(scope, true);
            // if an exception is thrown in the uncaughtException handler, we abort
            Bun::Bindgen::ZigExports::bunBindgenZig_module_run_main_logUnhandledException(globalObject, JSValue(ex));
            Bun::Bindgen::ZigExports::bunBindgenZig_Process_exit(lexicalGlobalObject, 1);
        }
    } else if (wrapped.listenerCount(uncaughtExceptionIdent) > 0) {
        wrapped.emit(uncaughtExceptionIdent, args);
    } else {
        return false;
    }

    return true;
}
static bool promisesIsErrorLike(JSC::JSGlobalObject* globalObject, JSC::JSValue obj)
{
    //   return typeof obj === 'object' &&
    //      obj !== null &&
    //      ObjectPrototypeHasOwnProperty(obj, 'stack');
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto object = obj.getObject();
    if (!object)
        return false;

    RELEASE_AND_RETURN(scope, JSC::objectPrototypeHasOwnProperty(globalObject, object, vm.propertyNames->stack));
}

static WTF::String noSideEffectsToString(JSC::VM& vm, JSC::JSGlobalObject* globalObject, JSC::JSValue reason)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (reason.isSymbol()) {
        auto result = asSymbol(reason)->tryGetDescriptiveString();
        if (result.has_value()) {
            return result.value();
        }
        throwOutOfMemoryError(globalObject, scope);
        return {};
    }

    if (reason.isNumber())
        RELEASE_AND_RETURN(scope, reason.toWTFString(globalObject));
    if (reason.isTrue())
        return "true"_str;
    if (reason.isFalse())
        return "false"_str;
    if (reason.isNull())
        return "null"_str;
    if (reason.isUndefined())
        return "undefined"_str;
    if (reason.isString())
        RELEASE_AND_RETURN(scope, reason.toWTFString(globalObject));
    if (reason.isBigInt())
        RELEASE_AND_RETURN(scope, reason.toWTFString(globalObject));
    return "[object Object]"_str;
}

bool Bindgen::Engine::bunBindgenEngine_promises_promiseIsErrorLike(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_promises_promiseIsErrorLike_Arguments& args)
{
    return promisesIsErrorLike(&context.globalObject, args.reason);
}

WTF::String Bindgen::Engine::bunBindgenEngine_js_strings_noSideEffectsToString(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_js_strings_noSideEffectsToString_Arguments& args)
{
    return noSideEffectsToString(context.globalObject.vm(), &context.globalObject, args.reason);
}

void Bindgen::Engine::bunBindgenEngine_ProcessHost_emitUnhandledRejectionWarning(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_emitUnhandledRejectionWarning_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    auto warning = JSC::createError(globalObject, "Unhandled promise rejection. This error originated either by "
                                                  "throwing inside of an async function without a catch block, "
                                                  "or by rejecting a promise which was not handled with .catch(). "
                                                  "To terminate the bun process on unhandled promise "
                                                  "rejection, use the CLI flag `--unhandled-rejections=strict`."_s);
    RETURN_IF_EXCEPTION(scope, );
    auto warningName = jsString(vm, "UnhandledPromiseRejectionWarning"_str);
    RETURN_IF_EXCEPTION(scope, );
    warning->putDirect(vm, vm.propertyNames->name, warningName, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RETURN_IF_EXCEPTION(scope, );

    JSValue reasonStack {};
    auto isErrorLike = promisesIsErrorLike(globalObject, args.reason);
    RETURN_IF_EXCEPTION(scope, );
    if (isErrorLike) {
        reasonStack = args.reason.get(globalObject, vm.propertyNames->stack);
        RETURN_IF_EXCEPTION(scope, );
        if (reasonStack) {
            warning->putDirect(vm, vm.propertyNames->stack, reasonStack);
            RETURN_IF_EXCEPTION(scope, );
        }
    }
    if (!reasonStack) {
        auto reasonString = noSideEffectsToString(vm, globalObject, args.reason);
        RETURN_IF_EXCEPTION(scope, );
        if (!reasonString.isNull()) {
            reasonStack = jsString(vm, reasonString);
            RETURN_IF_EXCEPTION(scope, );
        }
    }
    if (!reasonStack)
        reasonStack = jsUndefined();

    if (reasonStack.isString()) {
        auto message = asString(reasonStack)->value(globalObject);
        RETURN_IF_EXCEPTION(scope, );
        Process::emitWarning(globalObject, message, "UnhandledPromiseRejectionWarning"_s);
        RETURN_IF_EXCEPTION(scope, );
    }
    Process::emitWarningErrorInstance(globalObject, uncheckedDowncast<ErrorInstance>(warning));
    RETURN_IF_EXCEPTION(scope, );
}

static bool processHandleUnhandledRejection(JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSValue reason, JSC::JSValue promise)
{
    if (!lexicalGlobalObject->inherits(Zig::GlobalObject::info()))
        return false;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto* process = globalObject->processObject();

    auto eventType = Identifier::fromString(JSC::getVM(globalObject), "unhandledRejection"_s);
    auto& wrapped = process->wrapped();
    if (wrapped.listenerCount(eventType) > 0) {
        MarkedArgumentBuffer args;
        args.append(reason);
        args.append(promise);
        wrapped.emit(eventType, args);
        return true;
    }

    return false;
}

static bool processEmitHandledPromiseEvent(JSC::JSGlobalObject* lexicalGlobalObject, JSC::JSValue promise)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(JSC::getVM(lexicalGlobalObject));
    if (!lexicalGlobalObject->inherits(Zig::GlobalObject::info()))
        return false;
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    auto* process = globalObject->processObject();

    auto eventType = Identifier::fromString(JSC::getVM(globalObject), "rejectionHandled"_s);

    if (Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineAllowRejectionHandledWarning(globalObject->bunVM())) {
        Process::emitWarning(globalObject, "Promise rejection was handled asynchronously"_s, "PromiseRejectionHandledWarning"_s);
        RETURN_IF_EXCEPTION(scope, true);
    }
    auto& wrapped = process->wrapped();
    if (wrapped.listenerCount(eventType) > 0) {
        MarkedArgumentBuffer args;
        args.append(promise);
        wrapped.emit(eventType, args);
        return true;
    }

    return false;
}

__attribute__((noinline)) static void forwardSignal(int signalNumber)
{
    // We want a function that's equivalent to the generated signal handler but whose address is different.
    // This is so that we can be sure not to uninstall signal handlers that we didn't install here.
    Bun::Bindgen::ZigExports::bunBindgenZig_posix_signals_onPosixSignal(signalNumber);
}

static void onDidChangeListeners(EventEmitter& eventEmitter, const Identifier& eventName, bool isAdded)
{
    if (Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_currentVirtualMachineIsMainThread()) {
        // IPC handlers
        if (eventName == "message" || eventName == "disconnect") {
            auto* global = uncheckedDowncast<GlobalObject>(eventEmitter.scriptExecutionContext()->jsGlobalObject());
            auto& vm = JSC::getVM(global);
            auto messageListenerCount = eventEmitter.listenerCount(vm.propertyNames->message);
            auto disconnectListenerCount = eventEmitter.listenerCount(Identifier::fromString(vm, "disconnect"_s));
            if (disconnectListenerCount >= 1 && Bun::Bindgen::ZigExports::bunBindgenZig_NodeCluster_shouldIgnoreOneDisconnectEventListener(global)) {
                disconnectListenerCount--;
            }
            auto totalListenerCount = messageListenerCount + disconnectListenerCount;
            if (isAdded) {
                if (Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectHasIPC(global)
                    && totalListenerCount == 1) {
                    auto scope = DECLARE_THROW_SCOPE(vm);
                    Bun::Bindgen::ZigExports::bunBindgenZig_IPC_ensureProcessIPCInitialized(global);
                    RETURN_IF_EXCEPTION(scope, void());
                    Bun::Bindgen::ZigExports::bunBindgenZig_NodeCluster_refChannelUnlessOverridden(global);
                }
            } else {
                if (Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectHasIPC(global)
                    && totalListenerCount == 0) {
                    Bun::Bindgen::ZigExports::bunBindgenZig_NodeCluster_unrefChannelUnlessOverridden(global);
                }
            }
            return;
        }

        // Signal Handlers
        if (!signalToContextIdsMap) {
            signalToContextIdsMap = new HashMap<int, SignalHandleValue>();
        }

        if (auto signalCode = signalNumberForName(eventName.string())) {
            int signalNumber = *signalCode;
#if OS(LINUX)
            // SIGKILL and SIGSTOP cannot be handled, and JSC needs its own signal handler to
            // suspend and resume the JS thread which we must not override.
            if (signalNumber != SIGKILL && signalNumber != SIGSTOP && signalNumber != g_wtfConfig.sigThreadSuspendResume) {
#elif OS(DARWIN) || OS(FREEBSD)
            // these signals cannot be handled
            if (signalNumber != SIGKILL && signalNumber != SIGSTOP) {
#elif OS(WINDOWS)
            // windows has no SIGSTOP
            if (signalNumber != SIGKILL) {
#else
#error unknown OS
#endif

                if (isAdded) {
                    if (!signalToContextIdsMap->contains(signalNumber)) {
                        SignalHandleValue signal_handle = {
#if OS(WINDOWS)
                            .handle = nullptr,
#endif
                        };
#if !OS(WINDOWS)
                        Bun::Bindgen::ZigExports::bunBindgenZig_posix_signals_ensureSignalHandler();
                        struct sigaction action;
                        memset(&action, 0, sizeof(struct sigaction));

                        // Set the handler in the action struct
                        action.sa_handler = forwardSignal;

                        // Clear the sa_mask
                        sigemptyset(&action.sa_mask);
                        sigaddset(&action.sa_mask, signalNumber);
                        action.sa_flags = SA_RESTART;

                        sigaction(signalNumber, &action, nullptr);
#else
                        signal_handle.handle = Bun::Bindgen::ZigExports::bunBindgenZig_uv_signal_handles_uvSignalHandleInit(
                            uncheckedDowncast<Zig::GlobalObject>(eventEmitter.scriptExecutionContext()->jsGlobalObject())->uvLoop(), signalNumber, &signalHandler)
                                                   .value_or(nullptr);

                        if (!signal_handle.handle) [[unlikely]]
                            return;
#endif

                        signalToContextIdsMap->set(signalNumber, signal_handle);
                    }
                } else {
                    if (signalToContextIdsMap->find(signalNumber) != signalToContextIdsMap->end() && !hasSignalListeners(eventEmitter, signalNumber)) {

#if !OS(WINDOWS)
                        if (void (*oldHandler)(int) = signal(signalNumber, SIG_DFL); oldHandler != forwardSignal) {
                            // Don't uninstall the old handler if it's not the one we installed.
                            signal(signalNumber, oldHandler);
                        }
#else
                        SignalHandleValue signal_handle = signalToContextIdsMap->get(signalNumber);
                        Bun::Bindgen::ZigExports::bunBindgenZig_uv_signal_handles_uvSignalHandleClose(signal_handle.handle);
#endif
                        signalToContextIdsMap->remove(signalNumber);
                    }
                }
            }
        }
    }
}

Process::~Process()
{
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_emitWarningEvent(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_emitWarningEvent_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    auto* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* process = globalObject->processObject();
    auto value = args.value;

    auto ident = builtinNames(vm).warningPublicName();
    if (process->wrapped().hasEventListeners(ident)) {
        JSC::MarkedArgumentBuffer callArgs;
        callArgs.append(value);
        process->wrapped().emit(ident, callArgs);
        return;
    } else if (!Bun::Bindgen::ZigExports::bunBindgenZig_Process_nodeNoWarnings()) {
        Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_messageWithTypeAndLevel(
            globalObject,
            static_cast<uint32_t>(MessageType::Log),
            static_cast<uint32_t>(MessageLevel::Warning),
            std::span<const JSC::JSValue>(&value, 1));
        RETURN_IF_EXCEPTION(scope, void());
    }
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_throwValue(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_throwValue_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    scope.throwException(globalObject, args.value);
}

#if !OS(WINDOWS)
static int persistStandardStream(int fd)
{
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return flags;
    flags &= ~FD_CLOEXEC;
    return fcntl(fd, F_SETFD, flags);
}
#endif

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_execve(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_execve_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    Zig::GlobalObject* globalObject = defaultGlobalObject(lexicalGlobalObject);
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_currentVirtualMachineIsMainThread()) {
        scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_WORKER_UNSUPPORTED_OPERATION, "Calling process.execve is not supported in workers"_s));
        return;
    }

    static bool experimentalWarningEmitted = false;
    if (!experimentalWarningEmitted) {
        experimentalWarningEmitted = true;
        Process::emitWarning(globalObject, "process.execve is an experimental feature and might change at any time"_s, "ExperimentalWarning"_s);
        if (scope.exception()) experimentalWarningEmitted = false;
    }
    RETURN_IF_EXCEPTION(scope, void());

#if OS(WINDOWS)
    scope.throwException(globalObject, createError(globalObject, ErrorCode::ERR_FEATURE_UNAVAILABLE_ON_PLATFORM, "The feature process.execve is unavailable on the current platform, which is being used to run Node.js"_s));
    return;
#else
    const auto* execPath = args.execPath.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!execPath)
        return;

    if (execPath->contains(static_cast<char16_t>(0))) {
        Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, "execPath"_s,
            jsString(vm, *execPath), "must be a string without null bytes"_s);
        return;
    }

    const auto* arguments = args.args.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!arguments)
        return;

    Vector<Vector<uint8_t>> argvStorage;
    if (!argvStorage.tryReserveInitialCapacity(arguments->size())) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }

    for (size_t i = 0; i < arguments->size(); i++) {
        const auto& argument = arguments->at(i);
        if (argument.contains(static_cast<char16_t>(0))) {
            auto name = tryMakeString("args["_s, i, "]"_s);
            if (name.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return;
            }
            Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, name,
                jsString(vm, argument), "must be a string without null bytes"_s);
            return;
        }
        auto utf8 = encodeUTF8ReplacingInvalidSequences(argument, UTF8Termination::Null);
        if (!utf8) {
            throwOutOfMemoryError(globalObject, scope);
            return;
        }
        argvStorage.unsafeAppendWithoutCapacityCheck(WTF::move(*utf8));
    }

    const auto* environment = args.env.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!environment)
        return;

    Vector<Vector<uint8_t>> envStorage;
    if (environment->has_value()) {
        if (!envStorage.tryReserveInitialCapacity(environment->value().size())) {
            throwOutOfMemoryError(globalObject, scope);
            return;
        }

        for (const auto& [key, value] : environment->value()) {
            if (key.contains(static_cast<char16_t>(0)) || value.contains(static_cast<char16_t>(0))) {
                Bun::ERR::INVALID_ARG_VALUE(scope, globalObject, "env"_s,
                    jsString(vm, value), "must be an object with string keys and values without null bytes"_s);
                return;
            }
            auto entry = tryMakeString(key, '=', value);
            if (entry.isNull()) {
                throwOutOfMemoryError(globalObject, scope);
                return;
            }
            auto utf8 = encodeUTF8ReplacingInvalidSequences(entry, UTF8Termination::Null);
            if (!utf8) {
                throwOutOfMemoryError(globalObject, scope);
                return;
            }
            envStorage.unsafeAppendWithoutCapacityCheck(WTF::move(*utf8));
        }
    }

    auto execPathUtf8 = encodeUTF8ReplacingInvalidSequences(*execPath, UTF8Termination::Null);
    if (!execPathUtf8) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }

    // Build the null-terminated argv/envp pointer arrays only after the
    // backing storage is fully populated so there is no risk of pointers
    // becoming stale across any intermediate Vector growth.
    Vector<char*> argv;
    if (!argv.tryReserveInitialCapacity(static_cast<size_t>(argvStorage.size()) + 1)) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }
    for (auto& s : argvStorage)
        argv.unsafeAppendWithoutCapacityCheck(reinterpret_cast<char*>(s.mutableSpan().data()));
    argv.unsafeAppendWithoutCapacityCheck(nullptr);

    Vector<char*> envp;
    if (!envp.tryReserveInitialCapacity(static_cast<size_t>(envStorage.size()) + 1)) {
        throwOutOfMemoryError(globalObject, scope);
        return;
    }
    for (auto& s : envStorage)
        envp.unsafeAppendWithoutCapacityCheck(reinterpret_cast<char*>(s.mutableSpan().data()));
    envp.unsafeAppendWithoutCapacityCheck(nullptr);

    // Set stdin, stdout and stderr to be non-close-on-exec so that the new
    // process will inherit them.
    if (persistStandardStream(0) < 0 || persistStandardStream(1) < 0 || persistStandardStream(2) < 0) {
        throwSystemError(scope, globalObject, "fcntl"_s, errno);
        return;
    }

    int savedErrno;

#if OS(DARWIN)
    // macOS lacks SOCK_CLOEXEC/close_range, so use posix_spawn with the Apple
    // extensions: POSIX_SPAWN_SETEXEC makes posix_spawn(2) behave like a more
    // featureful execve(2) (replace the current image rather than fork), and
    // POSIX_SPAWN_CLOEXEC_DEFAULT atomically closes every descriptor that
    // isn't explicitly inherited via file actions. This mirrors
    // reloadProcess() in src/bun.zig.
    posix_spawnattr_t attrs;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attrs);
    posix_spawn_file_actions_init(&actions);

    // Reset the blocked signal mask, but don't touch dispositions:
    // POSIX_SPAWN_SETEXEC already gives execve(2) semantics (caught handlers
    // become SIG_DFL; SIG_IGN is preserved), which matches the non-Darwin
    // path and Node. SETSIGDEF with a full set would additionally force
    // SIG_IGN dispositions (e.g. Bun's SIGPIPE) back to SIG_DFL, diverging
    // from Linux.
    sigset_t emptyMask;
    sigemptyset(&emptyMask);
    posix_spawnattr_setsigmask(&attrs, &emptyMask);
    posix_spawnattr_setflags(&attrs,
        POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK);

    posix_spawn_file_actions_addinherit_np(&actions, 0);
    posix_spawn_file_actions_addinherit_np(&actions, 1);
    posix_spawn_file_actions_addinherit_np(&actions, 2);

    pid_t pid;
    savedErrno = posix_spawn(&pid, reinterpret_cast<const char*>(execPathUtf8->span().data()), &actions, &attrs, argv.begin(), envp.begin());
    // With POSIX_SPAWN_SETEXEC a successful call never returns; reaching
    // here means it failed and the return value is the errno.
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
#else
    if (bun_close_range(3, UINT32_MAX, BUN_CLOSE_RANGE_CLOEXEC) < 0) {
        savedErrno = errno;
    } else {
        sigset_t emptyMask;
        sigemptyset(&emptyMask);
        // execve resets caught handlers but preserves the blocked signal mask.
        pthread_sigmask(SIG_SETMASK, &emptyMask, nullptr);
        ::execve(reinterpret_cast<const char*>(execPathUtf8->span().data()), argv.begin(), envp.begin());
        savedErrno = errno;
    }
#endif

    // Process state has been changed for execve, so this path cannot resume JavaScript.
    fprintf(stderr, "process.execve failed with errno %d\n", savedErrno);
    fprintf(stderr, "SystemError [process.execve]: execve %s: %s\n", strerror(savedErrno), reinterpret_cast<const char*>(execPathUtf8->span().data()));
    fprintf(stderr, "    at execve (node:internal/process/per_thread:0:0)\n");
    fflush(stderr);

    // Disable core dumps before aborting. Node also calls abort() here, but
    // Bun's CI treats any core file produced during a test run (including
    // from an intentionally-aborting child process) as a failure. The error
    // has already been written to stderr, so a core dump adds no diagnostic
    // value.
    struct rlimit noCore = { 0, 0 };
    setrlimit(RLIMIT_CORE, &noCore);
    abort();
#endif
}

static void putWarningString(JSGlobalObject* globalObject, JSObject* warning, const Identifier& property, const WTF::String& text)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* value = jsString(vm, text);
    RETURN_IF_EXCEPTION(scope, void());
    warning->putDirect(vm, property, value, static_cast<unsigned>(PropertyAttribute::DontEnum));
    RETURN_IF_EXCEPTION(scope, void());
}

static ErrorInstance* createWarning(JSGlobalObject* globalObject, const WTF::String& message, const WTF::String& name)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* warning = createError(globalObject, message.isEmpty() ? "Warning"_s : message);
    RETURN_IF_EXCEPTION(scope, nullptr);
    putWarningString(globalObject, warning, globalObject->vm().propertyNames->name, name);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return uncheckedDowncast<ErrorInstance>(warning);
}

void Process::emitWarningErrorInstance(JSC::JSGlobalObject* lexicalGlobalObject, ErrorInstance* errorInstance)
{
    Zig::GlobalObject* globalObject = defaultGlobalObject(lexicalGlobalObject);
    VM& vm = getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* process = globalObject->processObject();

    auto warningName = errorInstance->get(lexicalGlobalObject, vm.propertyNames->name);
    RETURN_IF_EXCEPTION(scope, void());
    bool isDeprecation = false;
    if (warningName.isString()) {
        auto name = asString(warningName)->value(globalObject);
        RETURN_IF_EXCEPTION(scope, void());
        isDeprecation = WTF::StringView(name) == "DeprecationWarning"_s;
    }
    if (isDeprecation) {
        if (Process::noDeprecation()) {
            return;
        }
        if (Process::throwDeprecation()) {
            auto func = JSFunction::create(vm, globalObject, 1, ""_s, bun_bindgen_host_ProcessHost_throwValue, JSC::ImplementationVisibility::Private);
            RETURN_IF_EXCEPTION(scope, void());
            process->queueNextTick(globalObject, func, errorInstance);
            RETURN_IF_EXCEPTION(scope, void());
            return;
        }
    }

    //   process.nextTick(doEmitWarning, warning);
    auto func = JSFunction::create(vm, globalObject, 1, ""_s, bun_bindgen_host_ProcessHost_emitWarningEvent, JSC::ImplementationVisibility::Private);
    RETURN_IF_EXCEPTION(scope, void());
    process->queueNextTick(globalObject, func, errorInstance);
    RETURN_IF_EXCEPTION(scope, void());
}
void Process::emitWarning(JSC::JSGlobalObject* lexicalGlobalObject, const WTF::String& message, const WTF::String& name, const std::optional<WTF::String>& code)
{
    Zig::GlobalObject* globalObject = defaultGlobalObject(lexicalGlobalObject);
    VM& vm = getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (Process::noDeprecation() && name == "DeprecationWarning"_s) return;
    auto* errorInstance = createWarning(globalObject, message, name);
    RETURN_IF_EXCEPTION(scope, void());
    if (code) {
        putWarningString(globalObject, errorInstance, builtinNames(vm).codePublicName(), *code);
        RETURN_IF_EXCEPTION(scope, void());
    }
    emitWarningErrorInstance(lexicalGlobalObject, errorInstance);
    RETURN_IF_EXCEPTION(scope, void());
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_emitWarning(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_emitWarning_Arguments& args)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    WTF::String name = "Warning"_s;
    std::optional<WTF::String> code;
    std::optional<WTF::String> detail;
    bool useArgumentCode = true;

    if (args.type.is_name()) {
        name = args.type.name();
        if (Process::noDeprecation() && name == "DeprecationWarning"_s)
            return;
    } else if (args.type.is_options()) {
        useArgumentCode = false;
        const auto& options = args.type.options();
        if (options.type)
            name = *options.type;
        if (options.detail.is_string())
            detail = options.detail.string();

        const auto* optionCode = options.code.convert();
        RETURN_IF_EXCEPTION(scope, void());
        if (!optionCode)
            return;
        if (optionCode->is_string())
            code = optionCode->string();
    } else if (args.type.is_callable()) {
        useArgumentCode = false;
    }

    if (useArgumentCode) {
        const auto* argumentCode = args.code.convert();
        RETURN_IF_EXCEPTION(scope, void());
        if (!argumentCode)
            return;
        if (argumentCode->is_string())
            code = argumentCode->string();
    }

    const auto* warning = args.warning.convert();
    RETURN_IF_EXCEPTION(scope, void());
    if (!warning)
        return;

    ErrorInstance* errorInstance;
    if (warning->is_error()) {
        errorInstance = uncheckedDowncast<ErrorInstance>(warning->error());
    } else {
        const auto& message = warning->message();
        errorInstance = createWarning(globalObject, message, name);
        RETURN_IF_EXCEPTION(scope, void());
    }

    if (code) {
        putWarningString(globalObject, errorInstance, builtinNames(vm).codePublicName(), *code);
        RETURN_IF_EXCEPTION(scope, void());
    }
    if (detail) {
        putWarningString(globalObject, errorInstance, vm.propertyNames->detail, *detail);
        RETURN_IF_EXCEPTION(scope, void());
    }

    Process::emitWarningErrorInstance(globalObject, errorInstance);
    RETURN_IF_EXCEPTION(scope, void());
}

std::optional<uint8_t> Bindgen::Cpp::bunBindgenCpp_ProcessHost_processExitCode(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processExitCode_Arguments& args)
{
    auto* process = processObject(args.bindingThis);
    if (!process || !process->m_isExitCodeObservable)
        return std::nullopt;

    return static_cast<uint8_t>(Bun::Bindgen::ZigExports::bunBindgenZig_virtual_machine_virtualMachineGetExitCode(process->globalObject()->bunVM()));
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessExitCode(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessExitCode_Arguments& args)
{
    auto* process = processObject(args.bindingThis);
    if (!process)
        return false;

    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const auto* code = args.code.convert();
    RETURN_IF_EXCEPTION(scope, false);
    if (!code)
        return false;
    if (*code)
        applyProcessExitCode(process, **code);
    scope.release();
    return true;
}

std::optional<bool> Bindgen::Cpp::bunBindgenCpp_ProcessHost_processConnected(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processConnected_Arguments& args)
{
    auto* process = processObject(args.bindingThis);
    if (!process)
        return std::nullopt;

    return Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectConnectedIPC(process->globalObject());
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessConnected(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessConnected_Arguments&)
{
    return false;
}

static JSValue constructReportObjectComplete(VM& vm, Zig::GlobalObject* globalObject, const String& fileName)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
#if !OS(WINDOWS)
    auto constructUserLimits = [&]() -> JSValue {
        JSC::JSObject* userLimits = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 11);
        RETURN_IF_EXCEPTION(scope, {});

        static constexpr int resourceLimits[] = {
            RLIMIT_CORE,
            RLIMIT_DATA,
            RLIMIT_FSIZE,
            RLIMIT_MEMLOCK,
            RLIMIT_RSS,
            RLIMIT_NOFILE,
            RLIMIT_STACK,
            RLIMIT_CPU,
            RLIMIT_NPROC,
            RLIMIT_AS,
        };

        static constexpr ASCIILiteral labels[] = {
            "core_file_size_blocks"_s,
            "data_seg_size_kbytes"_s,
            "file_size_blocks"_s,
            "max_locked_memory_bytes"_s,
            "max_memory_size_kbytes"_s,
            "open_files"_s,
            "stack_size_bytes"_s,
            "cpu_time_seconds"_s,
            "max_user_processes"_s,
            "virtual_memory_kbytes"_s,
        };

        for (size_t i = 0; i < std::size(resourceLimits); i++) {
            JSC::JSObject* limitObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 2);
            RETURN_IF_EXCEPTION(scope, {});
            struct rlimit limit;
            getrlimit(resourceLimits[i], &limit);

            JSValue soft = limit.rlim_cur == RLIM_INFINITY ? JSC::jsString(vm, String("unlimited"_s)) : JSC::jsNumber(limit.rlim_cur);

            JSValue hard = limit.rlim_max == RLIM_INFINITY ? JSC::jsString(vm, String("unlimited"_s)) : JSC::jsNumber(limit.rlim_max);

            limitObject->putDirect(vm, JSC::Identifier::fromString(vm, "soft"_s), soft, 0);
            limitObject->putDirect(vm, JSC::Identifier::fromString(vm, "hard"_s), hard, 0);

            userLimits->putDirect(vm, JSC::Identifier::fromString(vm, labels[i]), limitObject, 0);
        }

        return userLimits;
    };

    auto constructResourceUsage = [&]() -> JSC::JSValue {
        JSC::JSObject* resourceUsage = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 11);
        RETURN_IF_EXCEPTION(scope, {});

        rusage usage;

        getrusage(RUSAGE_SELF, &usage);

        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "free_memory"_s), JSC::jsNumber(usage.ru_maxrss), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "total_memory"_s), JSC::jsNumber(usage.ru_maxrss), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "rss"_s), JSC::jsNumber(usage.ru_maxrss), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "available_memory"_s), JSC::jsNumber(usage.ru_maxrss), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "userCpuSeconds"_s), JSC::jsNumber(usage.ru_utime.tv_sec), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "kernelCpuSeconds"_s), JSC::jsNumber(usage.ru_stime.tv_sec), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "cpuConsumptionPercent"_s), JSC::jsNumber(usage.ru_utime.tv_sec), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "userCpuConsumptionPercent"_s), JSC::jsNumber(usage.ru_utime.tv_sec), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "kernelCpuConsumptionPercent"_s), JSC::jsNumber(usage.ru_utime.tv_sec), 0);
        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "maxRss"_s), JSC::jsNumber(usage.ru_maxrss), 0);

        JSC::JSObject* pageFaults = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 2);
        RETURN_IF_EXCEPTION(scope, {});
        pageFaults->putDirect(vm, JSC::Identifier::fromString(vm, "IORequired"_s), JSC::jsNumber(usage.ru_majflt), 0);
        pageFaults->putDirect(vm, JSC::Identifier::fromString(vm, "IONotRequired"_s), JSC::jsNumber(usage.ru_minflt), 0);

        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "pageFaults"_s), pageFaults, 0);

        JSC::JSObject* fsActivity = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 2);
        RETURN_IF_EXCEPTION(scope, {});
        fsActivity->putDirect(vm, JSC::Identifier::fromString(vm, "reads"_s), JSC::jsNumber(usage.ru_inblock), 0);
        fsActivity->putDirect(vm, JSC::Identifier::fromString(vm, "writes"_s), JSC::jsNumber(usage.ru_oublock), 0);

        resourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "fsActivity"_s), fsActivity, 0);

        return resourceUsage;
    };

    auto constructHeader = [&]() -> JSC::JSValue {
        JSC::JSObject* header = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype());
        RETURN_IF_EXCEPTION(scope, {});

        header->putDirect(vm, JSC::Identifier::fromString(vm, "reportVersion"_s), JSC::jsNumber(3), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "event"_s), JSC::jsString(vm, String("JavaScript API"_s)), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "trigger"_s), JSC::jsString(vm, String("GetReport"_s)), 0);
        if (fileName.isEmpty()) {
            header->putDirect(vm, JSC::Identifier::fromString(vm, "filename"_s), JSC::jsNull(), 0);
        } else {
            header->putDirect(vm, JSC::Identifier::fromString(vm, "filename"_s), JSC::jsString(vm, fileName), 0);
        }

        double time = WTF::jsCurrentTime();
        auto timeStamp = Bun::toISOString(vm, time);

        header->putDirect(vm, JSC::Identifier::fromString(vm, "dumpEventTime"_s), JSC::numberToString(vm, time, 10), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "dumpEventTimeStamp"_s), JSC::jsString(vm, timeStamp));
        header->putDirect(vm, JSC::Identifier::fromString(vm, "processId"_s), JSC::jsNumber(getpid()), 0);
        // TODO:
        header->putDirect(vm, JSC::Identifier::fromString(vm, "threadId"_s), JSC::jsNumber(0), 0);

        {
            char cwd[PATH_MAX] = { 0 };

            if (getcwd(cwd, PATH_MAX) == nullptr) {
                cwd[0] = '.';
                cwd[1] = '\0';
            }

            header->putDirect(vm, JSC::Identifier::fromString(vm, "cwd"_s), JSC::jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const Latin1Character*>(cwd), strlen(cwd) })), 0);
            RETURN_IF_EXCEPTION(scope, {});
        }

        auto commandLine = Bun::Bindgen::ZigExports::bunBindgenZig_Process_createExecArgv(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        header->putDirect(vm, JSC::Identifier::fromString(vm, "commandLine"_s), Bun::toJSArray(globalObject, commandLine.span()), 0);
        RETURN_IF_EXCEPTION(scope, {});
        header->putDirect(vm, JSC::Identifier::fromString(vm, "nodejsVersion"_s), JSC::jsString(vm, String::fromLatin1(REPORTED_NODEJS_VERSION)), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "wordSize"_s), JSC::jsNumber(64), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "arch"_s), JSC::jsString(vm, WTF::String(processArch())), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "platform"_s), JSC::jsString(vm, WTF::String(processPlatform())), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "componentVersions"_s), bunBindgenObjectSurface_ProcessVersions_create(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        header->putDirect(vm, JSC::Identifier::fromString(vm, "release"_s), bunBindgenObjectSurface_ProcessRelease_create(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});

        {
            // uname
            struct utsname buf;
            if (uname(&buf) != 0) {
                memset(&buf, 0, sizeof(buf));
            }

            header->putDirect(vm, JSC::Identifier::fromString(vm, "osName"_s), JSC::jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const Latin1Character*>(buf.sysname), strlen(buf.sysname) })), 0);
            header->putDirect(vm, JSC::Identifier::fromString(vm, "osRelease"_s), JSC::jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const Latin1Character*>(buf.release), strlen(buf.release) })), 0);
            header->putDirect(vm, JSC::Identifier::fromString(vm, "osVersion"_s), JSC::jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const Latin1Character*>(buf.version), strlen(buf.version) })), 0);
            header->putDirect(vm, JSC::Identifier::fromString(vm, "osMachine"_s), JSC::jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const Latin1Character*>(buf.machine), strlen(buf.machine) })), 0);
        }

        // host
        {
            // TODO: use HOSTNAME_MAX
            char host[1024] = { 0 };
            if (gethostname(host, 1024) != 0) {
                host[0] = '0';
            }

            header->putDirect(vm, JSC::Identifier::fromString(vm, "host"_s), JSC::jsString(vm, String::fromUTF8ReplacingInvalidSequences(std::span { reinterpret_cast<const Latin1Character*>(host), strlen(host) })), 0);
        }

#if OS(LINUX)
#ifdef __GNU_LIBRARY__
        header->putDirect(vm, JSC::Identifier::fromString(vm, "glibcVersionCompiler"_s), JSC::jsString(vm, makeString(__GLIBC__, '.', __GLIBC_MINOR__)), 0);
        header->putDirect(vm, JSC::Identifier::fromString(vm, "glibcVersionRuntime"_s), JSC::jsString(vm, String::fromUTF8(gnu_get_libc_version())), 0);
#else
#endif
#endif

        header->putDirect(vm, Identifier::fromString(vm, "cpus"_s), JSC::constructEmptyArray(globalObject, nullptr), 0);
        RETURN_IF_EXCEPTION(scope, {});
        header->putDirect(vm, Identifier::fromString(vm, "networkInterfaces"_s), JSC::constructEmptyArray(globalObject, nullptr), 0);
        RETURN_IF_EXCEPTION(scope, {});

        return header;
    };

    auto constructJavaScriptHeap = [&]() -> JSC::JSValue {
        JSC::JSObject* heap = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 16);
        RETURN_IF_EXCEPTION(scope, {});

        JSC::JSObject* heapSpaces = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 9);
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "read_only_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "new_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "old_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "code_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "shared_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "new_large_object_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "large_object_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "code_large_object_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});
        heapSpaces->putDirect(vm, JSC::Identifier::fromString(vm, "shared_large_object_space"_s), JSC::constructEmptyObject(globalObject), 0);
        RETURN_IF_EXCEPTION(scope, {});

        heap->putDirect(vm, JSC::Identifier::fromString(vm, "totalMemory"_s), JSC::jsNumber(WTF::ramSize()), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "executableMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "totalCommittedMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "availableMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "totalGlobalHandlesMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "usedGlobalHandlesMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "usedMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "memoryLimit"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "mallocedMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "externalMemory"_s), JSC::jsNumber(vm.heap.externalMemorySize()), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "peakMallocedMemory"_s), jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "nativeContextCount"_s), JSC::jsNumber(1), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "detachedContextCount"_s), JSC::jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "doesZapGarbage"_s), JSC::jsNumber(0), 0);
        heap->putDirect(vm, JSC::Identifier::fromString(vm, "heapSpaces"_s), heapSpaces, 0);

        return heap;
    };

    auto constructUVThreadResourceUsage = [&]() -> JSC::JSValue {
        JSC::JSObject* uvthreadResourceUsage = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 6);
        RETURN_IF_EXCEPTION(scope, {});

        uvthreadResourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "userCpuSeconds"_s), JSC::jsNumber(0), 0);
        uvthreadResourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "kernelCpuSeconds"_s), JSC::jsNumber(0), 0);
        uvthreadResourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "cpuConsumptionPercent"_s), JSC::jsNumber(0), 0);
        uvthreadResourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "userCpuConsumptionPercent"_s), JSC::jsNumber(0), 0);
        uvthreadResourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "kernelCpuConsumptionPercent"_s), JSC::jsNumber(0), 0);

        JSC::JSObject* fsActivity = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 2);
        RETURN_IF_EXCEPTION(scope, {});
        fsActivity->putDirect(vm, JSC::Identifier::fromString(vm, "reads"_s), JSC::jsNumber(0), 0);
        fsActivity->putDirect(vm, JSC::Identifier::fromString(vm, "writes"_s), JSC::jsNumber(0), 0);

        uvthreadResourceUsage->putDirect(vm, JSC::Identifier::fromString(vm, "fsActivity"_s), fsActivity, 0);

        return uvthreadResourceUsage;
    };

    auto constructJavaScriptStack = [&]() -> JSC::JSValue {
        JSC::JSObject* javascriptStack = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 3);
        RETURN_IF_EXCEPTION(scope, {});

        javascriptStack->putDirect(vm, vm.propertyNames->message, JSC::jsString(vm, String("Error [ERR_SYNTHETIC]: JavaScript Callstack"_s)), 0);

        // TODO: allow errors as an argument
        {
            WTF::Vector<JSC::StackFrame> stackFrames;
            vm.interpreter.getStackTrace(javascriptStack, stackFrames, 1);
            String name = "Error"_s;
            String message = "JavaScript Callstack"_s;
            OrdinalNumber line = OrdinalNumber::beforeFirst();
            OrdinalNumber column = OrdinalNumber::beforeFirst();
            WTF::String sourceURL;
            WTF::String stackProperty = Bun::formatStackTrace(
                vm, globalObject, globalObject, name, message,
                line, column,
                sourceURL, stackFrames, nullptr);

            WTF::String stack;
            // first line after "Error:"
            size_t firstLine = stackProperty.find('\n');
            if (firstLine != WTF::notFound) {
                stack = stackProperty.substring(firstLine + 1);
            }

            JSC::JSArray* stackArray = JSC::constructEmptyArray(globalObject, nullptr);
            RETURN_IF_EXCEPTION(scope, {});

            stack.split('\n', [&](const WTF::StringView& line) {
                stackArray->push(globalObject, JSC::jsString(vm, line.toString().trim(isASCIIWhitespace)));
                RETURN_IF_EXCEPTION(scope, );
            });
            RETURN_IF_EXCEPTION(scope, {});

            javascriptStack->putDirect(vm, vm.propertyNames->stack, stackArray, 0);
        }

        JSC::JSObject* errorProperties = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 1);
        RETURN_IF_EXCEPTION(scope, {});
        errorProperties->putDirect(vm, JSC::Identifier::fromString(vm, "code"_s), JSC::jsString(vm, String("ERR_SYNTHETIC"_s)), 0);
        javascriptStack->putDirect(vm, JSC::Identifier::fromString(vm, "errorProperties"_s), errorProperties, 0);
        return javascriptStack;
    };

    auto constructSharedObjects = [&]() -> JSC::JSValue {
        JSC::JSObject* sharedObjects = JSC::constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});

        // TODO:

        return sharedObjects;
    };

    auto constructLibUV = [&]() -> JSC::JSValue {
        JSC::JSObject* libuv = JSC::constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});

        // TODO:

        return libuv;
    };

    auto constructWorkers = [&]() -> JSC::JSValue {
        JSC::JSObject* workers = JSC::constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});

        // TODO:

        return workers;
    };

    auto constructEnvironmentVariables = [&]() -> JSC::JSValue {
        return globalObject->processEnvObject();
    };

    auto constructCpus = [&]() -> JSC::JSValue {
        JSC::JSObject* cpus = JSC::constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});

        // TODO:

        return cpus;
    };

    auto constructNetworkInterfaces = [&]() -> JSC::JSValue {
        JSC::JSObject* networkInterfaces = JSC::constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});

        // TODO:

        return networkInterfaces;
    };

    auto constructNativeStack = [&]() -> JSC::JSValue {
        JSC::JSObject* nativeStack = JSC::constructEmptyArray(globalObject, nullptr);
        RETURN_IF_EXCEPTION(scope, {});

        // TODO:

        return nativeStack;
    };

    {
        JSC::JSObject* report = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 19);
        RETURN_IF_EXCEPTION(scope, {});

        report->putDirect(vm, JSC::Identifier::fromString(vm, "header"_s), constructHeader(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "javascriptStack"_s), constructJavaScriptStack(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "javascriptHeap"_s), constructJavaScriptHeap(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "nativeStack"_s), constructNativeStack(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "resourceUsage"_s), constructResourceUsage(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "uvthreadResourceUsage"_s), constructUVThreadResourceUsage(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "libuv"_s), constructLibUV(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "workers"_s), constructWorkers(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "environmentVariables"_s), constructEnvironmentVariables(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "userLimits"_s), constructUserLimits(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "sharedObjects"_s), constructSharedObjects(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "cpus"_s), constructCpus(), 0);
        RETURN_IF_EXCEPTION(scope, {});
        report->putDirect(vm, JSC::Identifier::fromString(vm, "networkInterfaces"_s), constructNetworkInterfaces(), 0);
        RETURN_IF_EXCEPTION(scope, {});

        return report;
    }
#else // OS(WINDOWS)
    // Forward declaration - implemented in BunProcessReportObjectWindows.cpp
    JSValue constructReportObjectWindows(VM & vm, Zig::GlobalObject * globalObject, Process * process);

    // Get the Process object - needed for accessing report settings
    Process* process = globalObject->processObject();

    return constructReportObjectWindows(vm, globalObject, process);
#endif
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_getReport(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_getReport_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    // TODO: node:vm
    return constructReportObjectComplete(vm, uncheckedDowncast<Zig::GlobalObject>(globalObject), String());
}

std::optional<Bun::Bindgen::CppAny> Bindgen::Cpp::bunBindgenCpp_ProcessHost_writeReport(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_writeReport_Arguments& args)
{
    // TODO:
    return args.filename;
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_processReportOnUncaughtException(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processReportOnUncaughtException_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->processObject()->m_reportOnUncaughtException;
}

static JSValue constructStdioWriteStream(JSC::JSGlobalObject* globalObject, JSC::JSObject* processObject, int fd)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    const auto reportException = [&]() {
        if (auto* exception = scope.exception()) {
            (void)scope.tryClearException();
            Zig::GlobalObject::reportUncaughtExceptionAtEventLoop(globalObject, exception);
            return true;
        }
        return false;
    };

    JSC::JSFunction* getStdioWriteStream = JSC::JSFunction::create(vm, globalObject, processObjectInternalsGetStdioWriteStreamCodeGenerator(vm), globalObject);
    if (reportException())
        return jsUndefined();
    JSC::MarkedArgumentBuffer args;
    args.append(processObject);
    args.append(JSC::jsNumber(fd));
    args.append(jsBoolean(Bun::Bindgen::ZigExports::bunBindgenZig_ProcessTTY_outputStdioIsTTY(fd)));
    auto fdType = Bun::Bindgen::ZigExports::bunBindgenZig_Process_processStdioFdType(fd);
    args.append(jsNumber(static_cast<int32_t>(fdType) - 1));

    JSC::CallData callData = JSC::getCallData(getStdioWriteStream);

    auto result = JSC::profiledCall(globalObject, ProfilingReason::API, getStdioWriteStream, callData, globalObject->globalThis(), args);
    if (reportException())
        return jsUndefined();

    ASSERT_WITH_MESSAGE(JSC::isJSArray(result), "Expected an array from getStdioWriteStream");
    JSC::JSArray* resultObject = uncheckedDowncast<JSC::JSArray>(result);

    // process.stdout and process.stderr differ from other Node.js streams in important ways:
    // 1. They are used internally by console.log() and console.error(), respectively.
    // 2. Writes may be synchronous depending on what the stream is connected to and whether the system is Windows or POSIX:
    // Files: synchronous on Windows and POSIX
    // TTYs (Terminals): asynchronous on Windows, synchronous on POSIX
    // Pipes (and sockets): synchronous on Windows, asynchronous on POSIX
    bool forceSync = false;
#if OS(WINDOWS)
    using StdioFdType = decltype(fdType);
    forceSync = fdType == StdioFdType::file || fdType == StdioFdType::pipe;
#else
    // Note: files are always sync anyway.

    // TODO: once console.* is wired up to write/read through the same buffering mechanism as FileSink for process.stdout, process.stderr, we can make this non-blocking for sockets on POSIX.
    // Until then, we have to force it to be sync EVEN for sockets or else console.log() may flush at a different time than process.stdout.write.
    forceSync = true;
#endif
    if (forceSync) {
        auto sink = resultObject->getIndex(globalObject, 1);
        if (reportException())
            return jsUndefined();
        Bun::Bindgen::ZigExports::bunBindgenZig_JSSink_fileSinkForceSynchronous(globalObject, sink);
        if (reportException())
            return jsUndefined();
    }

    auto stream = resultObject->getIndex(globalObject, 0);
    if (reportException())
        return jsUndefined();
    return stream;
}

static std::optional<JSValue> constructStdout(VM& vm, JSObject* processObject)
{
    auto result = constructStdioWriteStream(processObject->globalObject(), processObject, 1);
    if (result.isUndefined())
        return std::nullopt;
    RELEASE_ASSERT(result.isObject());
    return result;
}

static std::optional<JSValue> constructStderr(VM& vm, JSObject* processObject)
{
    auto result = constructStdioWriteStream(processObject->globalObject(), processObject, 2);
    if (result.isUndefined())
        return std::nullopt;
    RELEASE_ASSERT(result.isObject());
    return result;
}

#if OS(WINDOWS)
#define STDIN_FILENO 0
#endif

static std::optional<JSValue> constructStdin(VM& vm, JSObject* processObject)
{
    auto* globalObject = processObject->globalObject();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::JSFunction* getStdinStream = JSC::JSFunction::create(vm, globalObject, processObjectInternalsGetStdinStreamCodeGenerator(vm), globalObject);
    JSC::MarkedArgumentBuffer args;
    args.append(processObject);
    args.append(JSC::jsNumber(STDIN_FILENO));
    args.append(jsBoolean(Bun::Bindgen::ZigExports::bunBindgenZig_ProcessTTY_outputStdioIsTTY(STDIN_FILENO)));
    auto fdType = Bun::Bindgen::ZigExports::bunBindgenZig_Process_processStdioFdType(STDIN_FILENO);
    args.append(jsNumber(static_cast<int32_t>(fdType) - 1));
    JSC::CallData callData = JSC::getCallData(getStdinStream);

    auto result = JSC::profiledCall(globalObject, ProfilingReason::API, getStdinStream, callData, globalObject, args);
    if (auto* exception = scope.exception()) {
        (void)scope.tryClearException();
        Zig::GlobalObject::reportUncaughtExceptionAtEventLoop(globalObject, exception);
        return std::nullopt;
    }
    if (result.isUndefined())
        return std::nullopt;
    RELEASE_ASSERT(result.isObject());
    return result;
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_processThrowDeprecation(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processThrowDeprecation_Arguments&)
{
    return Process::throwDeprecation();
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessThrowDeprecation(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessThrowDeprecation_Arguments& args)
{
    Process::setThrowDeprecation(args.value);
    return true;
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructProcessSend(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructProcessSend_Arguments&)
{
    auto* globalObject = &context.globalObject;
    if (Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectHasIPC(globalObject)) {
        return JSC::JSFunction::create(globalObject->vm(), globalObject, 1, String("send"_s), bun_bindgen_host_Process_send, ImplementationVisibility::Public);
    }
    return std::nullopt;
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_disconnect(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_disconnect_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto global = uncheckedDowncast<GlobalObject>(globalObject);

    if (!Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectConnectedIPC(globalObject)) {
        processEmitErrorEvent(global, createError(globalObject, ErrorCode::ERR_IPC_DISCONNECTED, "IPC channel is already disconnected"_s));
        return;
    }

    Bun::Bindgen::ZigExports::bunBindgenZig_IPC_closeChildIPC(globalObject);
}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructProcessDisconnect(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructProcessDisconnect_Arguments&)
{
    auto* globalObject = &context.globalObject;
    if (Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectHasIPC(globalObject)) {
        return JSC::JSFunction::create(globalObject->vm(), globalObject, 1, String("disconnect"_s), bun_bindgen_host_ProcessHost_disconnect, ImplementationVisibility::Public);
    }
    return std::nullopt;
}

static std::optional<JSValue> constructProcessChannel(VM& vm, JSObject* processObject)
{
    auto* globalObject = processObject->globalObject();
    if (Bun::Bindgen::ZigExports::bunBindgenZig_IPC_globalObjectHasIPC(globalObject)) {
        auto& vm = JSC::getVM(globalObject);
        auto scope = DECLARE_THROW_SCOPE(vm);

        JSC::JSFunction* getControl = JSC::JSFunction::create(vm, globalObject, processObjectInternalsGetChannelCodeGenerator(vm), globalObject);
        JSC::MarkedArgumentBuffer args;
        JSC::CallData callData = JSC::getCallData(getControl);

        auto result = JSC::profiledCall(globalObject, ProfilingReason::API, getControl, callData, globalObject->globalThis(), args);
        RETURN_IF_EXCEPTION(scope, {});
        return result;
    } else {
        return std::nullopt;
    }
}

#if OS(WINDOWS)
#define getpid _getpid
#endif

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructPid(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructPid_Arguments&)
{
    return getpid();
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_processPpid(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processPpid_Arguments&)
{
    // Always call the syscall so the value reflects reparenting
    // (e.g. after the original parent dies and the child is
    // reparented to init). Matches Node.js behavior.
#if OS(WINDOWS)
    return uv_os_getppid();
#else
    return getppid();
#endif
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructArgv0(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructArgv0_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_Process_createArgv0(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructExecPath(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructExecPath_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto result = Bun::Bindgen::ZigExports::bunBindgenZig_Process_getExecPath(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

std::optional<WTF::String> Bindgen::Cpp::bunBindgenCpp_ProcessHost_processGetEval(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processGetEval_Arguments&)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_Process_getEval(&context.globalObject);
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessGetEval(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessGetEval_Arguments&)
{
    // dont allow setting eval from js
    return true;
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructVersion(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructVersion_Arguments&)
{
    return makeString("v"_s, ASCIILiteral::fromLiteralUnsafe(REPORTED_NODEJS_VERSION));
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructRevision(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructRevision_Arguments&)
{
    return Bun::Bindgen::ZigExports::bunBindgenZig_Process_revision();
}

static JSValue constructEnv(VM& vm, JSObject* processObject)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(processObject->globalObject());
    return globalObject->processEnvObject();
}

#if !OS(WINDOWS)

WTF::Vector<uint32_t> Bindgen::Cpp::bunBindgenCpp_ProcessHost_getgroups(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_getgroups_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    int ngroups = getgroups(0, nullptr);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    if (ngroups == -1) {
        throwSystemError(throwScope, globalObject, "getgroups"_s, errno);
        return {};
    }
    if (!ngroups)
        return {};
    WTF::Vector<uint32_t> groups;
    static_assert(std::is_same_v<gid_t, uint32_t>);
    if (!groups.tryGrow(ngroups)) {
        throwOutOfMemoryError(globalObject, throwScope);
        return {};
    }
    const int count = getgroups(ngroups, groups.mutableSpan().data());
    if (count == -1) {
        throwSystemError(throwScope, globalObject, "getgroups"_s, errno);
        return {};
    }
    groups.shrink(count);
    return groups;
}

enum class NodeCredentialKind : uint8_t {
    user,
    group,
};

static uint32_t resolveNodeCredential(
    JSGlobalObject* globalObject,
    ThrowScope& scope,
    const Bindgen::NodeCredentialIdInput& input,
    NodeCredentialKind kind)
{
    if (input.is_number())
        return input.number();

    RELEASE_ASSERT(input.is_name());
    const auto& name = input.name();
    if (!name.contains('\0')) {
        auto utf8 = encodeUTF8ReplacingInvalidSequences(name, UTF8Termination::Null);
        if (!utf8) {
            throwOutOfMemoryError(globalObject, scope);
            return 0;
        }

        Vector<char, 1024> buffer;
        if (!buffer.tryGrow(1024)) {
            throwOutOfMemoryError(globalObject, scope);
            return 0;
        }
        for (;;) {
            int error;
            if (kind == NodeCredentialKind::user) {
                struct passwd entry;
                struct passwd* result = nullptr;
                error = getpwnam_r(reinterpret_cast<const char*>(utf8->span().data()), &entry, buffer.mutableSpan().data(), buffer.size(), &result);
                if (!error && result)
                    return result->pw_uid;
            } else {
                struct group entry;
                struct group* result = nullptr;
                error = getgrnam_r(reinterpret_cast<const char*>(utf8->span().data()), &entry, buffer.mutableSpan().data(), buffer.size(), &result);
                if (!error && result)
                    return result->gr_gid;
            }

            if (error == ERANGE) {
                if (buffer.size() > std::numeric_limits<size_t>::max() / 2 || !buffer.tryGrow(buffer.size() * 2)) {
                    throwOutOfMemoryError(globalObject, scope);
                    return 0;
                }
                continue;
            }
            if (error) {
                throwSystemError(scope, globalObject, kind == NodeCredentialKind::user ? "getpwnam_r"_s : "getgrnam_r"_s, error);
                return 0;
            }
            break;
        }
    }

    auto message = tryMakeString(
        kind == NodeCredentialKind::user ? "User identifier does not exist: "_s : "Group identifier does not exist: "_s,
        name);
    if (message.isNull()) {
        throwOutOfMemoryError(globalObject, scope);
        return 0;
    }
    scope.throwException(globalObject, Bun::createError(globalObject, Bun::ErrorCode::ERR_UNKNOWN_CREDENTIAL, message));
    return 0;
}

template<auto setId, NodeCredentialKind kind>
static int32_t setCredentialId(Bindgen::CppCallContext& context, const Bindgen::NodeCredentialIdInput& input, ASCIILiteral syscall)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(globalObject));
    auto id = resolveNodeCredential(globalObject, scope, input, kind);
    RETURN_IF_EXCEPTION(scope, 0);
    auto result = setId(id);
    if (result != 0)
        throwSystemError(scope, globalObject, syscall, errno);
    RETURN_IF_EXCEPTION(scope, 0);
    scope.release();
    return result;
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_setuid(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setuid_Arguments& args)
{
    return setCredentialId<::setuid, NodeCredentialKind::user>(context, args.id, "setuid"_s);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_seteuid(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_seteuid_Arguments& args)
{
    return setCredentialId<::seteuid, NodeCredentialKind::user>(context, args.id, "seteuid"_s);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_setegid(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setegid_Arguments& args)
{
    return setCredentialId<::setegid, NodeCredentialKind::group>(context, args.id, "setegid"_s);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_setgid(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setgid_Arguments& args)
{
    return setCredentialId<::setgid, NodeCredentialKind::group>(context, args.id, "setgid"_s);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_setgroups(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setgroups_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(globalObject));
    Vector<gid_t> groups;
    if (!groups.tryGrow(args.groups.size())) {
        throwOutOfMemoryError(globalObject, scope);
        return 0;
    }
    for (size_t index = 0; index < args.groups.size(); ++index) {
        groups[index] = resolveNodeCredential(globalObject, scope, args.groups.span()[index], NodeCredentialKind::group);
        RETURN_IF_EXCEPTION(scope, 0);
    }
    auto result = ::setgroups(groups.size(), groups.span().data());
    if (result != 0)
        throwSystemError(scope, globalObject, "setgroups"_s, errno);
    RETURN_IF_EXCEPTION(scope, 0);
    scope.release();
    return result;
}

#else

WTF::Vector<uint32_t> Bindgen::Cpp::bunBindgenCpp_ProcessHost_getgroups(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_getgroups_Arguments&)
{
    return {};
}

#define BUN_PROCESS_WINDOWS_CREDENTIAL_STUB(name)                          \
    int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_##name(                \
        Bindgen::CppCallContext&,                                          \
        const Bindgen::Cpp::BunBindgenCpp_ProcessHost_##name##_Arguments&) \
    {                                                                      \
        return 0;                                                          \
    }

BUN_PROCESS_WINDOWS_CREDENTIAL_STUB(setegid)
BUN_PROCESS_WINDOWS_CREDENTIAL_STUB(seteuid)
BUN_PROCESS_WINDOWS_CREDENTIAL_STUB(setgid)
BUN_PROCESS_WINDOWS_CREDENTIAL_STUB(setgroups)
BUN_PROCESS_WINDOWS_CREDENTIAL_STUB(setuid)

#undef BUN_PROCESS_WINDOWS_CREDENTIAL_STUB

#endif

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_assert(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_assert_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    if (args.condition) {
        return;
    }

    if (!args.message) {
        Bun::ERR::ASSERTION(throwScope, globalObject, "assertion error"_s);
        return;
    }

    const auto* message = args.message->convert();
    RETURN_IF_EXCEPTION(throwScope, void());
    if (!message)
        return;
    if (*message) {
        Bun::ERR::ASSERTION(throwScope, globalObject, **message);
        return;
    }
    Bun::ERR::ASSERTION(throwScope, globalObject, "assertion error"_s);
}

#define PROCESS_BINDING_NOT_IMPLEMENTED_ISSUE(str, issue)                                                                                                                                                                                \
    {                                                                                                                                                                                                                                    \
        throwScope.throwException(globalObject, createError(globalObject, String("process.binding(\"" str "\") is not implemented in Bun. Track the status & thumbs up the issue: https://github.com/oven-sh/bun/issues/" issue ""_s))); \
        return JSValue {};                                                                                                                                                                                                               \
    }

#define PROCESS_BINDING_NOT_IMPLEMENTED(str)                                                                                                                                                                                            \
    {                                                                                                                                                                                                                                   \
        throwScope.throwException(globalObject, createError(globalObject, String("process.binding(\"" str "\") is not implemented in Bun. If that breaks something, please file an issue and include a reproducible code sample."_s))); \
        return JSValue {};                                                                                                                                                                                                              \
    }

inline JSValue processBindingUtil(Zig::GlobalObject* globalObject, JSC::VM& vm)
{
    return globalObject->internalModuleRegistry()->requireId(globalObject, vm, InternalModuleRegistry::Field::NodeUtilTypes);
}

#ifdef BUN_DEBUG
inline constexpr bool ProcessBindingConfigIsDebugBuild = true;
#else
inline constexpr bool ProcessBindingConfigIsDebugBuild = false;
#endif

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingConfig
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingConfig

inline JSValue processBindingConfig(Zig::GlobalObject* globalObject, JSC::VM& vm)
{
    auto config = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 9);
    bunBindgenObjectSurface_ProcessBindingConfig_install(vm, config->classInfo(), *config);
    return config;
}

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingCryptoX509
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingCryptoX509

JSValue createCryptoX509Object(JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    auto cryptoX509 = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 1);
    bunBindgenObjectSurface_ProcessBindingCryptoX509_install(vm, cryptoX509->classInfo(), *cryptoX509);
    return cryptoX509;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_binding(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_binding_Arguments& args)
{
    auto* jsGlobalObject = &context.globalObject;
    auto& vm = JSC::getVM(jsGlobalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto globalObject = uncheckedDowncast<Zig::GlobalObject>(jsGlobalObject);
    auto process = globalObject->processObject();
    const auto& moduleName = args.moduleName;

    if (moduleName == "async_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("async_wrap");
    if (moduleName == "buffer"_s) return globalObject->processBindingBuffer();
    if (moduleName == "cares_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("cares_wrap");
    if (moduleName == "config"_s) return processBindingConfig(globalObject, vm);
    if (moduleName == "constants"_s) return globalObject->processBindingConstants();
    if (moduleName == "contextify"_s) PROCESS_BINDING_NOT_IMPLEMENTED("contextify");
    if (moduleName == "crypto"_s) PROCESS_BINDING_NOT_IMPLEMENTED("crypto");
    if (moduleName == "crypto/x509"_s) return createCryptoX509Object(globalObject);
    if (moduleName == "fs"_s) RELEASE_AND_RETURN(throwScope, globalObject->processBindingFs());
    if (moduleName == "fs_event_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("fs_event_wrap");
    if (moduleName == "http_parser"_s) return globalObject->processBindingHTTPParser();
    if (moduleName == "icu"_s) PROCESS_BINDING_NOT_IMPLEMENTED("icu");
    if (moduleName == "inspector"_s) PROCESS_BINDING_NOT_IMPLEMENTED("inspector");
    if (moduleName == "js_stream"_s) PROCESS_BINDING_NOT_IMPLEMENTED("js_stream");
    if (moduleName == "natives"_s) return process->bindingNatives();
    if (moduleName == "os"_s) PROCESS_BINDING_NOT_IMPLEMENTED("os");
    if (moduleName == "pipe_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("pipe_wrap");
    if (moduleName == "process_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("process_wrap");
    if (moduleName == "signal_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("signal_wrap");
    if (moduleName == "spawn_sync"_s) PROCESS_BINDING_NOT_IMPLEMENTED("spawn_sync");
    if (moduleName == "stream_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED_ISSUE("stream_wrap", "4957");
    if (moduleName == "tcp_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("tcp_wrap");
    if (moduleName == "tls_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("tls_wrap");
    if (moduleName == "tty_wrap"_s) return Bun::createNodeTTYWrapObject(globalObject);
    if (moduleName == "udp_wrap"_s) PROCESS_BINDING_NOT_IMPLEMENTED("udp_wrap");
    if (moduleName == "url"_s) PROCESS_BINDING_NOT_IMPLEMENTED("url");
    if (moduleName == "util"_s) RELEASE_AND_RETURN(throwScope, processBindingUtil(globalObject, vm));
    if (moduleName == "uv"_s) return process->bindingUV();
    if (moduleName == "v8"_s) PROCESS_BINDING_NOT_IMPLEMENTED("v8");
    if (moduleName == "zlib"_s) PROCESS_BINDING_NOT_IMPLEMENTED("zlib");

    throwScope.throwException(globalObject, createError(globalObject, makeString("No such module: "_s, moduleName)));
    return {};
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_reallyExit(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_reallyExit_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
    auto* zigGlobal = defaultGlobalObject(globalObject);
    Bun::Bindgen::ZigExports::bunBindgenZig_Process_exit(zigGlobal, args.code);
    // Main-thread process exit is noreturn. In a worker it returns; the
    // Zig WebWorker.exit() it called requests JSC termination (guarded so it's a
    // no-op when re-entered from a process.on('exit') handler).
    throwScope.release();
}

template<typename Visitor>
void Process::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    Process* thisObject = uncheckedDowncast<Process>(cell);
    ASSERT_GC_OBJECT_INHERITS(thisObject, info());
    Base::visitChildren(thisObject, visitor);
    visitor.append(thisObject->m_uncaughtExceptionCaptureCallback);
    visitor.append(thisObject->m_nextTickFunction);
    visitor.append(thisObject->m_cachedCwd);

    thisObject->m_bindingUV.visit(visitor);
    thisObject->m_bindingNatives.visit(visitor);
    thisObject->m_emitHelperFunction.visit(visitor);
}

DEFINE_VISIT_CHILDREN(Process);

static Process* processObject(JSValue value)
{
    auto* process = dynamicDowncast<Process>(value);
    RELEASE_ASSERT(process);
    return process;
}

static Process* processObject(const std::optional<JSValue>& value)
{
    if (!value)
        return nullptr;
    return processObject(*value);
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_getCanonicalProcess(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_getCanonicalProcess_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->processObject();
}

static Process* getProcessObject(JSC::JSGlobalObject* lexicalGlobalObject, const Bindgen::ProcessObjectReceiverInput& input)
{
    if (input.is_process())
        return processObject(input.process());

    return defaultGlobalObject(lexicalGlobalObject)->processObject();
}

Bindgen::NodeResourceUsageResult Bindgen::Cpp::bunBindgenCpp_ProcessHost_resourceUsage(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_resourceUsage_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

#if !OS(WINDOWS)
    struct rusage rusage;
    if (getrusage(RUSAGE_SELF, &rusage) != 0) {
        throwSystemError(throwScope, globalObject, "Failed to get resource usage"_s, "getrusage"_s, errno);
        return {};
    }
#else
    uv_rusage_t rusage;
    int err = uv_getrusage(&rusage);
    if (err) {
        throwSystemError(throwScope, globalObject, "uv_getrusage"_s, err);
        return {};
    }
#endif
    throwScope.release();
    return {
        .userCPUTime = static_cast<double>(std::chrono::microseconds::period::den * rusage.ru_utime.tv_sec + rusage.ru_utime.tv_usec),
        .systemCPUTime = static_cast<double>(std::chrono::microseconds::period::den * rusage.ru_stime.tv_sec + rusage.ru_stime.tv_usec),
        .maxRSS = static_cast<double>(rusage.ru_maxrss),
        .sharedMemorySize = static_cast<double>(rusage.ru_ixrss),
        .unsharedDataSize = static_cast<double>(rusage.ru_idrss),
        .unsharedStackSize = static_cast<double>(rusage.ru_isrss),
        .minorPageFault = static_cast<double>(rusage.ru_minflt),
        .majorPageFault = static_cast<double>(rusage.ru_majflt),
        .swappedOut = static_cast<double>(rusage.ru_nswap),
        .fsRead = static_cast<double>(rusage.ru_inblock),
        .fsWrite = static_cast<double>(rusage.ru_oublock),
        .ipcSent = static_cast<double>(rusage.ru_msgsnd),
        .ipcReceived = static_cast<double>(rusage.ru_msgrcv),
        .signalsCount = static_cast<double>(rusage.ru_nsignals),
        .voluntaryContextSwitches = static_cast<double>(rusage.ru_nvcsw),
        .involuntaryContextSwitches = static_cast<double>(rusage.ru_nivcsw),
    };
}

Bindgen::NodeCPUUsageResult Bindgen::Cpp::bunBindgenCpp_ProcessHost_cpuUsage(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_cpuUsage_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);
#if !OS(WINDOWS)
    struct rusage rusage;
    if (getrusage(RUSAGE_SELF, &rusage) != 0) {
        throwSystemError(throwScope, globalObject, "Failed to get CPU usage"_s, "getrusage"_s, errno);
        return {};
    }
#else
    uv_rusage_t rusage;
    int err = uv_getrusage(&rusage);
    if (err) {
        throwSystemError(throwScope, globalObject, "Failed to get CPU usage"_s, "uv_getrusage"_s, err);
        return {};
    }
#endif

    double user = std::chrono::microseconds::period::den * rusage.ru_utime.tv_sec + rusage.ru_utime.tv_usec;
    double system = std::chrono::microseconds::period::den * rusage.ru_stime.tv_sec + rusage.ru_stime.tv_usec;

    if (args.prevValue.has_value()) {
        user -= args.prevValue->user;
        system -= args.prevValue->system;
    }

    throwScope.release();
    return {
        .user = user,
        .system = system,
    };
}

namespace Bindgen::Cpp {

NodeMemoryUsageResult bunBindgenCpp_ProcessHost_memoryUsage(CppCallContext& context, const BunBindgenCpp_ProcessHost_memoryUsage_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    size_t current_rss = 0;
    if (int error = bun_process_resident_memory(&current_rss)) {
        throwSystemError(throwScope, globalObject, "Failed to get memory usage"_s, "memoryUsage"_s, error);
        return {};
    }

    throwScope.release();
    return {
        .rss = static_cast<double>(current_rss),
        .heapTotal = static_cast<double>(vm.heap.blockBytesAllocated()),
        .heapUsed = static_cast<double>(vm.heap.sizeAfterLastEdenCollection()),
        .external = static_cast<double>(vm.heap.extraMemorySize() + vm.heap.externalMemorySize()),
        .arrayBuffers = static_cast<double>(vm.heap.arrayBufferSize()),
    };
}

uint64_t bunBindgenCpp_ProcessHost_memoryUsageRSS(CppCallContext& context, const BunBindgenCpp_ProcessHost_memoryUsageRSS_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    size_t current_rss = 0;
    if (int error = bun_process_resident_memory(&current_rss)) {
        throwSystemError(throwScope, globalObject, "Failed to get memory usage"_s, "memoryUsage"_s, error);
        return 0;
    }

    throwScope.release();
    return current_rss;
}

}

std::optional<JSC::JSValue> Bindgen::Cpp::bunBindgenCpp_ProcessHost_openStdin(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_openStdin_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    Zig::GlobalObject* global = defaultGlobalObject(globalObject);
    auto throwScope = DECLARE_THROW_SCOPE(vm);

    auto stdinValue = global->processObject()->getIfPropertyExists(globalObject, Identifier::fromString(vm, "stdin"_s));
    RETURN_IF_EXCEPTION(throwScope, {});
    if (stdinValue) {
        if (!stdinValue.isObject()) {
            throwTypeError(globalObject, throwScope, "stdin is not an object"_s);
            return {};
        }

        JSValue resumeValue = stdinValue.getObject()->getIfPropertyExists(globalObject, Identifier::fromString(vm, "resume"_s));
        RETURN_IF_EXCEPTION(throwScope, {});
        if (resumeValue && !resumeValue.isUndefinedOrNull()) {
            auto resumeFunction = dynamicDowncast<JSFunction>(resumeValue);
            if (!resumeFunction) [[unlikely]] {
                throwTypeError(globalObject, throwScope, "stdin.resume is not a function"_s);
                return {};
            }

            auto callData = getCallData(resumeFunction);

            MarkedArgumentBuffer args;
            JSC::profiledCall(globalObject, ProfilingReason::API, resumeFunction, callData, stdinValue, args);
            RETURN_IF_EXCEPTION(throwScope, {});
        }

        throwScope.release();
        return stdinValue;
    }

    throwScope.release();
    return std::nullopt;
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_ref(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_ref_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.value || args.value->is_ignored()) {
        return;
    }
    JSValue maybeRefable = args.value->object();

    JSValue ref = maybeRefable.get(globalObject, Identifier::fromUid(vm.symbolRegistry().symbolForKey("nodejs.ref"_s)));
    RETURN_IF_EXCEPTION(scope, void());

    auto refBoolean = ref.toBoolean(globalObject);
    RETURN_IF_EXCEPTION(scope, void());

    if (!refBoolean) {
        ref = maybeRefable.get(globalObject, Identifier::fromString(vm, "ref"_s));
        RETURN_IF_EXCEPTION(scope, void());
    }

    if (ref.isCallable()) {
        CallData callData = getCallData(ref);
        JSC::profiledCall(globalObject, ProfilingReason::API, ref, callData, maybeRefable, {});
        RETURN_IF_EXCEPTION(scope, void());
    }

    RELEASE_AND_RETURN(scope, void());
}

void Bindgen::Cpp::bunBindgenCpp_ProcessHost_unref(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_unref_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!args.value || args.value->is_ignored()) {
        return;
    }
    JSValue maybeUnrefable = args.value->object();

    JSValue unref = maybeUnrefable.get(globalObject, Identifier::fromUid(vm.symbolRegistry().symbolForKey("nodejs.unref"_s)));
    RETURN_IF_EXCEPTION(scope, void());

    auto unrefBoolean = unref.toBoolean(globalObject);
    RETURN_IF_EXCEPTION(scope, void());

    if (!unrefBoolean) {
        unref = maybeUnrefable.get(globalObject, Identifier::fromString(vm, "unref"_s));
        RETURN_IF_EXCEPTION(scope, void());
    }

    if (unref.isCallable()) {
        CallData callData = getCallData(unref);
        JSC::profiledCall(globalObject, ProfilingReason::API, unref, callData, maybeUnrefable, {});
        RETURN_IF_EXCEPTION(scope, void());
    }

    RELEASE_AND_RETURN(scope, void());
}

namespace Bindgen::Cpp {

void bunBindgenCpp_ProcessHost_abort(CppCallContext&, const BunBindgenCpp_ProcessHost_abort_Arguments&)
{
#if OS(WINDOWS)
    _exit(134);
#endif
    ::abort();
}

uint64_t bunBindgenCpp_ProcessHost_constrainedMemory(CppCallContext&, const BunBindgenCpp_ProcessHost_constrainedMemory_Arguments&)
{
    return static_cast<uint64_t>(WTF::ramSize());
}

void bunBindgenCpp_ProcessHost_empty(CppCallContext&, const BunBindgenCpp_ProcessHost_empty_Arguments&)
{
}

void bunBindgenCpp_ProcessHost_fatalException(CppCallContext&, const BunBindgenCpp_ProcessHost_fatalException_Arguments&)
{
}

uint32_t bunBindgenCpp_ProcessHost_getegid(CppCallContext&, const BunBindgenCpp_ProcessHost_getegid_Arguments&)
{
#if OS(WINDOWS)
    return 0;
#else
    return ::getegid();
#endif
}

uint32_t bunBindgenCpp_ProcessHost_geteuid(CppCallContext&, const BunBindgenCpp_ProcessHost_geteuid_Arguments&)
{
#if OS(WINDOWS)
    return 0;
#else
    return ::geteuid();
#endif
}

uint32_t bunBindgenCpp_ProcessHost_getgid(CppCallContext&, const BunBindgenCpp_ProcessHost_getgid_Arguments&)
{
#if OS(WINDOWS)
    return 0;
#else
    return ::getgid();
#endif
}

uint32_t bunBindgenCpp_ProcessHost_getuid(CppCallContext&, const BunBindgenCpp_ProcessHost_getuid_Arguments&)
{
#if OS(WINDOWS)
    return 0;
#else
    return ::getuid();
#endif
}

bool bunBindgenCpp_ProcessHost_hasUncaughtExceptionCaptureCallback(CppCallContext& context, const BunBindgenCpp_ProcessHost_hasUncaughtExceptionCaptureCallback_Arguments&)
{
    auto* globalObject = defaultGlobalObject(&context.globalObject);
    JSC::JSValue callback = globalObject->processObject()->getUncaughtExceptionCaptureCallback();
    return !callback.isEmpty() && callback.isCell();
}

void bunBindgenCpp_ProcessHost_setSourceMapsEnabled(CppCallContext& context, const BunBindgenCpp_ProcessHost_setSourceMapsEnabled_Arguments& args)
{
    defaultGlobalObject(&context.globalObject)->processObject()->m_sourceMapsEnabled = args.enabled;
}

void bunBindgenCpp_ProcessHost_reportUncaughtException(CppCallContext& context, const BunBindgenCpp_ProcessHost_reportUncaughtException_Arguments& args)
{
    ZigExports::bunBindgenZig_errors_reportUnhandledError(&context.globalObject, args.value);
}

void bunBindgenCpp_ProcessHost_drainMicrotaskQueue(CppCallContext& context, const BunBindgenCpp_ProcessHost_drainMicrotaskQueue_Arguments&)
{
    context.globalObject.vm().drainMicrotasks();
}

double bunBindgenCpp_ProcessHost_uptime(CppCallContext& context, const BunBindgenCpp_ProcessHost_uptime_Arguments&)
{
    double now = static_cast<double>(ZigExports::bunBindgenZig_virtual_machine_readOriginTimer(bunVM(&context.globalObject)));
    return (now / 1000000.0) / 1000.0;
}

}

std::optional<JSNextTickQueue::PreparedTask> Process::prepareNextTick(Zig::GlobalObject* globalObject, JSValue callback, std::span<const JSValue> arguments)
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    if (arguments.size() > std::numeric_limits<unsigned>::max()) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    MarkedArgumentBuffer rootedArguments;
    rootedArguments.ensureCapacity(arguments.size());
    if (rootedArguments.hasOverflowed()) {
        throwOutOfMemoryError(globalObject, scope);
        return std::nullopt;
    }
    for (auto argument : arguments) {
        RELEASE_ASSERT(argument);
        rootedArguments.append(argument);
    }
    RELEASE_AND_RETURN(scope, prepareNextTick(globalObject, callback, ArgList { rootedArguments }));
}

std::optional<JSNextTickQueue::PreparedTask> Process::prepareNextTick(Zig::GlobalObject* globalObject, JSValue callback, const ArgList& arguments, JSValue receiver)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!m_nextTickFunction) {
        constructNextTickFn(vm, globalObject);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }
    auto exiting = get(globalObject, Identifier::fromString(vm, "_exiting"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (exiting.toBoolean(globalObject))
        return JSNextTickQueue::PreparedTask {};

    JSArray* array = nullptr;
    if (!arguments.isEmpty()) {
        array = constructEmptyArray(globalObject, nullptr, static_cast<unsigned>(arguments.size()));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        for (unsigned index = 0; index < arguments.size(); ++index) {
            RELEASE_ASSERT(arguments.at(index));
            array->putDirectIndex(globalObject, index, arguments.at(index));
            RETURN_IF_EXCEPTION(scope, std::nullopt);
        }
    }
    RELEASE_AND_RETURN(scope, globalObject->m_nextTickQueue.get()->prepareTask(*globalObject, callback, array, receiver));
}

void Process::queueNextTick(JSC::JSGlobalObject* globalObject, JSValue callback, JSValue argument)
{
    const JSValue arguments[] = { argument };
    queueNextTick(globalObject, callback, std::span<const JSValue> { arguments });
}

void Process::queueNextTick(JSC::JSGlobalObject* globalObject, JSValue callback, std::span<const JSValue> arguments)
{
    auto prepared = prepareNextTick(defaultGlobalObject(globalObject), callback, arguments);
    if (prepared)
        prepared->commit();
}

std::optional<JSNextTickQueue::PreparedTask> Process::prepareEmitOnNextTick(Zig::GlobalObject* globalObject, ASCIILiteral eventName, JSValue event)
{
    auto& vm = getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = m_emitHelperFunction.getInitializedOnMainThread(this);
    const JSValue arguments[] = { this, jsString(vm, String(eventName)), event };
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    RELEASE_AND_RETURN(scope, prepareNextTick(globalObject, function, arguments));
}

void Bindgen::Engine::bunBindgenEngine_NodeCluster_scheduleProcessErrorEvent(
    Bindgen::EngineCallContext& context,
    const Bindgen::Engine::BunBindgenEngine_NodeCluster_scheduleProcessErrorEvent_Arguments& args)
{
    auto* globalObject = uncheckedDowncast<Zig::GlobalObject>(&context.globalObject);
    auto& vm = globalObject->vm();
    auto* function = JSFunction::create(
        vm,
        globalObject,
        1,
        String(),
        ::bun_bindgen_host_NodeCluster_emitProcessErrorEvent,
        ImplementationVisibility::Public,
        NoIntrinsic,
        callHostFunctionAsConstructor,
        nullptr);
    globalObject->processObject()->queueNextTick(globalObject, function, args.errorValue);
}

// This does the equivalent of
// return require.cache.get(Bun.main)
static JSValue constructMainModuleProperty(VM& vm, JSObject* processObject)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* globalObject = defaultGlobalObject(processObject->globalObject());
    auto* bun = globalObject->bunObject();
    RETURN_IF_EXCEPTION(scope, {});
    auto& builtinNames = Bun::builtinNames(vm);
    JSValue mainValue = bun->get(globalObject, builtinNames.mainPublicName());
    RETURN_IF_EXCEPTION(scope, {});
    auto* requireMap = globalObject->requireMap();
    RETURN_IF_EXCEPTION(scope, {});
    JSValue mainModule = requireMap->get(globalObject, mainValue);
    RETURN_IF_EXCEPTION(scope, {});
    return mainModule;
}

JSValue Process::constructNextTickFn(JSC::VM& vm, Zig::GlobalObject* globalObject)
{
    JSNextTickQueue* nextTickQueueObject;
    if (!globalObject->m_nextTickQueue) {
        nextTickQueueObject = JSNextTickQueue::create(globalObject);
        globalObject->m_nextTickQueue.set(vm, globalObject, nextTickQueueObject);
    } else {
        nextTickQueueObject = globalObject->m_nextTickQueue.get();
    }

    JSC::JSFunction* initializer = JSC::JSFunction::create(vm, globalObject, processObjectInternalsInitializeNextTickQueueCodeGenerator(vm), globalObject);

    JSC::MarkedArgumentBuffer args;
    args.append(this);
    args.append(nextTickQueueObject);
    args.append(JSC::JSFunction::create(vm, globalObject, 1, String(), bun_bindgen_host_ProcessHost_drainMicrotaskQueue, ImplementationVisibility::Private));
    args.append(JSC::JSFunction::create(vm, globalObject, 1, String(), bun_bindgen_host_ProcessHost_reportUncaughtException, ImplementationVisibility::Private));

    JSValue nextTickFunction = JSC::profiledCall(globalObject, ProfilingReason::API, initializer, JSC::getCallData(initializer), globalObject->globalThis(), args);
    if (nextTickFunction && nextTickFunction.isObject()) {
        this->m_nextTickFunction.set(vm, this, nextTickFunction.getObject());
    }

    return nextTickFunction;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_constructProcessNextTickFn(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_constructProcessNextTickFn_Arguments& args)
{
    auto* process = processObject(args.bindingThis);
    JSGlobalObject* lexicalGlobalObject = &context.globalObject;
    Zig::GlobalObject* globalObject = uncheckedDowncast<Zig::GlobalObject>(lexicalGlobalObject);
    return process->constructNextTickFn(JSC::getVM(globalObject), globalObject);
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_processNoDeprecation(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processNoDeprecation_Arguments&)
{
    return Process::noDeprecation();
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessNoDeprecation(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessNoDeprecation_Arguments& args)
{
    Process::setNoDeprecation(args.value);
    return true;
}

static uint16_t debugPort;

double Bindgen::Cpp::bunBindgenCpp_ProcessHost_processDebugPort(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processDebugPort_Arguments&)
{
    return debugPort;
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessDebugPort(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessDebugPort_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    double port = args.value;

    if (std::isnan(port) || std::isinf(port)) {
        port = 0;
    }

    if ((port != 0 && port < 1024) || port > 65535) {
        throwNodeRangeError(globalObject, scope, "process.debugPort must be 0 or in range 1024 to 65535"_s);
        return false;
    }

    debugPort = floor(port);
    return true;
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_processTitle(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processTitle_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
#if !OS(WINDOWS)
    auto value = Bun::Bindgen::ZigExports::bunBindgenZig_Process_getTitle(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_AND_RETURN(scope, value);
#else
    char title[1024];
    title[0] = '\0';
    if (uv_get_process_title(title, sizeof(title)) != 0 || title[0] == '\0') {
        RELEASE_AND_RETURN(scope, String("bun"_s));
    }

    RELEASE_AND_RETURN(scope, WTF::String::fromUTF8(title));
#endif
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_setProcessTitle(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_setProcessTitle_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* thisObject = args.bindingThis ? JSC::asObject(*args.bindingThis) : nullptr;
    auto* jsString = args.value ? JSC::asString(*args.value) : nullptr;
    if (!thisObject || !jsString) {
        return false;
    }
#if !OS(WINDOWS)
    WTF::String str = jsString->value(globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    Bun::Bindgen::ZigExports::bunBindgenZig_Process_setTitle(globalObject, str);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
#else
    WTF::String str = jsString->value(globalObject);
    RETURN_IF_EXCEPTION(scope, false);
    auto cstr = encodeUTF8ReplacingInvalidSequences(str, UTF8Termination::Null);
    if (!cstr) {
        throwOutOfMemoryError(globalObject, scope);
        return false;
    }
    return uv_set_process_title(reinterpret_cast<const char*>(cstr->span().data())) == 0;
#endif
}

static inline WTF::String getCachedCwd(JSC::JSGlobalObject* globalObject)
{
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);

    // https://github.com/nodejs/node/blob/2eff28fb7a93d3f672f80b582f664a7c701569fb/lib/internal/bootstrap/switches/does_own_process_state.js#L142-L146
    auto* processObject = defaultGlobalObject(globalObject)->processObject();
    if (auto* cached = processObject->cachedCwd()) {
        auto result = cached->value(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope, result);
    }

    auto cwd = Bun::Bindgen::ZigExports::bunBindgenZig_Process_getCwd(globalObject);
    RETURN_IF_EXCEPTION(scope, {});
    JSString* cwdStr = JSC::jsString(vm, cwd);
    processObject->setCachedCwd(vm, cwdStr);
    RELEASE_AND_RETURN(scope, cwd);
}

WTF::String Bindgen::Cpp::bunBindgenCpp_ProcessHost_cwd(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_cwd_Arguments&)
{
    return getCachedCwd(&context.globalObject);
}

int32_t Bindgen::Cpp::bunBindgenCpp_ProcessHost_reallyKill(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_reallyKill_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(JSC::getVM(globalObject));

    int pid = args.pid;
    int signal = args.signal;

#if !OS(WINDOWS)
    if (pid == getpid()) {
        Bun::Bindgen::ZigExports::bunBindgenZig_Process_suppressCrashOnProcessKillSelfIfDesired();
    }
    int result = kill(pid, signal);
    if (result < 0)
        result = errno;
#else
    int result = uv_kill(pid, signal);
#endif

    scope.release();
    return result;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_processObject(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processObject_Arguments&)
{
    return defaultGlobalObject(&context.globalObject)->processObject();
}

std::optional<uint8_t> Bindgen::Cpp::bunBindgenCpp_ProcessHost_processSignalNumber(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processSignalNumber_Arguments& args)
{
    if (args.signal.is_string())
        return signalNumberForName(args.signal.string());
    return std::nullopt;
}

bool Bindgen::Cpp::bunBindgenCpp_ProcessHost_processKillResult(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_processKillResult_Arguments& args)
{
    if (args.errorNumber) {
        auto* global = &context.globalObject;
        auto scope = DECLARE_THROW_SCOPE(global->vm());
        throwSystemError(scope, global, "kill"_s, args.errorNumber);
        return false;
    }
    return true;
}

JSC::JSValue Bindgen::Cpp::bunBindgenCpp_ProcessHost_loadBuiltinModule(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_ProcessHost_loadBuiltinModule_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto* zigGlobalObject = uncheckedDowncast<Zig::GlobalObject>(globalObject);
    VM& vm = zigGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    JSValue fetchResult = Bun::resolveAndFetchBuiltinModule(zigGlobalObject, args.moduleName);
    if (fetchResult) {
        RELEASE_AND_RETURN(scope, fetchResult);
    }

    RELEASE_AND_RETURN(scope, jsUndefined());
}

static void processEmitMessageEvent(Zig::GlobalObject* global, JSValue value)
{
    auto* process = global->processObject();
    auto& vm = JSC::getVM(global);

    auto ident = vm.propertyNames->message;
    if (process->wrapped().hasEventListeners(ident)) {
        JSC::MarkedArgumentBuffer args;
        args.append(value);
        args.append(JSC::jsUndefined());
        process->wrapped().emit(ident, args);
    }
}

static void processEmitDisconnectEvent(Zig::GlobalObject* global)
{
    auto* process = global->processObject();
    auto& vm = JSC::getVM(global);
    auto ident = Identifier::fromString(vm, "disconnect"_s);
    if (process->wrapped().hasEventListeners(ident)) {
        JSC::MarkedArgumentBuffer args;
        process->wrapped().emit(ident, args);
    }
}

static void processEmitErrorEvent(Zig::GlobalObject* global, JSValue value)
{
    auto* process = global->processObject();
    auto& vm = JSC::getVM(global);
    if (process->wrapped().hasEventListeners(vm.propertyNames->error)) {
        JSC::MarkedArgumentBuffer args;
        args.append(value);
        process->wrapped().emit(vm.propertyNames->error, args);
    }
}

bool Bindgen::Engine::bunBindgenEngine_ProcessHost_processHandleUncaughtException(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processHandleUncaughtException_Arguments& args)
{
    return processHandleUncaughtException(&context.globalObject, args.exception, args.isRejection);
}

bool Bindgen::Engine::bunBindgenEngine_ProcessHost_processHandleUnhandledRejection(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processHandleUnhandledRejection_Arguments& args)
{
    return processHandleUnhandledRejection(&context.globalObject, args.reason, args.promise.value_or(jsUndefined()));
}

bool Bindgen::Engine::bunBindgenEngine_ProcessHost_processEmitHandledPromiseEvent(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processEmitHandledPromiseEvent_Arguments& args)
{
    return processEmitHandledPromiseEvent(&context.globalObject, args.promise);
}

void Bindgen::Engine::bunBindgenEngine_ProcessHost_processEmitMessageEvent(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processEmitMessageEvent_Arguments& args)
{
    processEmitMessageEvent(defaultGlobalObject(&context.globalObject), args.value);
}

void Bindgen::Engine::bunBindgenEngine_ProcessHost_processEmitDisconnectEvent(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processEmitDisconnectEvent_Arguments&)
{
    processEmitDisconnectEvent(defaultGlobalObject(&context.globalObject));
}

void Bindgen::Engine::bunBindgenEngine_NodeCluster_processEmitErrorEvent(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_NodeCluster_processEmitErrorEvent_Arguments& args)
{
    processEmitErrorEvent(defaultGlobalObject(&context.globalObject), Bun::extractErrorValue(args.value).value_or(args.value));
}

void Bindgen::Engine::bunBindgenEngine_ProcessHost_processDispatchOnBeforeExit(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processDispatchOnBeforeExit_Arguments& args)
{
    processDispatchOnBeforeExit(defaultGlobalObject(&context.globalObject), args.exitCode);
}

void Bindgen::Engine::bunBindgenEngine_ProcessHost_processDispatchOnExit(
    Bindgen::EngineCallContext& context,
    const BunBindgenEngine_ProcessHost_processDispatchOnExit_Arguments& args)
{
    processDispatchOnExit(defaultGlobalObject(&context.globalObject), args.exitCode);
}

const JSC::ClassInfo Process::s_info
    = { "Process"_s, &Base::s_info, &bunBindgenObjectSurface_BunProcessTable, nullptr,
          CREATE_METHOD_TABLE(Process) };

void Process::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);

    wrapped().onDidChangeListener = &onDidChangeListeners;

    m_bindingUV.initLater([](const JSC::LazyProperty<Process, JSC::JSObject>::Initializer& init) {
        init.set(Bun::ProcessBindingUV::create(init.vm, init.owner->globalObject()));
    });
    m_bindingNatives.initLater([](const JSC::LazyProperty<Process, JSC::JSObject>::Initializer& init) {
        init.set(Bun::ProcessBindingNatives::create(init.vm, ProcessBindingNatives::createStructure(init.vm, init.owner->globalObject())));
    });
    m_emitHelperFunction.initLater([](const JSC::LazyProperty<Process, JSFunction>::Initializer& init) {
        auto* global = init.owner->globalObject();
        init.set(JSFunction::create(init.vm, global, processObjectInternalsEmitHelperCodeGenerator(init.vm), global));
    });
    bunBindgenObjectSurface_BunProcess_install(vm, info(), *this);
}

#define BUN_DEFINE_LAZY_SURFACE_FUNCTION(Module, Function, ReturnType, Callback)     \
    ReturnType Bindgen::Cpp::bunBindgenCpp_##Module##_##Function(                    \
        Bindgen::CppCallContext& context,                                            \
        const Bindgen::Cpp::BunBindgenCpp_##Module##_##Function##_Arguments& args)   \
    {                                                                                \
        return Callback(context.globalObject.vm(), processObject(args.bindingThis)); \
    }

BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessHost, constructProcessChannel, std::optional<JSC::JSValue>, constructProcessChannel)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessHost, constructEnv, JSC::JSValue, constructEnv)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessHost, constructMainModuleProperty, JSC::JSValue, constructMainModuleProperty)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessHost, constructStderr, std::optional<JSC::JSValue>, constructStderr)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessHost, constructStdin, std::optional<JSC::JSValue>, constructStdin)
BUN_DEFINE_LAZY_SURFACE_FUNCTION(ProcessHost, constructStdout, std::optional<JSC::JSValue>, constructStdout)

#undef BUN_DEFINE_LAZY_SURFACE_FUNCTION

} // namespace Bun
