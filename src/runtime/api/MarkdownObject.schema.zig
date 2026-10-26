const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");
const std = @import("std");

const autolink_options = b.dictionary("MarkdownAutolinkOptions", .{
    b.dictionaryField("url", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("www", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("email", b.boolean, .{ .boolean_conversion = .truthy }),
});

const autolinks = b.unionType("MarkdownAutolinks", .{
    b.unionMember("enabled", b.boolean),
    b.unionMember("options", autolink_options),
}, .{ .ordered = true });

const heading_options = b.dictionary("MarkdownHeadingOptions", .{
    b.dictionaryField("ids", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("autolink", b.boolean, .{ .boolean_conversion = .truthy }),
});

const headings = b.unionType("MarkdownHeadings", .{
    b.unionMember("enabled", b.boolean),
    b.unionMember("options", heading_options),
}, .{ .ordered = true });

fn booleanOption(
    comptime name: []const u8,
    comptime js_name: []const u8,
    comptime default_value: bool,
) b.DictionaryField {
    return b.dictionaryField(name, b.boolean, .{
        .aliases = if (std.mem.eql(u8, name, js_name)) &.{} else &.{name},
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = default_value },
        .js_name = js_name,
    });
}

const markdown_options = b.dictionary("MarkdownOptions", .{
    b.dictionaryField("autolinks", autolinks, .{}),
    b.dictionaryField("headings", headings, .{}),
    booleanOption("tables", "tables", true),
    booleanOption("strikethrough", "strikethrough", true),
    booleanOption("tasklists", "tasklists", true),
    booleanOption("hard_soft_breaks", "hardSoftBreaks", false),
    booleanOption("wiki_links", "wikiLinks", false),
    booleanOption("underline", "underline", false),
    booleanOption("latex_math", "latexMath", false),
    booleanOption("collapse_whitespace", "collapseWhitespace", false),
    booleanOption("permissive_atx_headers", "permissiveAtxHeaders", false),
    booleanOption("no_indented_code_blocks", "noIndentedCodeBlocks", false),
    booleanOption("no_html_blocks", "noHtmlBlocks", false),
    booleanOption("no_html_spans", "noHtmlSpans", false),
    booleanOption("tag_filter", "tagFilter", false),
    b.dictionaryField("react_version", b.int32, .{
        .integer_conversion = .coerce,
        .js_name = "reactVersion",
    }),
});

const ansi_theme = b.dictionary("MarkdownAnsiTheme", .{
    b.dictionaryField("colors", b.boolean, .{
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = true },
    }),
    b.dictionaryField("hyperlinks", b.boolean, .{
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = false },
    }),
    b.dictionaryField("kitty_graphics", b.boolean, .{
        .aliases = &.{"kitty_graphics"},
        .boolean_conversion = .truthy,
        .default_value = .{ .boolean = false },
        .js_name = "kittyGraphics",
    }),
    b.dictionaryField("light", b.boolean, .{ .boolean_conversion = .truthy }),
    b.dictionaryField("columns", b.uint16, .{
        .default_value = .{ .unsigned = 80 },
        .integer_conversion = .{ .clamp = .{ .min = 0, .max = 65535 } },
    }),
});

const markdown_render_callback = b.callback(
    "MarkdownRenderCallback",
    .{
        b.argument("children", b.dom_string, .{}),
        b.rest("metadata", b.invocation_any),
    },
    archetypes.nullable_dom_string,
    .{ .receiver = null, .profile = .webidl },
);

fn callbackField(comptime name: []const u8) b.DictionaryField {
    return b.dictionaryField(name, markdown_render_callback, .{});
}

const callbacks = b.dictionary("MarkdownCallbacks", .{
    callbackField("heading"),
    callbackField("paragraph"),
    callbackField("blockquote"),
    callbackField("code"),
    callbackField("list"),
    callbackField("listItem"),
    callbackField("hr"),
    callbackField("table"),
    callbackField("thead"),
    callbackField("tbody"),
    callbackField("tr"),
    callbackField("th"),
    callbackField("td"),
    callbackField("html"),
    callbackField("strong"),
    callbackField("emphasis"),
    callbackField("link"),
    callbackField("image"),
    callbackField("codespan"),
    callbackField("strikethrough"),
    callbackField("text"),
});

fn componentField(comptime name: []const u8) b.DictionaryField {
    return b.dictionaryField(name, b.invocation_any, .{});
}

const components = b.dictionary("MarkdownComponents", .{
    componentField("h1"),
    componentField("h2"),
    componentField("h3"),
    componentField("h4"),
    componentField("h5"),
    componentField("h6"),
    componentField("p"),
    componentField("blockquote"),
    componentField("ul"),
    componentField("ol"),
    componentField("li"),
    componentField("pre"),
    componentField("hr"),
    componentField("html"),
    componentField("table"),
    componentField("thead"),
    componentField("tbody"),
    componentField("tr"),
    componentField("th"),
    componentField("td"),
    componentField("em"),
    componentField("strong"),
    componentField("a"),
    componentField("img"),
    componentField("code"),
    componentField("del"),
    componentField("math"),
    componentField("u"),
    componentField("br"),
});

