#include "JSHTTPParserPrototype.h"
#include "JSHTTPParser.h"
#include "JSConnectionsList.h"
#include "ZigGlobalObject.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include <wtf/MathExtras.h>

namespace Bun {

using namespace JSC;

const ClassInfo JSHTTPParserPrototype::s_info = { "HTTPParser"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSHTTPParserPrototype) };

#define BUN_BINDGEN_OBJECT_SURFACE_JSHTTPParserPrototype
#include "ObjectSurfaces.h"
#undef BUN_BINDGEN_OBJECT_SURFACE_JSHTTPParserPrototype

void JSHTTPParserPrototype::finishCreation(VM& vm)
{
    Base::finishCreation(vm);
    bunBindgenObjectSurface_JSHTTPParserPrototype_install(vm, info(), *this);
}

static JSHTTPParser* httpParser(JSC::JSValue value)
{
    auto* parser = dynamicDowncast<JSHTTPParser>(value);
    RELEASE_ASSERT(parser);
    return parser;
}

static JSConnectionsList* connectionsList(const std::optional<std::optional<JSC::JSValue>>& value)
{
    auto candidate = value.value_or(std::nullopt);
    if (!candidate)
        return nullptr;
    auto* connections = dynamicDowncast<JSConnectionsList>(*candidate);
    RELEASE_ASSERT(connections);
    return connections;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserClose(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserClose_Arguments& args)
{
    httpParser(args.bindingThis)->freeImpl();
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserFree(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserFree_Arguments& args)
{
    if (!httpParser(args.bindingThis)->impl())
        return;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserRemove(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserRemove_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return;

    parser->impl()->remove(globalObject, parser);
    RETURN_IF_EXCEPTION(scope, void());
}

Bun::Bindgen::NodeHTTPParserExecuteResult Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserExecute(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserExecute_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* parser = httpParser(args.bindingThis);
    Bun::Bindgen::NodeHTTPParserExecuteResult output;
    if (!parser->impl()) {
        output.set_undefined_value(true);
        return output;
    }

    if (args.buffer) {
        const auto& buffer = *args.buffer;
        JSValue result = parser->impl()->execute(globalObject, reinterpret_cast<const char*>(buffer.unsafePtr("The entry frame keeps the input leased through HTTP parsing and reentrant callbacks"_s)), buffer.size());
        RETURN_IF_EXCEPTION(scope, {});

        if (!result.isEmpty()) {
            if (result.isNumber()) {
                output.set_bytes_read(static_cast<uint64_t>(result.asNumber()));
            } else {
                RELEASE_ASSERT(dynamicDowncast<ErrorInstance>(result));
                output.set_error(result);
            }
            return output;
        }
    }

    output.set_undefined_value(true);
    return output;
}

Bun::Bindgen::NodeHTTPParserFinishResult Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserFinish(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserFinish_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* parser = httpParser(args.bindingThis);
    Bun::Bindgen::NodeHTTPParserFinishResult output;
    if (!parser->impl()) {
        output.set_undefined_value(true);
        return output;
    }

    JSValue result = parser->impl()->execute(globalObject, nullptr, 0);
    RETURN_IF_EXCEPTION(scope, {});

    if (!result.isEmpty()) {
        RELEASE_ASSERT(dynamicDowncast<ErrorInstance>(result));
        output.set_error(result);
        return output;
    }

    output.set_undefined_value(true);
    return output;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserInitialize(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserInitialize_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    uint64_t maxHttpHeaderSize = args.maxHttpHeaderSize && args.maxHttpHeaderSize->is_number()
        ? truncateDoubleToUint64(args.maxHttpHeaderSize->number())
        : 0;

    if (maxHttpHeaderSize == 0) {
        maxHttpHeaderSize = Bindgen::ZigExports::bunBindgenZig_NodeHTTP_defaultMaxHTTPHeaderSize();
    }

    uint32_t lenientFlags = args.lenientFlags.value_or(std::nullopt).value_or(kLenientNone);
    JSConnectionsList* connections = connectionsList(args.connectionsList);
    llhttp_type_t type = static_cast<llhttp_type_t>(args.parserType.value_or(0));

    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return;

    parser->impl()->initialize(globalObject, parser, type, maxHttpHeaderSize, lenientFlags, connections);
    RETURN_IF_EXCEPTION(scope, void());
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserPause(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserPause_Arguments& args)
{
    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return;

    parser->impl()->pause();
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserResume(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserResume_Arguments& args)
{
    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return;

    parser->impl()->resume();
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserConsume(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserConsume_Arguments& args)
{
    if (!httpParser(args.bindingThis)->impl())
        return;
}

void Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserUnconsume(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserUnconsume_Arguments& args)
{
    if (!httpParser(args.bindingThis)->impl())
        return;
}

std::optional<Bun::Bindgen::CppBytes> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserGetCurrentBuffer(
    Bindgen::CppCallContext& context,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserGetCurrentBuffer_Arguments& args)
{
    auto* lexicalGlobalObject = &context.globalObject;
    VM& vm = lexicalGlobalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return std::nullopt;

    WTF::Vector<uint8_t> result;
    if (!result.tryAppend(parser->impl()->getCurrentBuffer())) {
        throwOutOfMemoryError(lexicalGlobalObject, scope);
        return std::nullopt;
    }
    scope.release();
    return result;
}

std::optional<double> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserDuration(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserDuration_Arguments& args)
{
    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return std::nullopt;

    return parser->impl()->duration();
}

std::optional<bool> Bindgen::Cpp::bunBindgenCpp_NodeHTTP_httpParserHeadersCompleted(
    Bindgen::CppCallContext&,
    const Bindgen::Cpp::BunBindgenCpp_NodeHTTP_httpParserHeadersCompleted_Arguments& args)
{
    auto* parser = httpParser(args.bindingThis);
    if (!parser->impl())
        return std::nullopt;

    return parser->impl()->headersCompleted();
}

} // namespace Bun
