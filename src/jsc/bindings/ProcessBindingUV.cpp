#include "ProcessBindingUV.h"
#include "SchemaBindings.h"
#include "JavaScriptCore/ArrayAllocationProfile.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/ThrowScope.h"
#include "ZigGlobalObject.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/JSMap.h"
#include "JavaScriptCore/JSMapInlines.h"

// clang-format off

#if !defined(E2BIG)
#define E2BIG 7
#endif
#if !defined(EACCES)
#define EACCES 13
#endif
#if !defined(EADDRINUSE)
#define EADDRINUSE 48
#endif
#if !defined(EADDRNOTAVAIL)
#define EADDRNOTAVAIL 49
#endif
#if !defined(EAFNOSUPPORT)
#define EAFNOSUPPORT 47
#endif
#if !defined(EAGAIN)
#define EAGAIN 35
#endif
// EAI_* are libuv's fixed UV__EAI_* values (uv/errno.h), NOT the host's
// getaddrinfo codes. Unconditionally redefine — if <netdb.h> was included
// earlier (directly or via a unified-build sibling) its values are wrong
// here: e.g. glibc's EAI_NODATA is -5, so `err == -EAI_NODATA` would
// match 5 instead of -3007.
#undef EAI_ADDRFAMILY
#define EAI_ADDRFAMILY 3000
#undef EAI_AGAIN
#define EAI_AGAIN 3001
#undef EAI_BADFLAGS
#define EAI_BADFLAGS 3002
#undef EAI_BADHINTS
#define EAI_BADHINTS 3013
#undef EAI_CANCELED
#define EAI_CANCELED 3003
#undef EAI_FAIL
#define EAI_FAIL 3004
#undef EAI_FAMILY
#define EAI_FAMILY 3005
#undef EAI_MEMORY
#define EAI_MEMORY 3006
#undef EAI_NODATA
#define EAI_NODATA 3007
#undef EAI_NONAME
#define EAI_NONAME 3008
#undef EAI_OVERFLOW
#define EAI_OVERFLOW 3009
#undef EAI_PROTOCOL
#define EAI_PROTOCOL 3014
#undef EAI_SERVICE
#define EAI_SERVICE 3010
#undef EAI_SOCKTYPE
#define EAI_SOCKTYPE 3011
#if !defined(EALREADY)
#define EALREADY 37
#endif
#if !defined(EBADF)
#define EBADF 9
#endif
#if !defined(EBUSY)
#define EBUSY 16
#endif
#if !defined(ECANCELED)
#define ECANCELED 89
#endif
#if !defined(ECHARSET)
#define ECHARSET 4080
#endif
#if !defined(ECONNABORTED)
#define ECONNABORTED 53
#endif
#if !defined(ECONNREFUSED)
#define ECONNREFUSED 61
#endif
#if !defined(ECONNRESET)
#define ECONNRESET 54
#endif
#if !defined(EDESTADDRREQ)
#define EDESTADDRREQ 39
#endif
#if !defined(EEXIST)
#define EEXIST 17
#endif
#if !defined(EFAULT)
#define EFAULT 14
#endif
#if !defined(EFBIG)
#define EFBIG 27
#endif
#if !defined(EHOSTUNREACH)
#define EHOSTUNREACH 65
#endif
#if !defined(EINTR)
#define EINTR 4
#endif
#if !defined(EINVAL)
#define EINVAL 22
#endif
#if !defined(EIO)
#define EIO 5
#endif
#if !defined(EISCONN)
#define EISCONN 56
#endif
#if !defined(EISDIR)
#define EISDIR 21
#endif
#if !defined(ELOOP)
#define ELOOP 62
#endif
#if !defined(EMFILE)
#define EMFILE 24
#endif
#if !defined(EMSGSIZE)
#define EMSGSIZE 40
#endif
#if !defined(ENAMETOOLONG)
#define ENAMETOOLONG 63
#endif
#if !defined(ENETDOWN)
#define ENETDOWN 50
#endif
#if !defined(ENETUNREACH)
#define ENETUNREACH 51
#endif
#if !defined(ENFILE)
#define ENFILE 23
#endif
#if !defined(ENOBUFS)
#define ENOBUFS 55
#endif
#if !defined(ENODEV)
#define ENODEV 19
#endif
#if !defined(ENOENT)
#define ENOENT 2
#endif
#if !defined(ENOMEM)
#define ENOMEM 12
#endif
#if !defined(ENONET)
#define ENONET 4056
#endif
#if !defined(ENOPROTOOPT)
#define ENOPROTOOPT 42
#endif
#if !defined(ENOSPC)
#define ENOSPC 28
#endif
#if !defined(ENOSYS)
#define ENOSYS 78
#endif
#if !defined(ENOTCONN)
#define ENOTCONN 57
#endif
#if !defined(ENOTDIR)
#define ENOTDIR 20
#endif
#if !defined(ENOTEMPTY)
#define ENOTEMPTY 66
#endif
#if !defined(ENOTSOCK)
#define ENOTSOCK 38
#endif
#if !defined(ENOTSUP)
#define ENOTSUP 45
#endif
#if !defined(EOVERFLOW)
#define EOVERFLOW 84
#endif
#if !defined(EPERM)
#define EPERM 1
#endif
#if !defined(EPIPE)
#define EPIPE 32
#endif
#if !defined(EPROTO)
#define EPROTO 100
#endif
#if !defined(EPROTONOSUPPORT)
#define EPROTONOSUPPORT 43
#endif
#if !defined(EPROTOTYPE)
#define EPROTOTYPE 41
#endif
#if !defined(ERANGE)
#define ERANGE 34
#endif
#if !defined(EROFS)
#define EROFS 30
#endif
#if !defined(ESHUTDOWN)
#define ESHUTDOWN 58
#endif
#if !defined(ESPIPE)
#define ESPIPE 29
#endif
#if !defined(ESRCH)
#define ESRCH 3
#endif
#if !defined(ETIMEDOUT)
#define ETIMEDOUT 60
#endif
#if !defined(ETXTBSY)
#define ETXTBSY 26
#endif
#if !defined(EXDEV)
#define EXDEV 18
#endif
#if !defined(UNKNOWN)
#define UNKNOWN 4094
#endif
// this is intentionally always overridden
#if defined(EOF)
#undef EOF
#endif
#define EOF 4095
#if !defined(ENXIO)
#define ENXIO 6
#endif
#if !defined(EMLINK)
#define EMLINK 31
#endif
#if !defined(EHOSTDOWN)
#define EHOSTDOWN 64
#endif
#if !defined(EREMOTEIO)
#define EREMOTEIO 4030
#endif
#if !defined(ENOTTY)
#define ENOTTY 25
#endif
#if !defined(EFTYPE)
#define EFTYPE 79
#endif
#if !defined(EILSEQ)
#define EILSEQ 92
#endif
#if !defined(ESOCKTNOSUPPORT)
#define ESOCKTNOSUPPORT 44
#endif
#if !defined(ENODATA)
#define ENODATA 96
#endif
#if !defined(EUNATCH)
#define EUNATCH 4023
#endif

