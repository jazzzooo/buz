const b = @import("bindgen_schema");
const deferred_test_location = "the test helper validates its copied source blob before coercing optional coordinates";
const archetypes = @import("binding_schema_archetypes");
const node_fs_stat = @import("binding_schema_NodeFSStat");
const socket = @import("binding_schema_Socket");
const subprocess = @import("binding_schema_Subprocess");
const shell_template = @import("binding_schema_ShellTemplate");

fn valueOrDOMStringPairArguments(
    comptime value: b.Type,
    comptime value_name: []const u8,
    comptime first_name: []const u8,
    comptime second_name: []const u8,
) b.Overloads {
    return b.overloads(.{
        b.overloadCase("value", .{b.argument(value_name, value, .{})}),
        b.overloadCase("strings", .{
            b.argument(first_name, b.dom_string, .{}),
            b.argument(second_name, b.dom_string, .{}),
        }),
    }, .{});
}

const css_browser_targets = b.dictionary("CSSBrowserTargets", .{
    b.dictionaryField("android", b.uint32, .{}),
    b.dictionaryField("chrome", b.uint32, .{}),
    b.dictionaryField("edge", b.uint32, .{}),
    b.dictionaryField("firefox", b.uint32, .{}),
    b.dictionaryField("ie", b.uint32, .{}),
    b.dictionaryField("ios_saf", b.uint32, .{}),
    b.dictionaryField("opera", b.uint32, .{}),
    b.dictionaryField("safari", b.uint32, .{}),
    b.dictionaryField("samsung", b.uint32, .{}),
});

const css_parser_flag = b.enumeration("CSSParserFlag", .{
    b.enumerationValue("deep_selector_combinator", "DEEP_SELECTOR_COMBINATOR"),
});

const css_parser_options = b.dictionary("CSSParserOptions", .{
    b.dictionaryField("flags", b.sequence(css_parser_flag), .{}),
});

const css_testing_errors = b.domainErrors(.{
    b.domainError("css_error", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

fn cssTestingFunction(
    comptime name: []const u8,
    comptime options_name: []const u8,
    comptime options: b.Type,
) b.Function {
    return b.function(
        name,
        .{
            b.argument("source", b.dom_string, .{}),
            b.argument("expected", b.dom_string, .{}),
            b.argument(options_name, options, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.dom_string,
        .{ .backend = .zig, .errors = css_testing_errors, .length = 3, .profile = .exact },
    );
}

const source_map_from_vlq_errors = b.domainErrors(.{
    b.domainError("invalid_input", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "InternalSourceMap.fromVLQ: invalid VLQ input" },
    }),
});

const source_map_to_vlq_errors = b.domainErrors(.{
    b.domainError("invalid_blob", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "InternalSourceMap.toVLQ: invalid blob" },
    }),
});

const source_map_find_errors = b.domainErrors(.{
    b.domainError("invalid_blob", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "InternalSourceMap.find: invalid blob" },
    }),
});

const source_map_mapping = b.dictionary("InternalSourceMapMapping", .{
    b.dictionaryField("generated_line", b.int32, .{ .required = true, .js_name = "generatedLine" }),
    b.dictionaryField("generated_column", b.int32, .{ .required = true, .js_name = "generatedColumn" }),
    b.dictionaryField("original_line", b.int32, .{ .required = true, .js_name = "originalLine" }),
    b.dictionaryField("original_column", b.int32, .{ .required = true, .js_name = "originalColumn" }),
    b.dictionaryField("source_index", b.int32, .{ .required = true, .js_name = "sourceIndex" }),
});

const linear_fifo_errors = b.domainErrors(.{
    b.domainError("invalid_scenario", b.none, .{
        .class = .range_error,
        .message = .{ .literal = "linearFifoOrderedRemoveProbe: invalid scenario" },
    }),
});

const socket_option_errors = b.domainErrors(.{
    b.systemError("system"),
});

const counters_result = b.dictionary("InternalTestingCountersResult", .{
    b.dictionaryField("spawnSync_blocking", b.int32, .{ .required = true }),
    b.dictionaryField("spawn_memfd", b.int32, .{ .required = true }),
});