const event_phase = b.enumeration("MarkdownEventPhase", .{
    b.enumerationValue("enter", "enter"),
    b.enumerationValue("leave", "leave"),
    b.enumerationValue("text", "text"),
    b.enumerationValue("raw_text", "rawText"),
    b.enumerationValue("hard_break", "hardBreak"),
});

const event_kind = b.enumeration("MarkdownEventKind", .{
    b.enumerationValue("none", "none"),
    b.enumerationValue("heading", "heading"),
    b.enumerationValue("paragraph", "paragraph"),
    b.enumerationValue("blockquote", "blockquote"),
    b.enumerationValue("code", "code"),
    b.enumerationValue("unordered_list", "unorderedList"),
    b.enumerationValue("ordered_list", "orderedList"),
    b.enumerationValue("list_item", "listItem"),
    b.enumerationValue("horizontal_rule", "horizontalRule"),
    b.enumerationValue("table", "table"),
    b.enumerationValue("table_head", "tableHead"),
    b.enumerationValue("table_body", "tableBody"),
    b.enumerationValue("table_row", "tableRow"),
    b.enumerationValue("table_header_cell", "tableHeaderCell"),
    b.enumerationValue("table_cell", "tableCell"),
    b.enumerationValue("html", "html"),
    b.enumerationValue("emphasis", "emphasis"),
    b.enumerationValue("strong", "strong"),
    b.enumerationValue("link", "link"),
    b.enumerationValue("image", "image"),
    b.enumerationValue("code_span", "codeSpan"),
    b.enumerationValue("strikethrough", "strikethrough"),
    b.enumerationValue("math", "math"),
    b.enumerationValue("math_display", "mathDisplay"),
    b.enumerationValue("wiki_link", "wikiLink"),
    b.enumerationValue("underline", "underline"),
});

const markdown_event = b.dictionary("MarkdownEvent", .{
    b.dictionaryField("phase", event_phase, .{ .required = true }),
    b.dictionaryField("kind", event_kind, .{ .required = true }),
    b.dictionaryField("data", b.uint32, .{ .required = true }),
    b.dictionaryField("primary", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("secondary", b.optional(b.dom_string), .{ .required = true }),
    b.dictionaryField("checked", b.optional(b.boolean), .{ .required = true }),
});

const markdown_events = b.sequence(markdown_event);
const markdown_parse_output = b.dictionary("MarkdownParseOutput", .{
    b.dictionaryField("events", markdown_events, .{ .required = true }),
    b.dictionaryField("legacy", b.boolean, .{ .required = true }),
});

fn optionalArgument(comptime name: []const u8, comptime value_type: b.Type) b.Argument {
    return b.argument(name, value_type, .{
        .presence = .optional,
        .missing = .undefined_or_null,
    });
}

const parse_session_errors = b.domainErrors(.{
    b.domainError("inactive_session", b.none, .{
        .class = .type_error,
        .message = .{ .literal = "Markdown parse session has already been consumed or released" },
    }),
});

const parse_session = b.class(
    "MarkdownParseSession",
    b.constructor(
        .{b.argument("input", archetypes.string_or_buffer, .{})},
        .{ .length = 1 },
    ),
    .{
        b.method(
            "parse",
            .{optionalArgument("options", markdown_options)},
            markdown_parse_output,
            .{
                .length = 1,
                .errors = parse_session_errors,
            },
        ),
        b.method("release", .{}, b.none, .{ .length = 0 }),
    },
    .{},
    .{
        .backend = .zig,
        .identity = .fresh,
        .ownership = .unique,
        .profile = .exact,
        .reference_thread = .vm,
    },
);

const functions = .{
    b.function(
        "html",
        .{
            b.argument("input", archetypes.string_or_buffer, .{}),
            optionalArgument("options", markdown_options),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .length = 1,
            .profile = .exact,
        },
    ),
    b.function(
        "ansi",
        .{
            b.argument("input", archetypes.string_or_buffer, .{}),
            optionalArgument("theme", ansi_theme),
        },
        b.dom_string,
        .{
            .backend = .zig,
            .length = 2,
            .profile = .exact,
        },
    ),
    b.function(
        "render",
        .{
            b.argument("input", archetypes.string_or_buffer, .{}),
            optionalArgument("callbacks", callbacks),
            optionalArgument("options", markdown_options),
        },
        b.dom_string,
        .{
            .backend = .builtin,
            .builtin = "markdownRenderCodeGenerator",
            .length = 3,
            .profile = .exact,
        },
    ),
    b.function(
        "react",
        .{
            b.argument("input", archetypes.string_or_buffer, .{}),
            optionalArgument("components", components),
            optionalArgument("options", markdown_options),
        },
        b.any,
        .{
            .backend = .builtin,
            .builtin = "markdownReactCodeGenerator",
            .length = 3,
            .profile = .exact,
        },
    ),
};

pub const schema = b.moduleWithClasses("MarkdownObject", functions, .{parse_session});
pub const markdown_parse_session = schema.class("MarkdownParseSession");
