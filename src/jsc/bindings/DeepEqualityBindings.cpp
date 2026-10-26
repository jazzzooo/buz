#include "root.h"

#include "BunObject.h"
#include "DOMURL.h"
#include "FetchHeaders.h"
#include "JSDOMURL.h"
#include "JSDOMWrapper.h"
#include "JSDOMExceptionHandling.h"
#include "JSFetchHeaders.h"
#include "JSURLSearchParams.h"
#include "SchemaBindings.h"
#include "URLSearchParams.h"
#include "helpers.h"
#include <JavaScriptCore/BigIntObject.h>
#include <JavaScriptCore/BooleanObject.h>
#include <JavaScriptCore/DateInstance.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/ErrorInstanceInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSArrayInlines.h>
#include <JavaScriptCore/JSGlobalObjectInlines.h>
#include <JavaScriptCore/JSGlobalProxy.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapIterator.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/JSPromiseConstructor.h>
#include <JavaScriptCore/JSSet.h>
#include <JavaScriptCore/JSSetIterator.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSWeakMap.h>
#include <JavaScriptCore/JSWrapperObject.h>
#include <JavaScriptCore/NumberObject.h>
#include <JavaScriptCore/PropertyNameArray.h>
#include <JavaScriptCore/RegExpObject.h>
#include <JavaScriptCore/VMInlines.h>
#include <set>
#include <wtf/Scope.h>

using namespace JSC;
using namespace WebCore;

typedef uint8_t ExpectFlags;

// Keep this in sync with the Expect flags wire layout in test_runner/expect/State.zig.
// clang disable unused warning
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"

static constexpr int FLAG_PROMISE_RESOLVES = (1 << 0);
static constexpr int FLAG_PROMISE_REJECTS = (1 << 1);
static constexpr int FLAG_NOT = (1 << 2);

#pragma clang diagnostic pop

enum class AsymmetricMatcherResult : uint8_t {
    PASS,
    FAIL,
    NOT_MATCHER,
};

enum class AsymmetricMatcherConstructorType : int8_t {
    exception = -1,
    none = 0,
    Symbol = 1,
    String = 2,
    Object = 3,
    Array = 4,
    BigInt = 5,
    Boolean = 6,
    Number = 7,
    Promise = 8,
    InstanceOf = 9,
};

template<bool isStrict, bool enableAsymmetricMatchers>
bool Bun__deepEquals(JSC::JSGlobalObject* globalObject, JSC::JSValue v1, JSC::JSValue v2, JSC::MarkedArgumentBuffer&, Vector<std::pair<JSC::JSValue, JSC::JSValue>, 16>& stack, JSC::ThrowScope& scope, bool addToStack);

template<bool enableAsymmetricMatchers>
bool Bun__deepMatch(
    JSC::JSValue object,
    std::set<JSC::EncodedJSValue>* seenObjProperties,
    JSC::JSValue subset,
    std::set<JSC::EncodedJSValue>* seenSubsetProperties,
    JSC::JSGlobalObject* globalObject,
    JSC::ThrowScope& throwScope,
    JSC::MarkedArgumentBuffer* gcBuffer,
    bool replacePropsWithAsymmetricMatchers,
    bool isMatchingObjectContaining);

Bun::Bindgen::Engine::BunBindgenEngine_Expect_asymmetricMatcherConstructorTypeFromJS_Return Bun::Bindgen::Engine::bunBindgenEngine_Expect_asymmetricMatcherConstructorTypeFromJS(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_Expect_asymmetricMatcherConstructorTypeFromJS_Arguments& args)
{
    using Return = Bun::Bindgen::AsymmetricMatcherConstructorType;
    auto* globalObject = &context.globalObject;
    if (args.value.isObject()) {
        JSObject* object = args.value.getObject();
        auto& vm = JSC::getVM(globalObject);
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (globalObject->numberObjectConstructor() == object) {
            return Return::Number;
        }

        if (globalObject->booleanObjectConstructor() == object) {
            return Return::Boolean;
        }

        auto stringConstructorValue = globalObject->stringPrototype()->getIfPropertyExists(globalObject, vm.propertyNames->constructor);
        RETURN_IF_EXCEPTION(scope, Return::none);
        if (stringConstructorValue == object) {
            return Return::String;
        }

        auto symbolConstructorValue = globalObject->symbolPrototype()->getIfPropertyExists(globalObject, vm.propertyNames->constructor);
        RETURN_IF_EXCEPTION(scope, Return::none);
        if (symbolConstructorValue == object) {
            return Return::Symbol;
        }

        auto bigIntConstructorValue = globalObject->bigIntPrototype()->getIfPropertyExists(globalObject, vm.propertyNames->constructor);
        RETURN_IF_EXCEPTION(scope, Return::none);
        if (bigIntConstructorValue == object) {
            return Return::BigInt;
        }

        JSObject* promiseConstructor = globalObject->promiseConstructor();

        if (promiseConstructor == object) {
            return Return::Promise;
        }

        JSObject* array = globalObject->arrayConstructor();

        if (array == object) {
            return Return::Array;
        }

        JSObject* obj = globalObject->objectConstructor();

        if (obj == object) {
            return Return::Object;
        }

        return Return::InstanceOf;
    }

    return Return::none;
}

bool readFlagsAndProcessPromise(JSValue& instanceValue, ExpectFlags& flags, JSGlobalObject* globalObject, JSValue& value, AsymmetricMatcherConstructorType& constructorType, ThrowScope& throwScope)
{
    auto processed = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_readFlagsAndProcessPromise(
        globalObject,
        instanceValue,
        value);
    RETURN_IF_EXCEPTION(throwScope, false);
    if (!processed.value)
        return false;
    flags = processed.flags;
    constructorType = static_cast<AsymmetricMatcherConstructorType>(flags >> 3);
    value = *processed.value;
    return true;
}

