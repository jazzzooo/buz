pub fn fromContextCreation(context: anytype, failure: bun.uws.TLSContextFailure) bindgen.CallError(@TypeOf(context)) {
    const message: []const u8 = switch (failure.kind) {
        .out_of_memory => return error.OutOfMemory,
        .none => return fromCode(context, failure.boring_ssl_code),
        .load_ca_file => "Failed to load CA file",
        .invalid_ca_file => "Invalid CA file",
        .invalid_ca => "Invalid CA",
        .invalid_ciphers => "Invalid ciphers",
    };
    return context.fail(.tls_boringssl, try bindgen.ThreadSafeDOMString.fromUTF8(message));
}

pub fn fromCode(context: anytype, code: u32) bindgen.CallError(@TypeOf(context)) {
    if (bun.BoringSSL.c.ERR_GET_REASON(code) == bun.BoringSSL.c.ERR_R_MALLOC_FAILURE)
        return error.OutOfMemory;
    const message = bun.BoringSSL.ErrorMessage.init(code);
    return context.fail(.tls_boringssl, try bindgen.ThreadSafeDOMString.fromUTF8(message.slice()));
}

pub fn takeCode() bun.OOM!u32 {
    const ssl = bun.BoringSSL.c;
    var first: u32 = 0;
    var allocation_failed = false;
    while (true) {
        const code = ssl.ERR_get_error();
        if (code == 0) break;
        if (first == 0) first = code;
        if (ssl.ERR_GET_REASON(code) == ssl.ERR_R_MALLOC_FAILURE) allocation_failed = true;
    }
    if (allocation_failed) return error.OutOfMemory;
    return first;
}

const bun = @import("bun");
const bindgen = bun.bindgen;
