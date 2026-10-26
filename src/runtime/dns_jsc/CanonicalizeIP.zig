pub fn canonicalizeIP(
    context: bun.bindgen.CallContext(CanonicalizeIPSchema),
    args: bun.bindgen.Args(CanonicalizeIPSchema),
) bun.bindgen.CallError(CanonicalizeIPSchema)!?bun.bindgen.DOMString {
    const address = args.address orelse return context.fail(.missing_address, {});
    const max_address_length = if (comptime bun.Environment.isWindows) 65 else 46;

    const address_utf8 = try address.toUTF8(bun.default_allocator);
    defer address_utf8.deinit();
    const address_bytes = address_utf8.slice();
    if (address_bytes.len >= max_address_length or strings.containsChar(address_bytes, '/')) return null;

    var binary: [16]u8 = undefined;
    var text: [max_address_length + 1]u8 = undefined;
    bun.copy(u8, &text, address_bytes);
    text[address_bytes.len] = 0;

    var family: c_int = c_ares.AF.INET;
    if (c_ares.ares_inet_pton(family, &text, &binary) != 1) {
        family = c_ares.AF.INET6;
        if (c_ares.ares_inet_pton(family, &text, &binary) != 1) return null;
    }
    if (c_ares.ares_inet_ntop(family, &binary, &text, @sizeOf(@TypeOf(text))) == null) return null;

    const canonical = std.mem.sliceTo(text[0..], 0);
    const result = try bun.bindgen.DOMString.fromUTF8(if (strings.eql(address_bytes, canonical)) address_bytes else canonical);
    return result;
}

const CanonicalizeIPBindings = bun.bindgen.Module("CanonicalizeIP");
const CanonicalizeIPSchema = CanonicalizeIPBindings.function("canonicalizeIP");
const CanonicalizeIPBinding = bun.bindgen.Fn(CanonicalizeIPSchema, canonicalizeIP);

comptime {
    _ = CanonicalizeIPBinding;
}

const std = @import("std");
const bun = @import("bun");
const c_ares = bun.c_ares;
const strings = bun.strings;