AsymmetricMatcherResult matchAsymmetricMatcherAndGetFlags(JSGlobalObject* globalObject, JSValue matcherProp, JSValue otherProp, ThrowScope& throwScope, ExpectFlags& flags)
{
    AsymmetricMatcherConstructorType constructorType = AsymmetricMatcherConstructorType::none;

    if (bun_bindgen_class_Expect_ExpectAnything_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        if (otherProp.isUndefinedOrNull()) {
            return AsymmetricMatcherResult::FAIL;
        }

        return AsymmetricMatcherResult::PASS;
    } else if (bun_bindgen_class_Expect_ExpectAny_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        JSValue constructorValue = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectAnyConstructorValue(globalObject, matcherProp);
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
        JSObject* constructorObject = constructorValue.getObject();

        switch (constructorType) {
        case AsymmetricMatcherConstructorType::Symbol: {
            if (otherProp.isSymbol()) {
                return AsymmetricMatcherResult::PASS;
            }
            break;
        }
        case AsymmetricMatcherConstructorType::String: {
            if (otherProp.isCell()) {
                JSCell* cell = otherProp.asCell();
                switch (cell->type()) {
                case JSC::StringType:
                case JSC::StringObjectType:
                case JSC::DerivedStringObjectType: {
                    return AsymmetricMatcherResult::PASS;
                }
                default: {
                    break;
                }
                }
            }
            break;
        }

        case AsymmetricMatcherConstructorType::BigInt: {
            if (otherProp.isBigInt()) {
                return AsymmetricMatcherResult::PASS;
            }
            break;
        }

        case AsymmetricMatcherConstructorType::Boolean: {
            if (otherProp.isBoolean()) {
                return AsymmetricMatcherResult::PASS;
            }

            if (dynamicDowncast<BooleanObject>(otherProp)) {
                return AsymmetricMatcherResult::PASS;
            }

            break;
        }

        case AsymmetricMatcherConstructorType::Number: {
            if (otherProp.isNumber()) {
                return AsymmetricMatcherResult::PASS;
            }

            if (dynamicDowncast<NumberObject>(otherProp)) {
                return AsymmetricMatcherResult::PASS;
            }

            break;
        }

        case AsymmetricMatcherConstructorType::Promise: {
            if (otherProp.isCell() && otherProp.asCell()->type() == JSPromiseType) {
                return AsymmetricMatcherResult::PASS;
            }
            break;
        }

        case AsymmetricMatcherConstructorType::Array: {
            if (JSC::isArray(globalObject, otherProp)) {
                return AsymmetricMatcherResult::PASS;
            }
            break;
        }

        case AsymmetricMatcherConstructorType::Object: {
            if (otherProp.isObject()) {
                return AsymmetricMatcherResult::PASS;
            }
            break;
        }

        case AsymmetricMatcherConstructorType::InstanceOf: {
            break;
        }
        case AsymmetricMatcherConstructorType::exception:
        case AsymmetricMatcherConstructorType::none: {
            ASSERT_NOT_REACHED_WITH_MESSAGE("Invalid constructor type");
            break;
        }
        }

        bool hasInstance = constructorObject->hasInstance(globalObject, otherProp);
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
        if (hasInstance) {
            return AsymmetricMatcherResult::PASS;
        }

        return AsymmetricMatcherResult::FAIL;
    } else if (bun_bindgen_class_Expect_ExpectStringContaining_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        JSValue expectedSubstring = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectStringContainingValue(globalObject, matcherProp);
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

        if (otherProp.isString()) {
            String otherString = otherProp.toWTFString(globalObject);
            RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

            String substring = expectedSubstring.toWTFString(globalObject);
            RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

            if (otherString.find(substring) != WTF::notFound) {
                return AsymmetricMatcherResult::PASS;
            }
        }

        return AsymmetricMatcherResult::FAIL;
    } else if (bun_bindgen_class_Expect_ExpectStringMatching_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        JSValue expectedTestValue = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectStringMatchingValue(globalObject, matcherProp);
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

        if (otherProp.isString()) {
            if (expectedTestValue.isString()) {
                String otherString = otherProp.toWTFString(globalObject);
                RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

                String substring = expectedTestValue.toWTFString(globalObject);
                RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

                if (otherString.find(substring) != WTF::notFound) {
                    return AsymmetricMatcherResult::PASS;
                }
            } else if (expectedTestValue.isCell() and expectedTestValue.asCell()->type() == RegExpObjectType) {
                if (auto* regex = dynamicDowncast<RegExpObject>(expectedTestValue)) {
                    JSString* otherString = otherProp.toString(globalObject);
                    RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
                    auto matched = regex->match(globalObject, otherString);
                    RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
                    if (matched) {
                        return AsymmetricMatcherResult::PASS;
                    }
                }
            }
        }

        return AsymmetricMatcherResult::FAIL;
    } else if (bun_bindgen_class_Expect_ExpectArrayContaining_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        JSValue expectedArrayValue = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectArrayContainingValue(globalObject, matcherProp);
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);

        // Note: isArray() accepts Proxy->Array, but jsDynamicCast returns null for Proxy.
        JSArray* expectedArray = dynamicDowncast<JSArray>(expectedArrayValue);
        JSArray* otherArray = dynamicDowncast<JSArray>(otherProp);
        if (expectedArray && otherArray) {
            unsigned expectedLength = expectedArray->length();
            unsigned otherLength = otherArray->length();

            // A empty array is all array's subset
            if (expectedLength == 0) {
                return AsymmetricMatcherResult::PASS;
            }

            // O(m*n) but works for now
            for (unsigned m = 0; m < expectedLength; m++) {
                JSValue expectedValue = expectedArray->getIndex(globalObject, m);
                RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
                bool found = false;

                for (unsigned n = 0; n < otherLength; n++) {
                    JSValue otherValue = otherArray->getIndex(globalObject, n);
                    RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
                    Vector<std::pair<JSValue, JSValue>, 16> stack;
                    MarkedArgumentBuffer gcBuffer;
                    bool foundNow = Bun__deepEquals<false, true>(globalObject, expectedValue, otherValue, gcBuffer, stack, throwScope, true);
                    RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
                    if (foundNow) {
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    return AsymmetricMatcherResult::FAIL;
                }
            }

            return AsymmetricMatcherResult::PASS;
        }

        return AsymmetricMatcherResult::FAIL;
    } else if (bun_bindgen_class_Expect_ExpectObjectContaining_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        JSValue patternObject = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectObjectContainingValue(globalObject, matcherProp);
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
        if (patternObject.isObject()) {
            if (otherProp.isObject()) {
                // SAFETY: visited property sets are not required when
                // `enableAsymmetricMatchers` and `isMatchingObjectContaining`
                // are both true
                bool match = Bun__deepMatch<true>(otherProp, nullptr, patternObject, nullptr, globalObject, throwScope, nullptr, false, true);
                RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
                if (match) {
                    return AsymmetricMatcherResult::PASS;
                }
            }
        }

        return AsymmetricMatcherResult::FAIL;
    } else if (bun_bindgen_class_Expect_ExpectCloseTo_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        if (!otherProp.isNumber()) {
            // disable the "not" flag here, because if not a number it should still return FAIL when negated
            flags = flags & ~FLAG_NOT;
            return AsymmetricMatcherResult::FAIL;
        }

        bool isClose = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectCloseToMatches(globalObject, matcherProp, otherProp.asNumber());
        RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
        return isClose ? AsymmetricMatcherResult::PASS : AsymmetricMatcherResult::FAIL;
    } else if (bun_bindgen_class_Expect_ExpectCustomAsymmetricMatcher_try_cast_value(matcherProp)) {
        if (!readFlagsAndProcessPromise(matcherProp, flags, globalObject, otherProp, constructorType, throwScope))
            return AsymmetricMatcherResult::FAIL;

        // ignore the "not" flag here, because the custom matchers handle it themselves (accessing this.isNot)
        // and it would result in a double negation
        flags = flags & ~FLAG_NOT;

        bool passed = Bun::Bindgen::ZigExports::bunBindgenZig_Expect_expectCustomAsymmetricMatcherExecute(globalObject, matcherProp, otherProp);
        return passed ? AsymmetricMatcherResult::PASS : AsymmetricMatcherResult::FAIL;
    }

    return AsymmetricMatcherResult::NOT_MATCHER;
}

