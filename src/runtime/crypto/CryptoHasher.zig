pub const CryptoHasher = struct {
    bindgen_state: bindgen.ClassState = .{},
    state: NativeState,

    const NativeState = union(enum) {
        hmac: ?HMAC,
        evp: EVP,
        zig: CryptoHasherZig,

        fn deinit(state: *NativeState) void {
            switch (state.*) {
                .evp => |*inner| inner.deinit(),
                .zig => |*inner| inner.deinit(),
                .hmac => |*inner| if (inner.*) |*hmac| hmac.deinit(),
            }
        }
    };

    const Digest = EVP.Digest;
    const Binding = bindgen.Class(CryptoHasherClassSchema, CryptoHasher);

    fn create(initial_state: NativeState) bun.OOM!*CryptoHasher {
        var state = initial_state;
        errdefer state.deinit();
        const hasher = try bun.default_allocator.create(CryptoHasher);
        hasher.* = .{ .state = state };
        return hasher;
    }

    pub const Extern = struct {
        const HasherOwner = @typeInfo(@FieldType(bun.bindgen.Return(CryptoHasherGetByNameSchema), "hasher")).optional.child;

        pub const ResolveResult = union(enum) {
            success: *CryptoHasher,
            unsupported,
            failure: u32,
        };

        pub const OperationResult = union(enum) {
            success,
            unsupported,
            failure: u32,
        };

        pub const DigestResult = union(enum) {
            success: u32,
            unsupported,
            output_too_small,
            failure: u32,
        };

        pub fn getByName(engine: *BoringSSL.ENGINE, name: []const u8) bun.OOM!ResolveResult {
            if (CryptoHasherZig.init(name)) |inner| {
                return .{ .success = try CryptoHasher.create(.{ .zig = inner }) };
            }

            const algorithm = EVP.Algorithm.map.get(name) orelse return .unsupported;

            switch (algorithm) {
                .ripemd160,
                .blake2b256,
                .blake2b512,

                .@"sha512-224",
                => {
                    if (algorithm.md()) |md| {
                        return switch (try EVP.init(algorithm, md, engine)) {
                            .success => |evp| .{ .success = try CryptoHasher.create(.{ .evp = evp }) },
                            .failure => |code| .{ .failure = code },
                        };
                    }
                },
                else => return .unsupported,
            }

            return .unsupported;
        }

        pub fn getFromOther(engine: *BoringSSL.ENGINE, other_handle: *CryptoHasher) bun.OOM!ResolveResult {
            switch (other_handle.state) {
                .zig => |other| {
                    return .{ .success = try CryptoHasher.create(.{
                        .zig = other.copy(),
                    }) };
                },
                .evp => |other| {
                    return switch (try other.copy(engine)) {
                        .success => |evp| .{ .success = try CryptoHasher.create(.{ .evp = evp }) },
                        .failure => |code| .{ .failure = code },
                    };
                },
                else => return .unsupported,
            }
        }

        fn destroy(handle: *CryptoHasher) void {
            handle.finalize();
        }

        fn update(handle: *CryptoHasher, input: []const u8) OperationResult {
            switch (handle.state) {
                .zig => |*inner| {
                    inner.update(input);
                    return .success;
                },
                .evp => |*inner| {
                    return switch (inner.update(input)) {
                        .success => .success,
                        .failure => |code| .{ .failure = code },
                    };
                },
                else => return .unsupported,
            }
        }

        pub fn digest(handle: *CryptoHasher, engine: *BoringSSL.ENGINE, digest_buf: []u8) DigestResult {
            if (!isXof(handle) and digest_buf.len < @as(usize, getDigestSize(handle))) return .output_too_small;
            switch (handle.state) {
                .zig => |*inner| {
                    const res = if (inner.isXof()) inner.finalWithLength(digest_buf) else inner.final(digest_buf);
                    return .{ .success = @intCast(res.len) };
                },
                .evp => |*inner| {
                    return switch (inner.finalAndReset(engine, digest_buf)) {
                        .success => |res| .{ .success = @intCast(res.len) },
                        .failure => |code| .{ .failure = code },
                    };
                },
                else => return .unsupported,
            }
        }

        fn getDigestSize(handle: *CryptoHasher) u32 {
            return switch (handle.state) {
                .zig => |inner| inner.digest_length,
                .evp => |inner| inner.size(),
                else => 0,
            };
        }

        fn isXof(handle: *const CryptoHasher) bool {
            return switch (handle.state) {
                .zig => |*inner| inner.isXof(),
                else => false,
            };
        }

        fn bindGetByName(
            _: bun.bindgen.CallContext(CryptoHasherGetByNameSchema),
            args: bun.bindgen.Args(CryptoHasherGetByNameSchema),
        ) bun.JSError!bun.bindgen.Return(CryptoHasherGetByNameSchema) {
            return switch (try getByName(
                bun.current_runtime.boringEngine(),
                args.name.unsafePtr("the C++ caller owns the algorithm-name bytes until synchronous digest lookup returns"),
            )) {
                .success => |hasher| .{
                    .status = .success,
                    .hasher = HasherOwner.initNative(hasher),
                    .errorCode = 0,
                },
                .unsupported => .{
                    .status = .unsupported,
                    .hasher = null,
                    .errorCode = 0,
                },
                .failure => |code| .{
                    .status = .boringssl_error,
                    .hasher = null,
                    .errorCode = code,
                },
            };
        }

        fn bindGetFromOther(
            _: bun.bindgen.CallContext(CryptoHasherGetFromOtherSchema),
            args: bun.bindgen.Args(CryptoHasherGetFromOtherSchema),
        ) bun.JSError!bun.bindgen.Return(CryptoHasherGetFromOtherSchema) {
            return switch (try getFromOther(bun.current_runtime.boringEngine(), args.hasher)) {
                .success => |hasher| .{
                    .status = .success,
                    .hasher = HasherOwner.initNative(hasher),
                    .errorCode = 0,
                },
                .unsupported => .{
                    .status = .unsupported,
                    .hasher = null,
                    .errorCode = 0,
                },
                .failure => |code| .{
                    .status = .boringssl_error,
                    .hasher = null,
                    .errorCode = code,
                },
            };
        }

        fn bindDestroy(
            args: bun.bindgen.Args(CryptoHasherDestroySchema),
        ) bun.bindgen.Return(CryptoHasherDestroySchema) {
            @This().destroy(args.hasher);
        }

        fn bindUpdate(
            args: bun.bindgen.Args(CryptoHasherUpdateSchema),
        ) bun.bindgen.Return(CryptoHasherUpdateSchema) {
            const data = args.data.unsafePtr("the C++ caller owns the input bytes until the synchronous hash update finishes reading them");
            return switch (@This().update(args.hasher, data)) {
                .success => .{ .status = .success, .errorCode = 0 },
                .unsupported => .{ .status = .unsupported, .errorCode = 0 },
                .failure => |code| .{ .status = .boringssl_error, .errorCode = code },
            };
        }

        fn bindDigest(
            _: bun.bindgen.CallContext(CryptoHasherDigestSchema),
            args: bun.bindgen.Args(CryptoHasherDigestSchema),
        ) bun.bindgen.Return(CryptoHasherDigestSchema) {
            const output = args.output.unsafePtr("the C++ caller owns the output buffer until synchronous digest generation finishes writing it");
            return switch (@This().digest(args.hasher, bun.current_runtime.boringEngine(), output)) {
                .success => |length| .{
                    .status = .success,
                    .length = length,
                    .errorCode = 0,
                },
                .unsupported => .{
                    .status = .unsupported,
                    .length = 0,
                    .errorCode = 0,
                },
                .output_too_small => .{
                    .status = .output_too_small,
                    .length = 0,
                    .errorCode = 0,
                },
                .failure => |code| .{
                    .status = .boringssl_error,
                    .length = 0,
                    .errorCode = code,
                },
            };
        }

        fn bindGetDigestSize(
            args: bun.bindgen.Args(CryptoHasherGetDigestSizeSchema),
        ) bun.bindgen.Return(CryptoHasherGetDigestSizeSchema) {
            return getDigestSize(args.hasher);
        }

        fn bindIsXof(
            args: bun.bindgen.Args(CryptoHasherIsXofSchema),
        ) bun.bindgen.Return(CryptoHasherIsXofSchema) {
            return isXof(args.hasher);
        }
    };

    pub fn getByteLength(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherByteLengthSchema),
        _: bindgen.Args(CryptoHasherByteLengthSchema),
    ) bindgen.CallError(CryptoHasherByteLengthSchema)!u16 {
        return @intCast(switch (this.state) {
            .evp => |*inner| inner.size(),
            .hmac => |*inner| if (inner.*) |*hmac| hmac.size() else {
                return context.fail(.hmac_consumed, {});
            },
            .zig => |*inner| inner.digest_length,
        });
    }

    pub fn getAlgorithm(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherAlgorithmSchema),
        _: bindgen.Args(CryptoHasherAlgorithmSchema),
    ) bindgen.CallError(CryptoHasherAlgorithmSchema)!bindgen.DOMString {
        return switch (this.state) {
            inline .evp, .zig => |*inner| bindgen.DOMString.fromUTF8(@tagName(inner.algorithm)),
            .hmac => |inner| if (inner) |hmac| bindgen.DOMString.fromUTF8(@tagName(hmac.algorithm)) else {
                return context.fail(.hmac_consumed, {});
            },
        };
    }

    pub fn getAlgorithms(
        _: bindgen.CallContext(CryptoHasherAlgorithmsSchema),
        _: bindgen.Args(CryptoHasherAlgorithmsSchema),
    ) bun.JSError!bindgen.Return(CryptoHasherAlgorithmsSchema) {
        return try bindgen.Return(CryptoHasherAlgorithmsSchema).fromBunStrings(&EVP.Algorithm.names().values);
    }

    fn hashInto(context: anytype, evp: *EVP, input: NodeTypes.BlobOrStringOrBuffer, output: []u8) bun.bindgen.CallError(@TypeOf(context))![]u8 {
        if (input == .blob and input.blob.isBunFile()) {
            return context.fail(.bun_file_unsupported, {});
        }

        return switch (evp.hash(bun.current_runtime.boringEngine(), input.slice(), output)) {
            .success => |digest_result| digest_result,
            .failure => |code| failBoringSSLError(context, code),
        };
    }

    fn failShortOutputBuffer(context: anytype, size: usize) bun.bindgen.CallError(@TypeOf(context)) {
        const message = try std.fmt.allocPrint(bun.default_allocator, "TypedArray must be at least {d} bytes", .{size});
        defer bun.default_allocator.free(message);
        return context.fail(.short_output_buffer, try bun.bindgen.DOMString.fromUTF8(message));
    }

    fn failUnsupportedAlgorithm(context: anytype, algorithm: []const u8) bun.bindgen.CallError(@TypeOf(context)) {
        const message = try std.fmt.allocPrint(bun.default_allocator, "Unsupported algorithm {s}", .{algorithm});
        defer bun.default_allocator.free(message);
        return context.fail(.unsupported_algorithm, try bun.bindgen.DOMString.fromUTF8(message));
    }

    fn failBoringSSLError(context: anytype, code: u32) bun.bindgen.CallError(@TypeOf(context)) {
        var outbuf: [128 + 1 + "BoringSSL ".len]u8 = undefined;
        @memset(&outbuf, 0);
        outbuf[0.."BoringSSL ".len].* = "BoringSSL ".*;
        const message_buf = outbuf["BoringSSL ".len..];
        _ = BoringSSL.ERR_error_string_n(code, message_buf, message_buf.len);
        const formatted = std.mem.sliceTo(outbuf[0..], 0);
        const message = if (formatted.len == "BoringSSL ".len) brk: {
            break :brk try std.fmt.allocPrint(
                bun.default_allocator,
                "An unknown BoringSSL error occurred: {d}",
                .{code},
            );
        } else formatted;
        defer if (message.ptr != formatted.ptr) bun.default_allocator.free(message);
        return context.fail(.boringssl_error, try bindgen.DOMString.fromUTF8(message));
    }

    fn hashWithOutput(
        context: anytype,
        evp: *EVP,
        input: NodeTypes.BlobOrStringOrBuffer,
        output: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        if (output) |resolved| switch (resolved) {
            .buffer => |view| {
                const size = evp.size();
                const bytes = view.unsafeMutPtr("the generated entry frame owns the destination lease until digest generation finishes writing");
                if (bytes.len < size) {
                    return failShortOutputBuffer(context, size);
                }
                _ = try hashInto(context, evp, input, bytes[0..size]);
                return .{ .pass_through = view.source() };
            },
            .string => |view| {
                const encoding = try bindingOutputEncoding(context, view);
                var output_digest: Digest = undefined;
                const bytes = try hashInto(context, evp, input, &output_digest);
                return encodeHashOutput(bun.bindgen.Return(@TypeOf(context)), bytes, encoding);
            },
        };

        var output_digest: Digest = undefined;
        return .{ .node_buffer = try bindgen.OwnedBytes.fromSlice(try hashInto(context, evp, input, &output_digest)) };
    }

    fn hashByName(
        context: anytype,
        algorithm: []const u8,
        input: NodeTypes.BlobOrStringOrBuffer,
        output: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        switch (try EVP.resolveByName(bun.current_runtime.boringEngine(), algorithm)) {
            .success => |resolved| {
                var evp = resolved;
                defer evp.deinit();
                return hashWithOutput(context, &evp, input, output);
            },
            .failure => |code| return failBoringSSLError(context, code),
            .unsupported => {},
        }

        return try CryptoHasherZig.hashByName(context, algorithm, input, output) orelse {
            const message = try std.fmt.allocPrint(bun.default_allocator, "Unsupported algorithm \"{s}\"", .{algorithm});
            defer bun.default_allocator.free(message);
            return context.fail(.unsupported_algorithm, try bun.bindgen.DOMString.fromUTF8(message));
        };
    }

    pub fn hash(
        context: bindgen.CallContext(CryptoHasherHashSchema),
        args: bindgen.Args(CryptoHasherHashSchema),
    ) bindgen.CallError(CryptoHasherHashSchema)!bindgen.Return(CryptoHasherHashSchema) {
        const algorithm_slice = try args.algorithm.toUTF8(bun.default_allocator);
        defer algorithm_slice.deinit();

        const input_arg = args.input orelse
            return context.fail(.missing_input, {});
        const input = try NodeTypes.BlobOrStringOrBuffer.fromBindgen(input_arg, .utf8);
        defer input.deinit();

        return hashByName(context, algorithm_slice.slice(), input, args.output);
    }

    pub fn construct(
        context: bindgen.CallContext(CryptoHasherConstructorSchema),
        args: bindgen.Args(CryptoHasherConstructorSchema),
    ) bindgen.CallError(CryptoHasherConstructorSchema)!*CryptoHasher {
        const optional_algorithm = args.algorithm orelse {
            return context.fail(.missing_algorithm, {});
        };
        const algorithm_arg = optional_algorithm orelse {
            return context.fail(.algorithm_not_string, {});
        };
        const algorithm = try algorithm_arg.toUTF8(bun.default_allocator);
        defer algorithm.deinit();

        if (algorithm.slice().len == 0) {
            return context.fail(.invalid_algorithm_name, {});
        }

        var hmac_key: ?NodeTypes.StringOrBuffer = null;
        defer if (hmac_key) |*key| {
            key.deinit();
        };
        if (args.key) |key| {
            hmac_key = try NodeTypes.StringOrBuffer.fromBindgen(key, .utf8);
        }

        return CryptoHasher.create(brk: {
            if (hmac_key) |*key| {
                const chosen_algorithm = EVP.Algorithm.map.getWithEql(
                    algorithm.slice(),
                    bun.strings.eqlCaseInsensitiveASCIIIgnoreLength,
                ) orelse return failUnsupportedAlgorithm(context, algorithm.slice());

                break :brk .{
                    .hmac = switch (try HMAC.init(chosen_algorithm, key.slice())) {
                        .success => |hmac| hmac,
                        .failure => |code| return failBoringSSLError(context, code),
                        .unsupported => return context.fail(.hmac_unsupported, {}),
                    },
                };
            }

            switch (try EVP.resolveByName(bun.current_runtime.boringEngine(), algorithm.slice())) {
                .success => |evp| break :brk .{ .evp = evp },
                .failure => |code| return failBoringSSLError(context, code),
                .unsupported => {},
            }
            if (CryptoHasherZig.init(algorithm.slice())) |zig| break :brk .{ .zig = zig };
            return failUnsupportedAlgorithm(context, algorithm.slice());
        });
    }

    pub fn update(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherUpdateMemberSchema),
        args: bindgen.Args(CryptoHasherUpdateMemberSchema),
    ) bindgen.CallError(CryptoHasherUpdateMemberSchema)!bindgen.Return(CryptoHasherUpdateMemberSchema) {
        const input_arg = args.input orelse
            return context.fail(.missing_input, {});

        var encoding_text = bun.String.Slice.empty;
        defer encoding_text.deinit();
        const encoding: NodeTypes.Encoding = encoding: {
            const converted = args.encoding orelse break :encoding .utf8;
            const view = switch (converted) {
                .string => |view| view,
                .ignored => break :encoding .utf8,
            };
            encoding_text = try view.toUTF8(bun.default_allocator);
            break :encoding NodeTypes.Encoding.from(encoding_text.slice()) orelse .utf8;
        };

        if (encoding == .hex) switch (input_arg) {
            .string => |view| if (view.length() % 2 != 0) {
                const message = try std.fmt.allocPrint(
                    bun.default_allocator,
                    "The argument 'encoding' is invalid for data of length {d}. Received '{s}'",
                    .{ view.length(), encoding_text.slice() },
                );
                defer bun.default_allocator.free(message);
                return context.fail(.invalid_input_encoding, try bindgen.DOMString.fromUTF8(message));
            },
            else => {},
        };

        const buffer = try NodeTypes.BlobOrStringOrBuffer.fromBindgen(input_arg, encoding);
        defer buffer.deinit();
        if (buffer == .blob and buffer.blob.isBunFile()) {
            return context.fail(.bun_file_unsupported, {});
        }

        switch (this.state) {
            .evp => |*inner| {
                switch (inner.update(buffer.slice())) {
                    .success => {},
                    .failure => |code| return failBoringSSLError(context, code),
                }
            },
            .hmac => |*inner| {
                const hmac = if (inner.*) |*value| value else {
                    return context.fail(.hmac_consumed, {});
                };

                switch (hmac.update(buffer.slice())) {
                    .success => {},
                    .failure => |code| return failBoringSSLError(context, code),
                }
            },
            .zig => |*inner| {
                inner.update(buffer.slice());
                return args.bindingThis.toOwned();
            },
        }

        return args.bindingThis.toOwned();
    }

    pub fn copy(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherCopySchema),
        _: bindgen.Args(CryptoHasherCopySchema),
    ) bindgen.CallError(CryptoHasherCopySchema)!bindgen.Return(CryptoHasherCopySchema) {
        const copied: NativeState = switch (this.state) {
            .evp => |*inner| .{ .evp = switch (try inner.copy(bun.current_runtime.boringEngine())) {
                .success => |evp| evp,
                .failure => |code| return failBoringSSLError(context, code),
            } },
            .hmac => |*inner| brk: {
                const hmac = if (inner.*) |*value| value else {
                    return context.fail(.hmac_consumed, {});
                };
                break :brk .{
                    .hmac = switch (try hmac.copy()) {
                        .success => |copy_result| copy_result,
                        .failure => |code| return failBoringSSLError(context, code),
                    },
                };
            },
            .zig => |*inner| .{ .zig = inner.copy() },
        };
        const native = try CryptoHasher.create(copied);
        return Binding.adoptResult(native, context);
    }

    pub fn digest(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherDigestMemberSchema),
        args: bindgen.Args(CryptoHasherDigestMemberSchema),
    ) bindgen.CallError(CryptoHasherDigestMemberSchema)!bindgen.Return(CryptoHasherDigestMemberSchema) {
        const digest_size = this.digestSize() orelse
            return context.fail(.hmac_consumed, {});
        if (args.output) |output| switch (output) {
            .string => |view| {
                return this.digestToEncoding(context, try bindingOutputEncoding(context, view));
            },
            .buffer => |view| {
                const bytes = view.unsafeMutPtr("the generated entry frame owns the destination lease until digest generation finishes writing");
                if (bytes.len < digest_size) {
                    return failShortOutputBuffer(context, digest_size);
                }
                _ = try this.final(context, bytes);
                return .{ .pass_through = view.source() };
            },
        };

        var output_digest: EVP.Digest = std.mem.zeroes(EVP.Digest);
        const result = try this.final(context, &output_digest);
        return .{ .node_buffer = try bindgen.OwnedBytes.fromSlice(result) };
    }

    fn digestToEncoding(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherDigestMemberSchema),
        encoding: NodeTypes.Encoding,
    ) bindgen.CallError(CryptoHasherDigestMemberSchema)!bindgen.Return(CryptoHasherDigestMemberSchema) {
        var output_digest_buf: EVP.Digest = std.mem.zeroes(EVP.Digest);
        const output_digest_slice: []u8 = &output_digest_buf;
        const out = try this.final(context, output_digest_slice);
        return encodeHashOutput(bindgen.Return(CryptoHasherDigestMemberSchema), out, encoding);
    }

    fn digestSize(this: *const CryptoHasher) ?u16 {
        return switch (this.state) {
            .hmac => |*inner| if (inner.*) |*hmac| @intCast(hmac.size()) else null,
            .evp => |*inner| inner.size(),
            .zig => |*inner| inner.digest_length,
        };
    }

    fn final(
        this: *CryptoHasher,
        context: bindgen.CallContext(CryptoHasherDigestMemberSchema),
        output_digest_slice: []u8,
    ) bindgen.CallError(CryptoHasherDigestMemberSchema)![]u8 {
        return switch (this.state) {
            .hmac => |*inner| brk: {
                var hmac = inner.* orelse {
                    return context.fail(.hmac_consumed, {});
                };
                inner.* = null;
                defer hmac.deinit();
                break :brk switch (hmac.final(output_digest_slice)) {
                    .success => |digest_result| digest_result,
                    .failure => |code| return failBoringSSLError(context, code),
                };
            },
            .evp => |*inner| switch (inner.finalAndReset(bun.current_runtime.boringEngine(), output_digest_slice)) {
                .success => |digest_result| digest_result,
                .failure => |code| return failBoringSSLError(context, code),
            },
            .zig => |*inner| inner.final(output_digest_slice),
        };
    }

    fn deinit(this: *CryptoHasher) void {
        this.state.deinit();
        bun.destroy(this);
    }

    pub fn finalize(this: *CryptoHasher) void {
        this.deinit();
    }

    pub fn destroy(this: *CryptoHasher) void {
        this.deinit();
    }
};

