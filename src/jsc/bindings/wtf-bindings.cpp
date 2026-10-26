#include "root.h"
#include "SchemaBindings.h"
#include "wtf-bindings.h"
#include <limits>
#include <unicode/ucal.h>
#include <wtf/DateMath.h>
#include <wtf/GregorianDateTime.h>
#include <wtf/StackBounds.h>
#include <wtf/StackCheck.h>
#include <wtf/StackTrace.h>
#include <wtf/dtoa.h>
#include <wtf/NumberOfCores.h>
#include <wtf/RunLoop.h>

#include <wtf/text/Base64.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>

extern "C" {
extern const uint32_t Bun__WTFStringImpl__refCountOffset = WTF::StringImpl::refCountMemoryOffset();
extern const uint32_t Bun__WTFStringImpl__lengthOffset = WTF::StringImpl::lengthMemoryOffset();
extern const uint32_t Bun__WTFStringImpl__dataOffset = WTF::StringImpl::dataOffset();
extern const uint32_t Bun__WTFStringImpl__flagsOffset = WTF::StringImpl::flagsOffset();
extern const uint32_t Bun__WTFStringImpl__flagIs8Bit = WTF::StringImpl::flagIs8Bit();
extern const uint32_t Bun__WTFStringImpl__stringKindMask = WTF::StringImpl::maskStringKind();
extern const uint32_t Bun__WTFStringImpl__refCountStaticFlag = WTF::StringImpl::refCountFlagIsStaticString();
extern const uint32_t Bun__WTFStringImpl__refCountIncrement = WTF::StringImpl::refCountIncrement();
}

std::optional<double> Bun::Bindgen::Engine::bunBindgenEngine_numeric_conversions_parseDouble(
    const Bun::Bindgen::Engine::BunBindgenEngine_numeric_conversions_parseDouble_Arguments& args)
{
    size_t position = 0;
    double result = WTF::parseDouble(args.bytes, position);
    if (position == 0)
        return std::nullopt;
    return result;
}

namespace Bun {

PreparedTimeZoneOverride::Result PreparedTimeZoneOverride::prepare(WTF::StringView timeZone)
{
    RELEASE_ASSERT(!m_prepared);
    if (timeZone.isEmpty()) {
        m_identifier.clear();
        m_prepared = true;
        return Result::Valid;
    }
    if (timeZone.length() > static_cast<unsigned>(std::numeric_limits<int32_t>::max()))
        return Result::Invalid;

    Vector<char16_t, 32> input;
    const char16_t* characters;
    if (timeZone.is8Bit()) {
        if (!input.tryAppend(timeZone.span8()))
            return Result::OutOfMemory;
        characters = input.span().data();
    } else
        characters = timeZone.span16().data();

    Vector<char16_t> canonical;
    if (!canonical.tryGrow(32))
        return Result::OutOfMemory;
    auto status = U_ZERO_ERROR;
    const auto inputLength = static_cast<int32_t>(timeZone.length());
    auto length = ucal_getCanonicalTimeZoneID(characters, inputLength, canonical.mutableSpan().data(), static_cast<int32_t>(canonical.size()), nullptr, &status);
    if (status == U_BUFFER_OVERFLOW_ERROR) {
        if (length <= 0)
            return Result::Invalid;
        if (!canonical.tryGrow(length))
            return Result::OutOfMemory;
        status = U_ZERO_ERROR;
        length = ucal_getCanonicalTimeZoneID(characters, inputLength, canonical.mutableSpan().data(), static_cast<int32_t>(canonical.size()), nullptr, &status);
    }
    if (status == U_MEMORY_ALLOCATION_ERROR)
        return Result::OutOfMemory;
    if (U_FAILURE(status) || length < 0 || static_cast<size_t>(length) > canonical.size())
        return Result::Invalid;
    canonical.shrink(length);
    m_identifier = WTF::move(canonical);
    m_prepared = true;
    return Result::Valid;
}

void PreparedTimeZoneOverride::commit()
{
    RELEASE_ASSERT(m_prepared);
    WTF::commitTimeZoneOverride(m_identifier);
    m_prepared = false;
}

String base64URLEncodeToString(const Vector<uint8_t>& data)
{
    return WTF::base64URLEncodeToString(data.span());
}

String toISOString(JSC::VM& vm, double date)
{
    date = WTF::timeClip(date);
    if (!std::isfinite(date))
        return {};

    GregorianDateTime gregorianDateTime;
    vm.dateCache.msToGregorianDateTime(date, WTF::TimeType::UTCTime, gregorianDateTime);

    int ms = static_cast<int>(fmod(date, msPerSecond));
    if (ms < 0)
        ms += msPerSecond;

    int year = gregorianDateTime.year();
    String prefix;
    unsigned yearDigits = 4;
    if (year < 0 || year > 9999) {
        prefix = year < 0 ? "-"_s : "+"_s;
        yearDigits = 6;
        year = std::abs(year);
    }
    return makeString(prefix, pad('0', yearDigits, year), '-',
        pad('0', 2, gregorianDateTime.month() + 1), '-', pad('0', 2, gregorianDateTime.monthDay()), 'T',
        pad('0', 2, gregorianDateTime.hour()), ':', pad('0', 2, gregorianDateTime.minute()), ':',
        pad('0', 2, gregorianDateTime.second()), '.', pad('0', 3, ms), 'Z');
}

static thread_local WTF::StackBounds stackBoundsForCurrentThread = WTF::StackBounds::emptyBounds();

}

