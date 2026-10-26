#pragma once
#include "IDLTypes.h"
#include <concepts>
#include <wtf/RefPtr.h>

namespace Bun {

template<std::integral T>
struct IDLStrictInteger : WebCore::IDLInteger<T> {};
template<std::integral T>
struct IDLBigIntInteger : WebCore::IDLInteger<T> {};
struct IDLStrictDouble : WebCore::IDLUnrestrictedDouble {};
struct IDLIntegerOrInfinity : WebCore::IDLUnrestrictedDouble {};
struct IDLStrictBoolean : WebCore::IDLBoolean {};
struct IDLStrictString : WebCore::IDLDOMString {};
struct IDLStrictUSVString : WebCore::IDLUSVString {};
struct IDLStrictByteString : WebCore::IDLByteString {};

// Converts to a number first.
template<std::integral T>
struct IDLLooseInteger : IDLStrictInteger<T> {};

// ToInt32, then clamped to T's own range.
template<std::integral T>
struct IDLToInt32Saturated : IDLStrictInteger<T> {};

template<typename T, typename RefDerefTraits = WTF::DefaultRefDerefTraits<T>>
struct IDLBunInterface : WebCore::IDLType<WTF::RefPtr<T, WTF::RawPtrTraits<T>, RefDerefTraits>> {
};

}
