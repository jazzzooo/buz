#pragma once
#include "root.h"
#include "SchemaBindingsEnumerations.h"

#include "ExceptionOr.h"
#include <optional>
#include <wtf/RefCounted.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

using CookieSameSite = Bun::Bindgen::CookieSameSite;

struct CookieInit {
    String name = String();
    String value = String();
    String domain = String();
    String path = "/"_s;

    std::optional<int64_t> expires;
    bool secure = false;
    CookieSameSite sameSite = CookieSameSite::lax;
    bool httpOnly = false;
    std::optional<double> maxAge;
    bool partitioned = false;
};

class Cookie : public RefCounted<Cookie> {
    WTF_MAKE_NONCOPYABLE(Cookie);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Cookie);

public:
    ~Cookie();
    static ExceptionOr<Ref<Cookie>> create(const String& name, const String& value,
        const String& domain, const String& path,
        std::optional<int64_t> expires, bool secure, CookieSameSite sameSite,
        bool httpOnly, std::optional<double> maxAge, bool partitioned);

    static ExceptionOr<Ref<Cookie>> create(const CookieInit& init)
    {
        return create(init.name, init.value, init.domain, init.path, init.expires, init.secure, init.sameSite, init.httpOnly, init.maxAge, init.partitioned);
    }

    static ExceptionOr<Ref<Cookie>> parse(StringView cookieString);
    ExceptionOr<Ref<Cookie>> clone() const;

    const String& name() const { return m_name; }

    const String& value() const { return m_value; }
    void setValue(const String& value) { m_value = value; }

    const String& domain() const { return m_domain; }
    ExceptionOr<void> setDomain(const String& domain)
    {
        if (!isValidCookieDomain(domain)) {
            return Exception { TypeError, "Invalid cookie domain: contains invalid characters"_s };
        }
        m_domain = domain;
        return {};
    }

    const String& path() const { return m_path; }
    ExceptionOr<void> setPath(const String& path)
    {
        if (!isValidCookiePath(path)) {
            return Exception { TypeError, "Invalid cookie path: contains invalid characters"_s };
        }
        m_path = path;
        return {};
    }

    std::optional<int64_t> expires() const { return m_expires; }
    ExceptionOr<void> setExpires(std::optional<int64_t> ms)
    {
        if (ms && !isValidExpiration(*ms))
            return Exception { RangeError, "Invalid cookie expiration date"_s };
        m_expires = ms;
        return {};
    }

    bool secure() const { return m_secure; }
    void setSecure(bool secure) { m_secure = secure; }

    CookieSameSite sameSite() const { return m_sameSite; }
    void setSameSite(CookieSameSite sameSite) { m_sameSite = sameSite; }

    bool httpOnly() const { return m_httpOnly; }
    void setHttpOnly(bool httpOnly) { m_httpOnly = httpOnly; }

    std::optional<double> maxAge() const { return m_maxAge; }
    void setMaxAge(std::optional<double> maxAge) { m_maxAge = maxAge; }

    bool partitioned() const { return m_partitioned; }
    void setPartitioned(bool partitioned) { m_partitioned = partitioned; }

    bool isExpired() const;

    ExceptionOr<String> toString() const;
    size_t memoryCost() const;

    static bool isValidCookieName(const String& name);
    static bool isValidExpiration(double milliseconds);
    static bool isValidCookiePath(const String& path);
    static bool isValidCookieDomain(const String& domain);

private:
    Cookie(const String& name, const String& value,
        const String& domain, const String& path,
        std::optional<int64_t> expires, bool secure, CookieSameSite sameSite,
        bool httpOnly, std::optional<double> maxAge, bool partitioned);

    String m_name;
    String m_value;
    String m_domain;
    String m_path;
    std::optional<int64_t> m_expires;
    bool m_secure = false;
    CookieSameSite m_sameSite = CookieSameSite::lax;
    bool m_httpOnly = false;
    std::optional<double> m_maxAge;
    bool m_partitioned = false;
};

} // namespace WebCore
