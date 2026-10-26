#include "root.h"

#include "BunBuiltinNames.h"
#include "ErrorCode.h"
#include "SchemaBindings.h"
#include "ZigGlobalObject.h"
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSMap.h>
#include <JavaScriptCore/JSMapInlines.h>
#include <JavaScriptCore/JSMapIterator.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/ASCIICType.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

namespace Bun {

using namespace JSC;
using namespace WTF;

namespace {

bool isHTTPTokenCharacter(char16_t character)
{
    if (character > 0x7f)
        return false;
    auto ascii = static_cast<char>(character);
    return WTF::isASCIIAlphanumeric(ascii) || ascii == '!' || ascii == '#' || ascii == '$' || ascii == '%' || ascii == '&' || ascii == '\'' || ascii == '*' || ascii == '+' || ascii == '-' || ascii == '.' || ascii == '^' || ascii == '_' || ascii == '`' || ascii == '|' || ascii == '~';
}

int firstInvalidHTTPTokenCharacter(StringView value)
{
    for (size_t index = 0; index < value.length(); ++index) {
        if (!isHTTPTokenCharacter(value[index]))
            return static_cast<int>(std::min(index, static_cast<size_t>(std::numeric_limits<int>::max())));
    }
    return -1;
}

bool isHTTPQuotedStringCharacter(char16_t character)
{
    return character == '\t' || (character >= 0x20 && character <= 0x7e) || (character >= 0x80 && character <= 0xff);
}

int firstInvalidHTTPQuotedStringCharacter(StringView value)
{
    for (size_t index = 0; index < value.length(); ++index) {
        if (!isHTTPQuotedStringCharacter(value[index]))
            return static_cast<int>(std::min(index, static_cast<size_t>(std::numeric_limits<int>::max())));
    }
    return -1;
}

size_t skipHTTPWhitespace(StringView value, size_t position)
{
    while (position < value.length()) {
        auto character = value[position];
        if (character != '\t' && character != ' ' && character != '\r' && character != '\n')
            break;
        ++position;
    }
    return position;
}

size_t trimHTTPWhitespaceEnd(StringView value)
{
    size_t end = value.length();
    while (end) {
        auto character = value[end - 1];
        if (character != '\t' && character != ' ' && character != '\r' && character != '\n')
            break;
        --end;
    }
    return end;
}

String removeBackslashes(StringView value)
{
    if (value.find('\\') == notFound)
        return value.toString();
    StringBuilder builder;
    for (size_t index = 0; index < value.length(); ++index) {
        auto character = value[index];
        if (character == '\\' && index + 1 < value.length())
            character = value[++index];
        builder.append(character);
    }
    return builder.toString();
}

void appendEncodedParameterValue(StringBuilder& builder, StringView value)
{
    if (value.isEmpty()) {
        builder.append("\"\""_s);
        return;
    }
    if (firstInvalidHTTPTokenCharacter(value) == -1) {
        builder.append(value);
        return;
    }
    builder.append('"');
    for (size_t index = 0; index < value.length(); ++index) {
        auto character = value[index];
        if (character == '"' || character == '\\')
            builder.append('\\');
        builder.append(character);
    }
    builder.append('"');
}

bool parseMIMEParameters(JSGlobalObject* globalObject, JSMap* map, StringView input)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    size_t position = 0;

