#include "root.h"

#include "DOMFormData.h"
#include "JSDOMExceptionHandling.h"
#include "SchemaBindings.h"
#include "StringConversion.h"
#include <new>

using namespace JSC;
using namespace WebCore;

void Bun::Bindgen::Engine::releaseDOMFormData(WebCore::DOMFormData* form)
{
    form->deref();
}

WebCore::DOMFormData* Bun::Bindgen::Engine::bunBindgenEngine_dom_form_data_domFormDataRetain(
    const BunBindgenEngine_dom_form_data_domFormDataRetain_Arguments& args)
{
    args.form->ref();
    return args.form;
}

uint64_t Bun::Bindgen::Engine::bunBindgenEngine_dom_form_data_domFormDataMemoryCost(
    const BunBindgenEngine_dom_form_data_domFormDataMemoryCost_Arguments& args)
{
    return args.form->memoryCost();
}

void Bun::Bindgen::Engine::releaseDOMFormDataIterator(WebCore::DOMFormData::Iterator* iterator)
{
    delete iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_dom_form_data_domFormDataIteratorCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_dom_form_data_domFormDataIteratorCreate(
    const BunBindgenEngine_dom_form_data_domFormDataIteratorCreate_Arguments& args)
{
    auto* iterator = new (std::nothrow) WebCore::DOMFormData::Iterator(*args.form);
    if (!iterator)
        return Bun::Bindgen::nativeAllocationFailure();
    return iterator;
}

Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFormData_formDataCreate_Return Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFormData_formDataCreate(
    const BunBindgenEngine_WebCoreFormData_formDataCreate_Arguments&)
{
    auto formData = DOMFormData::create();
    if (formData.hasException()) {
        RELEASE_ASSERT(formData.releaseException().code() == OutOfMemoryError);
        return Bun::Bindgen::nativeAllocationFailure();
    }
    return &formData.releaseReturnValue().leakRef();
}

Bun::Bindgen::Engine::BunBindgenEngine_WebCoreFormData_formDataCreateFromURLQuery_Return Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFormData_formDataCreateFromURLQuery(
    const BunBindgenEngine_WebCoreFormData_formDataCreateFromURLQuery_Arguments& args)
{
    auto formData = DOMFormData::create(args.query);
    if (formData.hasException()) {
        RELEASE_ASSERT(formData.releaseException().code() == OutOfMemoryError);
        return Bun::Bindgen::nativeAllocationFailure();
    }
    return &formData.releaseReturnValue().leakRef();
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFormData_formDataAppend(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataAppend_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto name = Bun::decodeUTF8ReplacingInvalidSequences(args.name);
    if (!name) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    auto value = Bun::decodeUTF8ReplacingInvalidSequences(args.value);
    if (!value) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    propagateException(context.globalObject, scope, args.form->append(name.value(), value.value()));
}

void Bun::Bindgen::Engine::bunBindgenEngine_WebCoreFormData_formDataAppendFile(
    Bun::Bindgen::EngineCallContext& context,
    const BunBindgenEngine_WebCoreFormData_formDataAppendFile_Arguments& args)
{
    auto scope = DECLARE_THROW_SCOPE(context.globalObject.vm());
    auto name = Bun::decodeUTF8ReplacingInvalidSequences(args.name);
    if (!name) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    auto filename = Bun::decodeUTF8ReplacingInvalidSequences(args.filename);
    if (!filename) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    auto contentType = Bun::decodeUTF8ReplacingInvalidSequences(args.contentType);
    if (!contentType) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    RefPtr<Blob> blob = WebCore::Blob::create(args.value, &context.globalObject, contentType.value());
    RETURN_IF_EXCEPTION(scope, void());
    propagateException(context.globalObject, scope, args.form->append(name.value(), blob.releaseNonNull(), filename.value()));
}

std::optional<Bun::Bindgen::Engine::BunBindgenEngine_dom_form_data_domFormDataEntry_Return::value_type> Bun::Bindgen::Engine::bunBindgenEngine_dom_form_data_domFormDataEntry(
    const BunBindgenEngine_dom_form_data_domFormDataEntry_Arguments& args)
{
    using Entry = BunBindgenEngine_dom_form_data_domFormDataEntry_Return::value_type;
    const auto& items = args.form->items();
    if (args.index >= items.size())
        return std::nullopt;

    const auto& item = items[args.index];
    Entry result { .name = item.name };
    if (auto* value = std::get_if<WTF::String>(&item.data)) {
        result.value.set_string(*value);
        return result;
    }

    const auto& blob = std::get<Ref<WebCore::Blob>>(item.data);
    result.value.set_file({
        .blob = blob->impl(),
        .filename = blob->fileName(),
    });
    return result;
}
