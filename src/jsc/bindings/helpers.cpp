#include "root.h"
#include "helpers.h"
#include "BunClientData.h"
#include "SchemaBindings.h"
#include <optional>
#include <wtf/text/MakeString.h>
#include <string.h>
#ifdef _WIN32
#include <uv.h>
#endif

using namespace JSC;

static void throwSystemErrorWithMessage(ThrowScope& scope, JSGlobalObject* global,
    const String& message, ASCIILiteral syscall, int err, std::optional<String> code)
{
    RETURN_IF_EXCEPTION(scope, void());
    auto* instance = createError(global, message);
    RETURN_IF_EXCEPTION(scope, void());
    auto& vm = global->vm();
    auto& builtinNames = WebCore::builtinNames(vm);
    instance->putDirect(vm, builtinNames.syscallPublicName(), jsString(vm, String(syscall)), 0);
    RETURN_IF_EXCEPTION(scope, void());
    instance->putDirect(vm, builtinNames.errnoPublicName(), jsNumber(err), 0);
    RETURN_IF_EXCEPTION(scope, void());
    instance->putDirect(vm, vm.propertyNames->name, jsString(vm, String("SystemError"_s)), PropertyAttribute::DontEnum | 0);
    RETURN_IF_EXCEPTION(scope, void());
    if (code) {
        instance->putDirect(vm, builtinNames.codePublicName(), jsString(vm, *code));
        RETURN_IF_EXCEPTION(scope, void());
    }
    scope.throwException(global, instance);
}

void throwSystemError(ThrowScope& scope, JSGlobalObject* global, ASCIILiteral message, ASCIILiteral syscall, int err)
{
    throwSystemErrorWithMessage(scope, global, String(message), syscall, err, std::nullopt);
}

void throwSystemError(ThrowScope& scope, JSGlobalObject* global, ASCIILiteral syscall, int err)
{
    RETURN_IF_EXCEPTION(scope, void());
    auto errstr = Bun::Bindgen::ZigExports::bunBindgenZig_errors_systemErrnoName(err);
    RETURN_IF_EXCEPTION(scope, void());
    if (!errstr) {
        throwOutOfMemoryError(global, scope);
        return;
    }
#ifdef _WIN32
    auto strerr = uv_strerror(err);
#else
    auto strerr = strerror(err);
#endif
    auto message = tryMakeString(syscall, "() failed: "_s, errstr.value(), ": "_s,
        std::span<const Latin1Character>(reinterpret_cast<const Latin1Character*>(strerr), strlen(strerr)));
    if (message.isNull()) {
        throwOutOfMemoryError(global, scope);
        return;
    }
    throwSystemErrorWithMessage(scope, global, message, syscall, err, WTF::move(errstr.value()));
}
