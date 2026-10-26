#pragma once

#include "BindingRuntimeDeclarations.h"
#include <JavaScriptCore/HeapInlines.h>
#include <JavaScriptCore/HeapIterationScope.h>
#include <JavaScriptCore/JSObjectInlines.h>
#include <JavaScriptCore/MarkedSpaceInlines.h>
#include <wtf/HashMap.h>

namespace Bun::Bindgen {

const JSC::ClassInfo PlainClassPrototype::s_info = { "Object"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(PlainClassPrototype) };
CLASSINFO_KEEP_ADDRESS_UNIQUE(PlainClassPrototype)

using PrototypeTypeNames = WTF::UncheckedKeyHashMap<JSC::JSObject*, WTF::ASCIILiteral>;

static WTF::ASCIILiteral heapTypeName(JSC::JSCell* cell, PrototypeTypeNames& names)
{
    const auto* info = cell->classInfo();
    auto name = info && info->className ? info->className : "[unknown]"_s;
    if (info != JSC::JSFinalObject::info())
        return name;

    auto prototype = static_cast<JSC::JSFinalObject*>(cell)->getPrototypeDirect();
    WTF::Vector<JSC::JSObject*, 8> path;
    while (prototype.isObject()) {
        auto* object = JSC::asObject(prototype);
        const auto* prototypeInfo = object->classInfo();
        if (prototypeInfo->isSubClassOf(PlainClassPrototype::info())) {
            name = prototypeInfo->className;
            break;
        }
        auto known = names.find(object);
        if (known != names.end()) {
            name = known->value;
            break;
        }
        path.append(object);
        // Diagnostic traversal never invokes a prototype trap or property getter.
        if (object->structure()->typeInfo().overridesGetPrototype())
            break;
        prototype = object->getPrototypeDirect();
    }
    for (auto* object : path)
        names.set(object, name);
    return name;
}

JSC::TypeCountSet heapObjectTypeCounts(JSC::VM& vm, bool protectedOnly)
{
    JSC::TypeCountSet counts;
    PrototypeTypeNames names;
    JSC::HeapIterationScope iteration(vm.heap);
    const auto record = [&](JSC::JSCell* cell) {
        counts.add(heapTypeName(cell, names));
    };
    if (protectedOnly) {
        vm.heap.forEachProtectedCell(record);
    } else {
        vm.heap.objectSpace().forEachLiveCell(iteration, [&](JSC::HeapCell* cell, JSC::HeapCell::Kind kind) {
            if (JSC::isJSCellKind(kind))
                record(static_cast<JSC::JSCell*>(cell));
            return WTF::IterationStatus::Continue;
        });
    }
    return counts;
}

}
