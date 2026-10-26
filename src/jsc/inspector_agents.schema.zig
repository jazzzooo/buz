const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const engine_types = @import("binding_schema_engine_types");
const errors = @import("binding_schema_errors");
const node_http_response = @import("binding_schema_NodeHTTPResponse");

pub const lifecycle_agent = b.nominalHandle("InspectorLifecycleAgent", .{
    .cpp_type = .{ .pointer = &.{ .named = "Inspector::InspectorLifecycleAgent" } },
    .cpp_declarations = &.{.{ .class = "Inspector::InspectorLifecycleAgent" }},
    .access_thread = .vm,
});

pub const test_reporter_agent = b.nominalHandle("InspectorTestReporterAgent", .{
    .cpp_type = .{ .pointer = &.{ .named = "Inspector::InspectorTestReporterAgent" } },
    .cpp_declarations = &.{.{ .class = "Inspector::InspectorTestReporterAgent" }},
    .access_thread = .vm,
});

pub const http_server_agent = b.nominalHandle("InspectorHTTPServerAgent", .{
    .cpp_type = .{ .pointer = &.{ .named = "Inspector::InspectorHTTPServerAgent" } },
    .cpp_declarations = &.{.{ .class = "Inspector::InspectorHTTPServerAgent" }},
    .access_thread = .vm,
});

pub const bun_frontend_dev_server_agent = b.nominalHandle("InspectorBunFrontendDevServerAgent", .{
    .cpp_type = .{ .pointer = &.{ .named = "Inspector::InspectorBunFrontendDevServerAgent" } },
    .cpp_declarations = &.{.{ .class = "Inspector::InspectorBunFrontendDevServerAgent" }},
    .access_thread = .vm,
});

const test_status = b.enumeration("InspectorTestStatus", .{
    b.enumerationValue("pass", "pass"),
    b.enumerationValue("fail", "fail"),
    b.enumerationValue("timeout", "timeout"),
    b.enumerationValue("skip", "skip"),
    b.enumerationValue("todo", "todo"),
    b.enumerationValue("skipped_because_label", "skipped-because-label"),
});

const test_type = b.enumeration("InspectorTestType", .{
    b.enumerationValue("test", "test"),
    b.enumerationValue("describe", "describe"),
});

const http_route_type = b.enumeration("InspectorHTTPRouteType", .{
    b.enumerationValue("other", "default"),
    b.enumerationValue("api", "api"),
    b.enumerationValue("html", "html"),
    b.enumerationValue("static_route", "static"),
});

const http_route = b.dictionary("InspectorHTTPRoute", .{
    b.dictionaryField("routeId", b.int32, .{ .required = true }),
    b.dictionaryField("path", b.dom_string, .{ .required = true }),
    b.dictionaryField("type", http_route_type, .{ .required = true }),
    b.dictionaryField("scriptLine", b.int32, .{ .required = true }),
    b.dictionaryField("filePath", b.dom_string, .{ .required = true }),
    b.dictionaryField("scriptUrl", b.dom_string, .{ .required = true }),
});

