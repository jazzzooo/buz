#include "root.h"

#include "JavaScriptCore/ArgList.h"
#include "ConsoleObject.h"
#include "SchemaBindings.h"

#include <JavaScriptCore/ConsoleClient.h>
#include <JavaScriptCore/ConsoleMessage.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ScriptArguments.h>
#include <wtf/text/WTFString.h>

#include <JavaScriptCore/JSGlobalObjectInspectorController.h>
#include <JavaScriptCore/JSGlobalObjectDebuggable.h>
#include <JavaScriptCore/ConsoleClient.h>

#include "GCDefferalContext.h"
#include <JavaScriptCore/InspectorScriptProfilerAgent.h>
#include <JavaScriptCore/InspectorDebuggerAgent.h>
#include <JavaScriptCore/InspectorConsoleAgent.h>

namespace Bun {
using namespace JSC;
using namespace Inspector;

using ScriptArguments = Inspector::ScriptArguments;
using MessageType = JSC::MessageType;
using MessageLevel = JSC::MessageLevel;
using JSGlobalObject = JSC::JSGlobalObject;

using String = WTF::String;

void ConsoleObject::messageWithTypeAndLevel(MessageType type, MessageLevel level,
    JSC::JSGlobalObject* globalObject,
    Ref<ScriptArguments>&& arguments)
{
    if (globalObject->inspectable()) {
        if (auto client = globalObject->inspectorController().consoleClient()) {
            client->messageWithTypeAndLevel(type, level, globalObject, arguments.copyRef());
        }
    }
    auto& vm = JSC::getVM(globalObject);
    auto args = arguments.ptr();
    JSC::JSValue jsArgs[255];

    auto count = std::min(args->argumentCount(), (size_t)255);
    for (size_t i = 0; i < count; i++) {
        auto val = args->argumentAt(i);
        jsArgs[i] = val;
    }

    if (type == MessageType::Table && count >= 2 && !args->argumentAt(1).isUndefined() && (!args->argumentAt(1).isCell() || args->argumentAt(1).asCell()->type() != JSC::JSType::ArrayType)) [[unlikely]] {
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSC::throwTypeError(globalObject, scope, "The \"properties\" argument must be an instance of Array."_s);
        return;
    }

    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_messageWithTypeAndLevel(
        globalObject,
        static_cast<uint32_t>(type),
        static_cast<uint32_t>(level),
        std::span<const JSC::JSValue>(jsArgs, count));
}
void ConsoleObject::count(JSGlobalObject* globalObject, const String& label)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_consoleCount(globalObject, label);
}

void ConsoleObject::countReset(JSGlobalObject* globalObject, const String& label)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_consoleCountReset(globalObject, label);
}

void ConsoleObject::takeHeapSnapshot(JSC::JSGlobalObject* globalObject, const String& label)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_consoleTakeHeapSnapshot(globalObject, label);
}
void ConsoleObject::time(JSGlobalObject* globalObject, const String& label)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_consoleTime(globalObject, label);
}
void ConsoleObject::timeLog(JSGlobalObject* globalObject, const String& label,
    Ref<ScriptArguments>&& arguments)
{
    auto args = arguments.ptr();
    JSC::JSValue jsArgs[255];
    auto count = std::min(args->argumentCount(), (size_t)255);
    for (size_t i = 0; i < count; i++) {
        auto val = args->argumentAt(i);
        jsArgs[i] = val;
    }

    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_timeLog(
        globalObject,
        label,
        std::span<const JSC::JSValue>(jsArgs, count));
}
void ConsoleObject::timeEnd(JSGlobalObject* globalObject, const String& label)
{
    Bun::Bindgen::ZigExports::bunBindgenZig_ConsoleObject_consoleTimeEnd(globalObject, label);
}
void ConsoleObject::timeStamp(JSGlobalObject*, Ref<ScriptArguments>&&) {}
void ConsoleObject::record(JSGlobalObject*, Ref<ScriptArguments>&&) {}
void ConsoleObject::recordEnd(JSGlobalObject*, Ref<ScriptArguments>&&) {}
void ConsoleObject::screenshot(JSGlobalObject*, Ref<ScriptArguments>&&)
{
}
void ConsoleObject::warnUnimplemented(const String& method) {}

void ConsoleObject::profile(JSC::JSGlobalObject* globalObject, const String& title)
{
    if (globalObject->inspectable()) {
        if (auto client = globalObject->inspectorController().consoleClient()) {
            client->profile(globalObject, title);
        }
    }
}

void ConsoleObject::profileEnd(JSC::JSGlobalObject* globalObject, const String& title)
{
    if (globalObject->inspectable()) {
        if (auto client = globalObject->inspectorController().consoleClient()) {
            client->profileEnd(globalObject, title);
        }
    }
}

}