fn bindingOutputEncoding(context: anytype, view: anytype) bun.bindgen.CallError(@TypeOf(context))!NodeTypes.Encoding {
    const text = try view.toUTF8(bun.default_allocator);
    defer text.deinit();
    return NodeTypes.Encoding.from(text.slice()) orelse {
        const message = try bun.String.createFormat("Unknown encoding: {s}", .{text.slice()});
        return context.fail(.invalid_encoding, try bindgen.DOMString.fromBunString(message));
    };
}

fn encodeHashOutput(
    comptime Result: type,
    bytes: []const u8,
    encoding: NodeTypes.Encoding,
) bun.OOM!Result {
    if (encoding == .buffer) {
        return .{ .node_buffer = try bindgen.OwnedBytes.fromSlice(bytes) };
    }
    return .{
        .text = try bindgen.DOMString.fromBunString(
            webcore_encoding.toBunString(bytes, encoding),
        ),
    };
}

const CryptoHasherZig = struct {
    algorithm: EVP.Algorithm,
    state: union(enum) {
        shake128: std.crypto.hash.sha3.Shake128,
        shake256: std.crypto.hash.sha3.Shake256,
        blake2s256: std.crypto.hash.blake2.Blake2s256,
    },
    digest_length: u8,

    const algo_map = [_]struct { string, type }{
        .{ "shake128", std.crypto.hash.sha3.Shake128 },
        .{ "shake256", std.crypto.hash.sha3.Shake256 },
        .{ "blake2s256", std.crypto.hash.blake2.Blake2s256 },
    };

    inline fn digestLength(Algorithm: type) comptime_int {
        return switch (Algorithm) {
            std.crypto.hash.sha3.Shake128 => 16,
            std.crypto.hash.sha3.Shake256 => 32,
            else => Algorithm.digest_length,
        };
    }

    pub fn hashByName(
        context: anytype,
        algorithm: []const u8,
        input: NodeTypes.BlobOrStringOrBuffer,
        output: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!?bun.bindgen.Return(@TypeOf(context)) {
        inline for (algo_map) |item| {
            if (bun.strings.eqlComptime(algorithm, item[0])) {
                return try hashByNameInner(context, item[1], input, output);
            }
        }
        return null;
    }

    fn hashByNameInner(
        context: anytype,
        comptime Algorithm: type,
        input: NodeTypes.BlobOrStringOrBuffer,
        output: anytype,
    ) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
        if (input == .blob and input.blob.isBunFile()) {
            return context.fail(.bun_file_unsupported, {});
        }

        var h = Algorithm.init(.{});
        h.update(input.slice());

        const digest_length_comptime = digestLength(Algorithm);
        if (output) |resolved| switch (resolved) {
            .buffer => |view| {
                const bytes = view.unsafeMutPtr("the generated entry frame owns the destination lease until digest generation finishes writing");
                if (bytes.len < digest_length_comptime) {
                    return CryptoHasher.failShortOutputBuffer(context, digest_length_comptime);
                }
                h.final(bytes[0..digest_length_comptime]);
                return .{ .pass_through = view.source() };
            },
            .string => |view| {
                var out: [digestLength(Algorithm)]u8 = undefined;
                h.final(&out);
                return encodeHashOutput(
                    bun.bindgen.Return(@TypeOf(context)),
                    &out,
                    try bindingOutputEncoding(context, view),
                );
            },
        };

        var out: [digestLength(Algorithm)]u8 = undefined;
        h.final(&out);
        return .{ .node_buffer = try bindgen.OwnedBytes.fromSlice(&out) };
    }

    pub fn init(algorithm: []const u8) ?CryptoHasherZig {
        inline for (algo_map) |item| {
            const name, const T = item;
            if (bun.strings.eqlComptime(algorithm, name)) {
                const handle: CryptoHasherZig = .{
                    .algorithm = @field(EVP.Algorithm, name),
                    .state = @unionInit(@FieldType(CryptoHasherZig, "state"), name, T.init(.{})),
                    .digest_length = digestLength(T),
                };

                return handle;
            }
        }
        return null;
    }

    fn update(self: *CryptoHasherZig, bytes: []const u8) void {
        switch (self.state) {
            inline else => |*state| state.update(bytes),
        }
    }

    fn copy(self: *const CryptoHasherZig) CryptoHasherZig {
        return self.*;
    }

    fn isXof(self: *const CryptoHasherZig) bool {
        return self.algorithm == .shake128 or self.algorithm == .shake256;
    }

    fn final(self: *CryptoHasherZig, output_digest_slice: []u8) []u8 {
        bun.assert(output_digest_slice.len >= self.digest_length);
        return self.finalWithLength(output_digest_slice[0..self.digest_length]);
    }

    fn finalWithLength(self: *CryptoHasherZig, output_digest_slice: []u8) []u8 {
        switch (self.state) {
            inline else => |*state| {
                const T = @TypeOf(state.*);
                if (comptime T == std.crypto.hash.sha3.Shake128 or T == std.crypto.hash.sha3.Shake256) {
                    state.final(output_digest_slice);
                } else {
                    bun.assert(output_digest_slice.len == T.digest_length);
                    state.final(output_digest_slice[0..T.digest_length]);
                }
                state.* = T.init(.{});
                return output_digest_slice;
            },
        }
    }

    fn deinit(self: *CryptoHasherZig) void {
        self.* = undefined;
    }
};

