#include "root.h"
#include "Secrets.h"
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include "ObjectBindings.h"
#include "SchemaBindings.h"
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

namespace Bun {

using namespace JSC;
using namespace WTF;

struct SecretsJobOptions {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(SecretsJobOptions);

    enum Operation {
        GET = 0,
        SET = 1,
        DELETE_OP = 2
    };

    Operation op;
    CString service;
    CString name;
    CString password;
    bool allowUnrestrictedAccess = false;

    Secrets::Error error;
    std::optional<WTF::Vector<uint8_t>> resultPassword;
    bool deleted = false;

    SecretsJobOptions(Operation op, CString&& service, CString&& name, CString&& password, bool allowUnrestrictedAccess = false)
        : op(op)
        , service(service)
        , name(name)
        , password(password)
        , allowUnrestrictedAccess(allowUnrestrictedAccess)
    {
    }

    ~SecretsJobOptions()
    {
        if (password.length() > 0) {
            memsetSpan(password.mutableSpan(), 0);
        }

        if (resultPassword.has_value()) {
            memsetSpan(resultPassword.value().mutableSpan(), 0);
        }

        if (name.length() > 0) {
            memsetSpan(name.mutableSpan(), 0);
        }

        if (service.length() > 0) {
            memsetSpan(service.mutableSpan(), 0);
        }
    }

};

SecretsJobOptions* Bindgen::Engine::bunBindgenEngine_secrets_engine_secretsJobCreate(
    const BunBindgenEngine_secrets_engine_secretsJobCreate_Arguments& args)
{
    using Operation = decltype(args.operation);
    SecretsJobOptions::Operation operation;
    switch (args.operation) {
    case Operation::get:
        operation = SecretsJobOptions::GET;
        break;
    case Operation::set:
        operation = SecretsJobOptions::SET;
        break;
    case Operation::delete_op:
        operation = SecretsJobOptions::DELETE_OP;
        break;
    }

    return new SecretsJobOptions(
        operation,
        args.service.utf8(),
        args.name.utf8(),
        args.password ? args.password->utf8() : CString(),
        args.allow_unrestricted_access);
}

void Bindgen::Engine::bunBindgenEngine_secrets_engine_secretsJobRunTask(
    const BunBindgenEngine_secrets_engine_secretsJobRunTask_Arguments& args)
{
    auto* opts = args.options;
    switch (opts->op) {
    case SecretsJobOptions::GET: {
        auto result = Secrets::getPassword(opts->service, opts->name, opts->error);
        if (result.has_value()) {
            opts->resultPassword = WTF::move(result.value());
        }
        break;
    }

    case SecretsJobOptions::SET:
        opts->error = Secrets::setPassword(opts->service, opts->name, WTF::move(opts->password), opts->allowUnrestrictedAccess);
        break;

    case SecretsJobOptions::DELETE_OP:
        opts->deleted = Secrets::deletePassword(opts->service, opts->name, opts->error);
        break;
    }
}

Bun::Bindgen::Engine::BunBindgenEngine_secrets_engine_secretsJobTakeResult_Return Bindgen::Engine::bunBindgenEngine_secrets_engine_secretsJobTakeResult(
    const BunBindgenEngine_secrets_engine_secretsJobTakeResult_Arguments& args)
{
    using Return = BunBindgenEngine_secrets_engine_secretsJobTakeResult_Return::value_type;
    using Error = decltype(std::declval<Return>().error_kind);
    auto* opts = args.options;

    Error error = Error::none;
    switch (opts->error.type) {
    case Secrets::ErrorType::None:
        break;
    case Secrets::ErrorType::NotFound:
        error = Error::not_found;
        break;
    case Secrets::ErrorType::AccessDenied:
        error = Error::access_denied;
        break;
    case Secrets::ErrorType::PlatformError:
        error = Error::platform_error;
        break;
    }

    String message = opts->error.code == 0
        ? opts->error.message
        : makeString(opts->error.message, " (code: "_s, String::number(opts->error.code), ")"_s);
    std::optional<String> password;
    if (opts->resultPassword) {
        auto result = WTF::move(*opts->resultPassword);
        opts->resultPassword.reset();
        password = String::fromUTF8(result.span());
        memsetSpan(result.mutableSpan(), 0);
    }

    return Return {
        .error_kind = error,
        .platform_code = opts->error.code,
        .message = WTF::move(message),
        .password = WTF::move(password),
        .deleted = opts->deleted,
    };
}

void Bindgen::Engine::releaseSecretsJobOptions(SecretsJobOptions* options)
{
    delete options;
}

} // namespace Bun
