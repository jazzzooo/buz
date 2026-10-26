#include "root.h"

#include "SchemaBindings.h"
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSFunctionInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>

namespace Bun::Bindgen::Custom {

std::optional<WTF::String> bunBindgenTestDescription(JSC::JSGlobalObject& global, const TestDescriptionInput& input, WTF::ASCIILiteral)
{
    auto& vm = global.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (input.is_text())
        return input.text();
    if (input.is_number()) {
        auto text = JSC::jsNumber(input.number()).toWTFString(&global);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        RELEASE_AND_RETURN(scope, text);
    }

    auto value = input.callable();
    WTF::String name;
    bool anonymousClass = false;
    if (auto* function = dynamicDowncast<JSC::JSFunction>(value)) {
        name = function->calculatedDisplayName(vm);
        anonymousClass = name.isEmpty() && function->isClassConstructorFunction();
    } else if (auto* function = dynamicDowncast<JSC::InternalFunction>(value))
        name = function->name();
    else
        name = WTF::String(value.getObject()->className());
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (name.isEmpty() && !anonymousClass)
        return std::nullopt;
    RELEASE_AND_RETURN(scope, name.isNull() ? WTF::String(WTF::emptyString()) : WTF::move(name));
}

double bunBindgenDateTimestamp(JSC::JSValue input, WTF::ASCIILiteral)
{
    auto* date = dynamicDowncast<JSC::DateInstance>(input);
    RELEASE_ASSERT(date);
    return date->internalNumber();
}

double bunBindgenDateOrMilliseconds(const DateOrMillisecondsInput& input, WTF::ASCIILiteral name)
{
    if (input.is_number())
        return input.number();
    RELEASE_ASSERT(input.is_date());
    return bunBindgenDateTimestamp(input.date(), name);
}

}