fn StaticCryptoHasher(comptime algorithm: EVP.Algorithm, comptime name: [:0]const u8) type {
    return struct {
        bindgen_state: bindgen.ClassState = .{},
        hashing: EVP,
        digested: bool = false,

        const ThisHasher = @This();
        const ClassSchema = StaticCryptoHasherBindingModule.class(name);
        const ConstructorSchema = ClassSchema.constructor();
        const ByteLengthSchema = ClassSchema.memberKind("byteLength", .getter);
        const DigestSchema = ClassSchema.member("digest");
        const UpdateSchema = ClassSchema.member("update");
        const StaticByteLengthSchema = ClassSchema.memberKind("byteLength", .static_getter);
        const HashSchema = ClassSchema.member("hash");
        const Binding = bindgen.Class(ClassSchema, ThisHasher);

        pub fn getByteLength(
            _: *ThisHasher,
            _: bindgen.CallContext(ByteLengthSchema),
            _: bindgen.Args(ByteLengthSchema),
        ) bun.JSError!u16 {
            return algorithm.digestSize();
        }

        pub fn getByteLengthStatic(
            _: bindgen.CallContext(StaticByteLengthSchema),
            _: bindgen.Args(StaticByteLengthSchema),
        ) bun.JSError!u16 {
            return algorithm.digestSize();
        }

        fn initHasher(context: anytype) bun.bindgen.CallError(@TypeOf(context))!EVP {
            const md = algorithm.md() orelse
                return CryptoHasher.failBoringSSLError(context, 0);
            return switch (try EVP.init(algorithm, md, bun.current_runtime.boringEngine())) {
                .success => |initialized| initialized,
                .failure => |code| CryptoHasher.failBoringSSLError(context, code),
            };
        }

        pub fn hashBound(context: anytype, input_arg: anytype, output: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
            const input = try NodeTypes.BlobOrStringOrBuffer.fromBindgen(input_arg, .utf8);
            defer input.deinit();
            var hasher = try initHasher(context);
            defer hasher.deinit();
            const digest_size = algorithm.digestSize();

            if (output) |resolved| switch (resolved) {
                .buffer => |view| {
                    const bytes = view.unsafeMutPtr("the generated entry frame owns the destination lease until digest generation finishes writing");
                    if (bytes.len < digest_size) {
                        return CryptoHasher.failShortOutputBuffer(context, digest_size);
                    }
                    _ = try CryptoHasher.hashInto(context, &hasher, input, bytes[0..digest_size]);
                    return .{ .pass_through = view.source() };
                },
                .string => |view| {
                    var output_digest: EVP.Digest = undefined;
                    const digest_result = try CryptoHasher.hashInto(context, &hasher, input, &output_digest);
                    return encodeHashOutput(
                        bun.bindgen.Return(@TypeOf(context)),
                        digest_result,
                        try bindingOutputEncoding(context, view),
                    );
                },
            };

            var output_digest: EVP.Digest = undefined;
            const digest_result = try CryptoHasher.hashInto(context, &hasher, input, &output_digest);
            return .{ .uint8_array = try bindgen.OwnedBytes.fromSlice(digest_result) };
        }

        pub fn hash(
            context: bindgen.CallContext(HashSchema),
            args: bindgen.Args(HashSchema),
        ) bindgen.CallError(HashSchema)!bindgen.Return(HashSchema) {
            const input = args.input orelse
                return context.fail(.missing_input, {});
            return hashBound(context, input, args.output);
        }

        pub fn construct(
            context: bindgen.CallContext(ConstructorSchema),
            _: bindgen.Args(ConstructorSchema),
        ) bindgen.CallError(ConstructorSchema)!*ThisHasher {
            var initialized = try initHasher(context);
            errdefer initialized.deinit();
            const this = try bun.default_allocator.create(ThisHasher);
            this.* = .{ .hashing = initialized };
            return this;
        }

        pub fn update(
            this: *ThisHasher,
            context: bindgen.CallContext(UpdateSchema),
            args: bindgen.Args(UpdateSchema),
        ) bindgen.CallError(UpdateSchema)!bindgen.Return(UpdateSchema) {
            if (this.digested) {
                return context.fail(.already_digested, {});
            }
            const input = args.input orelse
                return context.fail(.missing_input, {});
            const buffer = try NodeTypes.BlobOrStringOrBuffer.fromBindgen(input, .utf8);
            defer buffer.deinit();

            if (buffer == .blob and buffer.blob.isBunFile()) {
                return context.fail(.bun_file_unsupported, {});
            }
            switch (this.hashing.update(buffer.slice())) {
                .success => {},
                .failure => |code| return CryptoHasher.failBoringSSLError(context, code),
            }
            return args.bindingThis.toOwned();
        }

        pub fn digest(
            this: *ThisHasher,
            context: bindgen.CallContext(DigestSchema),
            args: bindgen.Args(DigestSchema),
        ) bindgen.CallError(DigestSchema)!bindgen.Return(DigestSchema) {
            if (this.digested) {
                return context.fail(.already_digested, {});
            }

            if (args.output) |output| switch (output) {
                .buffer => |view| {
                    const bytes = view.unsafeMutPtr("the generated entry frame owns the destination lease until digest generation finishes writing");
                    const digest_size = algorithm.digestSize();
                    if (bytes.len < digest_size) {
                        return CryptoHasher.failShortOutputBuffer(context, digest_size);
                    }
                    switch (this.hashing.final(bytes[0..digest_size])) {
                        .success => {},
                        .failure => |code| return CryptoHasher.failBoringSSLError(context, code),
                    }
                    this.digested = true;
                    return .{ .pass_through = view.source() };
                },
                .string => |view| {
                    return this.digestToEncoding(context, try bindingOutputEncoding(context, view));
                },
            };

            var output_digest: EVP.Digest = std.mem.zeroes(EVP.Digest);
            const digest_result = switch (this.hashing.final(&output_digest)) {
                .success => |result| result,
                .failure => |code| return CryptoHasher.failBoringSSLError(context, code),
            };
            this.digested = true;
            return .{ .uint8_array = try bindgen.OwnedBytes.fromSlice(digest_result) };
        }

        fn digestToEncoding(
            this: *@This(),
            context: bindgen.CallContext(DigestSchema),
            encoding: NodeTypes.Encoding,
        ) bindgen.CallError(DigestSchema)!bindgen.Return(DigestSchema) {
            var output_digest_buf: EVP.Digest = std.mem.zeroes(EVP.Digest);
            const digest_result = switch (this.hashing.final(&output_digest_buf)) {
                .success => |result| result,
                .failure => |code| return CryptoHasher.failBoringSSLError(context, code),
            };
            this.digested = true;

            return encodeHashOutput(bindgen.Return(DigestSchema), digest_result, encoding);
        }

        pub fn destroy(this: *ThisHasher) void {
            this.hashing.deinit();
            bun.default_allocator.destroy(this);
        }
    };
}

