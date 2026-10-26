#include "root.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSBigIntInlines.h>
#include <JavaScriptCore/JSObject.h>
#if !OS(WINDOWS)
#include <sys/stat.h>
#endif

namespace Bun {

using namespace JSC;
using namespace WebCore;

#if OS(WINDOWS)
#ifndef mode_t
#pragma push_macro("mode_t")
#define BUN_PUSHED_MODE_T
#define mode_t int32_t
#endif

#ifndef S_IFMT
#define S_IFMT 0170000
#endif

#ifndef S_IFDIR
#define S_IFDIR 0040000
#endif

#ifndef S_IFCHR
#define S_IFCHR 0020000
#endif

#ifndef S_IFBLK
#define S_IFBLK 0060000
#endif

#ifndef S_IFREG
#define S_IFREG 0100000
#endif

#ifndef S_IFIFO
#define S_IFIFO 0010000
#endif

#ifndef S_IFLNK
#define S_IFLNK 0120000
#endif

#ifndef S_IFSOCK
#define S_IFSOCK 0140000
#endif

#ifndef S_ISBLK
#define S_ISBLK(m) (((m) & S_IFMT) == S_IFBLK) /* block special */
#endif
#ifndef S_ISCHR
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR) /* char special */
#endif
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR) /* directory */
#endif
#ifndef S_ISFIFO
#define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO) /* fifo or socket */
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG) /* regular file */
#endif
#ifndef S_ISLNK
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK) /* symbolic link */
#endif
#ifndef S_ISSOCK
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK) /* socket */
#endif
#endif

enum class StatFunction {
    isBlockDevice,
    isCharacterDevice,
    isDirectory,
    isFIFO,
    isFile,
    isSocket,
    isSymbolicLink,
};

static bool isModeFn(StatFunction fn, int64_t mode)
{
    switch (fn) {
    case StatFunction::isBlockDevice:
        return S_ISBLK(mode);
    case StatFunction::isCharacterDevice:
        return S_ISCHR(mode);
    case StatFunction::isDirectory:
        return S_ISDIR(mode);
    case StatFunction::isFIFO:
        return S_ISFIFO(mode);
    case StatFunction::isFile:
        return S_ISREG(mode);
    case StatFunction::isSocket:
        return S_ISSOCK(mode);
    case StatFunction::isSymbolicLink:
        return S_ISLNK(mode);
    default: {
        ASSERT_NOT_REACHED();
    }
    }
}

static double dateMilliseconds(double value)
{
    return value;
}

static double dateMilliseconds(JSC::JSValue value)
{
    return JSC::JSBigInt::toNumber(value).asNumber();
}

template<typename Receiver>
static std::optional<JSC::JSValue> getDateField(JSC::JSGlobalObject* globalObject, const Receiver& receiver, JSC::PropertyName propertyName)
{
    if (!receiver.is_object())
        return std::nullopt;

    auto& vm = globalObject->vm();
    const auto& object = receiver.object();
    auto* thisObject = object.source_identity.object();
    JSValue result = JSC::DateInstance::create(vm, globalObject->dateStructure(), dateMilliseconds(object.milliseconds));
    if (!thisObject->structure()->mayBePrototype()) {
        thisObject->putDirect(vm, propertyName, result, 0);
    }
    return result;
}

static void putDateField(JSC::JSGlobalObject* globalObject, const std::optional<JSValue>& receiver, JSValue value, ASCIILiteral name)
{
    if (!receiver)
        return;
    auto& vm = globalObject->vm();
    JSC::asObject(*receiver)->putDirect(vm, Identifier::fromString(vm, name), value, 0);
}

namespace Bindgen::Cpp {

template<typename Receiver>
static int64_t receiverMode(const Receiver& receiver)
{
    if (!receiver.is_object())
        return 0;
    return receiver.object().mode;
}

#define BUN_STATS_PREDICATE(className, name, statFunction, isBigInt)                                       \
    bool bunBindgenCpp_NodeFSStat_##className##_method_##name(                                             \
        CppCallContext&,                                                                                   \
        const BunBindgenCpp_NodeFSStat_##className##_method_##name##_Arguments& args)                      \
    {                                                                                                      \
        return isModeFn(statFunction, receiverMode(args.bindingThis));                                      \
    }

BUN_STATS_PREDICATE(Stats, isBlockDevice, StatFunction::isBlockDevice, false)
BUN_STATS_PREDICATE(Stats, isCharacterDevice, StatFunction::isCharacterDevice, false)
BUN_STATS_PREDICATE(Stats, isDirectory, StatFunction::isDirectory, false)
BUN_STATS_PREDICATE(Stats, isFIFO, StatFunction::isFIFO, false)
BUN_STATS_PREDICATE(Stats, isFile, StatFunction::isFile, false)
BUN_STATS_PREDICATE(Stats, isSocket, StatFunction::isSocket, false)
BUN_STATS_PREDICATE(Stats, isSymbolicLink, StatFunction::isSymbolicLink, false)
BUN_STATS_PREDICATE(BigIntStats, isBlockDevice, StatFunction::isBlockDevice, true)
BUN_STATS_PREDICATE(BigIntStats, isCharacterDevice, StatFunction::isCharacterDevice, true)
BUN_STATS_PREDICATE(BigIntStats, isDirectory, StatFunction::isDirectory, true)
BUN_STATS_PREDICATE(BigIntStats, isFIFO, StatFunction::isFIFO, true)
BUN_STATS_PREDICATE(BigIntStats, isFile, StatFunction::isFile, true)
BUN_STATS_PREDICATE(BigIntStats, isSocket, StatFunction::isSocket, true)
BUN_STATS_PREDICATE(BigIntStats, isSymbolicLink, StatFunction::isSymbolicLink, true)

#undef BUN_STATS_PREDICATE

#define BUN_STATS_DATE_ACCESSOR(className, name)                                                          \
    std::optional<JSValue> bunBindgenCpp_NodeFSStat_##className##_getter_##name(                           \
        CppCallContext& context,                                                                           \
        const BunBindgenCpp_NodeFSStat_##className##_getter_##name##_Arguments& args)                      \
    {                                                                                                      \
        return getDateField(&context.globalObject, args.bindingThis,                                       \
            Identifier::fromString(context.globalObject.vm(), #name ""_s));                                 \
    }                                                                                                      \
    void bunBindgenCpp_NodeFSStat_##className##_setter_##name(                                             \
        CppCallContext& context,                                                                           \
        const BunBindgenCpp_NodeFSStat_##className##_setter_##name##_Arguments& args)                      \
    {                                                                                                      \
        putDateField(&context.globalObject, args.bindingThis, args.value, #name ""_s);                     \
    }

BUN_STATS_DATE_ACCESSOR(Stats, atime)
BUN_STATS_DATE_ACCESSOR(Stats, mtime)
BUN_STATS_DATE_ACCESSOR(Stats, ctime)
BUN_STATS_DATE_ACCESSOR(Stats, birthtime)
BUN_STATS_DATE_ACCESSOR(BigIntStats, atime)
BUN_STATS_DATE_ACCESSOR(BigIntStats, mtime)
BUN_STATS_DATE_ACCESSOR(BigIntStats, ctime)
BUN_STATS_DATE_ACCESSOR(BigIntStats, birthtime)

#undef BUN_STATS_DATE_ACCESSOR

} // namespace Bindgen::Cpp

#if OS(WINDOWS)
#ifdef BUN_PUSHED_MODE_T
#pragma pop_macro("mode_t")
#undef BUN_PUSHED_MODE_T
#endif
#endif

} // namespace Bun