    while (position < input.length()) {
        position = skipHTTPWhitespace(input, position);
        if (position < input.length() && input[position] == ';')
            position = skipHTTPWhitespace(input, position + 1);
        if (position >= input.length())
            break;

        size_t nameEnd = position;
        while (nameEnd < input.length() && input[nameEnd] != ';' && input[nameEnd] != '=')
            ++nameEnd;
        String name = input.substring(position, nameEnd - position).convertToASCIILowercase();
        position = nameEnd;

        if (position >= input.length() || input[position] != '=') {
            auto semicolon = input.find(';', position);
            position = semicolon == notFound ? input.length() : semicolon + 1;
            continue;
        }
        ++position;

        String value;
        if (position < input.length() && input[position] == '"') {
            size_t start = ++position;
            bool escaped = false;
            while (position < input.length()) {
                auto character = input[position];
                if (escaped)
                    escaped = false;
                else if (character == '\\')
                    escaped = true;
                else if (character == '"')
                    break;
                ++position;
            }
            value = removeBackslashes(input.substring(start, position - start));
            if (position < input.length() && input[position] == '"')
                ++position;
            else {
                auto semicolon = input.find(';', position);
                position = semicolon == notFound ? input.length() : semicolon;
            }
        } else {
            size_t end = position;
            while (end < input.length() && input[end] != ';')
                ++end;
            auto rawValue = input.substring(position, end - position);
            value = rawValue.left(trimHTTPWhitespaceEnd(rawValue)).toString();
            position = end;
            if (value.isEmpty())
                continue;
        }

        if (name.isEmpty() || firstInvalidHTTPTokenCharacter(name) != -1 || firstInvalidHTTPQuotedStringCharacter(value) != -1)
            continue;

        auto nameValue = jsString(vm, name);
        bool exists = map->has(globalObject, nameValue);
        RETURN_IF_EXCEPTION(scope, false);
        if (!exists) {
            map->set(globalObject, nameValue, jsString(vm, value));
            RETURN_IF_EXCEPTION(scope, false);
        }

        if (position < input.length() && input[position] == ';')
            ++position;
    }
    return true;
}

struct ParsedMIMEType {
    String type;
    String subtype;
    size_t parametersStart;
};

std::optional<ParsedMIMEType> parseMIMEType(JSGlobalObject* globalObject, const String& inputString)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    StringView input(inputString);
    size_t position = skipHTTPWhitespace(input, 0);
    size_t slash = input.find('/', position);
    if (slash == notFound) {
        int invalid = firstInvalidHTTPTokenCharacter(input.substring(position));
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "type"_s, inputString, invalid == -1 ? -1 : static_cast<int>(position) + invalid);
        return std::nullopt;
    }

    auto typeView = input.substring(position, slash - position);
    int invalidType = firstInvalidHTTPTokenCharacter(typeView);
    if (typeView.isEmpty() || invalidType != -1) {
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "type"_s, inputString, invalidType == -1 ? static_cast<int>(position) : static_cast<int>(position) + invalidType);
        return std::nullopt;
    }

    position = slash + 1;
    size_t semicolon = input.find(';', position);
    size_t subtypeEnd = semicolon == notFound ? input.length() : semicolon;
    auto rawSubtype = input.substring(position, subtypeEnd - position);
    auto subtypeView = rawSubtype.left(trimHTTPWhitespaceEnd(rawSubtype));
    int invalidSubtype = firstInvalidHTTPTokenCharacter(subtypeView);
    if (subtypeView.isEmpty() || invalidSubtype != -1) {
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "subtype"_s, inputString, invalidSubtype == -1 ? static_cast<int>(position) : static_cast<int>(position) + invalidSubtype);
        return std::nullopt;
    }

    return ParsedMIMEType {
        typeView.convertToASCIILowercase(),
        subtypeView.convertToASCIILowercase(),
        semicolon == notFound ? input.length() : semicolon + 1,
    };
}

JSObject* createMIMEParamsObject(JSGlobalObject* globalObject, Structure* structure, JSMap* map)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* object = JSFinalObject::create(vm, structure);
    auto* defaultStructure = defaultGlobalObject(globalObject)->BunBindgen_MIMEParamsHost_MIMEParamsStructure();
    if (structure->id() == defaultStructure->id())
        object->putDirectOffset(vm, Bindgen::BunBindgen_MIMEParamsHost_MIMEParams_offset_map, map);
    else
        object->putDirect(vm, WebCore::builtinNames(vm).mimeParamsPrivateName(), map, 0);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return object;
}

