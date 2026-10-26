#include "root.h"
#include "SchemaBindings.h"
#include "CodeCoverageSnapshot.h"
#include <JavaScriptCore/ExceptionHelpers.h>

using namespace JSC;

void Bun::Bindgen::Engine::bunBindgenEngine_code_coverage_codeCoverageWithBlocksAndFunctions(
    EngineCallContext& context,
    const BunBindgenEngine_code_coverage_codeCoverageWithBlocksAndFunctions_Arguments& args)
{
    VM& vm = context.globalObject.vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    CodeCoverageSnapshot snapshot;
    if (!snapshot.collect(vm, args.sourceID)) {
        throwOutOfMemoryError(&context.globalObject, scope);
        return;
    }
    scope.release();
    Bun::Bindgen::ZigExports::bunBindgenZig_code_coverage_codeCoverageConsumeBlocks(
        &context.globalObject, args.generator, snapshot.blocks.span(), snapshot.functions.span(), args.ignoreSourceMap);
}
