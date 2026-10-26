// TODO: move all custom functions from the translated file into this file, then
// the translated file can be provided by `zig translate-c`
/// BoringSSL's translated C API
pub const c = boring;

var loaded = false;
pub fn load() void {
    if (loaded) return;
    loaded = true;
    boring.CRYPTO_library_init();
    bun.assert(boring.SSL_library_init() > 0);
    boring.SSL_load_error_strings();
    boring.ERR_load_BIO_strings();
    boring.OpenSSL_add_all_algorithms();

    @import("../boringssl_sys/Memory.zig").retainSymbols();
}

pub const ErrorMessage = struct {
    bytes: [128 + 1 + "BoringSSL ".len]u8,

    pub fn init(code: u32) ErrorMessage {
        var result: ErrorMessage = .{ .bytes = @splat(0) };
        const prefix = "BoringSSL ";
        result.bytes[0..prefix.len].* = prefix.*;
        const message = result.bytes[prefix.len..];
        _ = boring.ERR_error_string_n(code, message.ptr, message.len);
        if (result.bytes[prefix.len] == 0) {
            _ = std.mem.printSentinel(&result.bytes, "An unknown BoringSSL error occurred: {d}", .{code}, 0) catch unreachable;
        }
        return result;
    }

    pub fn slice(this: *const ErrorMessage) []const u8 {
        return std.mem.sliceTo(&this.bytes, 0);
    }
};

const INET6_ADDRSTRLEN = if (bun.Environment.isWindows) 65 else 46;

/// converts IP string to canonicalized IP string
/// return null when the IP is invalid
pub fn canonicalizeIP(addr_str: []const u8, outIP: *[INET6_ADDRSTRLEN + 1]u8) ?[]const u8 {
    if (addr_str.len >= INET6_ADDRSTRLEN) {
        return null;
    }
    var ip_std_text: [INET6_ADDRSTRLEN + 1]u8 = undefined;
    // we need a null terminated string as input
    bun.copy(u8, outIP, addr_str);
    outIP[addr_str.len] = 0;

    var af: c_int = std.posix.AF.INET;
    // get the standard text representation of the IP
    if (c_ares.ares_inet_pton(af, outIP, &ip_std_text) <= 0) {
        af = std.posix.AF.INET6;
        if (c_ares.ares_inet_pton(af, outIP, &ip_std_text) <= 0) {
            return null;
        }
    }
    // ip_addr will contain the null-terminated string of the cannonicalized IP
    if (c_ares.ares_inet_ntop(af, &ip_std_text, outIP, outIP.len) == null) {
        return null;
    }
    // use the null-terminated size to return the string
    const size = bun.len(bun.cast([*:0]u8, outIP));
    return outIP[0..size];
}

/// converts ASN1_OCTET_STRING to canonicalized IP string
/// return null when the IP is invalid
pub fn ip2String(ip: *boring.ASN1_OCTET_STRING, outIP: *[INET6_ADDRSTRLEN + 1]u8) ?[]const u8 {
    const af: c_int = if (ip.length == 4) std.posix.AF.INET else std.posix.AF.INET6;
    if (c_ares.ares_inet_ntop(af, ip.data, outIP, outIP.len) == null) {
        return null;
    }

    // use the null-terminated size to return the string
    const size = bun.len(bun.cast([*:0]u8, outIP));
    return outIP[0..size];
}

/// Matches a DNS name pattern (possibly with a leading `*.` wildcard) against
/// `hostname`. Mirrors Node.js `check()` in lib/tls.js for a single pattern.
fn matchDnsName(pattern: []const u8, hostname: []const u8) bool {
    if (pattern.len == 0) return false;
    if (!isSafeAltName(pattern, false)) return false;

    if (pattern[0] == '*') {
        // RFC 6125 Section 6.4.3: Wildcard must match exactly one label.
        // Enforce "*." prefix (wildcard must be leftmost and followed by a dot).
        if (pattern.len >= 2 and pattern[1] == '.') {
            const suffix = pattern[2..];
            // Disallow "*.tld" (suffix must contain at least one dot for proper domain hierarchy)
            if (strings.containsChar(suffix, '.')) {
                // Host must be at least "label.suffix" (suffix_len + 1 for dot + at least 1 char for label)
                if (hostname.len > suffix.len + 1) {
                    const dot_index = hostname.len - suffix.len - 1;
                    // The character before suffix must be a dot, and there must be no other
                    // dots in the prefix (single-label wildcard only).
                    if (hostname[dot_index] == '.' and !strings.containsChar(hostname[0..dot_index], '.')) {
                        const host_suffix = hostname[dot_index + 1 ..];
                        // RFC 4343: DNS names are case-insensitive
                        if (strings.eqlCaseInsensitiveASCII(suffix, host_suffix, true)) {
                            return true;
                        }
                    }
                }
            }
        }
    }
    // RFC 4343: DNS names are case-insensitive
    return strings.eqlCaseInsensitiveASCII(pattern, hostname, true);
}

