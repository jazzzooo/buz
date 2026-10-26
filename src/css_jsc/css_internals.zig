const TestKind = enum {
    normal,
    minify,
    prefix,
};

const TestCategory = enum {
    /// arg is browsers
    normal,
    /// arg is parser options
    parser_options,
};

pub fn minifyErrorTestWithOptions(
    context: bun.bindgen.CallContext(MinifyErrorTestWithOptionsSchema),
    args: bun.bindgen.Args(MinifyErrorTestWithOptionsSchema),
) bun.bindgen.CallError(MinifyErrorTestWithOptionsSchema)!bun.bindgen.Return(MinifyErrorTestWithOptionsSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.options,
        .minify,
        .parser_options,
    );
}

pub fn minifyTestWithOptions(
    context: bun.bindgen.CallContext(MinifyTestWithOptionsSchema),
    args: bun.bindgen.Args(MinifyTestWithOptionsSchema),
) bun.bindgen.CallError(MinifyTestWithOptionsSchema)!bun.bindgen.Return(MinifyTestWithOptionsSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.options,
        .minify,
        .parser_options,
    );
}

pub fn prefixTestWithOptions(
    context: bun.bindgen.CallContext(PrefixTestWithOptionsSchema),
    args: bun.bindgen.Args(PrefixTestWithOptionsSchema),
) bun.bindgen.CallError(PrefixTestWithOptionsSchema)!bun.bindgen.Return(PrefixTestWithOptionsSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.options,
        .prefix,
        .parser_options,
    );
}

pub fn testWithOptions(
    context: bun.bindgen.CallContext(TestWithOptionsSchema),
    args: bun.bindgen.Args(TestWithOptionsSchema),
) bun.bindgen.CallError(TestWithOptionsSchema)!bun.bindgen.Return(TestWithOptionsSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.options,
        .normal,
        .parser_options,
    );
}

pub fn minifyTest(
    context: bun.bindgen.CallContext(MinifyTestSchema),
    args: bun.bindgen.Args(MinifyTestSchema),
) bun.bindgen.CallError(MinifyTestSchema)!bun.bindgen.Return(MinifyTestSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.targets,
        .minify,
        .normal,
    );
}

pub fn prefixTest(
    context: bun.bindgen.CallContext(PrefixTestSchema),
    args: bun.bindgen.Args(PrefixTestSchema),
) bun.bindgen.CallError(PrefixTestSchema)!bun.bindgen.Return(PrefixTestSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.targets,
        .prefix,
        .normal,
    );
}

pub fn _test(
    context: bun.bindgen.CallContext(TestSchema),
    args: bun.bindgen.Args(TestSchema),
) bun.bindgen.CallError(TestSchema)!bun.bindgen.Return(TestSchema) {
    return testingImpl(
        context,
        args.source,
        args.expected,
        args.targets,
        .normal,
        .normal,
    );
}

pub fn testingImpl(
    context: anytype,
    source_value: anytype,
    expected_value: anytype,
    browser_options: anytype,
    comptime test_kind: TestKind,
    comptime test_category: TestCategory,
) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.DOMString {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try source_value.toUTF8(bun.default_allocator);
    defer source.deinit();
    _ = expected_value;

    var log = bun.logger.Log.init(alloc);
    defer log.deinit();

    var browsers: ?bun.css.targets.Browsers = null;
    const parser_options = parser_options: {
        var opts = bun.css.ParserOptions.default(alloc, &log);
        // if (test_kind == .prefix) break :parser_options opts;

        switch (test_category) {
            .normal => {
                if (browser_options) |targets| browsers = browsersFromOptions(targets);
            },
            .parser_options => {
                if (browser_options) |options| applyParserOptions(&opts, options);
            },
        }

        break :parser_options opts;
    };

    var import_records = bun.BabyList(bun.ImportRecord){};
    switch (bun.css.StyleSheet(bun.css.DefaultAtRule).parse(
        alloc,
        source.slice(),
        parser_options,
        &import_records,
        bun.bundle_v2.Index.invalid,
    )) {
        .result => |ret| {
            var stylesheet, var extra = ret;
            var minify_options: bun.css.MinifyOptions = bun.css.MinifyOptions.default();
            minify_options.targets.browsers = browsers;
            switch (stylesheet.minify(alloc, minify_options, &extra)) {
                .result => {},
                .err => |err| return failFormatted(context, "{f}", .{err.kind}),
            }

            const symbols = bun.ast.Symbol.Map{};
            var local_names = bun.css.LocalsResultsMap{};
            const result = switch (stylesheet.toCss(
                alloc,
                bun.css.PrinterOptions{
                    .minify = switch (test_kind) {
                        .minify => true,
                        .normal => false,
                        .prefix => false,
                    },
                    .targets = .{
                        .browsers = minify_options.targets.browsers,
                    },
                },
                .initOutsideOfBundler(&import_records),
                &local_names,
                &symbols,
            )) {
                .result => |result| result,
                .err => |err| return failFormatted(context, "{f}", .{err.kind}),
            };

            return bun.bindgen.DOMString.fromUTF8(result.code);
        },
        .err => |err| {
            if (log.hasErrors()) {
                return failLog(context, "parsing failed: ", &log);
            }
            return failFormatted(context, "parsing failed: {f}", .{err.kind});
        },
    }
}

