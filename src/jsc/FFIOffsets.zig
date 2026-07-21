/// Must match `FFIFields` in bindings/ffi.cpp.
pub const Fields = extern struct {
    JSArrayBufferView__offsetOfLength: u32,
    JSArrayBufferView__offsetOfByteOffset: u32,
    JSArrayBufferView__offsetOfVector: u32,
    JSCell__offsetOfType: u32,
    CallFrame__argumentOffset: u32,
};

extern "c" const Bun__FFI__offsets: Fields;

pub inline fn get() *const Fields {
    return &Bun__FFI__offsets;
}