AsymmetricMatcherResult matchAsymmetricMatcher(JSGlobalObject* globalObject, JSValue matcherProp, JSValue otherProp, ThrowScope& throwScope)
{
    ExpectFlags flags = ExpectFlags();
    AsymmetricMatcherResult result = matchAsymmetricMatcherAndGetFlags(globalObject, matcherProp, otherProp, throwScope, flags);
    RETURN_IF_EXCEPTION(throwScope, AsymmetricMatcherResult::FAIL);
    if (result != AsymmetricMatcherResult::NOT_MATCHER && (flags & FLAG_NOT)) {
        result = (result == AsymmetricMatcherResult::PASS) ? AsymmetricMatcherResult::FAIL : AsymmetricMatcherResult::PASS;
    }
    return result;
}

JSValue getIndexWithoutAccessors(JSGlobalObject* globalObject, JSObject* obj, uint64_t i)
{
    if (obj->canGetIndexQuickly(i)) {
        return obj->tryGetIndexQuickly(i);
    }

    PropertySlot slot(obj, PropertySlot::InternalMethodType::Get);
    if (obj->methodTable()->getOwnPropertySlotByIndex(obj, globalObject, i, slot)) {
        if (!slot.isAccessor()) {
            return slot.getValue(globalObject, i);
        }
    }

    return JSValue();
}

template<bool isStrict, bool enableAsymmetricMatchers>
std::optional<bool> specialObjectsDequal(JSC::JSGlobalObject* globalObject, MarkedArgumentBuffer& gcBuffer, Vector<std::pair<JSC::JSValue, JSC::JSValue>, 16>& stack, ThrowScope& scope, JSCell* _Nonnull c1, JSCell* _Nonnull c2);

