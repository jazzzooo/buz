#include "root.h"
#include "SchemaBindings.h"
#include <JavaScriptCore/RegularExpression.h>
#include <JavaScriptCore/Options.h>

using namespace JSC;
using namespace JSC::Yarr;

RegularExpression* Bun::Bindgen::Engine::bunBindgenEngine_regular_expressions_regularExpressionCreate(
    const BunBindgenEngine_regular_expressions_regularExpressionCreate_Arguments& args)
{
    // TODO: Remove this, we technically are accessing options before we finalize them.
    // This means you cannot use BUN_JSC_dumpCompiledRegExpPatterns on the flag passed to `bun test -t`
    // NOLINTBEGIN
    Options::AllowUnfinalizedAccessScope scope {};
    // NOLINTEND
    return new RegularExpression(args.pattern, OptionSet<Flags>(static_cast<Flags>(args.flags)));
}
void Bun::Bindgen::Engine::bunBindgenEngine_regular_expressions_regularExpressionDestroy(
    const BunBindgenEngine_regular_expressions_regularExpressionDestroy_Arguments& args)
{
    delete args.expression;
}
bool Bun::Bindgen::Engine::bunBindgenEngine_regular_expressions_regularExpressionIsValid(
    const BunBindgenEngine_regular_expressions_regularExpressionIsValid_Arguments& args)
{
    return args.expression->isValid();
}
int32_t Bun::Bindgen::Engine::bunBindgenEngine_regular_expressions_regularExpressionMatchedLength(
    const BunBindgenEngine_regular_expressions_regularExpressionMatchedLength_Arguments& args)
{
    return args.expression->matchedLength();
}
int32_t Bun::Bindgen::Engine::bunBindgenEngine_regular_expressions_regularExpressionSearchRev(
    const BunBindgenEngine_regular_expressions_regularExpressionSearchRev_Arguments& args)
{
    return args.expression->searchRev(args.string);
}
int32_t Bun::Bindgen::Engine::bunBindgenEngine_regular_expressions_regularExpressionMatches(
    const BunBindgenEngine_regular_expressions_regularExpressionMatches_Arguments& args)
{
    return args.expression->match(args.string, 0, 0);
}
