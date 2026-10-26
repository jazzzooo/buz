#include "config.h"
#include "JSDOMFormData.h"

#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include "blob.h"
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <algorithm>

namespace WebCore {

using namespace JSC;

RefPtr<DOMFormData> protectedFormData(JSGlobalObject* global, JSValue value)
{
    auto* form = Bun::Bindgen::ZigExports::bunBindgenZig_dom_form_data_formDataRetainFromWrapper(global, value);
    if (!form)
        return nullptr;
    return adoptRef(*form);
}

static JSMap* existingFileCache(JSDOMFormData& wrapper)
{
    auto value = wrapper.raw_slot_files();
    return value.isEmpty() ? nullptr : uncheckedDowncast<JSMap>(value);
}

static JSMap* createFileCache(JSGlobalObject& global)
{
    return JSMap::create(global.vm(), global.mapStructure());
}

static JSValue formDataEntryToJS(
    JSGlobalObject& global,
    JSDOMFormData& wrapper,
    size_t index,
    const DOMFormData::FormDataEntryValue& entry)
{
    if (auto* string = std::get_if<String>(&entry))
        return jsString(global.vm(), *string);

    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto* cache = existingFileCache(wrapper);
    const auto key = jsNumber(index);
    if (cache) {
        auto value = cache->get(&global, key);
        RETURN_IF_EXCEPTION(scope, {});
        if (!value.isUndefined())
            return value;
    }
    auto value = toJS(&global, defaultGlobalObject(&global), std::get<Ref<Blob>>(entry).get());
    RETURN_IF_EXCEPTION(scope, {});
    if (!cache) {
        cache = createFileCache(global);
        RETURN_IF_EXCEPTION(scope, {});
    }
    cache->set(&global, key, value);
    RETURN_IF_EXCEPTION(scope, {});
    wrapper.set_slot_files(global.vm(), cache);
    return value;
}

static JSMap* rebuildFileCache(
    JSGlobalObject& global,
    JSDOMFormData& wrapper,
    const DOMFormData& form,
    const String& name,
    std::optional<size_t> replacementIndex,
    JSValue replacement)
{
    auto scope = DECLARE_THROW_SCOPE(global.vm());
    auto* previous = existingFileCache(wrapper);
    if (!previous && replacement.isEmpty())
        return nullptr;
    auto* cache = createFileCache(global);
    RETURN_IF_EXCEPTION(scope, nullptr);
    const auto& items = form.items();
    size_t destination = 0;
    for (size_t index = 0; index < items.size(); ++index) {
        JSValue value;
        if (replacementIndex && index == *replacementIndex)
            value = replacement;
        else {
            if (items[index].name == name)
                continue;
            if (previous) {
                value = previous->get(&global, jsNumber(index));
                RETURN_IF_EXCEPTION(scope, nullptr);
            }
        }
        if (!value.isEmpty() && !value.isUndefined()) {
            cache->set(&global, jsNumber(destination), value);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        ++destination;
    }
    if (replacementIndex && *replacementIndex == items.size() && !replacement.isEmpty()) {
        cache->set(&global, jsNumber(destination), replacement);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return cache;
}

static void commitFileCache(JSGlobalObject& global, JSDOMFormData& wrapper, JSMap* cache)
{
    if (cache)
        wrapper.set_slot_files(global.vm(), cache);
    else
        wrapper.clear_slot_files();
}

struct FormDataGroups {
    struct Group {
        size_t offset;
        size_t count;
        size_t firstIndex;
    };
    Vector<size_t> order;
    Vector<Group> groups;
};

static ExceptionOr<FormDataGroups> groupFormDataItems(const DOMFormData& formData)
{
    const auto& items = formData.items();
    FormDataGroups result;
    if (!result.order.tryGrow(items.size()))
        return Exception { OutOfMemoryError };
    for (size_t index = 0; index < items.size(); ++index)
        result.order[index] = index;
    if (result.order.size() > 1) {
        std::sort(result.order.begin(), result.order.end(), [&](size_t left, size_t right) {
            const auto comparison = codePointCompare(items[left].name, items[right].name);
            return comparison == 0 ? left < right : comparison < 0;
        });
    }
    for (size_t offset = 0; offset < result.order.size();) {
        size_t end = offset + 1;
        const auto firstIndex = result.order[offset];
        while (end < result.order.size() && items[firstIndex].name == items[result.order[end]].name)
            ++end;
        if (!result.groups.tryAppend(FormDataGroups::Group { offset, end - offset, firstIndex }))
            return Exception { OutOfMemoryError };
        offset = end;
    }
    if (result.groups.size() > 1) {
        std::sort(result.groups.begin(), result.groups.end(), [](const auto& left, const auto& right) {
            return left.firstIndex < right.firstIndex;
        });
    }
    return result;
}

JSValue getInternalProperties(VM& vm, JSGlobalObject* global, JSDOMFormData* wrapper)
{
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto protectedForm = protectedFormData(global, wrapper);
    RETURN_IF_EXCEPTION(scope, {});
    RELEASE_ASSERT(protectedForm);
    auto& formData = *protectedForm;
    auto grouped = groupFormDataItems(formData);
    if (grouped.hasException()) {
        propagateException(*global, scope, grouped.releaseException());
        return {};
    }
    auto groups = grouped.releaseReturnValue();
    const size_t propertyCount = static_cast<size_t>(groups.groups.size()) + 1;
    auto* object = propertyCount <= JSFinalObject::maxInlineCapacity
        ? constructEmptyObject(global, global->objectPrototype(), propertyCount)
        : constructEmptyObject(global, global->objectPrototype());
    RETURN_IF_EXCEPTION(scope, {});

    object->putDirect(
        vm,
        vm.propertyNames->toStringTagSymbol,
        jsNontrivialString(vm, "FormData"_s),
        PropertyAttribute::DontEnum | PropertyAttribute::ReadOnly);
    RETURN_IF_EXCEPTION(scope, {});

    const auto& items = formData.items();
    for (const auto& group : groups.groups) {
        auto identifier = Identifier::fromString(vm, items[group.firstIndex].name);
        JSValue value;
        if (group.count == 1) {
            value = formDataEntryToJS(*global, *wrapper, group.firstIndex, items[group.firstIndex].data);
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            auto* array = constructEmptyArray(global, nullptr, group.count);
            RETURN_IF_EXCEPTION(scope, {});
            for (size_t index = 0; index < group.count; ++index) {
                const auto itemIndex = groups.order[group.offset + index];
                auto entry = formDataEntryToJS(*global, *wrapper, itemIndex, items[itemIndex].data);
                RETURN_IF_EXCEPTION(scope, {});
                array->putDirectIndex(global, index, entry);
                RETURN_IF_EXCEPTION(scope, {});
            }
            value = array;
        }
        object->putDirectMayBeIndex(global, identifier, value);
        RETURN_IF_EXCEPTION(scope, {});
    }

    return object;
}

} // namespace WebCore

namespace Bun::Bindgen::Engine {

using namespace JSC;
using namespace WebCore;

static FormDataEntryValueResult formDataEntryResult(
    JSGlobalObject& global,
    JSDOMFormData& wrapper,
    size_t index,
    const DOMFormData::FormDataEntryValue& entry)
{
    FormDataEntryValueResult result;
    if (auto* string = std::get_if<String>(&entry))
        result.set_string(*string);
    else
        result.set_blob(formDataEntryToJS(global, wrapper, index, entry));
    return result;
}

void bunBindgenEngine_WebCoreFormData_formDataAppendString(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataAppendString_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    propagateException(context.globalObject, scope, args.form->append(args.name, args.value));
}

struct FormDataFile {
    Ref<Blob> blob;
    String filename;
};

static ExceptionOr<FormDataFile> createFormDataFile(BunBindgen_Blob_Blob_Native* binding, const std::optional<String>& filename)
{
    auto created = Blob::create(binding);
    if (created.hasException())
        return created.releaseException();
    auto blob = created.releaseReturnValue();
    if (filename)
        return FormDataFile { WTF::move(blob), *filename };
    auto name = Bun::Bindgen::ZigExports::bunBindgenZig_Blob_blobFileName(blob->impl());
    if (!name)
        return WebCore::Exception { OutOfMemoryError };
    return FormDataFile { WTF::move(blob), WTF::move(name.value()) };
}

static JSValue preparedFileValue(JSGlobalObject& global, const DOMFormData::PreparedMutation& prepared, JSValue original, bool hasFilename)
{
    if (!hasFilename && bun_bindgen_class_Blob_File_try_cast_value(original))
        return original;
    return toJS(&global, defaultGlobalObject(&global), std::get<Ref<Blob>>(prepared.item().data).get());
}

void bunBindgenEngine_WebCoreFormData_formDataAppendBlob(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataAppendBlob_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto created = createFormDataFile(args.value, args.filename);
    if (created.hasException()) {
        propagateException(context.globalObject, scope, created.releaseException());
        return;
    }
    auto file = created.releaseReturnValue();
    auto preparation = args.form->prepareAppend(args.name, WTF::move(file.blob), file.filename);
    if (preparation.hasException()) {
        propagateException(context.globalObject, scope, preparation.releaseException());
        return;
    }
    auto prepared = preparation.releaseReturnValue();
    auto value = preparedFileValue(context.globalObject, prepared, args.original, args.filename.has_value());
    RETURN_IF_EXCEPTION(scope, void());
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    auto* cache = existingFileCache(wrapper);
    if (!cache) {
        cache = createFileCache(context.globalObject);
        RETURN_IF_EXCEPTION(scope, void());
    }
    cache->set(&context.globalObject, jsNumber(prepared.index()), value);
    RETURN_IF_EXCEPTION(scope, void());
    prepared.commit();
    commitFileCache(context.globalObject, wrapper, cache);
}

void bunBindgenEngine_WebCoreFormData_formDataDelete(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataDelete_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    auto* cache = rebuildFileCache(context.globalObject, wrapper, *args.form, args.name, std::nullopt, {});
    RETURN_IF_EXCEPTION(scope, void());
    args.form->remove(args.name);
    commitFileCache(context.globalObject, wrapper, cache);
}

std::optional<FormDataEntryValueResult> bunBindgenEngine_WebCoreFormData_formDataGet(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataGet_Arguments& args)
{
    const auto& items = args.form->items();
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    for (size_t index = 0; index < items.size(); ++index) {
        if (items[index].name == args.name)
            return formDataEntryResult(context.globalObject, wrapper, index, items[index].data);
    }
    return std::nullopt;
}

CppResultSequence<FormDataEntryValueResult> bunBindgenEngine_WebCoreFormData_formDataGetAll(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataGetAll_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    const auto& entries = args.form->items();
    const size_t count = std::ranges::count_if(entries, [&](const auto& entry) { return entry.name == args.name; });
    CppResultSequence<FormDataEntryValueResult> result;
    if (!result.reserveCapacity(context.results(), count))
        return {};
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    for (size_t index = 0; index < entries.size(); ++index) {
        const auto& entry = entries[index];
        if (entry.name != args.name)
            continue;
        auto value = formDataEntryResult(context.globalObject, wrapper, index, entry.data);
        RETURN_IF_EXCEPTION(scope, {});
        if (!result.append(context.results(), WTF::move(value)))
            return {};
    }
    return result;
}

bool bunBindgenEngine_WebCoreFormData_formDataHas(
    const BunBindgenEngine_WebCoreFormData_formDataHas_Arguments& args)
{
    return args.form->has(args.name);
}

void bunBindgenEngine_WebCoreFormData_formDataSetString(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataSetString_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto preparation = args.form->prepareSet(args.name, args.value);
    if (preparation.hasException()) {
        propagateException(context.globalObject, scope, preparation.releaseException());
        return;
    }
    auto prepared = preparation.releaseReturnValue();
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    auto* cache = rebuildFileCache(context.globalObject, wrapper, *args.form, prepared.item().name, prepared.index(), {});
    RETURN_IF_EXCEPTION(scope, void());
    prepared.commit();
    commitFileCache(context.globalObject, wrapper, cache);
}

void bunBindgenEngine_WebCoreFormData_formDataSetBlob(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataSetBlob_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto created = createFormDataFile(args.value, args.filename);
    if (created.hasException()) {
        propagateException(context.globalObject, scope, created.releaseException());
        return;
    }
    auto file = created.releaseReturnValue();
    auto preparation = args.form->prepareSet(args.name, WTF::move(file.blob), file.filename);
    if (preparation.hasException()) {
        propagateException(context.globalObject, scope, preparation.releaseException());
        return;
    }
    auto prepared = preparation.releaseReturnValue();
    auto value = preparedFileValue(context.globalObject, prepared, args.original, args.filename.has_value());
    RETURN_IF_EXCEPTION(scope, void());
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    auto* cache = rebuildFileCache(context.globalObject, wrapper, *args.form, prepared.item().name, prepared.index(), value);
    RETURN_IF_EXCEPTION(scope, void());
    prepared.commit();
    commitFileCache(context.globalObject, wrapper, cache);
}

CppResultSequence<std::pair<WTF::String, FormDataJSONValueResult>> bunBindgenEngine_WebCoreFormData_formDataJSON(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataJSON_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto grouped = groupFormDataItems(*args.form);
    if (grouped.hasException()) {
        propagateException(context.globalObject, scope, grouped.releaseException());
        return {};
    }
    auto groups = grouped.releaseReturnValue();
    const auto& items = args.form->items();
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    CppResultSequence<std::pair<WTF::String, FormDataJSONValueResult>> result;
    if (!result.reserveCapacity(context.results(), groups.groups.size()))
        return {};
    for (const auto& group : groups.groups) {
        FormDataJSONValueResult value;
        if (group.count == 1) {
            value.set_value(formDataEntryResult(context.globalObject, wrapper, group.firstIndex, items[group.firstIndex].data));
            RETURN_IF_EXCEPTION(scope, {});
        } else {
            CppResultSequence<FormDataEntryValueResult> values;
            if (!values.reserveCapacity(context.results(), group.count))
                return {};
            for (size_t index = 0; index < group.count; ++index) {
                const auto itemIndex = groups.order[group.offset + index];
                auto entryResult = formDataEntryResult(context.globalObject, wrapper, itemIndex, items[itemIndex].data);
                RETURN_IF_EXCEPTION(scope, {});
                if (!values.append(context.results(), WTF::move(entryResult)))
                    return {};
            }
            value.set_values(WTF::move(values));
        }
        if (!result.append(context.results(), { String(items[group.firstIndex].name), WTF::move(value) }))
            return {};
    }
    return result;
}

uint64_t bunBindgenEngine_WebCoreFormData_formDataCount(
    const BunBindgenEngine_WebCoreFormData_formDataCount_Arguments& args)
{
    return args.form->count();
}

BunBindgenEngine_WebCoreFormData_formDataIteratorEntry_Return bunBindgenEngine_WebCoreFormData_formDataIteratorEntry(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataIteratorEntry_Arguments& args)
{
    const auto index = args.iterator->index();
    auto entry = args.iterator->next();
    if (!entry)
        return std::nullopt;
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    auto value = formDataEntryResult(context.globalObject, wrapper, index, entry->value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return BunBindgenEngine_WebCoreFormData_formDataIteratorEntry_Return::value_type {
        .key = WTF::move(entry->key),
        .value = WTF::move(value),
    };
}

BunBindgenEngine_WebCoreFormData_formDataIteratorNext_Return bunBindgenEngine_WebCoreFormData_formDataIteratorNext(
    EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataIteratorNext_Arguments& args)
{
    const auto index = args.iterator->index();
    auto entry = args.iterator->next();
    if (!entry)
        return { .value = std::nullopt, .done = true };

    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto& wrapper = *uncheckedDowncast<JSDOMFormData>(args.wrapper);
    FormDataIteratorItemResult value;
    switch (args.kind) {
    case FormDataIteratorKind::entries: {
        CppResultSequence<FormDataEntryValueResult> pair;
        if (!pair.reserveCapacity(context.results(), 2))
            return {};
        FormDataEntryValueResult key;
        key.set_string(entry->key);
        if (!pair.append(context.results(), WTF::move(key)))
            return {};
        auto entryValue = formDataEntryResult(context.globalObject, wrapper, index, entry->value);
        RETURN_IF_EXCEPTION(scope, {});
        if (!pair.append(context.results(), WTF::move(entryValue)))
            return {};
        value.set_entry(WTF::move(pair));
        break;
    }
    case FormDataIteratorKind::keys: {
        FormDataEntryValueResult key;
        key.set_string(entry->key);
        value.set_value(WTF::move(key));
    } break;
    case FormDataIteratorKind::values: {
        auto entryValue = formDataEntryResult(context.globalObject, wrapper, index, entry->value);
        RETURN_IF_EXCEPTION(scope, {});
        value.set_value(WTF::move(entryValue));
        break;
    }
    }
    return { .value = WTF::move(value), .done = false };
}

} // namespace Bun::Bindgen::Engine
