// clang-format off
#pragma once

#include "root.h"

#include "JSCommonJSModule.h"
#include "ImportMetaObject.h"
#include "JavaScriptCore/ArgList.h"
#include "JavaScriptCore/JSCJSValue.h"
#include "JavaScriptCore/JSGlobalObjectInlines.h"
#include "isBuiltinModule.h"
#include <JavaScriptCore/JSBoundFunction.h>
#include <JavaScriptCore/ObjectConstructor.h>

using namespace Zig;
using namespace JSC;

namespace Bun {
void addNodeModuleConstructorProperties(JSC::VM &vm, Zig::GlobalObject *globalObject);

bool usesNodeModuleLookupPaths(const WTF::String& request);

}
