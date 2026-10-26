#include "root.h"
#include "ErrorStackFrame.h"
#include "SchemaBindings.h"
#include "JavaScriptCore/CodeBlock.h"
#include "JavaScriptCore/BytecodeIndex.h"
#include "wtf/Assertions.h"
#include "wtf/text/OrdinalNumber.h"

namespace Bun {
using namespace JSC;

/// Adjust a source position by a number of bytes. This accounts for when the adjustment
/// crosses line boundaries, and thus requires the source code in order to properly compute
/// the result.
void adjustPositionBackwards(ErrorStackFramePosition& pos, int amount, CodeBlock* code)
{
    if (pos.bytePosition - amount < 0) {
        pos.lineZeroBased = 0;
        pos.columnZeroBased = 0;
        pos.bytePosition = 0;
        return;
    }

    pos.columnZeroBased = pos.columnZeroBased - amount;
    if (pos.columnZeroBased < 0) {
        auto* provider = code->source().provider();
        if (!provider) {
            pos.lineZeroBased = 0;
            pos.columnZeroBased = 0;
            pos.bytePosition = 0;
            return;
        }

        auto source = provider->source();
        if (!source.is8Bit()) {
            // Debug-only assertion
            // Bun does not yet use 16-bit sources anywhere. The transpiler ensures everything
            // fit's into latin1 / 8-bit strings for on-average lower memory usage.
            ASSERT_NOT_REACHED("16-bit source re-mapping is not implemented here.");

            pos.lineZeroBased = 0;
            pos.columnZeroBased = 0;
            pos.bytePosition = 0;
            return;
        }

        for (int i = 0; i < amount; i++) {
            if (source[pos.bytePosition - i] == '\n') {
                pos.lineZeroBased = pos.lineZeroBased - 1;
            }
        }

        int columns = 0;
        // Initial -1 to skip the newline that gets counted.
        int i = pos.bytePosition - amount - 1;
        while (i > 0 && source[i] != '\n') {
            columns += 1;
            i -= 1;
        }
        pos.columnZeroBased = columns;
    }

    pos.bytePosition -= amount;
}

ErrorStackFramePosition getAdjustedPositionForBytecode(JSC::CodeBlock* code, JSC::BytecodeIndex bc)
{
    auto expr = code->expressionInfoForBytecodeIndex(bc);

    ErrorStackFramePosition pos {
        .lineZeroBased = OrdinalNumber::fromOneBasedInt(expr.lineColumn.line).zeroBasedInt(),
        .columnZeroBased = OrdinalNumber::fromOneBasedInt(expr.lineColumn.column).zeroBasedInt(),
        .bytePosition = static_cast<int>(expr.divot),
    };

    auto inst = code->instructionAt(bc);

    /// JavaScriptCore places error divots at different places than v8
    // Uncomment to debug this:
    // printf("lc = %d : %d (byte = %d)\n", pos.line.oneBasedInt(), pos.column.oneBasedInt(), expr.divot);
    // printf("off = %d : %d\n", expr.startOffset, expr.endOffset);
    // printf("name = %s\n", inst->name());

    switch (inst->opcodeID()) {
    case op_construct:
    case op_construct_varargs:
    case op_super_construct:
    case op_super_construct_varargs:
        // The divot by default is pointing at the `(` or the end of the class name.
        // We want to point at the `new` keyword, which is conveniently at the
        // expression start.
        adjustPositionBackwards(pos, expr.startOffset, code);
        break;

    default:
        break;
    }

    return pos;
}

void remapStackFramePosition(::VirtualMachine* vm, RemappableStackFrame& frame)
{
    auto result = Bindgen::ZigExports::bunBindgenZig_source_providers_remapStackFramePosition(
        vm,
        frame.sourceURL,
        knownStackIndex(frame.position.lineZeroBased),
        knownStackIndex(frame.position.columnZeroBased),
        knownStackIndex(frame.position.bytePosition),
        frame.remapped);
    if (!result)
        return;
    frame.sourceURL = result->sourceURL;
    frame.position.lineZeroBased = stackIndexOrUnknown(result->line);
    frame.position.columnZeroBased = stackIndexOrUnknown(result->column);
    frame.position.bytePosition = stackIndexOrUnknown(result->bytePosition);
    frame.remapped = result->remapped;
}

void remapStackFramePositions(::VirtualMachine* vm, std::span<RemappableStackFrame> frames)
{
    for (auto& frame : frames)
        remapStackFramePosition(vm, frame);
}

} // namespace Bun
