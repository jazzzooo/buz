#include "CookieMap.h"
#include <wtf/text/ParsingUtilities.h>
#include "HTTPParsers.h"
#include "decodeURIComponentSIMD.h"
#include "StringConversion.h"
#include <wtf/text/MakeString.h>
namespace WebCore {

CookieMap::~CookieMap() = default;

CookieMap::CookieMap(Vector<KeyValuePair<String, String>>&& cookies)
    : m_originalCookies(WTF::move(cookies))
{
}

ExceptionOr<Ref<CookieMap>> CookieMap::createOriginal(Vector<KeyValuePair<String, String>>&& cookies)
{
    auto* memory = WTF::FastMalloc::tryMalloc(sizeof(CookieMap));
    if (!memory)
        return Exception { OutOfMemoryError };
    return adoptRef(*new (memory) CookieMap(WTF::move(cookies)));
}

ExceptionOr<Ref<CookieMap>> CookieMap::create()
{
    return createOriginal({});
}

ExceptionOr<Ref<CookieMap>> CookieMap::create(std::span<const Vector<String>> pairs)
{
    Vector<KeyValuePair<String, String>> cookies;
    if (!cookies.tryReserveInitialCapacity(pairs.size()))
        return Exception { OutOfMemoryError };
    for (const auto& pair : pairs) {
        if (pair.size() != 2)
            return Exception { TypeError, "Invalid cookie string: expected name=value pair"_s };
        cookies.unsafeAppendWithoutCapacityCheck(makeKeyValuePair(pair[0], pair[1]));
    }
    return createOriginal(WTF::move(cookies));
}

ExceptionOr<Ref<CookieMap>> CookieMap::create(std::span<const std::pair<String, String>> pairs)
{
    Vector<KeyValuePair<String, String>> cookies;
    if (!cookies.tryReserveInitialCapacity(pairs.size()))
        return Exception { OutOfMemoryError };
    for (const auto& pair : pairs)
        cookies.unsafeAppendWithoutCapacityCheck(makeKeyValuePair(pair.first, pair.second));
    return createOriginal(WTF::move(cookies));
}

static ExceptionOr<String> decodeCookiePart(StringView part)
{
    if (part.find('%') == notFound) {
        auto result = tryMakeString(part);
        if (result.isNull())
            return Exception { OutOfMemoryError };
        return result;
    }
    auto utf8 = Bun::encodeUTF8ReplacingInvalidSequences(part);
    if (!utf8) {
        RELEASE_ASSERT(utf8.error() == WTF::UTF8ConversionError::OutOfMemory);
        return Exception { OutOfMemoryError };
    }
    auto decoded = Bun::decodeURIComponentSIMD({ reinterpret_cast<const uint8_t*>(utf8->span().data()), utf8->size() });
    if (!decoded)
        return Exception { OutOfMemoryError };
    return WTF::move(*decoded);
}

ExceptionOr<Ref<CookieMap>> CookieMap::create(StringView input)
{
    Vector<KeyValuePair<String, String>> cookies;
    for (auto pair : input.split(';')) {
        const auto equals = pair.find('=');
        if (equals == notFound)
            continue;
        auto nameView = pair.substring(0, equals).trim(isASCIIWhitespace<char16_t>);
        if (nameView.isEmpty())
            continue;
        auto name = decodeCookiePart(nameView);
        if (name.hasException())
            return name.releaseException();
        auto value = decodeCookiePart(pair.substring(equals + 1).trim(isASCIIWhitespace<char16_t>));
        if (value.hasException())
            return value.releaseException();
        if (!cookies.tryAppend(makeKeyValuePair(name.releaseReturnValue(), value.releaseReturnValue())))
            return Exception { OutOfMemoryError };
    }
    return createOriginal(WTF::move(cookies));
}

std::optional<String> CookieMap::get(const String& name) const
{
    auto modifiedCookieIndex = m_modifiedCookies.findIf([&](const auto& change) {
        return change.cookie->name() == name;
    });
    if (modifiedCookieIndex != notFound) {
        if (m_modifiedCookies[modifiedCookieIndex].kind == ChangeKind::Delete) {
            return std::nullopt;
        }
        return m_modifiedCookies[modifiedCookieIndex].cookie->value();
    }
    auto originalCookieIndex = m_originalCookies.findIf([&](auto& cookie) {
        return cookie.key == name;
    });
    if (originalCookieIndex != notFound) {
        return std::optional<String>(m_originalCookies[originalCookieIndex].value);
    }
    return std::nullopt;
}

bool CookieMap::has(const String& name) const
{
    return get(name).has_value();
}

ExceptionOr<Vector<String>> CookieMap::toSetCookieHeaders() const
{
    Vector<String> result;
    if (!result.tryReserveInitialCapacity(m_modifiedCookies.size()))
        return Exception { OutOfMemoryError };
    for (const auto& change : m_modifiedCookies) {
        auto serialized = change.cookie->toString();
        if (serialized.hasException())
            return serialized.releaseException();
        result.unsafeAppendWithoutCapacityCheck(serialized.releaseReturnValue());
    }
    return result;
}

void CookieMap::removeInternal(const String& name)
{
    // Remove any existing matching cookies
    m_originalCookies.removeAllMatching([&](auto& cookie) {
        return cookie.key == name;
    });
    m_modifiedCookies.removeAllMatching([&](const auto& change) {
        return change.cookie->name() == name;
    });
}

ExceptionOr<void> CookieMap::set(Ref<Cookie> cookie)
{
    return setChange(WTF::move(cookie), ChangeKind::Set);
}

ExceptionOr<void> CookieMap::setChange(Ref<Cookie> cookie, ChangeKind kind)
{
    const bool replacesModified = m_modifiedCookies.findIf([&](const auto& existing) {
        return existing.cookie->name() == cookie->name();
    }) != notFound;
    if (!replacesModified && !m_modifiedCookies.tryReserveCapacity(static_cast<size_t>(m_modifiedCookies.size()) + 1))
        return Exception { OutOfMemoryError };
    removeInternal(cookie->name());
    m_modifiedCookies.unsafeAppendWithoutCapacityCheck(Change { WTF::move(cookie), kind });
    return {};
}

ExceptionOr<void> CookieMap::remove(const CookieStoreDeleteOptions& options)
{
    auto cookie_exception = Cookie::create(options.name, ""_s, options.domain, options.path, 1, false, CookieSameSite::lax, false, std::nullopt, false);
    if (cookie_exception.hasException()) {
        return cookie_exception.releaseException();
    }
    return setChange(cookie_exception.releaseReturnValue(), ChangeKind::Delete);
}

ExceptionOr<Ref<CookieMap>> CookieMap::clone() const
{
    Vector<KeyValuePair<String, String>> original;
    Vector<Change> modified;
    if (!original.tryAppend(m_originalCookies.span()) || !modified.tryReserveInitialCapacity(m_modifiedCookies.size()))
        return Exception { OutOfMemoryError };
    for (const auto& change : m_modifiedCookies) {
        auto cookie = change.cookie->clone();
        if (cookie.hasException())
            return cookie.releaseException();
        modified.unsafeAppendWithoutCapacityCheck(Change { cookie.releaseReturnValue(), change.kind });
    }
    auto result = createOriginal(WTF::move(original));
    if (result.hasException())
        return result.releaseException();
    auto clone = result.releaseReturnValue();
    clone->m_modifiedCookies = WTF::move(modified);
    return clone;
}

size_t
CookieMap::size() const
{
    size_t size = 0;
    for (const auto& change : m_modifiedCookies) {
        if (change.kind == ChangeKind::Delete) continue;
        size += 1;
    }
    size += m_originalCookies.size();
    return size;
}

size_t CookieMap::memoryCost() const
{
    size_t cost = sizeof(CookieMap);
    for (auto& cookie : m_originalCookies) {
        cost += cookie.key.sizeInBytes();
        cost += cookie.value.sizeInBytes();
    }
    for (const auto& change : m_modifiedCookies) {
        cost += change.cookie->name().sizeInBytes();
        cost += change.cookie->value().sizeInBytes();
    }
    return cost;
}

std::optional<KeyValuePair<String, String>> CookieMap::Iterator::next()
{
    while (m_index < static_cast<size_t>(m_target->m_modifiedCookies.size()) + m_target->m_originalCookies.size()) {
        if (m_index >= m_target->m_modifiedCookies.size()) {
            return m_target->m_originalCookies[(m_index++) - m_target->m_modifiedCookies.size()];
        }

        const auto& change = m_target->m_modifiedCookies[m_index++];
        if (change.kind == ChangeKind::Delete)
            continue;
        return KeyValuePair<String, String>(change.cookie->name(), change.cookie->value());
    }
    return std::nullopt;
}

CookieMap::Iterator::Iterator(CookieMap& cookieMap)
    : m_target(cookieMap)
{
}

} // namespace WebCore