const active_tasks_result = b.dictionary("InternalTestingActiveTasksResult", .{
    b.dictionaryField("active_tasks", b.size, .{ .required = true, .js_name = "activeTasks" }),
    b.dictionaryField("concurrent_ref", b.int32, .{ .required = true, .js_name = "concurrentRef" }),
    b.dictionaryField("num_polls", b.int32, .{ .required = true, .js_name = "numPolls" }),
});

const transport_live_counts = b.dictionary("InternalTestingTransportLiveCounts", .{
    b.dictionaryField("sessions", b.int32, .{ .required = true }),
    b.dictionaryField("streams", b.int32, .{ .required = true }),
});

const internal_testing_operation_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const patch_diff_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.systemError("system"),
});

const patch_apply_errors = b.domainErrors(.{
    b.domainError("parse_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
    b.systemError("system"),
});

const patch_parse_errors = b.domainErrors(.{
    b.domainError("parse_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const create_memfd_errors = b.domainErrors(.{
    b.domainError("unavailable", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "memfd_create is not implemented on this platform" },
    }),
    b.systemError("system"),
});

const hosted_git_info = b.dictionary("InternalTestingHostedGitInfo", .{
    b.dictionaryField("type", b.dom_string, .{ .required = true }),
    b.dictionaryField("domain", b.dom_string, .{ .required = true }),
    b.dictionaryField("project", b.dom_string, .{ .required = true }),
    b.dictionaryField("user", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("committish", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("default_representation", b.dom_string, .{ .required = true, .js_name = "default" }),
});

const npmrc_result = b.dictionary("InternalTestingNpmrcResult", .{
    b.dictionaryField("default_registry_url", b.dom_string, .{ .required = true }),
    b.dictionaryField("default_registry_token", b.dom_string, .{ .required = true }),
    b.dictionaryField("default_registry_username", b.dom_string, .{ .required = true }),
    b.dictionaryField("default_registry_password", b.dom_string, .{ .required = true }),
    b.dictionaryField("default_registry_email", b.dom_string, .{ .required = true }),
});

const dependency_tag = b.enumeration("InternalTestingDependencyTag", .{
    b.enumerationValueWithOptions("npm", "npm", .{ .native_value = 1 }),
    b.enumerationValueWithOptions("dist_tag", "dist_tag", .{ .native_value = 2 }),
    b.enumerationValueWithOptions("tarball", "tarball", .{ .native_value = 3 }),
    b.enumerationValueWithOptions("folder", "folder", .{ .native_value = 4 }),
    b.enumerationValueWithOptions("symlink", "symlink", .{ .native_value = 5 }),
    b.enumerationValueWithOptions("workspace", "workspace", .{ .native_value = 6 }),
    b.enumerationValueWithOptions("git", "git", .{ .native_value = 7 }),
    b.enumerationValueWithOptions("github", "github", .{ .native_value = 8 }),
    b.enumerationValueWithOptions("catalog", "catalog", .{ .native_value = 9 }),
});

const dependency_dist_tag = b.dictionary("InternalTestingDependencyDistTag", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("tag", b.dom_string, .{ .required = true }),
});
const dependency_folder = b.dictionary("InternalTestingDependencyFolder", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("folder", b.dom_string, .{ .required = true }),
});
const dependency_git = b.dictionary("InternalTestingDependencyGit", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("owner", b.dom_string, .{ .required = true }),
    b.dictionaryField("repo", b.dom_string, .{ .required = true }),
    b.dictionaryField("ref", b.dom_string, .{ .required = true }),
});
const dependency_github = b.dictionary("InternalTestingDependencyGitHub", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("owner", b.dom_string, .{ .required = true }),
    b.dictionaryField("repo", b.dom_string, .{ .required = true }),
    b.dictionaryField("ref", b.dom_string, .{ .required = true }),
});
const dependency_npm = b.dictionary("InternalTestingDependencyNpm", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("version", b.dom_string, .{ .required = true }),
    b.dictionaryField("alias", b.boolean, .{ .required = true }),
});
const dependency_symlink = b.dictionary("InternalTestingDependencySymlink", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("path", b.dom_string, .{ .required = true }),
});
const dependency_workspace = b.dictionary("InternalTestingDependencyWorkspace", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
});
const dependency_tarball_local = b.dictionary("InternalTestingDependencyLocalTarball", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("path", b.dom_string, .{ .required = true }),
});
const dependency_tarball_remote = b.dictionary("InternalTestingDependencyRemoteTarball", .{
    b.dictionaryField("type", dependency_tag, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("url", b.dom_string, .{ .required = true }),
});
const dependency_version = b.unionType("InternalTestingDependencyVersion", .{
    b.unionMember("dist_tag", dependency_dist_tag),
    b.unionMember("folder", dependency_folder),
    b.unionMember("git", dependency_git),
    b.unionMember("github", dependency_github),
    b.unionMember("npm", dependency_npm),
    b.unionMember("symlink", dependency_symlink),
    b.unionMember("workspace", dependency_workspace),
    b.unionMember("tarball_local", dependency_tarball_local),
    b.unionMember("tarball_remote", dependency_tarball_remote),
}, .{ .ordered = true });
const dependency_update_request = b.dictionary("InternalTestingDependencyUpdateRequest", .{
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
    b.dictionaryField("version", dependency_version, .{ .required = true }),
});
const dependency_result = b.unionType("InternalTestingDependencyResult", .{
    b.unionMember("version", dependency_version),
    b.unionMember("update_request", dependency_update_request),
}, .{ .ordered = true });
const dependency_parse_errors = b.domainErrors(.{
    b.domainError("parse_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const stats_result = b.unionType("InternalTestingStatsResult", .{
    b.unionMember("stats", b.plainClassResult(node_fs_stat.stats)),
    b.unionMember("bigint_stats", b.plainClassResult(node_fs_stat.big_int_stats)),
}, .{ .ordered = true });

const socket_pair_errors = b.domainErrors(.{
    b.domainError("unsupported_platform", b.none, .{
        .class = .generic_error,
        .message = .{ .literal = "Not implemented on Windows" },
    }),
    b.systemError("system"),
});

const sigaction_state = b.dictionary("InternalTestingSigactionState", .{
    b.dictionaryField("handler", b.double, .{ .required = true }),
    b.dictionaryField("flags", b.double, .{ .required = true }),
});

const sigaction_layout = b.dictionary("InternalTestingSigactionLayout", .{
    b.dictionaryField("installed", sigaction_state, .{ .required = true }),
    b.dictionaryField("readback", sigaction_state, .{ .required = true }),
    b.dictionaryField("size_of", b.double, .{ .required = true, .js_name = "sizeof" }),
});

const tarball_entry = b.dictionary("InternalTestingTarballEntry", .{
    b.dictionaryField("pathname", b.dom_string, .{ .required = true }),
    b.dictionaryField("kind", b.dom_string, .{ .required = true }),
    b.dictionaryField("perm", b.uint32, .{ .required = true }),
    b.dictionaryField("contents", b.dom_string, .{}),
});

const tarball_result = b.dictionary("InternalTestingTarballResult", .{
    b.dictionaryField("entries", b.sequence(tarball_entry), .{ .required = true }),
    b.dictionaryField("size", b.size, .{ .required = true }),
    b.dictionaryField("shasum", b.dom_string, .{ .required = true }),
    b.dictionaryField("integrity", b.dom_string, .{ .required = true }),
});

const read_tarball_errors = b.domainErrors(.{
    b.domainError("operation_failed", b.dom_string, .{
        .class = .generic_error,
        .message = .payload,
    }),
});

const stdio_stream = b.enumeration("InternalTestingStdioStream", .{
    b.enumerationValue("stdout", "stdout"),
    b.enumerationValue("stderr", "stderr"),
});

const functions = .{
    b.function(
        "parseLockfile",
        .{b.argument("cwd", archetypes.string_like_dom_string, .{})},
        b.dom_string,
        .{
            .backend = .zig,
            .errors = internal_testing_operation_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "parseManifest",
        .{
            b.argument("filename", b.dom_string, .{}),
            b.argument("registry", b.dom_string, .{}),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .errors = internal_testing_operation_errors,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function("openTempDirWithoutSharingDelete", .{}, b.none, .{
        .backend = .zig,
        .length = 1,
        .profile = .exact,
    }),
    b.function("closeTempDirHandle", .{}, b.none, .{ .backend = .zig, .length = 1, .profile = .exact }),
    b.function("createCountersObject", .{}, counters_result, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function("secureContextLiveCount", .{}, b.int64, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function(
        "createStatsForIno",
        .{
            b.argument("ino", archetypes.unsigned_integer_number_or_bigint, .{}),
            archetypes.truthyBoolean("bigint", .{}),
        },
        stats_result,
        .{ .backend = .zig, .length = 2, .profile = .exact },
    ),
    cssTestingFunction("cssTest", "targets", css_browser_targets),
    b.function(
        "cssAttrTest",
        .{
            b.argument("source", b.dom_string, .{}),
            b.argument("expected", b.dom_string, .{}),
            b.argument("minify", b.boolean, .{ .boolean_conversion = .strict_true }),
            b.argument("targets", css_browser_targets, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.dom_string,
        .{ .backend = .zig, .errors = css_testing_errors, .length = 3, .profile = .exact },
    ),
    cssTestingFunction("cssMinifyErrorTestWithOptions", "options", css_parser_options),
    cssTestingFunction("cssMinifyTest", "targets", css_browser_targets),
    cssTestingFunction("cssMinifyTestWithOptions", "options", css_parser_options),
    cssTestingFunction("cssPrefixTest", "targets", css_browser_targets),
    cssTestingFunction("cssPrefixTestWithOptions", "options", css_parser_options),
    cssTestingFunction("cssTestWithOptions", "options", css_parser_options),
    b.function(
        "dependencyFromJS",
        valueOrDOMStringPairArguments(archetypes.dom_string_or_dom_strings, "request", "alias", "name"),
        b.optionalUndefined(dependency_result),
        .{
            .backend = .zig,
            .errors = dependency_parse_errors,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "inferDependencyTag",
        .{b.argument("specifier", archetypes.dom_string_or_ignored, .{ .presence = .optional, .missing = .omitted })},
        b.optionalUndefined(dependency_tag),
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "escapeRegExp",
        .{b.argument("input", b.dom_string, .{})},
        b.dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "escapeRegExpForPackageNameMatching",
        .{b.argument("input", b.dom_string, .{})},
        b.dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function("getActiveTasks", .{}, active_tasks_result, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function(
        "hostedGitFromUrl",
        .{b.argument("url", b.dom_string, .{})},
        b.optional(hosted_git_info),
        .{ .backend = .zig, .errors = internal_testing_operation_errors, .length = 1, .profile = .exact },
    ),
    b.function(
        "hostedGitParseUrl",
        .{b.argument("url", b.dom_string, .{})},
        b.dom_string,
        .{ .backend = .zig, .errors = internal_testing_operation_errors, .length = 1, .profile = .exact },
    ),
    b.function("h2LiveCounts", .{}, transport_live_counts, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function("h3LiveCounts", .{}, transport_live_counts, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function(
        "loadNpmrc",
        .{
            b.argument("contents", b.dom_string, .{}),
            b.argument("env", archetypes.environment_variables, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        npmrc_result,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "parseIni",
        .{b.argument("contents", b.dom_string, .{})},
        b.dom_string,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "createMemfd",
        .{b.argument("size", b.int64, .{})},
        b.int32,
        .{ .backend = .zig, .errors = create_memfd_errors, .length = 1, .profile = .exact },
    ),
    b.function(
        "architectureIsMatch",
        .{b.argument("constraints", archetypes.dom_strings, .{})},
        b.boolean,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "operatingSystemIsMatch",
        .{b.argument("constraints", archetypes.dom_strings, .{})},
        b.boolean,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "readTarball",
        .{b.argument("path", b.dom_string, .{})},
        tarball_result,
        .{
            .backend = .zig,
            .errors = read_tarball_errors,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "applyPatch",
        .{
            b.argument("patch", b.dom_string, .{}),
            b.argument("directory", b.dom_string, .{ .presence = .optional, .missing = .undefined_or_null }),
        },
        b.boolean,
        .{ .backend = .zig, .errors = patch_apply_errors, .length = 2, .profile = .exact },
    ),
    b.function(
        "makePatchDiff",
        .{
            b.argument("oldDirectory", b.dom_string, .{}),
            b.argument("newDirectory", b.dom_string, .{}),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .errors = patch_diff_errors,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "parsePatch",
        .{b.argument("patch", b.dom_string, .{})},
        b.dom_string,
        .{ .backend = .zig, .errors = patch_parse_errors, .length = 1, .profile = .exact },
    ),
    b.function(
        "linearFifoOrderedRemoveProbe",
        .{b.argument("scenario", b.int32, .{})},
        b.sequence(b.uint8),
        .{ .backend = .zig, .errors = linear_fifo_errors, .length = 1, .profile = .exact },
    ),
    b.function(
        "createSocketPair",
        .{},
        b.sequence(b.int32),
        .{ .backend = .zig, .errors = socket_pair_errors, .length = 0, .profile = .exact },
    ),
    b.function(
        "setSocketOptions",
        .{
            b.argument("socket", b.classRef(socket.tcp_socket), .{}),
            b.argument("kind", b.uint8, .{ .integer_conversion = .{ .enforce_range = .{ .min = 1, .max = 2 } } }),
            b.argument("size", b.int32, .{}),
        },
        b.none,
        .{ .backend = .zig, .errors = socket_option_errors, .length = 3, .profile = .exact },
    ),
    b.function("timerClockMs", .{}, b.double, .{
        .backend = .zig,
        .length = 0,
        .profile = .exact,
    }),
    b.function("fileSinkLiveCount", .{}, b.int32, .{ .backend = .zig, .length = 0, .profile = .exact }),
    b.function(
        "shellDisabledOnThisPlatform",
        .{b.argument("name", b.dom_string, .{})},
        b.boolean,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "shellLex",
        .{
            b.argument("strings", shell_template.strings, .{}),
            b.argument("values", shell_template.values, .{}),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .errors = shell_template.errors,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "shellParse",
        .{
            b.argument("strings", shell_template.strings, .{}),
            b.argument("values", shell_template.values, .{}),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .errors = shell_template.errors,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "sourceMapFind",
        .{
            b.argument("blob", b.buffer(.copy), .{}),
            b.argument("line", b.lazy(b.int32), .{
                .presence = .optional,
                .missing = .omitted,
                .integer_conversion = .coerce,
                .deferred_reason = deferred_test_location,
            }),
            b.argument("column", b.lazy(b.int32), .{
                .presence = .optional,
                .missing = .omitted,
                .integer_conversion = .coerce,
                .deferred_reason = deferred_test_location,
            }),
        },
        b.optional(source_map_mapping),
        .{
            .backend = .zig,
            .errors = source_map_find_errors,
            .length = 3,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "sourceMapFromVLQ",
        .{b.argument("vlq", b.dom_string, .{})},
        b.buffer(.copy),
        .{
            .backend = .zig,
            .errors = source_map_from_vlq_errors,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "sourceMapToVLQ",
        .{b.argument("blob", b.buffer(.lease), .{})},
        b.dom_string,
        .{
            .backend = .zig,
            .errors = source_map_to_vlq_errors,
            .length = 1,
            .profile = .exact,
            .missing_required_arguments = .convert_undefined,
        },
    ),
    b.function(
        "toUTF16AllocSentinel",
        .{b.argument("bytes", b.buffer(.lease), .{})},
        b.dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact, .missing_required_arguments = .convert_undefined },
    ),
    b.function(
        "BunString_toThreadSafeRefCountDelta",
        .{},
        b.int32,
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "injectStdioReadError",
        .{
            b.argument("subprocess", b.classRef(subprocess.subprocess), .{}),
            b.argument("stream", stdio_stream, .{}),
        },
        b.boolean,
        .{ .backend = .zig, .length = 2, .profile = .exact },
    ),
    b.function(
        "sigactionLayout",
        .{},
        b.optionalUndefined(sigaction_layout),
        .{ .backend = .zig, .length = 0, .profile = .exact },
    ),
    b.function(
        "translateNtStatusToE",
        .{b.argument("status", b.uint32, .{})},
        archetypes.optional_dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "translateUVErrorToE",
        .{b.argument("code", b.int32, .{})},
        archetypes.optional_dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "sysErrorNameFromLibuv",
        .{b.argument("code", b.int32, .{})},
        archetypes.optional_dom_string,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
    b.function(
        "setSyntheticAllocationLimit",
        .{b.argument("limit", b.int64, .{ .integer_conversion = .coerce })},
        b.size,
        .{ .backend = .zig, .length = 1, .profile = .exact },
    ),
};

pub const schema = b.module("InternalTesting", functions);