template<bool isStrict, bool enableAsymmetricMatchers>
bool Bun__deepEquals(JSC::JSGlobalObject* globalObject, JSValue v1, JSValue v2, MarkedArgumentBuffer& gcBuffer, Vector<std::pair<JSC::JSValue, JSC::JSValue>, 16>& stack, ThrowScope& scope, bool addToStack)
{
    VM& vm = globalObject->vm();
    if (!vm.isSafeToRecurse()) [[unlikely]] {
        throwStackOverflowError(globalObject, scope);
        return false;
    }

    // need to check this before primitives, asymmetric matchers
    // can match against any type of value.
    if constexpr (enableAsymmetricMatchers) {
        if (!v2.isEmpty() && v2.isObject()) {
            switch (matchAsymmetricMatcher(globalObject, v2, v1, scope)) {
            case AsymmetricMatcherResult::FAIL:
                return false;
            case AsymmetricMatcherResult::PASS:
                return true;
            case AsymmetricMatcherResult::NOT_MATCHER:
                // continue comparison
                break;
            }
        }
        if (!v1.isEmpty() && v1.isObject()) {
            switch (matchAsymmetricMatcher(globalObject, v1, v2, scope)) {
            case AsymmetricMatcherResult::FAIL:
                return false;
            case AsymmetricMatcherResult::PASS:
                return true;
            case AsymmetricMatcherResult::NOT_MATCHER:
                // continue comparison
                break;
            }
        }
    }

    if (!v1.isEmpty() && !v2.isEmpty()) {
        auto same = JSC::sameValue(globalObject, v1, v2);
        RETURN_IF_EXCEPTION(scope, false);
        if (same) {
            return true;
        }
    }

    if (v1.isEmpty() || v2.isEmpty())
        return v1.isEmpty() == v2.isEmpty();

    if (v1.isPrimitive() || v2.isPrimitive())
        return false;

    RELEASE_ASSERT(v1.isCell());
    RELEASE_ASSERT(v2.isCell());

    const size_t length = stack.size();
    const auto originalGCBufferSize = gcBuffer.size();
    for (size_t i = 0; i < length; i++) {
        auto values = stack.at(i);
        if (JSC::JSValue::strictEqual(globalObject, values.first, v1)) {
            return JSC::JSValue::strictEqual(globalObject, values.second, v2);
        } else if (JSC::JSValue::strictEqual(globalObject, values.second, v2))
            return false;
    }

    if (addToStack) {
        gcBuffer.append(v1);
        gcBuffer.append(v2);
        stack.append({ v1, v2 });
    }
    auto removeFromStack = WTF::makeScopeExit([&] {
        if (addToStack) {
            stack.removeAt(length);
            while (gcBuffer.size() > originalGCBufferSize)
                gcBuffer.removeLast();
        }
    });

    JSCell* c1 = v1.asCell();
    JSCell* c2 = v2.asCell();
    ASSERT(c1);
    ASSERT(c2);
    std::optional<bool> isSpecialEqual = specialObjectsDequal<isStrict, enableAsymmetricMatchers>(globalObject, gcBuffer, stack, scope, c1, c2);
    RETURN_IF_EXCEPTION(scope, false);
    if (isSpecialEqual.has_value()) return WTF::move(*isSpecialEqual);
    isSpecialEqual = specialObjectsDequal<isStrict, enableAsymmetricMatchers>(globalObject, gcBuffer, stack, scope, c2, c1);
    if (isSpecialEqual.has_value()) return WTF::move(*isSpecialEqual);
    JSObject* o1 = v1.getObject();
    JSObject* o2 = v2.getObject();

    bool v1Array = isArray(globalObject, v1);
    RETURN_IF_EXCEPTION(scope, false);
    bool v2Array = isArray(globalObject, v2);
    RETURN_IF_EXCEPTION(scope, false);

    if (v1Array != v2Array)
        return false;

    if (v1Array && v2Array && !(o1->isProxy() || o2->isProxy())) {
        JSC::JSArray* array1 = uncheckedDowncast<JSC::JSArray>(v1);
        JSC::JSArray* array2 = uncheckedDowncast<JSC::JSArray>(v2);

        size_t array1Length = array1->length();
        size_t array2Length = array2->length();
        if constexpr (isStrict) {
            if (array1Length != array2Length) {
                return false;
            }
        }

        uint64_t i = 0;
        for (; i < array1Length; i++) {
            JSValue left = getIndexWithoutAccessors(globalObject, o1, i);
            RETURN_IF_EXCEPTION(scope, false);
            JSValue right = getIndexWithoutAccessors(globalObject, o2, i);
            RETURN_IF_EXCEPTION(scope, false);

            if constexpr (isStrict) {
                if (left.isEmpty() && right.isEmpty()) {
                    continue;
                }
                if (left.isEmpty() || right.isEmpty()) {
                    return false;
                }
            }

            if constexpr (!isStrict) {
                if (((left.isEmpty() || right.isEmpty()) && (left.isUndefined() || right.isUndefined()))) {
                    continue;
                }
            }

            auto eql = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, left, right, gcBuffer, stack, scope, true);
            RETURN_IF_EXCEPTION(scope, false);
            if (!eql) return false;
        }

        for (; i < array2Length; i++) {
            JSValue right = getIndexWithoutAccessors(globalObject, o2, i);
            RETURN_IF_EXCEPTION(scope, false);

            if (((right.isEmpty() || right.isUndefined()))) {
                continue;
            }

            return false;
        }

        JSC::PropertyNameArrayBuilder a1(vm, PropertyNameMode::Symbols, PrivateSymbolMode::Exclude);
        JSC::PropertyNameArrayBuilder a2(vm, PropertyNameMode::Symbols, PrivateSymbolMode::Exclude);
        JSObject::getOwnPropertyNames(o1, globalObject, a1, DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(scope, false);
        JSObject::getOwnPropertyNames(o2, globalObject, a2, DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(scope, false);

        size_t propertyLength = a1.size();
        if constexpr (isStrict) {
            if (propertyLength != a2.size()) {
                return false;
            }
        }

        // take a property name from one, try to get it from both
        for (size_t i = 0; i < propertyLength; i++) {
            Identifier i1 = a1[i];
            PropertyName propertyName1 = PropertyName(i1);

            JSValue prop1 = o1->get(globalObject, propertyName1);
            RETURN_IF_EXCEPTION(scope, false);

            if (!prop1) [[unlikely]] {
                return false;
            }

            JSValue prop2 = o2->getIfPropertyExists(globalObject, propertyName1);
            RETURN_IF_EXCEPTION(scope, false);

            if constexpr (!isStrict) {
                if (prop1.isUndefined() && prop2.isEmpty()) {
                    continue;
                }
            }

            if (!prop2) {
                return false;
            }

            auto eql = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, prop1, prop2, gcBuffer, stack, scope, true);
            RETURN_IF_EXCEPTION(scope, false);
            if (!eql) return false;
        }

        RETURN_IF_EXCEPTION(scope, false);

        return true;
    }

    if constexpr (isStrict) {
        if (!equal(JSObject::calculatedClassName(o1), JSObject::calculatedClassName(o2))) {
            return false;
        }
    }

    JSC::Structure* o1Structure = o1->structure();
    if (!o1Structure->hasNonReifiedStaticProperties() && o1Structure->canPerformFastPropertyEnumeration()) {
        JSC::Structure* o2Structure = o2->structure();
        if (!o2Structure->hasNonReifiedStaticProperties() && o2Structure->canPerformFastPropertyEnumeration()) {

            bool result = true;
            bool sameStructure = o2Structure->id() == o1Structure->id();
            if (sameStructure) {
                o1Structure->forEachProperty(vm, [&](const PropertyTableEntry& entry) -> bool {
                    if (entry.attributes() & PropertyAttribute::DontEnum || PropertyName(entry.key()).isPrivateName()) {
                        return true;
                    }

                    JSValue left = o1->getDirect(entry.offset());
                    JSValue right = o2->getDirect(entry.offset());

                    if constexpr (!isStrict) {
                        if (left.isUndefined() && right.isEmpty()) {
                            return true;
                        }
                    }

                    if (!right) {
                        result = false;
                        return false;
                    }

                    if (left == right) return true;
                    auto same = JSC::sameValue(globalObject, left, right);
                    RETURN_IF_EXCEPTION(scope, false);
                    if (same) return true;

                    auto eql = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, left, right, gcBuffer, stack, scope, true);
                    RETURN_IF_EXCEPTION(scope, false);
                    if (!eql) {
                        result = false;
                        return false;
                    }

                    return true;
                });
            } else {
                size_t count = 0;
                o1Structure->forEachProperty(vm, [&](const PropertyTableEntry& entry) -> bool {
                    if (entry.attributes() & PropertyAttribute::DontEnum || PropertyName(entry.key()).isPrivateName()) {
                        return true;
                    }
                    count++;

                    JSValue left = o1->getDirect(entry.offset());
                    JSValue right = o2->getDirect(vm, JSC::PropertyName(entry.key()));

                    if constexpr (!isStrict) {
                        if (left.isUndefined() && right.isEmpty()) {
                            return true;
                        }
                    }

                    if (!right) {
                        result = false;
                        return false;
                    }

                    if (left == right) return true;
                    auto same = JSC::sameValue(globalObject, left, right);
                    RETURN_IF_EXCEPTION(scope, false);
                    if (same) return true;

                    auto eql = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, left, right, gcBuffer, stack, scope, true);
                    RETURN_IF_EXCEPTION(scope, false);
                    if (!eql) {
                        result = false;
                        return false;
                    }

                    return true;
                });

                if (result) {
                    size_t remain = count;
                    o2Structure->forEachProperty(vm, [&](const PropertyTableEntry& entry) -> bool {
                        if (entry.attributes() & PropertyAttribute::DontEnum || PropertyName(entry.key()).isPrivateName()) {
                            return true;
                        }

                        if constexpr (!isStrict) {
                            if (o2->getDirect(entry.offset()).isUndefined()) {
                                return true;
                            }
                        }

                        // Try to get the right value from the left. We don't need to check if they're equal
                        // because the above loop has already iterated each property in the left. If we've
                        // seen this property before, it was already `deepEquals`ed. If it doesn't exist,
                        // the objects are not equal.
                        if (o1->getDirectOffset(vm, JSC::PropertyName(entry.key())) == invalidOffset) {
                            result = false;
                            return false;
                        }

                        if (remain == 0) {
                            result = false;
                            return false;
                        }

                        remain--;
                        return true;
                    });
                }
            }

            return result;
        }
    }

    JSC::PropertyNameArrayBuilder a1(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Exclude);
    JSC::PropertyNameArrayBuilder a2(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Exclude);
    o1->getPropertyNames(globalObject, a1, DontEnumPropertiesMode::Exclude);
    RETURN_IF_EXCEPTION(scope, false);
    o2->getPropertyNames(globalObject, a2, DontEnumPropertiesMode::Exclude);
    RETURN_IF_EXCEPTION(scope, false);

    const size_t propertyArrayLength1 = a1.size();
    const size_t propertyArrayLength2 = a2.size();
    if constexpr (isStrict) {
        if (propertyArrayLength1 != propertyArrayLength2) {
            return false;
        }
    }

    // take a property name from one, try to get it from both
    size_t i;
    for (i = 0; i < propertyArrayLength1; i++) {
        Identifier i1 = a1[i];
        PropertyName propertyName1 = PropertyName(i1);

        JSValue prop1 = o1->get(globalObject, propertyName1);
        RETURN_IF_EXCEPTION(scope, false);

        if (!prop1) [[unlikely]] {
            return false;
        }

        JSValue prop2 = o2->getIfPropertyExists(globalObject, propertyName1);
        RETURN_IF_EXCEPTION(scope, false);

        if constexpr (!isStrict) {
            if (prop1.isUndefined() && prop2.isEmpty()) {
                continue;
            }
        }

        if (!prop2) {
            return false;
        }

        auto eql = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, prop1, prop2, gcBuffer, stack, scope, true);
        RETURN_IF_EXCEPTION(scope, false);
        if (!eql) return false;
    }

    // for the remaining properties in the other object, make sure they are undefined
    for (; i < propertyArrayLength2; i++) {
        Identifier i2 = a2[i];
        PropertyName propertyName2 = PropertyName(i2);

        JSValue prop2 = o2->getIfPropertyExists(globalObject, propertyName2);
        RETURN_IF_EXCEPTION(scope, false);

        if (!prop2.isUndefined()) {
            return false;
        }
    }

    return true;
}

