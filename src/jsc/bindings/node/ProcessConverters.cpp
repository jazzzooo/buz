#include "root.h"

#include "Bindgen/IDLConvertBase.h"
#include "BunProcess.h"
#include "NodeValidator.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/JSGlobalObjectFunctions.h>
#include <cmath>
#include <optional>
#include <signal.h>

namespace Bun::Bindgen::Custom {

std::optional<uint8_t> bunBindgenNodeExitCode(JSC::JSGlobalObject& global, const NodeExitCodeInput& input, WTF::ASCIILiteral name)
{
    if (input.is_nulled() || input.is_undefined())
        return std::nullopt;

    auto scope = DECLARE_THROW_SCOPE(global.vm());
    double number;
    if (input.is_number()) {
        number = input.number();
    } else {
        RELEASE_ASSERT(input.is_string());
        const auto& string = input.string();
        number = JSC::jsToNumber(WTF::StringView(string));
        if (string.isEmpty() || std::isnan(number)) {
            auto value = JSC::jsString(global.vm(), string);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            Bun::ERR::INVALID_ARG_TYPE(scope, &global, name, "number"_s, value);
            return std::nullopt;
        }
    }

    if (!std::isfinite(number) || std::trunc(number) != number) {
        Bun::ERR::OUT_OF_RANGE(scope, &global, name, "an integer"_s, JSC::jsNumber(number));
        return std::nullopt;
    }
    if (number < JSC::minSafeInteger() || number > JSC::maxSafeInteger()) {
        Bun::ERR::OUT_OF_RANGE(scope, &global, name, JSC::minSafeInteger(), JSC::maxSafeInteger(), JSC::jsNumber(number));
        return std::nullopt;
    }

    scope.release();
    return static_cast<uint8_t>(static_cast<int64_t>(number) % 256);
}

static uint8_t nodeSignalName(JSC::JSGlobalObject& global, const WTF::String& signal)
{
    if (signal.isEmpty())
        return SIGTERM;
    if (auto number = Bun::signalNumberForName(signal))
        return *number;

    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto value = JSC::jsString(global.vm(), signal);
    RETURN_IF_EXCEPTION(scope, 0);
    Bun::ERR::UNKNOWN_SIGNAL(scope, &global, value);
    return 0;
}

static uint8_t nodeSignalNumber(JSC::JSGlobalObject& global, double signal, bool allowZero)
{
    constexpr uint8_t defaultSignal = SIGTERM;
    auto throwInvalidSignal = [&](WTF::ASCIILiteral message) -> uint8_t {
        auto scope = DECLARE_THROW_SCOPE(global.vm());
        Bun::throwError(&global, scope, ErrorCode::ERR_INVALID_ARG_TYPE, message);
        return defaultSignal;
    };

    if (std::isnan(signal))
        return defaultSignal;
    if (!std::isfinite(signal) || std::trunc(signal) != signal)
        return throwInvalidSignal("Unknown signal"_s);
    if (signal < 0)
        return throwInvalidSignal("Invalid signal: must be >= 0"_s);
    if (signal > 31)
        return throwInvalidSignal("Invalid signal: must be < 32"_s);
    if (!allowZero && signal == 0) {
        auto scope = DECLARE_THROW_SCOPE(global.vm());
        Bun::ERR::UNKNOWN_SIGNAL(scope, &global, JSC::jsNumber(signal));
        return defaultSignal;
    }
    return static_cast<uint8_t>(signal);
}

uint8_t bunBindgenSubprocessSignalNumber(JSC::JSGlobalObject& global, double signal, WTF::ASCIILiteral)
{
    return nodeSignalNumber(global, signal, true);
}

static uint8_t nodeSignalCode(JSC::JSGlobalObject& global, const Bun::Bindgen::NodeSignalInput& input, bool allowZero)
{
    if (input.is_undefined_value() || input.is_null_value())
        return SIGTERM;
    if (input.is_number())
        return nodeSignalNumber(global, input.number(), allowZero);

    RELEASE_ASSERT(input.is_string());
    return nodeSignalName(global, input.string());
}

uint8_t bunBindgenNodeSignalCode(JSC::JSGlobalObject& global, const NodeSignalInput& input, WTF::ASCIILiteral)
{
    return nodeSignalCode(global, input, true);
}

uint8_t bunBindgenNodeTerminationSignalCode(JSC::JSGlobalObject& global, const NodeSignalInput& input, WTF::ASCIILiteral)
{
    return nodeSignalCode(global, input, false);
}

}