const engine_shims = .{
    b.engineShim(
        "inspectorDevServerClientConnected",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("connectionId", b.int32, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerClientDisconnected",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("connectionId", b.int32, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerBundleStart",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("triggerFiles", archetypes.dom_strings, .{}),
        },
        b.none,
        .vm_thread_allocating,
    ),
    b.engineShim(
        "inspectorDevServerBundleComplete",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("durationMs", b.double, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerBundleFailed",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("payload", b.dom_string, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerClientNavigated",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("connectionId", b.int32, .{}),
            b.argument("url", b.dom_string, .{}),
            b.argument("routeBundleId", b.optional(b.int32), .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerClientErrorReported",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("payload", b.dom_string, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerGraphUpdate",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("payload", b.dom_string, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorDevServerConsoleLog",
        .{
            b.argument("agent", bun_frontend_dev_server_agent, .{}),
            b.argument("devServerId", b.int32, .{}),
            b.argument("kind", b.uint8, .{}),
            b.argument("data", b.dom_string, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorLifecycleAgentReportReload",
        .{b.argument("agent", lifecycle_agent, .{})},
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorLifecycleAgentReportError",
        .{
            b.argument("agent", lifecycle_agent, .{}),
            b.argument("message", b.dom_string, .{}),
            b.argument("name", b.dom_string, .{}),
            b.argument("frames", b.sequence(errors.exception_stack_frame), .{}),
            b.argument("sourceLines", b.sequence(errors.exception_source_line), .{}),
        },
        b.none,
        .vm_thread_allocating,
    ),
    b.engineShim(
        "inspectorTestReporterAgentReportTestFound",
        .{
            b.argument("agent", test_reporter_agent, .{}),
            b.argument("callFrame", engine_types.call_frame, .{}),
            b.argument("testId", b.int32, .{}),
            b.argument("name", b.dom_string, .{}),
            b.argument("itemType", test_type, .{}),
            b.argument("parentId", b.int32, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorTestReporterAgentReportTestFoundWithLocation",
        .{
            b.argument("agent", test_reporter_agent, .{}),
            b.argument("testId", b.int32, .{}),
            b.argument("name", b.dom_string, .{}),
            b.argument("itemType", test_type, .{}),
            b.argument("parentId", b.int32, .{}),
            b.argument("sourceURL", b.dom_string, .{}),
            b.argument("line", b.int32, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorTestReporterAgentReportTestStart",
        .{
            b.argument("agent", test_reporter_agent, .{}),
            b.argument("testId", b.int32, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorTestReporterAgentReportTestEnd",
        .{
            b.argument("agent", test_reporter_agent, .{}),
            b.argument("testId", b.int32, .{}),
            b.argument("status", test_status, .{}),
            b.argument("elapsed", b.double, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorHTTPServerAgentNotifyServerStarted",
        .{
            b.argument("agent", http_server_agent, .{}),
            b.argument("serverId", b.int32, .{}),
            b.argument("address", b.dom_string, .{}),
            b.argument("startTime", b.double, .{}),
            b.argument("serverInstance", node_http_response.any_server_handle, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorHTTPServerAgentNotifyServerStopped",
        .{
            b.argument("agent", http_server_agent, .{}),
            b.argument("serverId", b.int32, .{}),
            b.argument("timestamp", b.double, .{}),
        },
        b.none,
        .vm_thread_nonthrowing,
    ),
    b.engineShim(
        "inspectorHTTPServerAgentNotifyServerRoutesUpdated",
        .{
            b.argument("agent", http_server_agent, .{}),
            b.argument("serverId", b.int32, .{}),
            b.argument("hotReloadId", b.int32, .{}),
            b.argument("routes", b.sequence(http_route), .{}),
        },
        b.none,
        .vm_thread_allocating,
    ),
};

const native_exports = .{
    b.nativeExport(
        "setInspectorBunFrontendDevServerAgent",
        .{ b.argument("agent", bun_frontend_dev_server_agent, .{}), b.argument("enabled", b.boolean, .{}) },
        b.none,
    ),
    b.nativeExport(
        "setInspectorTestReporterAgent",
        .{ b.argument("agent", test_reporter_agent, .{}), b.argument("enabled", b.boolean, .{}) },
        b.none,
    ),
    b.nativeExport(
        "setInspectorLifecycleAgent",
        .{ b.argument("agent", lifecycle_agent, .{}), b.argument("enabled", b.boolean, .{}) },
        b.none,
    ),
    b.nativeExport(
        "setInspectorHTTPServerAgent",
        .{ b.argument("agent", http_server_agent, .{}), b.argument("enabled", b.boolean, .{}) },
        b.none,
    ),
};

pub const schema = b.moduleWithDeclarations("inspector_agents", .{}, .{}, engine_shims, native_exports);