fn isSafeAltName(name: []const u8, utf8: bool) bool {
    for (name) |byte| {
        switch (byte) {
            '"', '\\', ',', '\'' => return false,
            else => if (utf8) {
                if (byte < ' ' or byte == '\x7f') return false;
            } else if (byte < ' ' or byte > '~') {
                return false;
            },
        }
    }
    return true;
}

pub fn checkX509ServerIdentity(
    x509: *boring.X509,
    hostname: []const u8,
) bool {
    const host_is_ip = strings.isIPAddress(hostname);
    // Node.js: CN is consulted only when the certificate carries no
    // DNS / IP / URI subjectAltName entries. Track whether any were seen.
    var has_identifier_san = false;

    // we check with native code if the cert is valid
    const index = boring.X509_get_ext_by_NID(x509, boring.NID_subject_alt_name, -1);
    if (index >= 0) {
        // we can check hostname
        if (boring.X509_get_ext(x509, index)) |ext| {
            const method = boring.X509V3_EXT_get(ext);
            if (method != boring.X509V3_EXT_get_nid(boring.NID_subject_alt_name)) {
                return false;
            }

            if (host_is_ip) {
                // we safely ensure buffer size with max len + 1
                var canonicalIPBuf: [INET6_ADDRSTRLEN + 1]u8 = undefined;
                var certIPBuf: [INET6_ADDRSTRLEN + 1]u8 = undefined;
                // we try to canonicalize the IP before comparing
                const host_ip = canonicalizeIP(hostname, &canonicalIPBuf) orelse hostname;

                if (boring.X509V3_EXT_d2i(ext)) |names_| {
                    const names: *boring.struct_stack_st_GENERAL_NAME = bun.cast(*boring.struct_stack_st_GENERAL_NAME, names_);
                    defer boring.sk_GENERAL_NAME_pop_free(names, boring.sk_GENERAL_NAME_free);
                    for (0..boring.sk_GENERAL_NAME_num(names)) |i| {
                        const gen = boring.sk_GENERAL_NAME_value(names, i);
                        if (gen) |name| {
                            switch (name.name_type) {
                                .GEN_DNS, .GEN_URI => has_identifier_san = true,
                                .GEN_IPADD => {
                                    has_identifier_san = true;
                                    if (ip2String(name.d.ip, &certIPBuf)) |cert_ip| {
                                        if (strings.eql(host_ip, cert_ip)) {
                                            return true;
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            } else {
                if (boring.X509V3_EXT_d2i(ext)) |names_| {
                    const names: *boring.struct_stack_st_GENERAL_NAME = bun.cast(*boring.struct_stack_st_GENERAL_NAME, names_);
                    defer boring.sk_GENERAL_NAME_pop_free(names, boring.sk_GENERAL_NAME_free);
                    for (0..boring.sk_GENERAL_NAME_num(names)) |i| {
                        const gen = boring.sk_GENERAL_NAME_value(names, i);
                        if (gen) |name| {
                            switch (name.name_type) {
                                .GEN_IPADD, .GEN_URI => has_identifier_san = true,
                                .GEN_DNS => {
                                    has_identifier_san = true;
                                    const dnsName = name.d.dNSName;
                                    const dnsNameSlice = dnsName.data[0..@as(usize, @intCast(dnsName.length))];
                                    if (matchDnsName(dnsNameSlice, hostname)) {
                                        return true;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                }
            }
        }
    }

    // Node.js tls.checkServerIdentity: when the certificate has no
    // DNS/IP/URI subjectAltName entries, fall back to the Subject
    // Common Name. Never for IP-literal hosts (RFC 2818 §3.1).
    if (!host_is_ip and !has_identifier_san) {
        if (boring.X509_get_subject_name(x509)) |subject| {
            var last: c_int = -1;
            while (true) {
                const entry_idx = boring.X509_NAME_get_index_by_NID(subject, boring.NID_commonName, last);
                if (entry_idx < 0) break;
                last = entry_idx;
                const entry = boring.X509_NAME_get_entry(subject, entry_idx) orelse continue;
                const data = boring.X509_NAME_ENTRY_get_data(entry) orelse continue;
                const cn_ptr = boring.ASN1_STRING_get0_data(data);
                const cn_len = boring.ASN1_STRING_length(data);
                if (cn_ptr == null or cn_len <= 0) continue;
                const cn = cn_ptr[0..@intCast(cn_len)];
                if (matchDnsName(cn, hostname)) {
                    return true;
                }
            }
        }
    }

    return false;
}

pub fn checkServerIdentity(
    ssl_ptr: *boring.SSL,
    hostname: []const u8,
) bool {
    if (boring.SSL_get_peer_cert_chain(ssl_ptr)) |cert_chain| {
        if (boring.sk_X509_value(cert_chain, 0)) |x509| {
            return checkX509ServerIdentity(x509, hostname);
        }
    }
    return false;
}

const boring = @import("../boringssl_sys/boringssl.zig");
const c_ares = @import("../cares_sys/c_ares.zig");
const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