template<bool isStrict, bool enableAsymmetricMatchers>
std::optional<bool> specialObjectsDequal(JSC::JSGlobalObject* globalObject, MarkedArgumentBuffer& gcBuffer, Vector<std::pair<JSC::JSValue, JSC::JSValue>, 16>& stack, ThrowScope& scope, JSCell* _Nonnull c1, JSCell* _Nonnull c2)
{
    VM& vm = globalObject->vm();
    uint8_t c1Type = c1->type();
    uint8_t c2Type = c2->type();

    auto* headers1 = dynamicDowncast<JSFetchHeaders>(c1);
    auto* headers2 = dynamicDowncast<JSFetchHeaders>(c2);
    if (headers1 && headers2) {
        auto wrapped1 = protectedFetchHeaders(globalObject, headers1);
        RETURN_IF_EXCEPTION(scope, false);
        auto wrapped2 = protectedFetchHeaders(globalObject, headers2);
        RETURN_IF_EXCEPTION(scope, false);
        RELEASE_ASSERT(wrapped1 && wrapped2);
        if (wrapped1->size() != wrapped2->size())
            return false;
        auto iter1 = wrapped1->createIterator();
        auto iter2 = wrapped2->createIterator();
        for (;;) {
            auto next1 = iter1.next();
            if (next1.hasException()) {
                WebCore::propagateException(globalObject, scope, next1.releaseException());
                return false;
            }
            auto next2 = iter2.next();
            if (next2.hasException()) {
                WebCore::propagateException(globalObject, scope, next2.releaseException());
                return false;
            }
            auto pair1 = next1.releaseReturnValue();
            auto pair2 = next2.releaseReturnValue();
            if (pair1.has_value() != pair2.has_value())
                return false;
            if (!pair1)
                break;
            if (pair1->key != pair2->key || pair1->value != pair2->value)
                return false;
        }
    } else if constexpr (isStrict) {
        if ((headers1 == nullptr) != (headers2 == nullptr))
            return false;
    }

    auto* params1 = dynamicDowncast<JSURLSearchParams>(c1);
    auto* params2 = dynamicDowncast<JSURLSearchParams>(c2);
    if (params1 && params2) {
        auto resource1 = protectedURLSearchParams(globalObject, params1);
        RETURN_IF_EXCEPTION(scope, false);
        auto resource2 = protectedURLSearchParams(globalObject, params2);
        RETURN_IF_EXCEPTION(scope, false);
        RELEASE_ASSERT(resource1 && resource2);
        const auto& pairs1 = resource1->pairs();
        const auto& pairs2 = resource2->pairs();
        if (pairs1.size() != pairs2.size())
            return false;
        for (size_t index = 0; index < pairs1.size(); ++index) {
            if (pairs1[index].key != pairs2[index].key || pairs1[index].value != pairs2[index].value)
                return false;
        }
        goto compareAsNormalValue;
    } else if constexpr (isStrict) {
        if ((params1 == nullptr) != (params2 == nullptr))
            return false;
    }

    {
        auto* url1 = dynamicDowncast<JSDOMURL>(c1);
        auto* url2 = dynamicDowncast<JSDOMURL>(c2);
        if (url1 && url2) {
            auto resource1 = protectedDOMURL(globalObject, url1);
            RETURN_IF_EXCEPTION(scope, false);
            auto resource2 = protectedDOMURL(globalObject, url2);
            RETURN_IF_EXCEPTION(scope, false);
            RELEASE_ASSERT(resource1 && resource2);
            auto snapshot1 = resource1->href();
            if (snapshot1.hasException()) {
                WebCore::propagateException(*globalObject, scope, snapshot1.releaseException());
                return false;
            }
            auto snapshot2 = resource2->href();
            if (snapshot2.hasException()) {
                WebCore::propagateException(*globalObject, scope, snapshot2.releaseException());
                return false;
            }
            if (snapshot1.releaseReturnValue() != snapshot2.releaseReturnValue())
                return false;
            goto compareAsNormalValue;
        } else if constexpr (isStrict) {
            if ((url1 == nullptr) != (url2 == nullptr))
                return false;
        }
    }

    switch (c1Type) {
    case JSSetType: {
        if (c2Type != JSSetType) {
            return false;
        }

        JSSet* set1 = uncheckedDowncast<JSSet>(c1);
        JSSet* set2 = uncheckedDowncast<JSSet>(c2);

        if (set1->size() != set2->size()) {
            return false;
        }

        auto iter1 = JSSetIterator::create(vm, globalObject->setIteratorStructure(), set1, IterationKind::Keys);
        RETURN_IF_EXCEPTION(scope, {});
        JSValue key1;
        while (iter1->next(globalObject, key1)) {
            bool has = set2->has(globalObject, key1);
            RETURN_IF_EXCEPTION(scope, {});
            if (has) {
                continue;
            }

            // We couldn't find the key in the second set. This may be a false positive due to how
            // JSValues are represented in JSC, so we need to fall back to a linear search to be sure.
            auto iter2 = JSSetIterator::create(vm, globalObject->setIteratorStructure(), set2, IterationKind::Keys);
            RETURN_IF_EXCEPTION(scope, {});
            JSValue key2;
            bool foundMatchingKey = false;
            while (iter2->next(globalObject, key2)) {
                bool equal = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, key1, key2, gcBuffer, stack, scope, false);
                RETURN_IF_EXCEPTION(scope, {});
                if (equal) {
                    foundMatchingKey = true;
                    break;
                }
            }

            if (!foundMatchingKey) {
                return false;
            }
        }

        return true;
    }
    case JSMapType: {
        if (c2Type != JSMapType) {
            return false;
        }

        JSMap* map1 = uncheckedDowncast<JSMap>(c1);
        JSMap* map2 = uncheckedDowncast<JSMap>(c2);
        size_t leftSize = map1->size();

        if (leftSize != map2->size()) {
            return false;
        }

        auto iter1 = JSMapIterator::create(vm, globalObject->mapIteratorStructure(), map1, IterationKind::Entries);
        RETURN_IF_EXCEPTION(scope, {});
        JSValue key1, value1;
        while (iter1->nextKeyValue(globalObject, key1, value1)) {
            JSValue value2 = map2->get(globalObject, key1);
            RETURN_IF_EXCEPTION(scope, {});
            if (value2.isUndefined()) {
                // We couldn't find the key in the second map. This may be a false positive due to
                // how JSValues are represented in JSC, so we need to fall back to a linear search
                // to be sure.
                auto iter2 = JSMapIterator::create(vm, globalObject->mapIteratorStructure(), map2, IterationKind::Entries);
                RETURN_IF_EXCEPTION(scope, {});
                JSValue key2;
                bool foundMatchingKey = false;
                while (iter2->nextKeyValue(globalObject, key2, value2)) {
                    bool keysEqual = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, key1, key2, gcBuffer, stack, scope, false);
                    RETURN_IF_EXCEPTION(scope, {});
                    if (keysEqual) {
                        foundMatchingKey = true;
                        break;
                    }
                }

                if (!foundMatchingKey) {
                    return false;
                }

                // Compare both values below.
            }

            bool valuesEqual = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, value1, value2, gcBuffer, stack, scope, false);
            RETURN_IF_EXCEPTION(scope, {});
            if (!valuesEqual) {
                return false;
            }
        }

        return true;
    }
    case ArrayBufferType: {
        if (c2Type != ArrayBufferType) {
            return false;
        }

        JSC::ArrayBuffer* left = uncheckedDowncast<JSArrayBuffer>(c1)->impl();
        JSC::ArrayBuffer* right = uncheckedDowncast<JSArrayBuffer>(c2)->impl();
        size_t byteLength = left->byteLength();

        if (right->byteLength() != byteLength) {
            return false;
        }

        if (left->isShared() != right->isShared()) [[unlikely]] {
            return false;
        }

        if (byteLength == 0)
            return true;

        if (right->isDetached() || left->isDetached()) [[unlikely]] {
            return false;
        }

        const void* vector = left->data();
        const void* rightVector = right->data();
        if (!vector || !rightVector) [[unlikely]] {
            return false;
        }

        if (vector == rightVector) [[unlikely]]
            return true;

        return (memcmp(vector, rightVector, byteLength) == 0);
    }
    case JSDateType: {
        if (c2Type != JSDateType) {
            return false;
        }

        JSC::DateInstance* left = uncheckedDowncast<DateInstance>(c1);
        JSC::DateInstance* right = uncheckedDowncast<DateInstance>(c2);

        return left->internalNumber() == right->internalNumber();
    }
    case RegExpObjectType: {
        if (c2Type != RegExpObjectType) {
            return false;
        }

        if (JSC::RegExpObject* left = dynamicDowncast<JSC::RegExpObject>(c1)) {
            JSC::RegExpObject* right = dynamicDowncast<JSC::RegExpObject>(c2);

            if (!right) [[unlikely]] {
                return false;
            }

            return left->regExp()->key() == right->regExp()->key();
        }

        return false;
    }
    case ErrorInstanceType: {
        if (c2Type != ErrorInstanceType) {
            return false;
        }

        // NOTE(@DonIsaac): could `left` ever _not_ be a JSC::ErrorInstance?
        if (JSC::ErrorInstance* left = dynamicDowncast<JSC::ErrorInstance>(c1)) {
            JSC::ErrorInstance* right = dynamicDowncast<JSC::ErrorInstance>(c2);

            if (!right) [[unlikely]] {
                return false;
            }

            if (left->errorType() != right->errorType()) {
                // quick check on ctors (does not handle subclasses)
                return false;
            }

            auto leftName = left->sanitizedNameString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            auto rightName = right->sanitizedNameString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            if (leftName != rightName) {
                // manual `.name` changes (usually in subclasses)
                return false;
            }

            auto leftMessage = left->sanitizedMessageString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            auto rightMessage = right->sanitizedMessageString(globalObject);
            RETURN_IF_EXCEPTION(scope, {});
            if (leftMessage != rightMessage) {
                // `.message`
                return false;
            }

            if constexpr (isStrict) {
                if (left->runtimeTypeForCause() != right->runtimeTypeForCause()) {
                    return false;
                }
            }

            VM& vm = JSC::getVM(globalObject);

            // `.cause` is non-enumerable, so it must be checked explicitly.
            // note that an undefined cause is different than a missing cause in
            // strict mode.
            const PropertyName cause(vm.propertyNames->cause);
            if constexpr (isStrict) {
                bool leftHasCause = left->hasProperty(globalObject, cause);
                RETURN_IF_EXCEPTION(scope, {});
                bool rightHasCause = right->hasProperty(globalObject, cause);
                RETURN_IF_EXCEPTION(scope, {});
                if (leftHasCause != rightHasCause) {
                    return false;
                }
            }
            auto leftCause = left->get(globalObject, cause);
            RETURN_IF_EXCEPTION(scope, {});
            auto rightCause = right->get(globalObject, cause);
            RETURN_IF_EXCEPTION(scope, {});
            bool causesEqual = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, leftCause, rightCause, gcBuffer, stack, scope, true);
            RETURN_IF_EXCEPTION(scope, {});
            if (!causesEqual) {
                return false;
            }

            // check arbitrary enumerable properties. `.stack` is not checked.
            left->materializeErrorInfoIfNeeded(vm);
            RETURN_IF_EXCEPTION(scope, {});
            right->materializeErrorInfoIfNeeded(vm);
            RETURN_IF_EXCEPTION(scope, {});
            JSC::PropertyNameArrayBuilder a1(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Exclude);
            JSC::PropertyNameArrayBuilder a2(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Exclude);
            left->getPropertyNames(globalObject, a1, DontEnumPropertiesMode::Exclude);
            RETURN_IF_EXCEPTION(scope, {});
            right->getPropertyNames(globalObject, a2, DontEnumPropertiesMode::Exclude);
            RETURN_IF_EXCEPTION(scope, {});

            const size_t propertyArrayLength1 = a1.size();
            const size_t propertyArrayLength2 = a2.size();
            if constexpr (isStrict) {
                if (propertyArrayLength1 != propertyArrayLength2) {
                    return false;
                }
            }

            // take a property name from one, try to get it from both
            size_t i;
            for (i = 0; i < propertyArrayLength1; i++) {
                Identifier i1 = a1[i];
                if (i1 == vm.propertyNames->stack) continue;
                PropertyName propertyName1 = PropertyName(i1);

                JSValue prop1 = left->get(globalObject, propertyName1);
                RETURN_IF_EXCEPTION(scope, {});
                ASSERT(prop1);

                JSValue prop2 = right->getIfPropertyExists(globalObject, propertyName1);
                RETURN_IF_EXCEPTION(scope, {});

                if constexpr (!isStrict) {
                    if (prop1.isUndefined() && prop2.isEmpty()) {
                        continue;
                    }
                }

                if (!prop2) {
                    return false;
                }

                bool propertiesEqual = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(globalObject, prop1, prop2, gcBuffer, stack, scope, true);
                RETURN_IF_EXCEPTION(scope, {});
                if (!propertiesEqual) {
                    return false;
                }
            }

            // for the remaining properties in the other object, make sure they are undefined
            for (; i < propertyArrayLength2; i++) {
                Identifier i2 = a2[i];
                if (i2 == vm.propertyNames->stack) continue;
                PropertyName propertyName2 = PropertyName(i2);

                JSValue prop2 = right->getIfPropertyExists(globalObject, propertyName2);
                RETURN_IF_EXCEPTION(scope, {});

                if (!prop2.isUndefined()) {
                    return false;
                }
            }

            return true;
        }
        break;
    }
    case Int8ArrayType:
    case Uint8ArrayType:
    case Uint8ClampedArrayType:
    case Int16ArrayType:
    case Uint16ArrayType:
    case Int32ArrayType:
    case Uint32ArrayType:
    case Float16ArrayType:
    case Float32ArrayType:
    case Float64ArrayType:
    case BigInt64ArrayType:
    case BigUint64ArrayType: {
        if (!isTypedArrayType(static_cast<JSC::JSType>(c2Type)) || c1Type != c2Type) {
            return false;
        }
        auto info = c1->classInfo();
        auto info2 = c2->classInfo();
        if (!info || !info2) {
            return false;
        }

        JSC::JSArrayBufferView* left = uncheckedDowncast<JSArrayBufferView>(c1);
        JSC::JSArrayBufferView* right = uncheckedDowncast<JSArrayBufferView>(c2);
        size_t byteLength = left->byteLength();

        if (right->byteLength() != byteLength) {
            return false;
        }

        if (byteLength == 0)
            return true;

        if (right->isDetached() || left->isDetached()) [[unlikely]] {
            return false;
        }

        const void* vector = left->vector();
        const void* rightVector = right->vector();
        if (!vector || !rightVector) [[unlikely]] {
            return false;
        }

        if (vector == rightVector) [[unlikely]]
            return true;

        // For Float32Array and Float64Array, when not in strict mode, we need to
        // handle +0 and -0 as equal, and NaN as not equal to itself.
        if (!isStrict && (c1Type == Float16ArrayType || c1Type == Float32ArrayType || c1Type == Float64ArrayType)) {
            if (c1Type == Float16ArrayType) {
                auto* leftFloat = static_cast<const WTF::Float16*>(vector);
                auto* rightFloat = static_cast<const WTF::Float16*>(rightVector);
                size_t numElements = byteLength / sizeof(WTF::Float16);

                for (size_t i = 0; i < numElements; i++) {
                    if (leftFloat[i] != rightFloat[i]) {
                        return false;
                    }
                }
                return true;
            } else if (c1Type == Float32ArrayType) {
                auto* leftFloat = static_cast<const float*>(vector);
                auto* rightFloat = static_cast<const float*>(rightVector);
                size_t numElements = byteLength / sizeof(float);

                for (size_t i = 0; i < numElements; i++) {
                    if (leftFloat[i] != rightFloat[i]) {
                        return false;
                    }
                }
                return true;
            } else { // Float64Array
                auto* leftDouble = static_cast<const double*>(vector);
                auto* rightDouble = static_cast<const double*>(rightVector);
                size_t numElements = byteLength / sizeof(double);

                for (size_t i = 0; i < numElements; i++) {
                    if (leftDouble[i] != rightDouble[i]) {
                        return false;
                    }
                }
                return true;
            }
        }

        return (memcmp(vector, rightVector, byteLength) == 0);
    }
    case StringObjectType: {
        if (c2Type != StringObjectType) {
            return false;
        }

        if (!equal(JSObject::calculatedClassName(c1->getObject()), JSObject::calculatedClassName(c2->getObject()))) {
            return false;
        }

        JSString* s1 = c1->toStringInline(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        JSString* s2 = c2->toStringInline(globalObject);
        RETURN_IF_EXCEPTION(scope, {});

        bool stringsEqual = s1->equal(globalObject, s2);
        RETURN_IF_EXCEPTION(scope, {});
        return stringsEqual;
    }
    case JSFunctionType: {
        return false;
    }

    case JSAsJSONType:
    case JSDOMWrapperType: {
        goto compareAsNormalValue;

    compareAsNormalValue:
        break;
    }
    // globalThis is only equal to globalThis
    // NOTE: globalThis from JS is a JSGlobalProxy (GlobalProxyType) wrapping Zig::GlobalObject (GlobalObjectType)
    case GlobalObjectType: {
        if (c1Type != c2Type) return false;
        auto* g1 = dynamicDowncast<JSC::JSGlobalObject>(c1);
        auto* g2 = dynamicDowncast<JSC::JSGlobalObject>(c2);
        return g1->m_globalThis == g2->m_globalThis;
    }
    case GlobalProxyType: {
        if (c1Type != c2Type) return false;
        auto* gp1 = dynamicDowncast<JSC::JSGlobalProxy>(c1);
        auto* gp2 = dynamicDowncast<JSC::JSGlobalProxy>(c2);
        return gp1->target()->m_globalThis == gp2->target()->m_globalThis;
    }
    case NumberObjectType:
    case BooleanObjectType: {
        // Number and Boolean wrapper objects must be the same type and have the same internal value
        if (c1Type != c2Type) return false;
        JSValue val1 = uncheckedDowncast<JSWrapperObject>(c1)->internalValue();
        JSValue val2 = uncheckedDowncast<JSWrapperObject>(c2)->internalValue();
        bool same = JSC::sameValue(globalObject, val1, val2);
        RETURN_IF_EXCEPTION(scope, {});
        if (!same) return false;
        // Fall through to check own properties
        break;
    }
    default:
        break;
    }
    return std::nullopt;
}

