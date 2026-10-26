#include "root.h"

#include "SchemaBindings.h"
#include "ErrorCode.h"
#include "Bindgen/IDLConvertBase.h"
#include <JavaScriptCore/ParseInt.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/JSGlobalObjectFunctions.h>
#include <cmath>
#include <limits>
#include <optional>
#include <wtf/WallTime.h>

namespace Bun::Bindgen::Custom {

double bunBindgenNodeFileTime(
    JSC::JSGlobalObject& global,
    const Bun::Bindgen::NodeFileTimeInput& input,
    WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    double seconds;
    JSC::JSValue sourceValue;

    if (input.is_number()) {
        seconds = input.number();
        sourceValue = JSC::jsNumber(seconds);
        if (std::isfinite(seconds) && seconds < 0)
            seconds = WTF::WallTime::now().secondsSinceEpoch().value();
    } else if (input.is_string()) {
        seconds = JSC::jsToNumber(WTF::StringView(input.string()));
    } else {
        RELEASE_ASSERT(input.is_date());
        sourceValue = input.date();
        auto* date = dynamicDowncast<JSC::DateInstance>(sourceValue);
        RELEASE_ASSERT(date);
        seconds = date->internalNumber() / 1000.0;
        if (std::isnan(seconds)) {
            scope.release();
            return std::numeric_limits<double>::quiet_NaN();
        }
    }

    if (!std::isfinite(seconds)) {
        if (input.is_string()) {
            sourceValue = JSC::jsString(global.vm(), input.string());
            RETURN_IF_EXCEPTION(scope, 0);
        }
        Bun::ERR::INVALID_ARG_INSTANCE(scope, &global, name, "Date or an Time in seconds"_s, sourceValue);
        return 0;
    }

    scope.release();
    return seconds;
}

uint32_t bunBindgenNodeFileMode(
    JSC::JSGlobalObject& global,
    const Bun::Bindgen::NodeFileModeInput& input,
    WTF::ASCIILiteral name)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    uint32_t mode;

    if (input.is_octal()) {
        const auto& string = input.octal();
        auto view = WTF::StringView(string);
        bool valid = !view.isEmpty();
        for (unsigned i = 0; i < view.length(); ++i) {
            if (view[i] < '0' || view[i] > '7') {
                valid = false;
                break;
            }
        }
        if (!valid) {
            auto sourceValue = JSC::jsString(global.vm(), string);
            RETURN_IF_EXCEPTION(scope, 0);
            Bun::ERR::INVALID_ARG_VALUE(scope, &global, name, sourceValue, "must be a 32-bit unsigned integer or an octal string"_s);
            return 0;
        }
        double parsed = JSC::parseInt(view, 8);
        LiteralConversionContext context(name);
        context.setValue(JSC::jsNumber(parsed));
        if (!std::isfinite(parsed)) {
            context.throwNumberNotInteger(global, scope, parsed);
            return 0;
        }
        if (parsed > std::numeric_limits<uint32_t>::max()) {
            context.throwIntegerOutOfRange(global, scope, parsed, uint32_t { 0 }, std::numeric_limits<uint32_t>::max());
            return 0;
        }
        mode = static_cast<uint32_t>(parsed);
    } else {
        RELEASE_ASSERT(input.is_number());
        mode = input.number();
    }

    scope.release();
    return mode;
}

}
