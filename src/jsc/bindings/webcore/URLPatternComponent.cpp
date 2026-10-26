/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "URLPatternComponent.h"

#include "ExceptionOr.h"
#include "URLPatternCanonical.h"
#include "URLPatternParser.h"
#include "URLPatternResult.h"
#include <JavaScriptCore/RegExp.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/YarrFlags.h>
#include <wtf/text/MakeString.h>
#include <utility>

namespace WebCore {
using namespace JSC;
namespace URLPatternUtilities {

URLPatternComponent::URLPatternComponent(String&& patternString, JSC::Strong<JSC::RegExp>&& regex, Vector<String>&& groupNameList, bool hasRegexpGroupsFromPartsList) noexcept
    : m_patternString(WTF::move(patternString))
    , m_groupNameList(WTF::move(groupNameList))
    , m_hasRegexGroupsFromPartList(hasRegexpGroupsFromPartsList)
{
    m_regularExpression.swap(regex);
}

URLPatternComponent::URLPatternComponent(URLPatternComponent&& other) noexcept
    : URLPatternComponent(WTF::move(other.m_patternString), WTF::move(other.m_regularExpression),
          WTF::move(other.m_groupNameList), std::exchange(other.m_hasRegexGroupsFromPartList, false))
{
}

URLPatternComponent& URLPatternComponent::operator=(URLPatternComponent&& other) noexcept
{
    if (this == &other)
        return *this;
    m_patternString = WTF::move(other.m_patternString);
    m_regularExpression.clear();
    m_regularExpression.swap(other.m_regularExpression);
    m_groupNameList = WTF::move(other.m_groupNameList);
    m_hasRegexGroupsFromPartList = std::exchange(other.m_hasRegexGroupsFromPartList, false);
    return *this;
}

// https://urlpattern.spec.whatwg.org/#compile-a-component
ExceptionOr<URLPatternComponent> URLPatternComponent::compile(Ref<JSC::VM> vm, StringView input, EncodingCallbackType type, const URLPatternStringOptions& options)
{
    auto maybePartList = URLPatternParser::parse(input, options, type);
    if (maybePartList.hasException())
        return maybePartList.releaseException();
    Vector<Part> partList = maybePartList.releaseReturnValue();

    auto generated = generateRegexAndNameList(partList, options);
    if (generated.hasException())
        return generated.releaseException();
    auto [regularExpressionString, nameList] = generated.releaseReturnValue();
    auto patternString = generatePatternString(partList, options);
    if (patternString.hasException())
        return patternString.releaseException();

    OptionSet<JSC::Yarr::Flags> flags = { JSC::Yarr::Flags::UnicodeSets };
    if (options.ignoreCase)
        flags.add(JSC::Yarr::Flags::IgnoreCase);

    JSC::RegExp* regularExpression = JSC::RegExp::create(vm, regularExpressionString, flags);
    if (regularExpression->constructionFailedOutOfMemory())
        return Exception { OutOfMemoryError };
    if (!regularExpression->isValid())
        return Exception { ExceptionCode::TypeError, "Unable to create RegExp object regular expression from provided URLPattern string."_s };

    bool hasRegexGroups = partList.containsIf([](auto& part) {
        return part.type == PartType::Regexp;
    });

    return URLPatternComponent { patternString.releaseReturnValue(), JSC::Strong<JSC::RegExp> { vm, regularExpression }, WTF::move(nameList), hasRegexGroups };
}

ExceptionOr<bool> URLPatternComponent::test(JSC::JSGlobalObject* globalObject, StringView input) const
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* regExp = m_regularExpression.get();
    auto matched = regExp->match(globalObject, input, 0);
    RETURN_IF_EXCEPTION(scope, Exception { ExceptionCode::ExistingExceptionError });
    return static_cast<bool>(matched);
}

// https://urlpattern.spec.whatwg.org/#protocol-component-matches-a-special-scheme
ExceptionOr<bool> URLPatternComponent::matchSpecialSchemeProtocol(JSC::JSGlobalObject* globalObject) const
{
    static constexpr std::array specialSchemeList { "ftp"_s, "file"_s, "http"_s, "https"_s, "ws"_s, "wss"_s };

    for (auto scheme : specialSchemeList) {
        auto matched = test(globalObject, scheme);
        if (matched.hasException())
            return matched.releaseException();
        if (matched.releaseReturnValue())
            return true;
    }
    return false;
}

// Implements both "regexp matching" and "create a component match result":
// https://urlpattern.spec.whatwg.org/#create-a-component-match-result
ExceptionOr<std::optional<URLPatternComponentResult>> URLPatternComponent::componentMatch(JSC::JSGlobalObject* globalObject, String&& input) const
{
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto* regExp = m_regularExpression.get();
    auto ovector = regExp->ovectorSpan();
    int position = regExp->match(globalObject, input, 0, ovector);
    RETURN_IF_EXCEPTION(scope, Exception { ExceptionCode::ExistingExceptionError });
    if (position < 0)
        return { std::nullopt };

    unsigned numSubpatterns = regExp->numSubpatterns();

    URLPatternComponentResult::GroupsRecord groups;
    if (!groups.tryReserveInitialCapacity(numSubpatterns))
        return Exception { OutOfMemoryError };
    for (unsigned i = 1; i <= numSubpatterns; ++i) {
        int start = ovector[i * 2];
        int end = ovector[i * 2 + 1];

        Variant<std::monostate, String> value;
        if (start >= 0) {
            auto matched = tryMakeString(StringView(input).substring(start, end - start));
            if (matched.isNull())
                return Exception { OutOfMemoryError };
            value = WTF::move(matched);
        }

        size_t groupIndex = i - 1;
        String groupName = groupIndex < m_groupNameList.size() ? m_groupNameList[groupIndex] : emptyString();
        groups.unsafeAppendWithoutCapacityCheck(URLPatternComponentResult::NameMatchPair { WTF::move(groupName), WTF::move(value) });
    }

    return { URLPatternComponentResult { !input.isEmpty() ? WTF::move(input) : emptyString(), WTF::move(groups) } };
}

}
}
