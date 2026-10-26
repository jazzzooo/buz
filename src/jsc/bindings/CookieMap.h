#pragma once
#include "root.h"

#include "Cookie.h"
#include "ExceptionOr.h"
#include <wtf/Vector.h>
#include <wtf/RefCounted.h>
#include <wtf/text/WTFString.h>
#include <span>
#include <utility>

namespace WebCore {

struct CookieStoreGetOptions {
    String name {};
    String url {};
};

struct CookieStoreDeleteOptions {
    String name {};
    String domain {};
    String path {};
};

class CookieMap : public RefCounted<CookieMap> {
    WTF_MAKE_NONCOPYABLE(CookieMap);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(CookieMap);

public:
    ~CookieMap();

    static ExceptionOr<Ref<CookieMap>> create();
    static ExceptionOr<Ref<CookieMap>> create(StringView);
    static ExceptionOr<Ref<CookieMap>> create(std::span<const Vector<String>>);
    static ExceptionOr<Ref<CookieMap>> create(std::span<const std::pair<String, String>>);

    std::optional<String> get(const String& name) const;
    ExceptionOr<Vector<String>> toSetCookieHeaders() const;

    bool has(const String& name) const;

    ExceptionOr<void> set(Ref<Cookie>);

    ExceptionOr<Ref<CookieMap>> clone() const;

    ExceptionOr<void> remove(const CookieStoreDeleteOptions& options);

    size_t size() const;
    size_t memoryCost() const;

    class Iterator {
    public:
        explicit Iterator(CookieMap&);

        std::optional<KeyValuePair<String, String>> next();

    private:
        Ref<CookieMap> m_target;
        size_t m_index { 0 };
    };

    Iterator createIterator() { return Iterator { *this }; }
    Iterator createIterator(const void*) { return Iterator { *this }; }

private:
    enum class ChangeKind : uint8_t { Set,
        Delete };
    struct Change {
        Ref<Cookie> cookie;
        ChangeKind kind;
    };

    CookieMap(Vector<KeyValuePair<String, String>>&& cookies);
    static ExceptionOr<Ref<CookieMap>> createOriginal(Vector<KeyValuePair<String, String>>&&);

    void removeInternal(const String& name);
    ExceptionOr<void> setChange(Ref<Cookie>, ChangeKind);

    Vector<KeyValuePair<String, String>> m_originalCookies;
    Vector<Change> m_modifiedCookies;
};

} // namespace WebCore