/**
 * @brief `Bun.deepMatch(a, b)`
 *
 * @note
 * The sets recording already visited properties (`seenObjProperties`,
 * `seenSubsetProperties`, and `gcBuffer`) aren not needed when both
 * `enableAsymmetricMatchers` and `isMatchingObjectContaining` are true. In
 * this case, it is safe to pass a `nullptr`.
 *
 * `gcBuffer` ensures JSC's stack scan does not come up empty-handed and free
 * properties currently within those stacks. Likely unnecessary, but better to
 * be safe tnan sorry
 *
 * @tparam enableAsymmetricMatchers
 * @param objValue
 * @param seenObjProperties already visited properties of `objValue`.
 * @param subsetValue
 * @param seenSubsetProperties already visited properties of `subsetValue`.
 * @param globalObject
 * @param throwScope
 * @param gcBuffer
 * @param replacePropsWithAsymmetricMatchers
 * @param isMatchingObjectContaining
 *
 * @return true
 * @return false
 */
template<bool enableAsymmetricMatchers>
bool Bun__deepMatch(
    JSValue objValue,
    std::set<EncodedJSValue>* seenObjProperties,
    JSValue subsetValue,
    std::set<EncodedJSValue>* seenSubsetProperties,
    JSGlobalObject* globalObject,
    ThrowScope& throwScope,
    MarkedArgumentBuffer* gcBuffer,
    bool replacePropsWithAsymmetricMatchers,
    bool isMatchingObjectContaining)
{

    // Caller must ensure only objects are passed to this function.
    ASSERT(objValue.isCell());
    ASSERT(subsetValue.isCell());
    // fast path for reference equality.
    if (objValue == subsetValue) return true;
    VM& vm = globalObject->vm();
    JSObject* obj = objValue.getObject();
    JSObject* subsetObj = subsetValue.getObject();

    PropertyNameArrayBuilder subsetProps(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Include);
    subsetObj->getPropertyNames(globalObject, subsetProps, DontEnumPropertiesMode::Exclude);
    RETURN_IF_EXCEPTION(throwScope, false);

    // TODO: add fast paths for:
    // - two "simple" objects (using ->forEachProperty in both)
    // - two "simple" arrays
    // similar to what is done in deepEquals (canPerformFastPropertyEnumerationForIterationBun)

    // arrays should match exactly
    if (isArray(globalObject, objValue) && isArray(globalObject, subsetValue)) {
        if (obj->getArrayLength() != subsetObj->getArrayLength()) {
            return false;
        }
        PropertyNameArrayBuilder objProps(vm, PropertyNameMode::StringsAndSymbols, PrivateSymbolMode::Include);
        obj->getPropertyNames(globalObject, objProps, DontEnumPropertiesMode::Exclude);
        RETURN_IF_EXCEPTION(throwScope, false);
        if (objProps.size() != subsetProps.size()) {
            return false;
        }
    }

    for (const auto& property : subsetProps) {
        JSValue prop = obj->getIfPropertyExists(globalObject, property);
        RETURN_IF_EXCEPTION(throwScope, false);
        if (prop.isEmpty()) {
            return false;
        }

        JSValue subsetProp = subsetObj->get(globalObject, property);
        RETURN_IF_EXCEPTION(throwScope, false);

        JSCell* subsetPropCell = !subsetProp.isEmpty() && subsetProp.isCell() ? subsetProp.asCell() : nullptr;
        JSCell* propCell = prop.isCell() ? prop.asCell() : nullptr;

        if constexpr (enableAsymmetricMatchers) {
            if (subsetPropCell && subsetPropCell->isObject()) {
                switch (matchAsymmetricMatcher(globalObject, subsetProp, prop, throwScope)) {
                case AsymmetricMatcherResult::FAIL:
                    return false;
                case AsymmetricMatcherResult::PASS:
                    if (replacePropsWithAsymmetricMatchers) {
                        obj->putDirectMayBeIndex(globalObject, property, subsetProp);
                        RETURN_IF_EXCEPTION(throwScope, false);
                    }
                    // continue to next subset prop
                    continue;
                case AsymmetricMatcherResult::NOT_MATCHER:
                    break;
                }
            }
            if (propCell && propCell->isObject()) {
                switch (matchAsymmetricMatcher(globalObject, prop, subsetProp, throwScope)) {
                case AsymmetricMatcherResult::FAIL:
                    return false;
                case AsymmetricMatcherResult::PASS:
                    if (replacePropsWithAsymmetricMatchers) {
                        subsetObj->putDirectMayBeIndex(globalObject, property, prop);
                        RETURN_IF_EXCEPTION(throwScope, false);
                    }
                    // continue to next subset prop
                    continue;
                case AsymmetricMatcherResult::NOT_MATCHER:
                    break;
                }
            }
        }

        if (subsetProp.isObject() and prop.isObject()) {
            // if this is called from inside an objectContaining asymmetric matcher, it should behave slightly differently:
            // in such case, it expects exhaustive matching of any nested object properties, not just a subset,
            // and the user would need to opt-in to subset matching by using another nested objectContaining matcher
            if (enableAsymmetricMatchers && isMatchingObjectContaining) {
                Vector<std::pair<JSValue, JSValue>, 16> stack;
                MarkedArgumentBuffer gcBuffer;
                auto eql = Bun__deepEquals<false, true>(globalObject, prop, subsetProp, gcBuffer, stack, throwScope, true);
                RETURN_IF_EXCEPTION(throwScope, false);
                if (!eql) return false;
            } else {
                ASSERT(seenObjProperties != nullptr);
                ASSERT(seenSubsetProperties != nullptr);
                ASSERT(gcBuffer != nullptr);
                auto didInsertProp = seenObjProperties->insert(JSC::JSValue::encode(prop));
                auto didInsertSubset = seenSubsetProperties->insert(JSC::JSValue::encode(subsetProp));
                gcBuffer->append(prop);
                gcBuffer->append(subsetProp);
                // property cycle detected
                if (!didInsertProp.second || !didInsertSubset.second) continue;
                if (!Bun__deepMatch<enableAsymmetricMatchers>(prop, seenObjProperties, subsetProp, seenSubsetProperties, globalObject, throwScope, gcBuffer, replacePropsWithAsymmetricMatchers, isMatchingObjectContaining)) {
                    return false;
                }
            }
        } else {
            auto same = JSC::sameValue(globalObject, prop, subsetProp);
            RETURN_IF_EXCEPTION(throwScope, false);
            if (!same) return false;
        }
    }

    return true;
}