fn failFormatted(context: anytype, comptime format: []const u8, args: anytype) bun.bindgen.CallError(@TypeOf(context)) {
    const message = std.fmt.allocPrint(bun.default_allocator, format, args) catch return error.OutOfMemory;
    defer bun.default_allocator.free(message);
    return context.fail(.css_error, try bun.bindgen.DOMString.fromUTF8(message));
}

fn failLog(context: anytype, prefix: []const u8, log: *const bun.logger.Log) bun.bindgen.CallError(@TypeOf(context)) {
    var output = std.Io.Writer.Allocating.init(bun.default_allocator);
    defer output.deinit();
    output.writer.writeAll(prefix) catch return error.OutOfMemory;
    log.printWithEnableAnsiColors(&output.writer, false) catch return error.OutOfMemory;
    return context.fail(.css_error, try bun.bindgen.DOMString.fromUTF8(output.written()));
}

fn applyParserOptions(opts: *bun.css.ParserOptions, options: anytype) void {
    const flags = options.flags orelse return;
    for (0..flags.len()) |index| switch (flags.at(index).?) {
        .deep_selector_combinator => opts.flags.deep_selector_combinator = true,
    };
}

fn browsersFromOptions(options: anytype) bun.css.targets.Browsers {
    return .{
        .android = options.android,
        .chrome = options.chrome,
        .edge = options.edge,
        .firefox = options.firefox,
        .ie = options.ie,
        .ios_saf = options.ios_saf,
        .opera = options.opera,
        .safari = options.safari,
        .samsung = options.samsung,
    };
}

pub fn attrTest(
    context: bun.bindgen.CallContext(AttrTestSchema),
    args: bun.bindgen.Args(AttrTestSchema),
) bun.bindgen.CallError(AttrTestSchema)!bun.bindgen.Return(AttrTestSchema) {
    var arena = bun.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = try args.source.toUTF8(bun.default_allocator);
    defer source.deinit();
    _ = args.expected;

    var targets: bun.css.targets.Targets = .{};
    if (args.targets) |browser_targets| targets.browsers = browsersFromOptions(browser_targets);

    var log = bun.logger.Log.init(alloc);
    defer log.deinit();

    const parser_options = bun.css.ParserOptions.default(alloc, &log);

    var import_records = bun.BabyList(bun.ImportRecord){};
    switch (bun.css.StyleAttribute.parse(alloc, source.slice(), parser_options, &import_records, bun.bundle_v2.Index.invalid)) {
        .result => |stylesheet_| {
            var stylesheet = stylesheet_;
            var minify_options: bun.css.MinifyOptions = bun.css.MinifyOptions.default();
            minify_options.targets = targets;
            stylesheet.minify(alloc, minify_options);

            const result = stylesheet.toCss(
                alloc,
                bun.css.PrinterOptions{
                    .minify = args.minify,
                    .targets = targets,
                },
                .initOutsideOfBundler(&import_records),
            ) catch return error.OutOfMemory;

            return bun.bindgen.DOMString.fromUTF8(result.code);
        },
        .err => |err| {
            if (log.hasAny()) {
                return failLog(context, "parsing failed: ", &log);
            }
            return failFormatted(context, "parsing failed: {f}", .{err.kind});
        },
    }
}

const bun = @import("bun");
const std = @import("std");

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const MinifyErrorTestWithOptionsSchema = InternalTestingBindings.function("cssMinifyErrorTestWithOptions");
const MinifyTestWithOptionsSchema = InternalTestingBindings.function("cssMinifyTestWithOptions");
const PrefixTestWithOptionsSchema = InternalTestingBindings.function("cssPrefixTestWithOptions");
const TestWithOptionsSchema = InternalTestingBindings.function("cssTestWithOptions");
const MinifyTestSchema = InternalTestingBindings.function("cssMinifyTest");
const PrefixTestSchema = InternalTestingBindings.function("cssPrefixTest");
const TestSchema = InternalTestingBindings.function("cssTest");
const AttrTestSchema = InternalTestingBindings.function("cssAttrTest");
const MinifyErrorTestWithOptionsBinding = bun.bindgen.Fn(MinifyErrorTestWithOptionsSchema, minifyErrorTestWithOptions);
const MinifyTestWithOptionsBinding = bun.bindgen.Fn(MinifyTestWithOptionsSchema, minifyTestWithOptions);
const PrefixTestWithOptionsBinding = bun.bindgen.Fn(PrefixTestWithOptionsSchema, prefixTestWithOptions);
const TestWithOptionsBinding = bun.bindgen.Fn(TestWithOptionsSchema, testWithOptions);
const MinifyTestBinding = bun.bindgen.Fn(MinifyTestSchema, minifyTest);
const PrefixTestBinding = bun.bindgen.Fn(PrefixTestSchema, prefixTest);
const TestBinding = bun.bindgen.Fn(TestSchema, _test);
const AttrTestBinding = bun.bindgen.Fn(AttrTestSchema, attrTest);

comptime {
    _ = MinifyErrorTestWithOptionsBinding;
    _ = MinifyTestWithOptionsBinding;
    _ = PrefixTestWithOptionsBinding;
    _ = TestWithOptionsBinding;
    _ = MinifyTestBinding;
    _ = PrefixTestBinding;
    _ = TestBinding;
    _ = AttrTestBinding;
}