JSObject* createMIMETypeObject(JSGlobalObject* globalObject, Structure* structure, const String& type, const String& subtype, JSObject* params)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* object = JSFinalObject::create(vm, structure);
    JSValue typeValue = jsString(vm, type);
    JSValue subtypeValue = jsString(vm, subtype);
    auto* defaultStructure = defaultGlobalObject(globalObject)->BunBindgen_MIMEParamsHost_MIMETypeStructure();
    if (structure->id() == defaultStructure->id()) {
        object->putDirectOffset(vm, Bindgen::BunBindgen_MIMEParamsHost_MIMEType_offset_type, typeValue);
        object->putDirectOffset(vm, Bindgen::BunBindgen_MIMEParamsHost_MIMEType_offset_subtype, subtypeValue);
        object->putDirectOffset(vm, Bindgen::BunBindgen_MIMEParamsHost_MIMEType_offset_params, params);
    } else {
        auto& names = WebCore::builtinNames(vm);
        object->putDirect(vm, names.mimeTypePrivateName(), typeValue, 0);
        RETURN_IF_EXCEPTION(scope, nullptr);
        object->putDirect(vm, names.mimeSubtypePrivateName(), subtypeValue, 0);
        RETURN_IF_EXCEPTION(scope, nullptr);
        object->putDirect(vm, names.mimeParamsPrivateName(), params, 0);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    return object;
}

} // namespace

static JSC::JSMap* bindgenMIMEParamsMap(JSC::JSValue value)
{
    return uncheckedDowncast<JSC::JSMap>(value);
}

JSObject* Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_construct_Arguments&)
{
    auto& globalObject = context.globalObject;
    auto* map = JSMap::create(globalObject.vm(), globalObject.mapStructure());
    return createMIMEParamsObject(&globalObject, context.structure, map);
}

std::optional<String> Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_get(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_get_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto key = jsString(globalObject->vm(), args.name);
    auto* map = bindgenMIMEParamsMap(args.bindingThis.map);
    bool exists = map->has(globalObject, key);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!exists)
        return std::nullopt;
    auto value = map->get(globalObject, key);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    auto result = value.toWTFString(globalObject);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return result;
}

bool Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_has(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_has_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    return bindgenMIMEParamsMap(args.bindingThis.map)->has(globalObject, jsString(globalObject->vm(), args.name));
}

void Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_set(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_set_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    int invalidName = firstInvalidHTTPTokenCharacter(args.name);
    if (args.name.isEmpty() || invalidName != -1) {
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "parameter name"_s, args.name, invalidName);
        return;
    }
    int invalidValue = firstInvalidHTTPQuotedStringCharacter(args.value);
    if (invalidValue != -1) {
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "parameter value"_s, args.value, invalidValue);
        return;
    }
    RELEASE_AND_RETURN(scope, bindgenMIMEParamsMap(args.bindingThis.map)->set(globalObject, jsString(globalObject->vm(), args.name), jsString(globalObject->vm(), args.value)));
}

void Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_delete(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_delete_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    bindgenMIMEParamsMap(args.bindingThis.map)->remove(globalObject, jsString(globalObject->vm(), args.name));
}

static String serializeMIMEParams(JSGlobalObject* globalObject, JSMap* map)
{
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* iterator = JSMapIterator::create(vm, globalObject->mapIteratorStructure(), map, IterationKind::Entries);
    RETURN_IF_EXCEPTION(scope, {});
    StringBuilder builder(OverflowPolicy::RecordOverflow);
    bool first = true;
    while (true) {
        JSValue keyValue;
        JSValue parameterValue;
        if (!iterator->nextKeyValue(globalObject, keyValue, parameterValue))
            break;
        String key = keyValue.toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        String value = parameterValue.toWTFString(globalObject);
        RETURN_IF_EXCEPTION(scope, {});
        if (!first)
            builder.append(';');
        first = false;
        builder.append(key, '=');
        appendEncodedParameterValue(builder, value);
        if (builder.hasOverflowed()) {
            throwOutOfMemoryError(globalObject, scope);
            return {};
        }
    }
    return builder.toString();
}

String Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_toString(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_toString_Arguments& args)
{
    return serializeMIMEParams(&context.globalObject, bindgenMIMEParamsMap(args.bindingThis.map));
}

static JSValue createMIMEParamsIterator(Bindgen::CppCallContext& context, JSMap* map, IterationKind kind)
{
    auto* globalObject = &context.globalObject;
    return JSMapIterator::create(globalObject->vm(), globalObject->mapIteratorStructure(), map, kind);
}