pub const MD4 = StaticCryptoHasher(.md4, "MD4");
pub const MD5 = StaticCryptoHasher(.md5, "MD5");
pub const SHA1 = StaticCryptoHasher(.sha1, "SHA1");
pub const SHA224 = StaticCryptoHasher(.sha224, "SHA224");
pub const SHA256 = StaticCryptoHasher(.sha256, "SHA256");
pub const SHA384 = StaticCryptoHasher(.sha384, "SHA384");
pub const SHA512 = StaticCryptoHasher(.sha512, "SHA512");
pub const SHA512_256 = StaticCryptoHasher(.@"sha512-256", "SHA512_256");

comptime {
    _ = CryptoHasher.Binding;
    _ = MD4.Binding;
    _ = MD5.Binding;
    _ = SHA1.Binding;
    _ = SHA224.Binding;
    _ = SHA256.Binding;
    _ = SHA384.Binding;
    _ = SHA512.Binding;
    _ = SHA512_256.Binding;
    _ = CryptoHasherGetByNameBinding;
    _ = CryptoHasherGetFromOtherBinding;
    _ = CryptoHasherDestroyBinding;
    _ = CryptoHasherUpdateBinding;
    _ = CryptoHasherDigestBinding;
    _ = CryptoHasherGetDigestSizeBinding;
    _ = CryptoHasherIsXofBinding;
}

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const BoringSSL = bun.BoringSSL.c;
const NodeTypes = @import("../node/types.zig");