#define BUN_UV_ERRNO_MAP(macro) \
  macro(E2BIG, "argument list too long") \
  macro(EACCES, "permission denied") \
  macro(EADDRINUSE, "address already in use") \
  macro(EADDRNOTAVAIL, "address not available") \
  macro(EAFNOSUPPORT, "address family not supported") \
  macro(EAGAIN, "resource temporarily unavailable") \
  macro(EAI_ADDRFAMILY, "address family not supported") \
  macro(EAI_AGAIN, "temporary failure") \
  macro(EAI_BADFLAGS, "bad ai_flags value") \
  macro(EAI_BADHINTS, "invalid value for hints") \
  macro(EAI_CANCELED, "request canceled") \
  macro(EAI_FAIL, "permanent failure") \
  macro(EAI_FAMILY, "ai_family not supported") \
  macro(EAI_MEMORY, "out of memory") \
  macro(EAI_NODATA, "no address") \
  macro(EAI_NONAME, "unknown node or service") \
  macro(EAI_OVERFLOW, "argument buffer overflow") \
  macro(EAI_PROTOCOL, "resolved protocol is unknown") \
  macro(EAI_SERVICE, "service not available for socket type") \
  macro(EAI_SOCKTYPE, "socket type not supported") \
  macro(EALREADY, "connection already in progress") \
  macro(EBADF, "bad file descriptor") \
  macro(EBUSY, "resource busy or locked") \
  macro(ECANCELED, "operation canceled") \
  macro(ECHARSET, "invalid Unicode character") \
  macro(ECONNABORTED, "software caused connection abort") \
  macro(ECONNREFUSED, "connection refused") \
  macro(ECONNRESET, "connection reset by peer") \
  macro(EDESTADDRREQ, "destination address required") \
  macro(EEXIST, "file already exists") \
  macro(EFAULT, "bad address in system call argument") \
  macro(EFBIG, "file too large") \
  macro(EHOSTUNREACH, "host is unreachable") \
  macro(EINTR, "interrupted system call") \
  macro(EINVAL, "invalid argument") \
  macro(EIO, "i/o error") \
  macro(EISCONN, "socket is already connected") \
  macro(EISDIR, "illegal operation on a directory") \
  macro(ELOOP, "too many symbolic links encountered") \
  macro(EMFILE, "too many open files") \
  macro(EMSGSIZE, "message too long") \
  macro(ENAMETOOLONG, "name too long") \
  macro(ENETDOWN, "network is down") \
  macro(ENETUNREACH, "network is unreachable") \
  macro(ENFILE, "file table overflow") \
  macro(ENOBUFS, "no buffer space available") \
  macro(ENODEV, "no such device") \
  macro(ENOENT, "no such file or directory") \
  macro(ENOMEM, "not enough memory") \
  macro(ENONET, "machine is not on the network") \
  macro(ENOPROTOOPT, "protocol not available") \
  macro(ENOSPC, "no space left on device") \
  macro(ENOSYS, "function not implemented") \
  macro(ENOTCONN, "socket is not connected") \
  macro(ENOTDIR, "not a directory") \
  macro(ENOTEMPTY, "directory not empty") \
  macro(ENOTSOCK, "socket operation on non-socket") \
  macro(ENOTSUP, "operation not supported on socket") \
  macro(EOVERFLOW, "value too large for defined data type") \
  macro(EPERM, "operation not permitted") \
  macro(EPIPE, "broken pipe") \
  macro(EPROTO, "protocol error") \
  macro(EPROTONOSUPPORT, "protocol not supported") \
  macro(EPROTOTYPE, "protocol wrong type for socket") \
  macro(ERANGE, "result too large") \
  macro(EROFS, "read-only file system") \
  macro(ESHUTDOWN, "cannot send after transport endpoint shutdown") \
  macro(ESPIPE, "invalid seek") \
  macro(ESRCH, "no such process") \
  macro(ETIMEDOUT, "connection timed out") \
  macro(ETXTBSY, "text file is busy") \
  macro(EXDEV, "cross-device link not permitted") \
  macro(UNKNOWN, "unknown error") \
  macro(EOF, "end of file") \
  macro(ENXIO, "no such device or address") \
  macro(EMLINK, "too many links") \
  macro(EHOSTDOWN, "host is down") \
  macro(EREMOTEIO, "remote I/O error") \
  macro(ENOTTY, "inappropriate ioctl for device") \
  macro(EFTYPE, "inappropriate file type or format") \
  macro(EILSEQ, "illegal byte sequence") \
  macro(ESOCKTNOSUPPORT, "socket type not supported") \
  macro(ENODATA, "no data available") \
  macro(EUNATCH, "protocol driver not attached")

