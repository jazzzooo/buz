const b = @import("bindgen_schema");
const call_site = @import("binding_schema_CallSite");
const histogram = @import("binding_schema_PerformanceHistogram");
const string_decoder = @import("binding_schema_StringDecoder");
const x509 = @import("binding_schema_X509");

const ordinary = b.SurfaceMemberOptions{ .attributes = .{} };
const non_enumerable = b.SurfaceMemberOptions{
    .attributes = .{ .enumerable = false },
};
const readonly = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false },
};
const readonly_permanent = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};
const tag = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};

fn callSiteMethod(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, call_site.schema.function(name), non_enumerable);
}

const call_site_prototype = b.objectSurface("CallSitePrototype", .{
    callSiteMethod("getThis"),
    callSiteMethod("getTypeName"),
    callSiteMethod("getFunction"),
    callSiteMethod("getFunctionName"),
    callSiteMethod("getMethodName"),
    callSiteMethod("getFileName"),
    callSiteMethod("getLineNumber"),
    callSiteMethod("getColumnNumber"),
    callSiteMethod("getEvalOrigin"),
    callSiteMethod("getScriptNameOrSourceURL"),
    callSiteMethod("isToplevel"),
    callSiteMethod("isEval"),
    callSiteMethod("isNative"),
    callSiteMethod("isConstructor"),
    callSiteMethod("isAsync"),
    callSiteMethod("isPromiseAll"),
    callSiteMethod("getPromiseIndex"),
    callSiteMethod("toString"),
    b.surfaceFunction("toJSON", call_site.schema.function("toJSON"), ordinary),
    b.surfaceSymbolString(.to_string_tag, "CallSite", tag),
}, .{ .installation = .reified });

fn histogramMethod(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, histogram.schema.function(declaration_name), ordinary);
}

fn histogramGetter(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunctionGetter(name, histogram.schema.function(name), readonly);
}

const histogram_prototype = b.objectSurface("JSNodePerformanceHooksHistogramPrototype", .{
    histogramMethod("record", "histogramRecord"),
    histogramMethod("recordDelta", "histogramRecordDelta"),
    histogramMethod("add", "histogramAdd"),
    histogramMethod("reset", "histogramReset"),
    histogramMethod("percentile", "histogramPercentile"),
    histogramMethod("percentileBigInt", "histogramPercentileBigInt"),
    histogramGetter("count"),
    histogramGetter("countBigInt"),
    histogramGetter("min"),
    histogramGetter("minBigInt"),
    histogramGetter("max"),
    histogramGetter("maxBigInt"),
    histogramGetter("mean"),
    histogramGetter("stddev"),
    histogramGetter("exceeds"),
    histogramGetter("exceedsBigInt"),
    histogramGetter("percentiles"),
    histogramGetter("percentilesBigInt"),
    b.surfaceSymbolString(.to_string_tag, "RecordableHistogram", tag),
}, .{ .installation = .reified });

const string_decoder_prototype = b.objectSurface("JSStringDecoderPrototype", .{
    b.surfaceFunctionGetter("lastChar", string_decoder.schema.function("lastChar"), readonly_permanent),
    b.surfaceFunctionGetter("lastNeed", string_decoder.schema.function("lastNeed"), readonly_permanent),
    b.surfaceFunctionGetter("lastTotal", string_decoder.schema.function("lastTotal"), readonly_permanent),
    b.surfaceFunctionGetter("encoding", string_decoder.schema.function("encoding"), readonly_permanent),
    b.surfaceFunction("write", string_decoder.schema.function("write"), ordinary),
    b.surfaceFunction("end", string_decoder.schema.function("end"), ordinary),
    b.surfaceFunction("text", string_decoder.schema.function("text"), ordinary),
    b.surfaceSymbolString(.to_string_tag, "StringDecoder", tag),
}, .{ .installation = .reified });

fn x509Method(comptime property_name: []const u8, comptime declaration_name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(property_name, x509.schema.function(declaration_name), ordinary);
}

fn x509Getter(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunctionGetter(name, x509.schema.function("certificateGetter_" ++ name), readonly);
}

const x509_prototype = b.objectSurface("JSX509CertificatePrototype", .{
    x509Getter("ca"),
    x509Method("checkEmail", "certificateCheckEmail"),
    x509Method("checkHost", "certificateCheckHost"),
    x509Method("checkIP", "certificateCheckIP"),
    x509Method("checkIssued", "certificateCheckIssued"),
    x509Method("checkPrivateKey", "certificateCheckPrivateKey"),
    x509Getter("fingerprint"),
    x509Getter("fingerprint256"),
    x509Getter("fingerprint512"),
    x509Getter("infoAccess"),
    x509Getter("issuer"),
    x509Getter("issuerCertificate"),
    x509Getter("keyUsage"),
    x509Getter("publicKey"),
    x509Getter("raw"),
    x509Getter("serialNumber"),
    x509Getter("subject"),
    x509Getter("subjectAltName"),
    x509Method("toJSON", "certificateToJSON"),
    x509Method("toLegacyObject", "certificateToLegacyObject"),
    x509Method("toString", "certificateToString"),
    x509Getter("validFrom"),
    x509Getter("validFromDate"),
    x509Getter("validTo"),
    x509Getter("validToDate"),
    x509Method("verify", "certificateVerify"),
    b.surfaceSymbolString(.to_string_tag, "X509Certificate", tag),
}, .{ .installation = .reified });

pub const schema = b.moduleWithSurfaces("CorePrototypeSurfaces", .{
    call_site_prototype,
    histogram_prototype,
    string_decoder_prototype,
    x509_prototype,
});
