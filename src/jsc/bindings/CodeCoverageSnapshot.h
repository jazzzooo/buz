#pragma once

#include "SchemaBindings.h"
#include <JavaScriptCore/ControlFlowProfiler.h>
#include <JavaScriptCore/FunctionHasExecutedCache.h>
#include <JavaScriptCore/VM.h>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <tuple>
#include <wtf/Vector.h>

namespace Bun {

struct CodeCoverageSnapshot {
    using Range = Bindgen::ZigExports::bunBindgenZig_code_coverage_codeCoverageConsumeBlocks_blocks_Element;
    WTF::Vector<Range> blocks;
    WTF::Vector<Range> functions;

    bool collect(JSC::VM& vm, JSC::SourceID sourceID)
    {
        const auto basicBlocks = vm.controlFlowProfiler()->getBasicBlocksForSourceIDWithoutFunctionRange(sourceID, vm);
        if (!blocks.tryReserveCapacity(basicBlocks.size()))
            return false;
        for (const auto& block : basicBlocks) {
            if (block.m_startOffset < 0 || block.m_endOffset < block.m_startOffset)
                continue;
            blocks.append({
                .startUTF16 = static_cast<uint32_t>(block.m_startOffset),
                .endUTF16 = static_cast<uint32_t>(block.m_endOffset) + 1,
                .executionCount = std::max<uint64_t>(block.m_executionCount, block.m_hasExecuted ? 1 : 0),
            });
        }

        const auto functionRanges = vm.functionHasExecutedCache()->getFunctionRanges(sourceID, JSC::FunctionHasExecutedCache::IncludeProgramRanges::No);
        if (!functions.tryReserveCapacity(functionRanges.size()))
            return false;
        for (const auto& function : functionRanges) {
            const auto start = std::get<1>(function);
            const auto end = std::get<2>(function);
            if (end < start || end == std::numeric_limits<uint32_t>::max())
                continue;
            functions.append({
                .startUTF16 = start,
                .endUTF16 = end + 1,
                .executionCount = std::get<0>(function) ? 1u : 0u,
            });
        }
        return true;
    }
};

}