// clang-format on
namespace Bun::Bindgen::Cpp {
using namespace JSC;
using namespace WTF;

WTF::String bunBindgenCpp_ProcessBindingUV_errname(
    CppCallContext&,
    const BunBindgenCpp_ProcessBindingUV_errname_Arguments& args)
{
    if (!args.value) [[unlikely]]
        return "Unknown system error"_s;

    auto err = *args.value;
#define CASE(name, desc) \
    if (err == -name) return String(#name##_s);

    BUN_UV_ERRNO_MAP(CASE)
#undef CASE

    return makeString("Unknown system error: "_s, err);
}

JSC::JSValue bunBindgenCpp_ProcessBindingUV_getErrorMap(
    CppCallContext& context,
    const BunBindgenCpp_ProcessBindingUV_getErrorMap_Arguments&)
{
    auto* globalObject = &context.globalObject;
    auto& vm = JSC::getVM(globalObject);
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto map = JSC::JSMap::create(vm, globalObject->mapStructure());

    // Inlining each of these via macros costs like 300 KB.
    const auto putProperty = [](JSC::VM& vm, JSC::ThrowScope& scope, JSC::JSMap* map, JSC::JSGlobalObject* globalObject, ASCIILiteral name, int value, ASCIILiteral desc) -> void {
        auto arr = JSC::constructEmptyArray(globalObject, static_cast<JSC::ArrayAllocationProfile*>(nullptr), 2);
        RETURN_IF_EXCEPTION(scope, void());
        arr->putDirectIndex(globalObject, 0, JSC::jsString(vm, String(name)));
        RETURN_IF_EXCEPTION(scope, void());
        arr->putDirectIndex(globalObject, 1, JSC::jsString(vm, String(desc)));
        RETURN_IF_EXCEPTION(scope, void());
        map->set(globalObject, JSC::jsNumber(value), arr);
        RETURN_IF_EXCEPTION(scope, void());
    };

#define PUT_PROPERTY(name, desc) \
    putProperty(vm, scope, map, globalObject, #name##_s, -name, desc##_s); \
    RETURN_IF_EXCEPTION(scope, {});
    BUN_UV_ERRNO_MAP(PUT_PROPERTY)
#undef PUT_PROPERTY

    return map;
}

} // namespace Bun::Bindgen::Cpp

namespace Bun::ProcessBindingUV {
using namespace JSC;

#define DEFINE_BINDING_CONSTANT(name, desc) inline constexpr int BunBindgenProcessBindingUV_##name = -name;
BUN_UV_ERRNO_MAP(DEFINE_BINDING_CONSTANT)
#undef DEFINE_BINDING_CONSTANT

#define BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingUV
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_ProcessBindingUV

JSObject* create(VM& vm, JSGlobalObject* globalObject)
{
    auto bindingObject = JSC::constructEmptyObject(globalObject, globalObject->objectPrototype(), 0);
    bunBindgenObjectSurface_ProcessBindingUV_install(vm, bindingObject->classInfo(), *bindingObject);
    return bindingObject;
}

} // namespace Bun::ProcessBindingUV