JSValue Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_entries(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_entries_Arguments& args)
{
    return createMIMEParamsIterator(context, bindgenMIMEParamsMap(args.bindingThis.map), IterationKind::Entries);
}

JSValue Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_keys(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_keys_Arguments& args)
{
    return createMIMEParamsIterator(context, bindgenMIMEParamsMap(args.bindingThis.map), IterationKind::Keys);
}

JSValue Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEParams_method_values(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEParams_method_values_Arguments& args)
{
    return createMIMEParamsIterator(context, bindgenMIMEParamsMap(args.bindingThis.map), IterationKind::Values);
}

JSObject* Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_construct(
    CppPlainConstructContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_construct_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto parsed = parseMIMEType(globalObject, args.input);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!parsed)
        return nullptr;

    auto* map = JSMap::create(vm, globalObject->mapStructure());
    bool parsedParameters = parseMIMEParameters(globalObject, map, StringView(args.input).substring(parsed->parametersStart));
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!parsedParameters)
        return nullptr;
    auto* params = createMIMEParamsObject(globalObject, defaultGlobalObject(globalObject)->BunBindgen_MIMEParamsHost_MIMEParamsStructure(), map);
    RETURN_IF_EXCEPTION(scope, nullptr);
    RELEASE_AND_RETURN(scope, createMIMETypeObject(globalObject, context.structure, parsed->type, parsed->subtype, params));
}

String Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_getter_type(
    CppCallContext&,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_getter_type_Arguments& args)
{
    return args.bindingThis.type;
}

void Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_setter_type(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_setter_type_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    int invalid = firstInvalidHTTPTokenCharacter(args.value);
    if (args.value.isEmpty() || invalid != -1) {
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "type"_s, args.value, invalid);
        return;
    }
    args.bindingThis.source_identity.object()->putDirect(globalObject->vm(), WebCore::builtinNames(globalObject->vm()).mimeTypePrivateName(), jsString(globalObject->vm(), args.value.convertToASCIILowercase()), 0);
    RETURN_IF_EXCEPTION(scope, );
}

String Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_getter_subtype(
    CppCallContext&,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_getter_subtype_Arguments& args)
{
    return args.bindingThis.subtype;
}

void Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_setter_subtype(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_setter_subtype_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    int invalid = firstInvalidHTTPTokenCharacter(args.value);
    if (args.value.isEmpty() || invalid != -1) {
        ERR::INVALID_MIME_SYNTAX(scope, globalObject, "subtype"_s, args.value, invalid);
        return;
    }
    args.bindingThis.source_identity.object()->putDirect(globalObject->vm(), WebCore::builtinNames(globalObject->vm()).mimeSubtypePrivateName(), jsString(globalObject->vm(), args.value.convertToASCIILowercase()), 0);
    RETURN_IF_EXCEPTION(scope, );
}

String Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_getter_essence(
    CppCallContext&,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_getter_essence_Arguments& args)
{
    return makeString(args.bindingThis.type, '/', args.bindingThis.subtype);
}

JSValue Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_getter_params(
    CppCallContext&,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_getter_params_Arguments& args)
{
    return args.bindingThis.params;
}

String Bindgen::Cpp::bunBindgenCpp_MIMEParamsHost_MIMEType_method_toString(
    CppCallContext& context,
    const BunBindgenCpp_MIMEParamsHost_MIMEType_method_toString_Arguments& args)
{
    auto* globalObject = &context.globalObject;
    auto scope = DECLARE_THROW_SCOPE(globalObject->vm());
    auto params = serializeMIMEParams(globalObject, bindgenMIMEParamsMap(args.bindingThis.params.map));
    RETURN_IF_EXCEPTION(scope, {});
    auto result = params.isEmpty()
        ? tryMakeString(args.bindingThis.type, '/', args.bindingThis.subtype)
        : tryMakeString(args.bindingThis.type, '/', args.bindingThis.subtype, ';', params);
    if (result.isNull())
        throwOutOfMemoryError(globalObject, scope);
    return result;
}

} // namespace Bun
