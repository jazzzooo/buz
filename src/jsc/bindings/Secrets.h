#pragma once

#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSObject.h>
#include <wtf/text/WTFString.h>
#include <wtf/Vector.h>
#include <optional>

namespace Bun {

namespace Secrets {

enum class ErrorType {
    None,
    NotFound,
    AccessDenied,
    PlatformError
};

struct Error {
    ErrorType type = ErrorType::None;
    WTF::String message;
    int code = 0;

    bool isError() const { return type != ErrorType::None; }
};

Error setPassword(const WTF::CString& service, const WTF::CString& name, WTF::CString&& password, bool allowUnrestrictedAccess = false);

std::optional<WTF::Vector<uint8_t>> getPassword(const WTF::CString& service, const WTF::CString& name, Error& error);
bool deletePassword(const WTF::CString& service, const WTF::CString& name, Error& error);

} // namespace Secrets

} // namespace Bun
