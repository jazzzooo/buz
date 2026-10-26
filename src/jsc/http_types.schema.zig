const b = @import("bindgen_schema");

pub const http_header_name = header_name: {
    @setEvalBranchQuota(200_000);
    const names = .{
        .{ "Accept", "Accept" },
        .{ "AcceptCharset", "Accept-Charset" },
        .{ "AcceptEncoding", "Accept-Encoding" },
        .{ "AcceptLanguage", "Accept-Language" },
        .{ "AcceptRanges", "Accept-Ranges" },
        .{ "AccessControlAllowCredentials", "Access-Control-Allow-Credentials" },
        .{ "AccessControlAllowHeaders", "Access-Control-Allow-Headers" },
        .{ "AccessControlAllowMethods", "Access-Control-Allow-Methods" },
        .{ "AccessControlAllowOrigin", "Access-Control-Allow-Origin" },
        .{ "AccessControlExposeHeaders", "Access-Control-Expose-Headers" },
        .{ "AccessControlMaxAge", "Access-Control-Max-Age" },
        .{ "AccessControlRequestHeaders", "Access-Control-Request-Headers" },
        .{ "AccessControlRequestMethod", "Access-Control-Request-Method" },
        .{ "Age", "Age" },
        .{ "Authorization", "Authorization" },
        .{ "CacheControl", "Cache-Control" },
        .{ "Connection", "Connection" },
        .{ "ContentDisposition", "Content-Disposition" },
        .{ "ContentEncoding", "Content-Encoding" },
        .{ "ContentLanguage", "Content-Language" },
        .{ "ContentLength", "Content-Length" },
        .{ "ContentLocation", "Content-Location" },
        .{ "ContentRange", "Content-Range" },
        .{ "ContentSecurityPolicy", "Content-Security-Policy" },
        .{ "ContentSecurityPolicyReportOnly", "Content-Security-Policy-Report-Only" },
        .{ "ContentType", "Content-Type" },
        .{ "Cookie", "Cookie" },
        .{ "Cookie2", "Cookie2" },
        .{ "CrossOriginEmbedderPolicy", "Cross-Origin-Embedder-Policy" },
        .{ "CrossOriginEmbedderPolicyReportOnly", "Cross-Origin-Embedder-Policy-Report-Only" },
        .{ "CrossOriginOpenerPolicy", "Cross-Origin-Opener-Policy" },
        .{ "CrossOriginOpenerPolicyReportOnly", "Cross-Origin-Opener-Policy-Report-Only" },
        .{ "CrossOriginResourcePolicy", "Cross-Origin-Resource-Policy" },
        .{ "DNT", "DNT" },
        .{ "Date", "Date" },
        .{ "DefaultStyle", "Default-Style" },
        .{ "ETag", "ETag" },
        .{ "Expect", "Expect" },
        .{ "Expires", "Expires" },
        .{ "Host", "Host" },
        .{ "IcyMetaInt", "Icy-Metaint" },
        .{ "IcyMetadata", "Icy-Metadata" },
        .{ "IfMatch", "If-Match" },
        .{ "IfModifiedSince", "If-Modified-Since" },
        .{ "IfNoneMatch", "If-None-Match" },
        .{ "IfRange", "If-Range" },
        .{ "IfUnmodifiedSince", "If-Unmodified-Since" },
        .{ "KeepAlive", "Keep-Alive" },
        .{ "LastEventID", "Last-Event-ID" },
        .{ "LastModified", "Last-Modified" },
        .{ "Link", "Link" },
        .{ "Location", "Location" },
        .{ "Origin", "Origin" },
        .{ "PingFrom", "Ping-From" },
        .{ "PingTo", "Ping-To" },
        .{ "Pragma", "Pragma" },
        .{ "ProxyAuthorization", "Proxy-Authorization" },
        .{ "ProxyConnection", "Proxy-Connection" },
        .{ "Purpose", "Purpose" },
        .{ "Range", "Range" },
        .{ "Referer", "Referer" },
        .{ "ReferrerPolicy", "Referrer-Policy" },
        .{ "Refresh", "Refresh" },
        .{ "ReportTo", "Report-To" },
        .{ "SecFetchDest", "Sec-Fetch-Dest" },
        .{ "SecFetchMode", "Sec-Fetch-Mode" },
        .{ "SecWebSocketAccept", "Sec-WebSocket-Accept" },
        .{ "SecWebSocketExtensions", "Sec-WebSocket-Extensions" },
        .{ "SecWebSocketKey", "Sec-WebSocket-Key" },
        .{ "SecWebSocketProtocol", "Sec-WebSocket-Protocol" },
        .{ "SecWebSocketVersion", "Sec-WebSocket-Version" },
        .{ "ServerTiming", "Server-Timing" },
        .{ "ServiceWorker", "Service-Worker" },
        .{ "ServiceWorkerAllowed", "Service-Worker-Allowed" },
        .{ "ServiceWorkerNavigationPreload", "Service-Worker-Navigation-Preload" },
        .{ "SetCookie", "Set-Cookie" },
        .{ "SetCookie2", "Set-Cookie2" },
        .{ "SourceMap", "Sourcemap" },
        .{ "StrictTransportSecurity", "Strict-Transport-Security" },
        .{ "TE", "TE" },
        .{ "TimingAllowOrigin", "Timing-Allow-Origin" },
        .{ "Trailer", "Trailer" },
        .{ "TransferEncoding", "Transfer-Encoding" },
        .{ "Upgrade", "Upgrade" },
        .{ "UpgradeInsecureRequests", "Upgrade-Insecure-Requests" },
        .{ "UserAgent", "User-Agent" },
        .{ "Vary", "Vary" },
        .{ "Via", "Via" },
        .{ "XContentTypeOptions", "X-Content-Type-Options" },
        .{ "XDNSPrefetchControl", "X-DNS-Prefetch-Control" },
        .{ "XFrameOptions", "X-Frame-Options" },
        .{ "XSourceMap", "X-Sourcemap" },
        .{ "XTempTablet", "X-Temp-Tablet" },
        .{ "XXSSProtection", "X-XSS-Protection" },
    };
    var values: [names.len]b.EnumerationValue = undefined;
    for (names, 0..) |name, index| {
        values[index] = b.enumerationValueWithOptions(name[0], name[1], .{ .native_value = index });
    }
    break :header_name b.enumerationWithOptions("HTTPHeaderName", values, .{
        .cpp_name = "HTTPHeaderName",
        .ascii_case_insensitive = true,
    });
};