const bindgen = bun.bindgen;
const EVP = @import("../../crypto/EVP.zig");
const HMAC = @import("../../crypto/HMAC.zig");
const webcore_encoding = @import("../webcore/encoding.zig");

const CryptoHasherBindingModule = bindgen.Module("CryptoHasher");
const CryptoHasherClassSchema = CryptoHasherBindingModule.class("CryptoHasher");
const CryptoHasherConstructorSchema = CryptoHasherClassSchema.constructor();
const CryptoHasherAlgorithmSchema = CryptoHasherClassSchema.member("algorithm");
const CryptoHasherByteLengthSchema = CryptoHasherClassSchema.member("byteLength");
const CryptoHasherCopySchema = CryptoHasherClassSchema.member("copy");
const CryptoHasherDigestMemberSchema = CryptoHasherClassSchema.member("digest");
const CryptoHasherUpdateMemberSchema = CryptoHasherClassSchema.member("update");
const CryptoHasherAlgorithmsSchema = CryptoHasherClassSchema.member("algorithms");
const CryptoHasherHashSchema = CryptoHasherClassSchema.member("hash");

const StaticCryptoHasherBindingModule = bindgen.Module("StaticCryptoHashers");
const CryptoHasherGetByNameSchema = CryptoHasherBindingModule.nativeExport("cryptoHasherGetByName");
const CryptoHasherGetFromOtherSchema = CryptoHasherBindingModule.nativeExport("cryptoHasherGetFromOther");
const CryptoHasherDestroySchema = CryptoHasherBindingModule.nativeExport("cryptoHasherDestroy");
const CryptoHasherUpdateSchema = CryptoHasherBindingModule.nativeExport("cryptoHasherUpdate");
const CryptoHasherDigestSchema = CryptoHasherBindingModule.nativeExport("cryptoHasherDigest");
const CryptoHasherGetDigestSizeSchema = CryptoHasherBindingModule.nativeExport("cryptoHasherGetDigestSize");
const CryptoHasherIsXofSchema = CryptoHasherBindingModule.nativeExport("cryptoHasherIsXof");
const CryptoHasherGetByNameBinding = bun.bindgen.Fn(CryptoHasherGetByNameSchema, CryptoHasher.Extern.bindGetByName);
const CryptoHasherGetFromOtherBinding = bun.bindgen.Fn(CryptoHasherGetFromOtherSchema, CryptoHasher.Extern.bindGetFromOther);
const CryptoHasherDestroyBinding = bun.bindgen.Fn(CryptoHasherDestroySchema, CryptoHasher.Extern.bindDestroy);
const CryptoHasherUpdateBinding = bun.bindgen.Fn(CryptoHasherUpdateSchema, CryptoHasher.Extern.bindUpdate);
const CryptoHasherDigestBinding = bun.bindgen.Fn(CryptoHasherDigestSchema, CryptoHasher.Extern.bindDigest);
const CryptoHasherGetDigestSizeBinding = bun.bindgen.Fn(CryptoHasherGetDigestSizeSchema, CryptoHasher.Extern.bindGetDigestSize);
const CryptoHasherIsXofBinding = bun.bindgen.Fn(CryptoHasherIsXofSchema, CryptoHasher.Extern.bindIsXof);
