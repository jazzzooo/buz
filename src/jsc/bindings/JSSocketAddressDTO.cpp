#include "JSSocketAddressDTO.h"

#include "JavaScriptCore/JSObjectInlines.h"
#include "JavaScriptCore/ObjectConstructor.h"
#include "JavaScriptCore/JSCast.h"
#include "SchemaBindings.h"
#include "BindgenCustom.h"
#include "ErrorCode.h"
#if OS(WINDOWS)
#include <winsock2.h>
#else
#include <sys/socket.h>
#endif

using namespace JSC;

namespace Bun {
namespace JSSocketAddressDTO {

static constexpr PropertyOffset addressOffset = 0;
static constexpr PropertyOffset familyOffset = 1;
static constexpr PropertyOffset portOffset = 2;

JSObject* create(Zig::GlobalObject* globalObject, JSString* value, int32_t port, bool isIPv6)
{
    static const NeverDestroyed<String> IPv4 = MAKE_STATIC_STRING_IMPL("IPv4");
    static const NeverDestroyed<String> IPv6 = MAKE_STATIC_STRING_IMPL("IPv6");

    VM& vm = globalObject->vm();

    JSObject* thisObject = constructEmptyObject(vm, globalObject->JSSocketAddressDTOStructure());
    thisObject->putDirectOffset(vm, 0, value);
    thisObject->putDirectOffset(vm, 1, isIPv6 ? jsString(vm, IPv6) : jsString(vm, IPv4));
    thisObject->putDirectOffset(vm, 2, jsNumber(port));

    return thisObject;
}

// Using a structure with inlined offsets should be more lightweight than a class.
Structure* createStructure(VM& vm, JSGlobalObject* globalObject)
{
    JSC::Structure* structure = globalObject->structureCache().emptyObjectStructureForPrototype(
        globalObject,
        globalObject->objectPrototype(),
        3);

    JSC::PropertyOffset offset;
    structure = structure->addPropertyTransition(
        vm,
        structure,
        JSC::Identifier::fromString(vm, "address"_s),
        0,
        offset);
    ASSERT(offset == addressOffset);

    structure = structure->addPropertyTransition(
        vm,
        structure,
        JSC::Identifier::fromString(vm, "family"_s),
        0,
        offset);
    ASSERT(offset == familyOffset);

    structure = structure->addPropertyTransition(
        vm,
        structure,
        JSC::Identifier::fromString(vm, "port"_s),
        0,
        offset);
    ASSERT(offset == portOffset);

    return structure;
}

} // namespace JSSocketAddress
} // namespace Bun

namespace Bun::Bindgen::Custom {
SocketAddressFamily bunBindgenSocketAddressFamily(JSC::JSGlobalObject& global, const SocketAddressFamilyInput& input, WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    if (input.is_string()) {
        const auto& text = input.string();
        if (equalIgnoringASCIICase(text, "ipv4"_s)) {
            scope.release();
            return SocketAddressFamily::ipv4;
        }
        if (equalIgnoringASCIICase(text, "ipv6"_s)) {
            scope.release();
            return SocketAddressFamily::ipv6;
        }
        auto value = JSC::jsString(global.vm(), text);
        RETURN_IF_EXCEPTION(scope, SocketAddressFamily::ipv4);
        Bun::ERR::INVALID_ARG_PROPERTY_VALUE(scope, &global, name, value, "'ipv4' or 'ipv6'"_s);
    } else {
        int32_t number = input.number();
        if (number == AF_INET) {
            scope.release();
            return SocketAddressFamily::ipv4;
        }
        if (number == AF_INET6) {
            scope.release();
            return SocketAddressFamily::ipv6;
        }
        Bun::ERR::INVALID_ARG_PROPERTY_VALUE(scope, &global, name, JSC::jsNumber(number), "AF_INET or AF_INET6"_s);
    }
    return SocketAddressFamily::ipv4;
}
}
