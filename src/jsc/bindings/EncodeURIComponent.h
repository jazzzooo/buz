#pragma once
#include "root.h"

#include "ExceptionOr.h"
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>

namespace WebCore {
ExceptionOr<void> encodeURIComponent(WTF::StringView source, StringBuilder& builder);
}