template bool Bun__deepMatch<true>(
    JSValue objValue,
    std::set<EncodedJSValue>* seenObjProperties,
    JSValue subsetValue,
    std::set<EncodedJSValue>* seenSubsetProperties,
    JSGlobalObject* globalObject,
    ThrowScope& throwScope,
    MarkedArgumentBuffer* gcBuffer,
    bool replacePropsWithAsymmetricMatchers,
    bool isMatchingObjectContaining);

template bool Bun__deepMatch<false>(
    JSValue objValue,
    std::set<EncodedJSValue>* seenObjProperties,
    JSValue subsetValue,
    std::set<EncodedJSValue>* seenSubsetProperties,
    JSGlobalObject* globalObject,
    ThrowScope& throwScope,
    MarkedArgumentBuffer* gcBuffer,
    bool replacePropsWithAsymmetricMatchers,
    bool isMatchingObjectContaining);

namespace Bun::Bindgen::Cpp {

bool bunBindgenCpp_BunObject_deepMatch(
    CppCallContext& context,
    const BunBindgenCpp_BunObject_deepMatch_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    std::set<EncodedJSValue> objVisited;
    std::set<EncodedJSValue> subsetVisited;
    MarkedArgumentBuffer gcBuffer;
    bool match = Bun__deepMatch<false>(args.object, &objVisited, args.subset, &subsetVisited, globalObject, scope, &gcBuffer, false, false);
    RETURN_IF_EXCEPTION(scope, false);
    return match;
}

}