pub const uws_response_kind = b.enumeration("UWSResponseKind", .{
    b.enumerationValue("tcp", "tcp"),
    b.enumerationValue("ssl", "ssl"),
    b.enumerationValue("h3", "h3"),
});

pub const uws_app = b.nominalHandle("UWSApp", .{
    .cpp_type = .{ .pointer = &.{ .named = "Bun::UWSAppNative" } },
    .cpp_declarations = &.{.{ .structure = "Bun::UWSAppNative" }},
    .access_thread = .current,
});

pub const uws_socket = b.nominalHandle("UWSSocket", .{
    .cpp_type = .{ .pointer = &.{ .named = "us_socket_t" } },
    .cpp_declarations = &.{.{ .structure = "us_socket_t" }},
    .access_thread = .current,
});

pub const fetch_headers = b.nominalHandle("FetchHeaders", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::FetchHeaders" } },
    .cpp_declarations = &.{.{ .class = "WebCore::FetchHeaders" }},
    .zig_type = "webcore.FetchHeaders",
    .access_thread = .vm,
});

pub const owned_fetch_headers = b.nominalHandle("FetchHeadersOwner", .{
    .cpp_type = .{ .pointer = &.{ .named = "WebCore::FetchHeaders" } },
    .cpp_declarations = &.{.{ .class = "WebCore::FetchHeaders" }},
    .zig_type = "webcore.FetchHeaders",
    .ownership = .owned,
    .cpp_release = "releaseFetchHeaders",
    .access_thread = .vm,
    .destroy_thread = .vm,
});

pub const schema = b.module("http_types", .{});
