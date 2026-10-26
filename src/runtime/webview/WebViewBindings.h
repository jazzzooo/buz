#pragma once

namespace JSC {
class JSGlobalObject;
class JSValue;
}

namespace Bun::Bindgen::WebViewPredicates {

bool isGlobalConsole(JSC::JSGlobalObject&, JSC::JSValue) noexcept;

}