// anonymous namespace to avoid name collision
namespace {
template<bool isStrict, bool enableAsymmetricMatchers>
inline bool deepEqualsWrapperImpl(JSC::EncodedJSValue a, JSC::EncodedJSValue b, JSC::JSGlobalObject* global)
{
    auto& vm = global->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    Vector<std::pair<JSC::JSValue, JSC::JSValue>, 16> stack;
    MarkedArgumentBuffer args;
    bool result = Bun__deepEquals<isStrict, enableAsymmetricMatchers>(global, JSC::JSValue::decode(a), JSC::JSValue::decode(b), args, stack, scope, true);
    RELEASE_AND_RETURN(scope, result);
}
}

bool Bun::Bindgen::Engine::bunBindgenEngine_js_value_inspection_jsValueDeepEquals(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_js_value_inspection_jsValueDeepEquals_Arguments& args)
{
    return deepEqualsWrapperImpl<false, false>(JSValue::encode(args.input.left), JSValue::encode(args.input.right), &context.globalObject);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_js_value_inspection_jsValueJestDeepEquals(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_js_value_inspection_jsValueJestDeepEquals_Arguments& args)
{
    return deepEqualsWrapperImpl<false, true>(JSValue::encode(args.input.left), JSValue::encode(args.input.right), &context.globalObject);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_js_value_inspection_jsValueStrictDeepEquals(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_js_value_inspection_jsValueStrictDeepEquals_Arguments& args)
{
    return deepEqualsWrapperImpl<true, false>(JSValue::encode(args.input.left), JSValue::encode(args.input.right), &context.globalObject);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_js_value_inspection_jsValueJestStrictDeepEquals(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_js_value_inspection_jsValueJestStrictDeepEquals_Arguments& args)
{
    return deepEqualsWrapperImpl<true, true>(JSValue::encode(args.input.left), JSValue::encode(args.input.right), &context.globalObject);
}

bool Bun::Bindgen::Engine::bunBindgenEngine_js_value_inspection_jsValueJestDeepMatch(
    Bun::Bindgen::EngineCallContext& context,
    const Bun::Bindgen::Engine::BunBindgenEngine_js_value_inspection_jsValueJestDeepMatch_Arguments& args)
{
    auto* globalObject = &context.globalObject;

    ThrowScope scope = DECLARE_THROW_SCOPE(globalObject->vm());

    std::set<EncodedJSValue> objVisited;
    std::set<EncodedJSValue> subsetVisited;
    MarkedArgumentBuffer gcBuffer;
    RELEASE_AND_RETURN(scope, Bun__deepMatch<true>(args.input.value, &objVisited, args.input.subset, &subsetVisited, globalObject, scope, &gcBuffer, args.input.replaceProperties, false));
}
