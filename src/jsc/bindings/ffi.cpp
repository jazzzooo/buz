#include "root.h"

#include <JavaScriptCore/CallFrame.h>

typedef struct FFIFields {
    uint32_t JSArrayBufferView__offsetOfLength;
    uint32_t JSArrayBufferView__offsetOfByteOffset;
    uint32_t JSArrayBufferView__offsetOfVector;
    uint32_t JSCell__offsetOfType;
    uint32_t CallFrame__argumentOffset;
} FFIFields;

extern "C" const FFIFields Bun__FFI__offsets = {
    .JSArrayBufferView__offsetOfLength = static_cast<uint32_t>(JSC::JSArrayBufferView::offsetOfLength()),
    .JSArrayBufferView__offsetOfByteOffset = static_cast<uint32_t>(JSC::JSArrayBufferView::offsetOfByteOffset()),
    .JSArrayBufferView__offsetOfVector = static_cast<uint32_t>(JSC::JSArrayBufferView::offsetOfVector()),
    .JSCell__offsetOfType = static_cast<uint32_t>(JSC::JSCell::typeInfoTypeOffset()),
    .CallFrame__argumentOffset = static_cast<uint32_t>(JSC::CallFrame::argumentOffset(0)),
};
