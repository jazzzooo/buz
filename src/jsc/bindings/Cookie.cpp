#include "Cookie.h"
#include "EncodeURIComponent.h"
#include "StringConversion.h"
#include <cmath>
#include <wtf/ASCIICType.h>
#include <wtf/WallTime.h>
#include <wtf/DateMath.h>
#include <wtf/GregorianDateTime.h>
#include <wtf/dtoa.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <wtf/text/MakeString.h>
#include "HTTPParsers.h"
namespace WebCore {

Cookie::~Cookie() = default;

Cookie::Cookie(const String& name, const String& value,
    const String& domain, const String& path,
    std::optional<int64_t> expires, bool secure, CookieSameSite sameSite,
    bool httpOnly, std::optional<double> maxAge, bool partitioned)
    : m_name(name)
    , m_value(value)
    , m_domain(domain)
    , m_path(path)
    , m_expires(expires)
    , m_secure(secure)
    , m_sameSite(sameSite)
    , m_httpOnly(httpOnly)
    , m_maxAge(maxAge)
    , m_partitioned(partitioned)
{
}

ExceptionOr<Ref<Cookie>> Cookie::create(const String& name, const String& value,
    const String& domain, const String& path,
    std::optional<int64_t> expires, bool secure, CookieSameSite sameSite,
    bool httpOnly, std::optional<double> maxAge, bool partitioned)
{
    if (!isValidCookieName(name)) {
        return Exception { TypeError, "Invalid cookie name: contains invalid characters"_s };
    }
    if (!isValidCookiePath(path)) {
        return Exception { TypeError, "Invalid cookie path: contains invalid characters"_s };
    }
    if (!isValidCookieDomain(domain)) {
        return Exception { TypeError, "Invalid cookie domain: contains invalid characters"_s };
    }
    if (expires && !isValidExpiration(*expires))
        return Exception { RangeError, "Invalid cookie expiration date"_s };
    auto* memory = WTF::FastMalloc::tryMalloc(sizeof(Cookie));
    if (!memory)
        return Exception { OutOfMemoryError };
    return adoptRef(*new (memory) Cookie(name, value, domain, path, expires, secure, sameSite, httpOnly, maxAge, partitioned));
}

ExceptionOr<Ref<Cookie>> Cookie::clone() const
{
    return create(m_name, m_value, m_domain, m_path, m_expires, m_secure, m_sameSite, m_httpOnly, m_maxAge, m_partitioned);
}

ExceptionOr<Ref<Cookie>> Cookie::parse(StringView cookieString)
{
    // RFC 6265 sec 4.1.1, RFC 2616 2.2 defines a cookie name consists of one char minimum, plus '='.
    if (cookieString.length() < 2) [[unlikely]] {
        return Exception { TypeError, "Invalid cookie string: empty"_s };
    }

    // Find the first name-value pair
    size_t firstSemicolonPos = cookieString.find(';');
    StringView cookiePair = firstSemicolonPos == notFound ? cookieString : cookieString.substring(0, firstSemicolonPos);

    size_t firstEqualsPos = cookiePair.find('=');
    if (firstEqualsPos == notFound) [[unlikely]] {
        return Exception { TypeError, "Invalid cookie string: no '=' found"_s };
    }

    String name = tryMakeString(cookiePair.substring(0, firstEqualsPos).trim(isASCIIWhitespace<char16_t>));
    if (name.isNull())
        return Exception { OutOfMemoryError };
    if (name.isEmpty())
        return Exception { TypeError, "Invalid cookie string: name cannot be empty"_s };

    ASSERT(isValidHTTPHeaderValue(name));
    String value = tryMakeString(cookiePair.substring(firstEqualsPos + 1).trim(isASCIIWhitespace<char16_t>));
    if (value.isNull())
        return Exception { OutOfMemoryError };

    // Default values
    String domain;
    String path = "/"_s;
    std::optional<int64_t> expires;
    bool secure = false;
    CookieSameSite sameSite = CookieSameSite::lax;
    bool httpOnly = false;
    std::optional<double> maxAge;
    bool partitioned = false;
    ASSERT(value.isEmpty() || isValidHTTPHeaderValue(value));
    // Parse attributes if there are any
    if (firstSemicolonPos != notFound) {
        auto attributesString = cookieString.substring(firstSemicolonPos + 1);

        for (auto attribute : attributesString.split(';')) {
            auto trimmedAttribute = attribute.trim(isASCIIWhitespace<char16_t>);
            size_t assignmentPos = trimmedAttribute.find('=');

            StringView attributeName;
            StringView attributeValue;

            if (assignmentPos != notFound) {
                attributeName = trimmedAttribute.substring(0, assignmentPos).trim(isASCIIWhitespace<char16_t>);
                attributeValue = trimmedAttribute.substring(assignmentPos + 1).trim(isASCIIWhitespace<char16_t>);
            } else {
                attributeName = trimmedAttribute;
            }

            if (equalIgnoringASCIICase(attributeName, "domain"_s)) {
                if (!attributeValue.isEmpty()) {
                    domain = tryMakeString(asASCIILowercase(attributeValue));
                    if (domain.isNull())
                        return Exception { OutOfMemoryError };
                }
            } else if (equalIgnoringASCIICase(attributeName, "path"_s)) {
                if (!attributeValue.isEmpty() && attributeValue.startsWith('/')) {
                    path = tryMakeString(attributeValue);
                    if (path.isNull())
                        return Exception { OutOfMemoryError };
                }
            } else if (equalIgnoringASCIICase(attributeName, "expires"_s) && !maxAge && !attributeValue.isEmpty()) {
                auto utf8 = Bun::encodeUTF8ReplacingInvalidSequences(attributeValue);
                if (!utf8)
                    return Exception { OutOfMemoryError };
                const double parsed = WTF::parseDate(std::span<const Latin1Character>(reinterpret_cast<const Latin1Character*>(utf8->span().data()), utf8->size()));
                if (isValidExpiration(parsed))
                    expires = static_cast<int64_t>(parsed);
            } else if (equalIgnoringASCIICase(attributeName, "max-age"_s)) {
                if (auto parsed = WTF::parseIntegerAllowingTrailingJunk<int64_t>(attributeValue); parsed.has_value()) {
                    maxAge = static_cast<double>(parsed.value());
                }
            } else if (equalIgnoringASCIICase(attributeName, "secure"_s)) {
                secure = true;
            } else if (equalIgnoringASCIICase(attributeName, "httponly"_s)) {
                httpOnly = true;
            } else if (equalIgnoringASCIICase(attributeName, "partitioned"_s)) {
                partitioned = true;
            } else if (equalIgnoringASCIICase(attributeName, "samesite"_s)) {
                if (WTF::equalIgnoringASCIICase(attributeValue, "strict"_s))
                    sameSite = CookieSameSite::strict;
                else if (WTF::equalIgnoringASCIICase(attributeValue, "lax"_s))
                    sameSite = CookieSameSite::lax;
                else if (WTF::equalIgnoringASCIICase(attributeValue, "none"_s))
                    sameSite = CookieSameSite::none;
            }
        }
    }

    return Cookie::create(name, value, domain, path, expires, secure, sameSite, httpOnly, maxAge, partitioned);
}

bool Cookie::isExpired() const
{
    if (!m_expires)
        return false; // Session cookie

    auto currentTime = WTF::WallTime::now().secondsSinceEpoch().seconds() * 1000.0;
    return currentTime > *m_expires;
}

static inline bool isValidCharacterInCookieName(char16_t c)
{
    return (c >= 0x21 && c <= 0x3A) || (c == 0x3C) || (c >= 0x3E && c <= 0x7E);
}
bool Cookie::isValidCookieName(const String& name)
{
    // /^[\u0021-\u003A\u003C\u003E-\u007E]+$/
    if (name.length() == 0) return false; // disallow empty name
    if (name.is8Bit()) {
        for (auto c : name.span8()) {
            if (!isValidCharacterInCookieName(c)) return false;
        }
    } else {
        for (auto c : name.span16()) {
            if (!isValidCharacterInCookieName(c)) return false;
        }
    }
    return true;
}
static inline bool isValidCharacterInCookiePath(char16_t c)
{
    return (c >= 0x20 && c <= 0x3A) || (c >= 0x3D && c <= 0x7E);
}
bool Cookie::isValidCookiePath(const String& path)
{
    // /^[\u0020-\u003A\u003D-\u007E]*$/
    if (path.is8Bit()) {
        for (auto c : path.span8()) {
            if (!isValidCharacterInCookiePath(c)) return false;
        }
    } else {
        for (auto c : path.span16()) {
            if (!isValidCharacterInCookiePath(c)) return false;
        }
    }
    return true;
}

static inline bool isValidCharacterInCookieDomain(char16_t c)
{
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
}
bool Cookie::isValidCookieDomain(const String& domain)
{
    // TODO: /^([.]?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$/i
    // for now, require all characters to be [a-z0-9.-]
    if (domain.is8Bit()) {
        for (auto c : domain.span8()) {
            if (!isValidCharacterInCookieDomain(c)) return false;
        }
    } else {
        for (auto c : domain.span16()) {
            if (!isValidCharacterInCookieDomain(c)) return false;
        }
    }
    return true;
}

bool Cookie::isValidExpiration(double milliseconds)
{
    return std::isfinite(milliseconds) && std::abs(milliseconds) <= WTF::maxECMAScriptTime;
}

ExceptionOr<String> Cookie::toString() const
{
    StringBuilder builder(OverflowPolicy::RecordOverflow);
    builder.append(m_name);
    builder.append('=');
    auto result = encodeURIComponent(m_value, builder);
    if (result.hasException())
        return result.releaseException();

    if (!m_domain.isEmpty()) {
        builder.append("; Domain="_s);
        builder.append(m_domain);
    }

    if (!m_path.isEmpty()) {
        builder.append("; Path="_s);
        builder.append(m_path);
    }

    if (m_expires) {
        builder.append("; Expires="_s);
        WTF::GregorianDateTime dateTime(*m_expires, WTF::LocalTimeOffset { false, 0 });
        RELEASE_ASSERT(dateTime.utcOffsetInMinute() == 0);
        const auto appendTwoDigits = [&](unsigned value) {
            RELEASE_ASSERT(value < 100);
            builder.append(static_cast<Latin1Character>('0' + value / 10));
            builder.append(static_cast<Latin1Character>('0' + value % 10));
        };
        // GregorianDateTime numbers Sunday as zero; weekdayName starts with Monday.
        builder.append(WTF::weekdayName[(dateTime.weekDay() + 6) % 7], ", "_s);
        appendTwoDigits(dateTime.monthDay());
        builder.append(' ', WTF::monthName[dateTime.month()], ' ');
        auto year = dateTime.year();
        if (year < 0) {
            builder.append('-');
            year = -year;
        }
        if (year < 10)
            builder.append("000"_s);
        else if (year < 100)
            builder.append("00"_s);
        else if (year < 1000)
            builder.append('0');
        builder.append(year, ' ');
        appendTwoDigits(dateTime.hour());
        builder.append(':');
        appendTwoDigits(dateTime.minute());
        builder.append(':');
        appendTwoDigits(dateTime.second());
        builder.append(" GMT"_s);
    }

    if (m_maxAge) {
        builder.append("; Max-Age="_s);
        WTF::NumberToStringBuffer buffer;
        builder.append(WTF::numberToStringAndSize(*m_maxAge, buffer));
    }

    if (m_secure)
        builder.append("; Secure"_s);

    if (m_httpOnly)
        builder.append("; HttpOnly"_s);

    if (m_partitioned)
        builder.append("; Partitioned"_s);

    switch (m_sameSite) {
    case CookieSameSite::strict:
        builder.append("; SameSite=Strict"_s);
        break;
    case CookieSameSite::lax:
        builder.append("; SameSite=Lax"_s);
        break;
    case CookieSameSite::none:
        builder.append("; SameSite=None"_s);
        break;
    }
    if (builder.hasOverflowed())
        return Exception { OutOfMemoryError };
    std::span<Latin1Character> bytes;
    auto impl = StringImpl::tryCreateUninitialized(builder.length(), bytes);
    if (!impl)
        return Exception { OutOfMemoryError };
    for (size_t i = 0; i < bytes.size(); ++i) {
        RELEASE_ASSERT(isASCII(builder[i]));
        bytes[i] = static_cast<Latin1Character>(builder[i]);
    }
    return String(WTF::move(impl));
}

size_t Cookie::memoryCost() const
{
    size_t cost = sizeof(Cookie);
    cost += m_name.sizeInBytes();
    cost += m_value.sizeInBytes();
    cost += m_domain.sizeInBytes();
    cost += m_path.sizeInBytes();
    return cost;
}

} // namespace WebCore