Bun::Bindgen::Engine::BunBindgenEngine_CrashHandlerBindings_dumpStackTrace_Return Bun::Bindgen::Engine::bunBindgenEngine_CrashHandlerBindings_dumpStackTrace(
    const BunBindgenEngine_CrashHandlerBindings_dumpStackTrace_Arguments& args)
{
    WTF::Vector<void*, 32> addresses;
    if (!addresses.tryReserveInitialCapacity(args.addresses.size()))
        return Bun::Bindgen::nativeAllocationFailure();
    for (uint64_t address : args.addresses)
        addresses.unsafeAppendWithoutCapacityCheck(reinterpret_cast<void*>(address));
    WTFPrintBacktrace(addresses.span());
    return {};
}

int32_t Bun::Bindgen::Engine::bunBindgenEngine_system_resources_numberOfProcessorCores(
    const Bun::Bindgen::Engine::BunBindgenEngine_system_resources_numberOfProcessorCores_Arguments&)
{
    return WTF::numberOfProcessorCores();
}

void Bun::Bindgen::Engine::bunBindgenEngine_wtf_threading_releaseFastMallocFreeMemory(
    const Bun::Bindgen::Engine::BunBindgenEngine_wtf_threading_releaseFastMallocFreeMemory_Arguments&)
{
    WTF::releaseFastMallocFreeMemory();
}

void Bun::Bindgen::Engine::bunBindgenEngine_wtf_threading_releaseFastMallocFreeMemoryForThisThread(
    const Bun::Bindgen::Engine::BunBindgenEngine_wtf_threading_releaseFastMallocFreeMemoryForThisThread_Arguments&)
{
    WTF::releaseFastMallocFreeMemoryForThisThread();
}

void Bun::Bindgen::Engine::bunBindgenEngine_wtf_threading_prepareForThreadExit(
    const Bun::Bindgen::Engine::BunBindgenEngine_wtf_threading_prepareForThreadExit_Arguments&)
{
    WTF::RunLoop::currentSingleton().threadWillExit();
    WTF::releaseFastMallocFreeMemoryForThisThread();
}

void Bun::Bindgen::Engine::bunBindgenEngine_wtf_threading_stackCheckInitialize(
    const Bun::Bindgen::Engine::BunBindgenEngine_wtf_threading_stackCheckInitialize_Arguments&)
{
    Bun::stackBoundsForCurrentThread = WTF::StackBounds::currentThreadStackBounds();
}

std::optional<size_t> Bun::Bindgen::Engine::bunBindgenEngine_wtf_threading_stackCheckGetEnd(
    const Bun::Bindgen::Engine::BunBindgenEngine_wtf_threading_stackCheckGetEnd_Arguments&)
{
    auto* address = Bun::stackBoundsForCurrentThread.end();
    if (!address)
        return std::nullopt;
    return reinterpret_cast<uintptr_t>(address);
}

double Bun::Bindgen::Engine::bunBindgenEngine_date_time_parseES5Date(
    const Bun::Bindgen::Engine::BunBindgenEngine_date_time_parseES5Date_Arguments& args)
{
    bool isLocalTime;
    return WTF::parseES5Date({ reinterpret_cast<const Latin1Character*>(args.bytes.data()), args.bytes.size() }, isLocalTime);
}
