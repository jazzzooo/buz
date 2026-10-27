const JsCode = []const u8;
const CssAssetId = u64;

fn GraphFileTypes(comptime DevServer: type) type {
    const PackedMap = DevServer.PackedMap;
    const RouteBundle = DevServer.RouteBundle;
    const LineCount = PackedMap.LineCount;
    return struct {
        // The server's incremental graph does not store previously bundled code because there is
        // only one instance of the server. Instead, it stores which module graphs it is a part of.
        // This makes sure that recompilation knows what bundler options to use.
        pub const ServerFile = struct {
            /// Is this file built for the Server graph.
            is_rsc: bool,
            /// Is this file built for the SSR graph.
            is_ssr: bool,
            /// If set, the client graph contains a matching file.
            /// The server
            is_client_component_boundary: bool,
            /// If this file is a route root, the route can be looked up in
            /// the route list. This also stops dependency propagation.
            is_route: bool,
            /// If the file has an error, the failure can be looked up
            /// in the `.failures` map.
            failed: bool,
            /// CSS and Asset files get special handling
            kind: FileKind,

            // `ClientFile` has a separate packed version, but `ServerFile` is already packed.
            // We still need to define a `Packed` type, though, so we can write `File.Packed`
            // regardless of `side`.
            pub const Packed = ServerFile;

            pub fn pack(self: *const ServerFile) Packed {
                return self;
            }

            pub fn unpack(self: Packed) ServerFile {
                return self;
            }

            fn stopsDependencyTrace(self: ServerFile) bool {
                return self.is_client_component_boundary;
            }

            pub fn fileKind(self: *const ServerFile) FileKind {
                return self.kind;
            }
        };

        const Content = union(enum) {
            unknown: void,
            /// When stale, the code is "", otherwise it contains at least one non-whitespace
            /// character, as empty chunks contain at least a function wrapper.
            js: JsCode,
            asset: JsCode,
            /// A CSS root is the first file in a CSS bundle, aka the one that the JS or HTML file
            /// points into.
            ///
            /// There are many complicated rules when CSS files reference each other, none of which
            /// are modelled in IncrementalGraph. Instead, any change to downstream files will find
            /// the CSS root, and queue it for a re-bundle. Additionally, CSS roots only have one
            /// level of imports, as the code in `finalizeBundle` will add all referenced files as
            /// edges directly to the root, creating a flat list instead of a tree. Those downstream
            /// files remaining empty; only present so that invalidation can trace them to this
            /// root.
            css_root: CssAssetId,
            css_child: void,

            const Untagged = std.meta.BareUnion(Content);
        };

        pub const ClientFile = struct {
            content: Content,
            source_map: PackedMap.Shared = .none,
            /// This should always be null if `source_map` is `.some`, since HTML files do not have
            /// source maps.
            html_route_bundle_index: ?RouteBundle.Index = null,
            /// If the file has an error, the failure can be looked up in the `.failures` map.
            failed: bool = false,
            /// For JS files, this is a component root; the server contains a matching file.
            is_hmr_root: bool = false,
            /// This is a file is an entry point to the framework. Changing this will always cause
            /// a full page reload.
            is_special_framework_file: bool = false,

            /// Packed version of `ClientFile`. Don't access fields directly; call `unpack`.
            pub const Packed = struct {
                // Due to padding, using `packed struct` here wouldn't save any space.
                unsafe_packed_data: struct {
                    content: Content.Untagged,
                    source_map: union {
                        some: Shared(*PackedMap),
                        none: struct {
                            line_count: union {
                                some: LineCount,
                                none: void,
                            },
                            html_route_bundle_index: union {
                                some: RouteBundle.Index,
                                none: void,
                            },
                        },
                    },
                    content_tag: std.meta.Tag(Content),
                    source_map_tag: std.meta.Tag(PackedMap.Shared),
                    is_html_route: bool,
                    failed: bool,
                    is_hmr_root: bool,
                    is_special_framework_file: bool,
                },

                pub fn unpack(self: Packed) ClientFile {
                    const data = self.unsafe_packed_data;
                    return .{
                        .content = switch (data.content_tag) {
                            inline else => |tag| @unionInit(
                                Content,
                                @tagName(tag),
                                @field(data.content, @tagName(tag)),
                            ),
                        },
                        .source_map = switch (data.source_map_tag) {
                            .some => .{ .some = data.source_map.some },
                            .none => .none,
                            .line_count => .{ .line_count = data.source_map.none.line_count.some },
                        },
                        .html_route_bundle_index = if (data.is_html_route)
                            data.source_map.none.html_route_bundle_index.some
                        else
                            null,
                        .failed = data.failed,
                        .is_hmr_root = data.is_hmr_root,
                        .is_special_framework_file = data.is_special_framework_file,
                    };
                }

                comptime {
                    if (!Environment.allow_assert) {
                        bun.assert_eql(@sizeOf(@This()), @sizeOf(u64) * 4);
                        bun.assert_eql(@alignOf(@This()), @alignOf([*]u8));
                    }
                }
            };

            pub fn pack(self: *const ClientFile) Packed {
                // HTML files should not have source maps
                assert(self.html_route_bundle_index == null or self.source_map != .some);
                return .{ .unsafe_packed_data = .{
                    .content = switch (std.meta.activeTag(self.content)) {
                        inline else => |tag| @unionInit(
                            Content.Untagged,
                            @tagName(tag),
                            @field(self.content, @tagName(tag)),
                        ),
                    },
                    .source_map = switch (self.source_map) {
                        .some => |map| .{ .some = map },
                        else => .{ .none = .{
                            .line_count = switch (self.source_map) {
                                .line_count => |count| .{ .some = count },
                                else => .{ .none = {} },
                            },
                            .html_route_bundle_index = if (self.html_route_bundle_index) |index|
                                .{ .some = index }
                            else
                                .{ .none = {} },
                        } },
                    },
                    .content_tag = self.content,
                    .source_map_tag = self.source_map,
                    .is_html_route = self.html_route_bundle_index != null,
                    .failed = self.failed,
                    .is_hmr_root = self.is_hmr_root,
                    .is_special_framework_file = self.is_special_framework_file,
                } };
            }

            pub fn kind(self: *const ClientFile) FileKind {
                return switch (self.content) {
                    .unknown => .unknown,
                    .js => .js,
                    .asset => .asset,
                    .css_root, .css_child => .css,
                };
            }

            fn jsCode(self: *const ClientFile) ?[]const u8 {
                return switch (self.content) {
                    .js, .asset => |code| code,
                    else => null,
                };
            }

            inline fn stopsDependencyTrace(_: ClientFile) bool {
                return false;
            }

            pub fn fileKind(self: *const ClientFile) FileKind {
                return self.kind();
            }
        };
    };
}

/// The paradigm of Bake's incremental state is to store a separate list of files
/// than the Graph in bundle_v2. When watch events happen, the bundler is run on
/// the changed files, excluding non-stale files via `isFileStale`.
///
/// Upon bundle completion, both `client_graph` and `server_graph` have their
/// `receiveChunk` methods called with all new chunks, counting the total length
/// needed. A call to `takeJSBundle` joins all of the chunks, resulting in the
/// code to send to client or evaluate on the server.
///
/// Then, `processChunkDependencies` is called on each chunk to update the
/// list of imports. When a change in imports is detected, the dependencies
/// are updated accordingly.
///
/// Since all routes share the two graphs, bundling a new route that shared
/// a module from a previously bundled route will perform the same exclusion
/// behavior that rebuilds use. This also ensures that two routes on the server
/// do not emit duplicate dependencies. By tracing `imports` on each file in
/// the module graph recursively, the full bundle for any given route can
/// be re-materialized (required when pressing Cmd+R after any client update)
///
/// Since source mappings are all relative to their previous mapping, each
/// chunk's mappings can be stored in the graph, and very trivially built into
/// JSON source map files (`createSourceMap`), even after hot updates. The
/// lifetime for these sourcemaps is a bit tricky and depend on the lifetime of
/// of WebSocket connections; see comments in `Assets` for more details.
pub fn WithOwner(comptime DevServer: type, comptime side: BakeCore.Side) type {
    return struct {
        const Self = @This();
        const FileTypes = GraphFileTypes(DevServer);
        const ServerFile = FileTypes.ServerFile;
        const ClientFile = FileTypes.ClientFile;
        const DevAllocator = DevServer.DevAllocator;
        const HotUpdateContext = DevServer.HotUpdateContext;
        const RouteBundle = DevServer.RouteBundle;
        const SerializedFailure = DevServer.SerializedFailure;
        const SourceMapStore = DevServer.SourceMapStore;
        const debug = DevServer.debug;
        const igLog = DevServer.igLog;
        const PackedMap = DevServer.PackedMap;
        const LineCount = PackedMap.LineCount;

        // Unless otherwise mentioned, all data structures use DevServer's allocator.
        // All arrays are indexed by FileIndex, except for `edges`.

        /// Keys are absolute paths for the "file" namespace, or the
        /// pretty-formatted path value that appear in imports. Absolute paths
        /// are stored so the watcher can quickly query and invalidate them.
        /// Key slices are owned by `dev.allocator()`
        bundled_files: bun.StringArrayHashMap(File.Packed),
        /// Track bools for files which are "stale", meaning they should be
        /// re-bundled before being used. Resizing this is usually deferred
        /// until after a bundle, since resizing the bit-set requires an
        /// exact size, instead of the log approach that dynamic arrays use.
        stale_files: std.bit_set.Dynamic,

        // TODO: rename `dependencies` to something that clearly indicates direction.
        // such as "parent" or "consumer"

        /// Start of a file's 'dependencies' linked list. These are the other
        /// files that have imports to this file. Walk this list to discover
        /// what files are to be reloaded when something changes.
        first_dep: std.ArrayList(EdgeIndex.Optional),
        /// Start of a file's 'imports' linked lists. These are the files that
        /// this file imports.
        first_import: std.ArrayList(EdgeIndex.Optional),
        /// `File` objects act as nodes in a directional many-to-many graph,
        /// where edges represent the imports between modules. An 'dependency'
        /// is a file that must to be notified when it `imported` changes. This
        /// is implemented using an array of `Edge` objects that act as linked
        /// list nodes; each file stores the first imports and dependency.
        edges: std.ArrayList(Edge),
        /// Free slots use `next_import` as an intrusive link and have no targets.
        free_edge_head: EdgeIndex.Optional,
        free_edge_count: usize,

        /// Byte length of every file queued for concatenation
        current_chunk_len: usize = 0,
        /// All part contents
        current_chunk_parts: std.ArrayList(switch (side) {
            .client => FileIndex,
            // This memory is allocated by the dev server allocator
            .server => bun.ptr.OwnedIn(
                []const u8,
                DevServer.DevAllocator,
            ),
        }),

        /// Asset IDs, which can be printed as hex in '/_bun/asset/{hash}.css'
        current_css_files: switch (side) {
            .client => std.ArrayList(CssAssetId),
            .server => void,
        },

        /// Source maps for server chunks and the file indices to track which
        /// file each chunk comes from
        current_chunk_source_maps: if (side == .server) std.ArrayList(CurrentChunkSourceMapData) else void = if (side == .server) .empty,

        pub const empty: Self = .{
            .bundled_files = .empty,
            .stale_files = .{},
            .first_dep = .empty,
            .first_import = .empty,

            .edges = .empty,
            .free_edge_head = .none,
            .free_edge_count = 0,

            .current_chunk_len = 0,
            .current_chunk_parts = .empty,

            .current_css_files = if (side == .client) .empty,
            .current_chunk_source_maps = if (side == .server) .empty else {},
        };

        const CurrentChunkSourceMapData = struct {
            file_index: FileIndex,
            source_map: PackedMap.Shared,

            pub fn deinit(self: *CurrentChunkSourceMapData) void {
                self.source_map.deinit();
            }
        };

        pub const File = switch (side) {
            // The server's incremental graph does not store previously bundled
            // code because there is only one instance of the server. Instead,
            // it stores which module graphs it is a part of. This makes sure
            // that recompilation knows what bundler options to use.
            .server => ServerFile,
            .client => ClientFile,
        };

        fn freeFileContent(
            g: *Self,
            key: []const u8,
            file: *File,
            css: enum { unref_css, ignore_css },
        ) void {
            comptime {
                bun.assertf(side == .client, "freeFileContent requires client graph", .{});
            }
            if (file.source_map.take()) |ptr| {
                var ptr_mut = ptr;
                ptr_mut.deinit();
            }
            defer file.content = .unknown;
            switch (file.content) {
                .js, .asset => |code| {
                    g.allocator().free(code);
                },
                .css_root, .css_child => if (css == .unref_css) {
                    g.owner().assets.unrefByPath(key);
                },
                .unknown => {},
            }
        }

        // If this data structure is not clear, see `DirectoryWatchStore.Dep`
        // for a simpler example. It is more complicated here because this
        // structure is two-way.
        pub const Edge = struct {
            /// The file with the import statement
            dependency: FileIndex,
            /// The file the import statement references.
            imported: FileIndex,
            /// Bit 0 is the ordinary graph; bit 1 is the SSR graph.
            targets: u2,

            /// Next edge in the "imports" linked list for the `dependency` file.
            /// Used to iterate through all files that `dependency` imports.
            next_import: EdgeIndex.Optional,

            /// Next edge in the "dependencies" linked list for the `imported` file.
            /// Used to iterate through all files that import `imported`.
            next_dependency: EdgeIndex.Optional,

            /// Previous edge in the "dependencies" linked list for the `imported` file.
            /// Enables bidirectional traversal and efficient removal from the middle of the list.
            prev_dependency: EdgeIndex.Optional,
        };

        /// An index into `bundled_files`, `stale_files`, `first_dep`, `first_import`
        /// Top bits cannot be relied on due to `SerializedFailure.Owner.Packed`
        pub const FileIndex = DevServerCore.FileIndex(side);
        pub const react_refresh_index = if (side == .client) FileIndex.init(0);

        /// An index into `edges`
        pub const EdgeIndex = bun.GenericIndex(u32, Edge);

        pub fn deinit(g: *Self) void {
            const alloc = g.allocator();
            useAllFields(Self, .{
                .bundled_files = {
                    for (g.bundled_files.keys(), g.bundled_files.values()) |k, v| {
                        alloc.free(k);
                        if (comptime side == .client) {
                            var file = v.unpack();
                            g.freeFileContent(k, &file, .ignore_css);
                        }
                    }
                    g.bundled_files.deinit(alloc);
                },
                .stale_files = g.stale_files.deinit(alloc),
                .first_dep = g.first_dep.deinit(alloc),
                .first_import = g.first_import.deinit(alloc),
                .edges = g.edges.deinit(alloc),
                .free_edge_head = {},
                .free_edge_count = {},
                .current_chunk_len = {},
                .current_chunk_parts = {
                    if (comptime side == .server) {
                        for (g.current_chunk_parts.items) |*part| part.deinit();
                    }
                    g.current_chunk_parts.deinit(alloc);
                },
                .current_css_files = if (comptime side == .client) g.current_css_files.deinit(alloc),
                .current_chunk_source_maps = if (side == .server) {
                    for (g.current_chunk_source_maps.items) |*source_map| {
                        source_map.deinit();
                    }
                    g.current_chunk_source_maps.deinit(alloc);
                },
            });
        }

        const MemoryCost = struct {
            graph: usize,
            code: usize,
            source_maps: usize,
        };

        /// Does NOT count @sizeOf(Self)
        pub fn memoryCostDetailed(g: *Self) MemoryCost {
            var graph: usize = 0;
            var code: usize = 0;
            var source_maps: usize = 0;
            graph += DevServer.memoryCostArrayHashMap(g.bundled_files);
            const stale_file_word_count = std.math.divCeil(
                usize,
                g.stale_files.capacity(),
                @bitSizeOf(usize),
            ) catch unreachable;
            graph += stale_file_word_count * @sizeOf(usize);
            graph += DevServer.memoryCostArrayList(g.first_dep);
            graph += DevServer.memoryCostArrayList(g.first_import);
            graph += DevServer.memoryCostArrayList(g.edges);
            graph += DevServer.memoryCostArrayList(g.current_chunk_parts);
            if (comptime side == .client) {
                graph += DevServer.memoryCostArrayList(g.current_css_files);
                for (g.bundled_files.values()) |packed_file| {
                    const file = packed_file.unpack();
                    switch (file.content) {
                        .js, .asset => |code_slice| code += code_slice.len,
                        else => {},
                    }
                    source_maps += file.source_map.memoryCost();
                }
            } else if (side == .server) {
                graph += DevServer.memoryCostArrayList(g.current_chunk_source_maps);
                for (g.current_chunk_source_maps.items) |item| {
                    source_maps += item.source_map.memoryCost();
                }
            }
            return .{
                .graph = graph,
                .code = code,
                .source_maps = source_maps,
            };
        }

        pub fn getFileIndex(g: *const Self, path: []const u8) ?FileIndex {
            return if (g.bundled_files.getIndex(path)) |i| FileIndex.init(@intCast(i)) else null;
        }

        pub fn isStale(g: *const Self, index: FileIndex) bool {
            return index.get() >= g.stale_files.capacity() or g.stale_files.isSet(index.get());
        }

        pub fn markStale(g: *Self, index: FileIndex) void {
            if (index.get() < g.stale_files.capacity()) g.stale_files.set(index.get());
        }

        /// Prefer calling .values() and indexing manually if accessing more than one
        pub fn getFileByIndex(g: *const Self, index: FileIndex) File {
            return g.bundled_files.values()[index.get()].unpack();
        }

        pub fn htmlRouteBundleIndex(g: *const Self, index: FileIndex) RouteBundle.Index {
            return g.getFileByIndex(index).html_route_bundle_index.?;
        }

        /// Tracks a bundled code chunk for cross-bundle chunks,
        /// ensuring it has an entry in `bundled_files`.
        ///
        /// Consumes `content` on success or failure. Allocations precede graph mutation.
        pub fn receiveChunk(
            g: *Self,
            ctx: *HotUpdateContext,
            index: bun.ast.Index,
            content: *DevServer.ChunkContent,
            is_ssr_graph: bool,
        ) !void {
            const dev = g.owner();
            dev.graph_safety_lock.assertLocked();
            defer content.deinit(dev.allocator());

            const path = ctx.sources[index.get()].path;
            const key = path.keyForIncrementalGraph();

            const log = bun.Output.scoped(.IncrementalGraphReceiveChunk, .visible);
            log("receiveChunk({s}, {s})", .{ @tagName(side), key });

            if (Environment.allow_assert) {
                switch (content.*) {
                    .css => {},
                    .js => |js| if (bun.strings.isAllWhitespace(js.code)) {
                        // Should at least contain the function wrapper
                        bun.Output.panic("Empty chunk is impossible: {s} {s}", .{
                            key,
                            switch (side) {
                                .client => "client",
                                .server => if (is_ssr_graph) "ssr" else "server",
                            },
                        });
                    },
                }
            }

            // Dump to filesystem if enabled
            if (bun.FeatureFlags.bake_debugging_features and content.* == .js) if (dev.dump_dir) |dump_dir| {
                DevServer.dumpBundleForChunk(dev, dump_dir, side, key, content.js.code, true, is_ssr_graph);
            };

            const existing_index = g.bundled_files.getIndex(key);
            const previous = if (existing_index) |i| g.bundled_files.values()[i].unpack() else null;
            if (existing_index == null) {
                try g.bundled_files.ensureUnusedCapacity(dev.allocator(), 1);
                try g.first_dep.ensureUnusedCapacity(dev.allocator(), 1);
                try g.first_import.ensureUnusedCapacity(dev.allocator(), 1);
            }
            const owned_key = if (existing_index == null) try dev.allocator().dupe(u8, key) else null;
            errdefer if (owned_key) |owned| dev.allocator().free(owned);

            if (previous) |file| {
                if (file.failed) try dev.incremental_result.failures_removed.ensureUnusedCapacity(dev.allocator(), 1);
            }
            const client_component_boundary = ctx.server_to_client_bitset.isSet(index.get());
            if (side == .server) {
                if (client_component_boundary) {
                    try dev.incremental_result.client_components_added.ensureUnusedCapacity(dev.allocator(), 1);
                } else if (previous != null and previous.?.is_client_component_boundary) {
                    try dev.incremental_result.client_components_removed.ensureUnusedCapacity(dev.allocator(), 1);
                }
            }

            var next_chunk_len = g.current_chunk_len;
            var prepared_source_map: PackedMap.Shared = .none;
            defer prepared_source_map.deinit();
            if (content.* == .js) {
                const js = &content.js;
                next_chunk_len = std.math.add(usize, g.current_chunk_len, js.code.len) catch return error.OutOfMemory;
                try g.current_chunk_parts.ensureUnusedCapacity(dev.allocator(), 1);
                if (side == .server) try g.current_chunk_source_maps.ensureUnusedCapacity(dev.allocator(), 1);

                prepared_source_map = source_map: {
                    if (js.source_map) |*map| {
                        if (map.chunk.buffer.len() > 0 and map.escaped_source.get() != null) {
                            break :source_map .{ .some = try PackedMap.create(&map.chunk, &map.escaped_source) };
                        }
                    }
                    const count = std.math.cast(u32, bun.strings.countChar(js.code, '\n')) orelse return error.OutOfMemory;
                    break :source_map .{ .line_count = .init(count) };
                };
            }

            const gop = g.bundled_files.getOrPutAssumeCapacity(key);
            const file_index = FileIndex.init(@intCast(gop.index));

            if (!gop.found_existing) {
                gop.key_ptr.* = owned_key.?;
                g.first_dep.appendAssumeCapacity(.none);
                g.first_import.appendAssumeCapacity(.none);
            }

            if (g.stale_files.capacity() > gop.index) {
                g.stale_files.unset(gop.index);
            }

            ctx.getCachedIndex(side, index).* = .init(FileIndex.init(@intCast(gop.index)));

            switch (side) {
                .client => {
                    var html_route_bundle_index: ?RouteBundle.Index = null;
                    var is_special_framework_file = false;

                    if (gop.found_existing) {
                        var existing = gop.value_ptr.unpack();

                        // Free the original content + old source map
                        g.freeFileContent(key, &existing, .ignore_css);

                        // Free a failure if it exists
                        if (existing.failed) {
                            const kv = dev.bundling_failures.fetchSwapRemoveAdapted(
                                SerializedFailure.Owner{ .client = file_index },
                                SerializedFailure.ArrayHashAdapter{},
                            ) orelse
                                Output.panic("Missing SerializedFailure in IncrementalGraph", .{});
                            dev.incremental_result.failures_removed.appendAssumeCapacity(kv.key);
                        }

                        // Persist some data
                        html_route_bundle_index = existing.html_route_bundle_index;
                        is_special_framework_file = existing.is_special_framework_file;
                    }

                    gop.value_ptr.* = File.pack(&.{
                        .content = switch (content.*) {
                            // non-root CSS files never get registered in this function
                            .css => |css| .{ .css_root = css },
                            .js => |js| if (ctx.loaders[index.get()].isJavaScriptLike())
                                .{ .js = js.code }
                            else
                                .{ .asset = js.code },
                        },
                        .source_map = prepared_source_map,
                        .html_route_bundle_index = html_route_bundle_index,
                        .is_hmr_root = ctx.server_to_client_bitset.isSet(index.get()),
                        .is_special_framework_file = is_special_framework_file,
                    });
                    prepared_source_map = .none;

                    switch (content.*) {
                        .js => {
                            // Track JavaScript chunks for concatenation
                            g.current_chunk_parts.appendAssumeCapacity(file_index);
                            g.current_chunk_len = next_chunk_len;
                            content.js.code = "";
                        },
                        else => {},
                    }
                },
                .server => {
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{
                            .is_rsc = !is_ssr_graph,
                            .is_ssr = is_ssr_graph,
                            .is_route = false,
                            .is_client_component_boundary = client_component_boundary,
                            .failed = false,
                            .kind = switch (content.*) {
                                .js => .js,
                                .css => .css,
                            },
                        };

                        if (client_component_boundary) {
                            dev.incremental_result.client_components_added.appendAssumeCapacity(file_index);
                        }
                    } else {
                        gop.value_ptr.kind = switch (content.*) {
                            .js => .js,
                            .css => .css,
                        };

                        if (is_ssr_graph) {
                            gop.value_ptr.is_ssr = true;
                        } else {
                            gop.value_ptr.is_rsc = true;
                        }

                        if (ctx.server_to_client_bitset.isSet(index.get())) {
                            gop.value_ptr.is_client_component_boundary = true;
                            dev.incremental_result.client_components_added.appendAssumeCapacity(file_index);
                        } else if (gop.value_ptr.is_client_component_boundary) {
                            const client_graph = &g.owner().client_graph;
                            const client_index = client_graph.getFileIndex(gop.key_ptr.*) orelse
                                Output.panic("Client graph is missing a component boundary", .{});
                            // Client imports may still reach this module without a server boundary.
                            var client_file = client_graph.getFileByIndex(client_index);
                            client_file.is_hmr_root = false;
                            client_graph.bundled_files.values()[client_index.get()] = client_file.pack();
                            gop.value_ptr.is_client_component_boundary = false;

                            dev.incremental_result.client_components_removed.appendAssumeCapacity(file_index);
                        }

                        if (gop.value_ptr.failed) {
                            gop.value_ptr.failed = false;
                            const kv = dev.bundling_failures.fetchSwapRemoveAdapted(
                                SerializedFailure.Owner{ .server = file_index },
                                SerializedFailure.ArrayHashAdapter{},
                            ) orelse
                                Output.panic("Missing failure in IncrementalGraph", .{});
                            dev.incremental_result.failures_removed.appendAssumeCapacity(kv.key);
                        }
                    }
                    if (content.* == .js) {
                        g.current_chunk_parts.appendAssumeCapacity(
                            bun.ptr.OwnedIn([]const u8, DevServer.DevAllocator).fromRawIn(
                                content.js.code,
                                dev.dev_allocator(),
                            ),
                        );
                        content.js.code = "";
                        g.current_chunk_len = next_chunk_len;
                        g.current_chunk_source_maps.appendAssumeCapacity(.{
                            .source_map = prepared_source_map,
                            .file_index = file_index,
                        });
                        prepared_source_map = .none;
                    }
                },
            }
        }

        const PendingEdge = struct {
            edge_index: EdgeIndex.Optional = .none,
            targets: u2 = 0,

            const Map = AutoArrayHashMap(FileIndex, PendingEdge);
        };

        /// Second pass of IncrementalGraph indexing
        /// - Updates dependency information for each file
        /// - Resolves what the HMR roots are
        pub fn processChunkDependencies(
            g: *Self,
            ctx: *HotUpdateContext,
            comptime mode: enum { normal, css },
            bundle_graph_index: bun.ast.Index,
            temp_alloc: Allocator,
        ) bun.OOM!void {
            const log = bun.Output.scoped(.processChunkDependencies, .visible);
            const file_index: FileIndex = ctx.getCachedIndex(side, bundle_graph_index).*.unwrap() orelse
                @panic("unresolved index"); // do not process for failed chunks
            if (mode == .normal and side == .server) {
                if (ctx.server_seen_bit_set.isSet(file_index.get())) return;
            }
            log("index id={d} {f}:", .{
                file_index.get(),
                bun.fmt.quote(g.bundled_files.keys()[file_index.get()]),
            });

            var replaced_targets: u2 = 1;
            if (mode == .normal and side == .server) {
                replaced_targets = 0;
                var source = ctx.server_first_source[file_index.get()];
                while (source.isValid()) {
                    const index = source;
                    replaced_targets |= sourceTargets(ctx, index);
                    source = ctx.server_next_source[index.get()];
                }
                bun.assert(replaced_targets != 0);
            }

            var pending: PendingEdge.Map = .empty;
            defer pending.deinit(temp_alloc);
            {
                var it: ?EdgeIndex = g.first_import.items[file_index.get()].unwrap();
                while (it) |edge_index| {
                    const dep = g.edges.items[edge_index.get()];
                    it = dep.next_import.unwrap();
                    assert(dep.dependency == file_index);
                    try pending.putNoClobber(temp_alloc, dep.imported, .{
                        .targets = dep.targets & ~replaced_targets,
                        .edge_index = edge_index.toOptional(),
                    });
                }
            }

            switch (mode) {
                .normal => if (side == .server) {
                    var source = ctx.server_first_source[file_index.get()];
                    while (source.isValid()) {
                        const index = source;
                        try g.collectChunkImports(ctx, temp_alloc, &pending, index);
                        source = ctx.server_next_source[index.get()];
                    }
                } else {
                    try g.collectChunkImports(ctx, temp_alloc, &pending, bundle_graph_index);
                },
                .css => try g.collectCssImports(ctx, temp_alloc, &pending, bundle_graph_index),
            }

            var added: usize = 0;
            var removed: usize = 0;
            for (pending.values()) |edge| {
                if (edge.targets == 0) {
                    removed += 1;
                } else if (edge.edge_index == .none) {
                    added += 1;
                }
            }
            const append_count = added -| g.free_edge_count;
            const edge_count = std.math.add(usize, g.edges.items.len, append_count) catch return error.OutOfMemory;
            if (edge_count > std.math.maxInt(u32)) return error.OutOfMemory;
            try g.edges.ensureUnusedCapacity(g.allocator(), append_count);
            try ctx.gts.resize(side, temp_alloc, g.bundled_files.count());
            if (!ctx.gts.bits(side).isSet(file_index.get())) try g.reserveDependencyTrace();

            // Clear obsolete import links before recycling any of their slots.
            for (pending.values()) |edge| {
                if (edge.targets == 0) g.edges.items[edge.edge_index.unwrap().?.get()].next_import = .none;
            }
            var new_imports: EdgeIndex.Optional = .none;
            for (pending.keys(), pending.values()) |imported, edge| {
                if (edge.targets == 0) continue;
                const edge_index = edge.edge_index.unwrap() orelse new_edge: {
                    const first_dep = &g.first_dep.items[imported.get()];
                    const created = g.newEdgeAssumeCapacity(.{
                        .next_import = .none,
                        .next_dependency = first_dep.*,
                        .prev_dependency = .none,
                        .imported = imported,
                        .dependency = file_index,
                        .targets = edge.targets,
                    });
                    if (first_dep.*.unwrap()) |next| {
                        g.edges.items[next.get()].prev_dependency = created.toOptional();
                    }
                    first_dep.* = created.toOptional();
                    break :new_edge created;
                };
                g.edges.items[edge_index.get()].targets = edge.targets;
                g.edges.items[edge_index.get()].next_import = new_imports;
                new_imports = edge_index.toOptional();
            }
            g.first_import.items[file_index.get()] = new_imports;

            for (pending.values()) |edge| {
                if (edge.targets == 0) {
                    const edge_index = edge.edge_index.unwrap().?;
                    g.disconnectEdgeFromDependencyList(edge_index);
                    g.freeEdge(edge_index);
                }
            }
            if (added != 0 or removed != 0) g.owner().incremental_result.had_adjusted_edges = true;
            g.traceDependenciesAssumeCapacity(file_index, ctx.gts, .stop_at_boundary, file_index);
            if (mode == .normal and side == .server) ctx.server_seen_bit_set.set(file_index.get());
        }

        /// When we delete an edge, we need to delete it by connecting the
        /// previous dependency (importer) edge to the next depedenency
        /// (importer) edge.
        ///
        /// DO NOT ONLY CALL THIS FUNCTION TO TRY TO DELETE AN EDGE, YOU MUST DELETE
        /// THE IMPORTS TOO!
        fn disconnectEdgeFromDependencyList(g: *Self, edge_index: EdgeIndex) void {
            const edge = &g.edges.items[edge_index.get()];
            const imported = edge.imported.get();
            const log = bun.Output.scoped(.disconnectEdgeFromDependencyList, .hidden);
            log("detach edge={d} | id={d} {f} -> id={d} {f} (first_dep={d})", .{
                edge_index.get(),
                edge.dependency.get(),
                bun.fmt.quote(g.bundled_files.keys()[edge.dependency.get()]),
                imported,
                bun.fmt.quote(g.bundled_files.keys()[edge.imported.get()]),
                if (g.first_dep.items[imported].unwrap()) |first_dep| first_dep.get() else 42069000,
            });

            // Delete this edge by connecting the previous dependency to the
            // next dependency and vice versa
            if (edge.prev_dependency.unwrap()) |prev| {
                const prev_dependency = &g.edges.items[prev.get()];
                prev_dependency.next_dependency = edge.next_dependency;

                if (edge.next_dependency.unwrap()) |next| {
                    const next_dependency = &g.edges.items[next.get()];
                    next_dependency.prev_dependency = edge.prev_dependency;
                }
            } else {
                // If no prev dependency, this better be the first one!
                assert_eql(g.first_dep.items[edge.imported.get()].unwrap(), edge_index);

                // The edge has no prev dependency, but it *might* have a next dependency!
                if (edge.next_dependency.unwrap()) |next| {
                    const next_dependency = &g.edges.items[next.get()];
                    next_dependency.prev_dependency = .none;
                    g.first_dep.items[edge.imported.get()] = next.toOptional();
                } else {
                    g.first_dep.items[edge.imported.get()] = .none;
                }
            }
        }

        fn collectCssImports(
            g: *Self,
            ctx: *HotUpdateContext,
            temp_alloc: Allocator,
            pending: *PendingEdge.Map,
            bundler_index: bun.ast.Index,
        ) !void {
            bun.assert(bundler_index.isValid());
            bun.assert(ctx.loaders[bundler_index.get()].isCSS());

            var sfb_buffer: [64]bun.ast.Index = undefined;
            var sfb: std.heap.BufferFirstAllocator = .init(@ptrCast(&sfb_buffer), temp_alloc);
            const queue_alloc = sfb.allocator();

            var queue: std.ArrayList(bun.ast.Index) = .empty;
            defer queue.deinit(queue_alloc);
            var visited: AutoArrayHashMap(bun.ast.Index, void) = .empty;
            defer visited.deinit(temp_alloc);
            try visited.put(temp_alloc, bundler_index, {});
            try queue.append(queue_alloc, bundler_index);

            while (queue.pop()) |index| {
                for (ctx.import_records[index.get()].slice()) |import_record| {
                    if (try g.collectImport(ctx, temp_alloc, pending, import_record, .css, 1)) |imported| {
                        const entry = try visited.getOrPut(temp_alloc, imported);
                        if (!entry.found_existing) {
                            try queue.append(queue_alloc, imported);
                        }
                    }
                }
            }
        }

        fn collectImport(
            g: *Self,
            ctx: *HotUpdateContext,
            temp_alloc: Allocator,
            pending: *PendingEdge.Map,
            import_record: bun.ImportRecord,
            comptime mode: enum {
                js_or_html,
                css,
            },
            targets: u2,
        ) bun.OOM!?bun.ast.Index {
            if (import_record.flags.is_unused or import_record.source_index.isRuntime()) return null;

            const key = import_record.path.keyForIncrementalGraph();
            const imported_file_index: FileIndex = brk: {
                if (import_record.source_index.isValid()) {
                    if (ctx.getCachedIndex(side, import_record.source_index).*.unwrap()) |i| {
                        break :brk i;
                    } else if (mode == .css) {
                        const kind: FileKind = if (ctx.loaders[import_record.source_index.get()].isCSS()) .css else .asset;
                        const index = (try g.insertEmpty(key, kind)).index;
                        ctx.getCachedIndex(side, import_record.source_index).* = index.toOptional();
                        break :brk index;
                    }
                }

                if (mode == .css) return null;
                break :brk .init(@intCast(g.bundled_files.getIndex(key) orelse return null));
            };

            const entry = try pending.getOrPut(temp_alloc, imported_file_index);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.targets |= targets;
            if (mode == .css and import_record.source_index.isValid() and ctx.loaders[import_record.source_index.get()].isCSS()) {
                return import_record.source_index;
            }
            return null;
        }

        fn sourceTargets(ctx: *const HotUpdateContext, index: bun.ast.Index) u2 {
            return if (side == .server and ctx.targets[index.get()].bakeGraph() == .ssr) 2 else 1;
        }

        fn collectChunkImports(
            g: *Self,
            ctx: *HotUpdateContext,
            temp_alloc: Allocator,
            pending: *PendingEdge.Map,
            index: bun.ast.Index,
        ) !void {
            bun.assert(index.isValid());
            bun.assert(ctx.loaders[index.get()] != .css);
            for (ctx.import_records[index.get()].slice()) |import_record| {
                _ = try g.collectImport(ctx, temp_alloc, pending, import_record, .js_or_html, sourceTargets(ctx, index));
            }
        }

        const TraceDependencyGoal = enum {
            stop_at_boundary,
            no_stop,
        };

        pub fn traceDependencies(
            g: *Self,
            file_index: FileIndex,
            gts: *GraphTraceState,
            goal: TraceDependencyGoal,
            from_file_index: FileIndex,
        ) !void {
            g.owner().graph_safety_lock.assertLocked();
            if (gts.bits(side).isSet(file_index.get())) return;
            try g.reserveDependencyTrace();
            g.traceDependenciesAssumeCapacity(file_index, gts, goal, from_file_index);
        }

        fn reserveDependencyTrace(g: *Self) bun.OOM!void {
            const dev = g.owner();
            const server_count = dev.server_graph.bundled_files.count();
            const client_count = dev.client_graph.bundled_files.count();
            try dev.incremental_result.framework_routes_affected.ensureUnusedCapacity(dev.allocator(), server_count);
            try dev.incremental_result.client_components_affected.ensureUnusedCapacity(dev.allocator(), server_count);
            try dev.incremental_result.html_routes_hard_affected.ensureUnusedCapacity(dev.allocator(), client_count);
            try dev.incremental_result.html_routes_soft_affected.ensureUnusedCapacity(dev.allocator(), client_count);
        }

        fn traceDependenciesAssumeCapacity(
            g: *Self,
            file_index: FileIndex,
            gts: *GraphTraceState,
            goal: TraceDependencyGoal,
            from_file_index: FileIndex,
        ) void {
            if (Environment.enable_logs) {
                igLog("traceDependencies(.{s}, {f}{s})", .{
                    @tagName(side),
                    bun.fmt.quote(g.bundled_files.keys()[file_index.get()]),
                    if (gts.bits(side).isSet(file_index.get())) " [already visited]" else "",
                });
            }

            if (gts.bits(side).isSet(file_index.get()))
                return;
            gts.bits(side).set(file_index.get());

            const file = g.getFileByIndex(file_index);

            switch (side) {
                .server => {
                    const dev = g.owner();
                    if (file.is_route) {
                        const route_index = dev.route_lookup.get(file_index) orelse
                            Output.panic("Route not in lookup index: {d} {f}", .{ file_index.get(), bun.fmt.quote(g.bundled_files.keys()[file_index.get()]) });
                        igLog("\\<- Route", .{});

                        dev.incremental_result.framework_routes_affected.appendAssumeCapacity(route_index);
                    }
                    if (file.is_client_component_boundary) {
                        dev.incremental_result.client_components_affected.appendAssumeCapacity(file_index);
                    }
                },
                .client => {
                    const dev = g.owner();
                    if (file.is_hmr_root) {
                        const key = g.bundled_files.keys()[file_index.get()];
                        const index = dev.server_graph.getFileIndex(key) orelse
                            Output.panic("Server Incremental Graph is missing component for {f}", .{bun.fmt.quote(key)});
                        dev.server_graph.traceDependenciesAssumeCapacity(index, gts, goal, index);
                    } else if (file.html_route_bundle_index) |route_bundle_index| {
                        // If the HTML file itself was modified, or an asset was
                        // modified, this must be a hard reload. Otherwise just
                        // invalidate the script tag.
                        const list = if (from_file_index == file_index or
                            g.getFileByIndex(from_file_index).content == .asset)
                            &dev.incremental_result.html_routes_hard_affected
                        else
                            &dev.incremental_result.html_routes_soft_affected;

                        list.appendAssumeCapacity(route_bundle_index);

                        if (goal == .stop_at_boundary)
                            return;
                    }
                },
            }

            // Certain files do not propagate updates to dependencies.
            // This is how updating a client component doesn't cause
            // a server-side reload.
            if (goal == .stop_at_boundary) {
                if (file.stopsDependencyTrace()) {
                    igLog("\\<- this file stops propagation", .{});
                    return;
                }
            }

            // Recurse
            var it: ?EdgeIndex = g.first_dep.items[file_index.get()].unwrap();
            while (it) |dep_index| {
                const edge = g.edges.items[dep_index.get()];
                it = edge.next_dependency.unwrap();
                g.traceDependenciesAssumeCapacity(
                    edge.dependency,
                    gts,
                    goal,
                    file_index,
                );
            }
        }

        pub fn traceImports(g: *Self, file_index: FileIndex, gts: *GraphTraceState, comptime goal: DevServerCore.TraceImportGoal) !void {
            g.owner().graph_safety_lock.assertLocked();

            if (Environment.enable_logs) {
                igLog("traceImports(.{s}, .{s}, {f}{s})", .{
                    @tagName(side),
                    @tagName(goal),
                    bun.fmt.quote(g.bundled_files.keys()[file_index.get()]),
                    if (gts.bits(side).isSet(file_index.get())) " [already visited]" else "",
                });
            }

            if (gts.bits(side).isSet(file_index.get()))
                return;
            gts.bits(side).set(file_index.get());

            const file = g.getFileByIndex(file_index);

            switch (comptime side) {
                .server => {
                    if (file.is_client_component_boundary or file.kind == .css) {
                        const dev = g.owner();
                        const key = g.bundled_files.keys()[file_index.get()];
                        const index = dev.client_graph.getFileIndex(key) orelse
                            Output.panic("Client Incremental Graph is missing component for {f}", .{bun.fmt.quote(key)});
                        try dev.client_graph.traceImports(index, gts, goal);

                        if (Environment.isDebug and file.kind == .css) {
                            // Server CSS files never have imports. They are
                            // purely a reference to the client graph.
                            bun.assert(g.first_import.items[file_index.get()] == .none);
                        }
                    }
                    if (goal == .find_errors and file.failed) {
                        try gts.failed_files.append(gts.allocator, .{ .server = file_index });
                    }
                },
                .client => {
                    switch (file.content) {
                        .css_child => {
                            bun.assertf(false, "only CSS roots should be found by tracing", .{});
                        },
                        .css_root => |id| {
                            if (goal == .find_css) {
                                try g.current_css_files.append(g.allocator(), id);
                            }

                            // See the comment on `Content.css_root` on how CSS roots
                            // have a slightly different meaning for their assets.
                            // Regardless, CSS can't import JS, so this trace is done.
                            return;
                        },
                        else => {},
                    }

                    if (goal == .find_client_modules) {
                        try g.current_chunk_parts.append(g.allocator(), file_index);
                        // TODO: will `file.jsCode` ever return null here?
                        g.current_chunk_len += if (file.jsCode()) |code| code.len else 0;
                    }

                    if (goal == .find_errors and file.failed) {
                        try gts.failed_files.append(gts.allocator, .{ .client = file_index });
                        return;
                    }
                },
            }

            // Recurse
            var it: ?EdgeIndex = g.first_import.items[file_index.get()].unwrap();
            while (it) |dep_index| {
                const edge = g.edges.items[dep_index.get()];
                it = edge.next_import.unwrap();
                try g.traceImports(edge.imported, gts, goal);
            }
        }

        /// Never takes ownership of `abs_path`
        /// Marks a chunk but without any content. Used to track dependencies to files that don't exist.
        pub fn insertStale(g: *Self, abs_path: []const u8, is_ssr_graph: bool) bun.OOM!FileIndex {
            return g.insertStaleExtra(abs_path, is_ssr_graph, false);
        }

        // TODO: `is_route` is unused in client graph
        pub fn insertStaleExtra(g: *Self, abs_path: []const u8, is_ssr_graph: bool, is_route: bool) bun.OOM!FileIndex {
            g.owner().graph_safety_lock.assertLocked();
            debug.log("Insert stale: {s}", .{abs_path});
            const file_index = (try g.insertEmpty(abs_path, .unknown)).index;
            const file = &g.bundled_files.values()[file_index.get()];
            g.markStale(file_index);

            switch (side) {
                .client => {
                    var updated = file.unpack();
                    g.freeFileContent(abs_path, &updated, .unref_css);
                    file.* = updated.pack();
                },
                .server => {
                    if (is_route) file.is_route = true;
                    if (is_ssr_graph) file.is_ssr = true else file.is_rsc = true;
                },
            }

            return file_index;
        }

        /// Returns the key that was inserted.
        pub fn insertEmpty(g: *Self, abs_path: []const u8, kind: FileKind) bun.OOM!struct {
            index: FileIndex,
            key: []const u8,
        } {
            g.owner().graph_safety_lock.assertLocked();
            const dev_alloc = g.allocator();
            if (g.bundled_files.getIndex(abs_path)) |index| {
                return .{ .index = .init(@intCast(index)), .key = g.bundled_files.keys()[index] };
            }
            if (g.bundled_files.count() >= std.math.maxInt(u30)) return error.OutOfMemory;
            try g.bundled_files.ensureUnusedCapacity(dev_alloc, 1);
            try g.first_dep.ensureUnusedCapacity(dev_alloc, 1);
            try g.first_import.ensureUnusedCapacity(dev_alloc, 1);
            try g.ensureStaleBitCapacityForCount(g.bundled_files.count() + 1, true);
            const owned_path = try dev_alloc.dupe(u8, abs_path);
            const index = g.bundled_files.count();
            g.bundled_files.putAssumeCapacityNoClobber(owned_path, switch (side) {
                .client => File.pack(&.{
                    .content = switch (kind) {
                        .unknown => .unknown,
                        .js => .{ .js = "" },
                        .asset => .{ .asset = "" },
                        .css => .css_child,
                    },
                }),
                .server => .{
                    .is_rsc = false,
                    .is_ssr = false,
                    .is_route = false,
                    .is_client_component_boundary = false,
                    .failed = false,
                    .kind = kind,
                },
            });
            g.first_dep.appendAssumeCapacity(.none);
            g.first_import.appendAssumeCapacity(.none);
            return .{ .index = .init(@intCast(index)), .key = owned_path };
        }

        /// Server CSS files are just used to be targets for graph traversal.
        /// Its content lives only on the client.
        pub fn insertCssFileOnServer(g: *Self, ctx: *HotUpdateContext, index: bun.ast.Index, abs_path: []const u8) bun.OOM!void {
            g.owner().graph_safety_lock.assertLocked();
            try g.ensureStaleBitCapacity(false);
            const file_index = (try g.insertEmpty(abs_path, .css)).index;

            switch (side) {
                .client => @compileError("not implemented: use receiveChunk"),
                .server => g.bundled_files.values()[file_index.get()] = .{
                    .is_rsc = false,
                    .is_ssr = false,
                    .is_route = false,
                    .is_client_component_boundary = false,
                    .failed = false,
                    .kind = .css,
                },
            }

            g.stale_files.unset(file_index.get());
            ctx.getCachedIndex(.server, index).* = .init(file_index);
        }

        pub fn insertFailure(
            g: *Self,
            comptime mode: enum { abs_path, index },
            key: switch (mode) {
                .abs_path => []const u8,
                .index => FileIndex,
            },
            log: *const Log,
            is_ssr_graph: bool,
        ) bun.OOM!void {
            g.owner().graph_safety_lock.assertLocked();

            const dev_alloc = g.allocator();
            const dev = g.owner();
            const existing: ?FileIndex = switch (mode) {
                .abs_path => g.getFileIndex(key),
                .index => key,
            };
            if (existing == null and g.bundled_files.count() >= std.math.maxInt(u30)) return error.OutOfMemory;
            const file_index = existing orelse FileIndex.init(@intCast(g.bundled_files.count()));
            const abs_path = switch (mode) {
                .abs_path => key,
                .index => g.bundled_files.keys()[key.get()],
            };
            const fail_owner: SerializedFailure.Owner = switch (side) {
                .server => .{ .server = file_index },
                .client => .{ .client = file_index },
            };
            const failure = failure: {
                const owner_display_name = try dev.relativePath(dev.allocator(), abs_path);
                defer dev.allocator().free(owner_display_name);
                break :failure try SerializedFailure.initFromLog(
                    dev.allocator(),
                    fail_owner,
                    owner_display_name,
                    log.msgs.items,
                );
            };
            errdefer failure.deinit(dev_alloc);
            const has_previous_failure = dev.bundling_failures.getKeyAdapted(fail_owner, SerializedFailure.ArrayHashAdapter{}) != null;
            if (!has_previous_failure) try dev.bundling_failures.ensureUnusedCapacity(dev_alloc, 1);
            try dev.incremental_result.failures_added.ensureUnusedCapacity(dev_alloc, 1);
            if (has_previous_failure) try dev.incremental_result.failures_removed.ensureUnusedCapacity(dev_alloc, 1);
            try g.ensureStaleBitCapacityForCount(g.bundled_files.count() + @intFromBool(existing == null), true);
            if (existing == null) _ = try g.insertEmpty(abs_path, .unknown);

            g.stale_files.set(file_index.get());
            const file = &g.bundled_files.values()[file_index.get()];
            switch (side) {
                .client => {
                    var updated = file.unpack();
                    g.freeFileContent(abs_path, &updated, .unref_css);
                    updated.failed = true;
                    file.* = updated.pack();
                },
                .server => {
                    if (is_ssr_graph) file.is_ssr = true else file.is_rsc = true;
                    file.failed = true;
                },
            }

            const fail_gop = dev.bundling_failures.getOrPutAssumeCapacity(failure);
            dev.incremental_result.failures_added.appendAssumeCapacity(failure);
            if (fail_gop.found_existing) {
                dev.incremental_result.failures_removed.appendAssumeCapacity(fail_gop.key_ptr.*);
                fail_gop.key_ptr.* = failure;
            }
            log.print(Output.errorWriter()) catch {};
        }

        pub fn onFileDeleted(g: *Self, abs_path: []const u8, bv2: *bun.BundleV2) void {
            const index = g.getFileIndex(abs_path) orelse return;

            const keys = g.bundled_files.keys();

            // Disconnect all imports
            var it: ?EdgeIndex = g.first_import.items[index.get()].unwrap();
            g.first_import.items[index.get()] = .none;
            while (it) |edge_index| {
                const dep = g.edges.items[edge_index.get()];
                it = dep.next_import.unwrap();
                assert(dep.dependency == index);

                g.disconnectEdgeFromDependencyList(edge_index);
                g.freeEdge(edge_index);
            }

            // Rebuild all dependencies
            it = g.first_dep.items[index.get()].unwrap();
            while (it) |edge_index| {
                const dep = g.edges.items[edge_index.get()];
                it = dep.next_dependency.unwrap();
                assert(dep.imported == index);

                bv2.enqueueFileFromDevServerIncrementalGraphInvalidation(
                    keys[dep.dependency.get()],
                    switch (side) {
                        .client => .browser,
                        .server => .bun,
                    },
                ) catch |err| bun.handleOom(err);
            }

            // Bust the resolution caches of the dir containing this file,
            // so that it cannot be resolved.
            const dirname = std.fs.path.dirname(abs_path) orelse abs_path;
            _ = bv2.transpiler.resolver.bustDirCache(dirname);

            // Additionally, clear the cached entry of the file from the path to
            // source index map.
            for (&bv2.graph.build_graphs.values) |*map| {
                _ = map.remove(abs_path);
            }
        }

        pub fn ensureStaleBitCapacity(g: *Self, are_new_files_stale: bool) !void {
            return g.ensureStaleBitCapacityForCount(g.bundled_files.count(), are_new_files_stale);
        }

        fn ensureStaleBitCapacityForCount(g: *Self, count: usize, are_new_files_stale: bool) bun.OOM!void {
            try g.stale_files.resize(
                g.allocator(),
                std.mem.alignForward(
                    usize,
                    @max(count, g.stale_files.capacity()),
                    // allocate 8 in 8 usize chunks
                    std.mem.byte_size_in_bits * @sizeOf(usize) * 8,
                ),
                are_new_files_stale,
            );
        }

        /// Given a set of paths, mark the relevant files as stale and append
        /// them into `entry_points`. This is called whenever a file is changed,
        /// and a new bundle has to be run.
        pub fn invalidate(g: *Self, paths: []const []const u8, entry_points: *EntryPointList, alloc: Allocator) !void {
            g.owner().graph_safety_lock.assertLocked();
            const keys = g.bundled_files.keys();
            const values = g.bundled_files.values();
            for (paths) |path| {
                const index = g.bundled_files.getIndex(path) orelse {
                    // Cannot enqueue because it's impossible to know what
                    // targets to bundle for. Instead, a failing bundle must
                    // retrieve the list of files and add them as stale.
                    continue;
                };
                // Store the graph-owned key, not the incoming `path`. `path`
                // may be a slice into `HotReloadEvent.extra_files`, which is
                // reset (and may be reallocated by the watcher thread) before
                // `entry_points` is consumed by startAsyncBundle/TestingBatch.
                const owned_path = keys[index];
                g.markStale(.init(@intCast(index)));
                const data = values[index].unpack();
                switch (side) {
                    .client => switch (data.content) {
                        .css_root, .css_child => {
                            if (data.content == .css_root) {
                                try entry_points.appendCss(alloc, owned_path);
                            }

                            var it = g.first_dep.items[index].unwrap();
                            while (it) |edge_index| {
                                const entry = g.edges.items[edge_index.get()];
                                const dep = entry.dependency;
                                g.markStale(dep);

                                const dep_file = values[dep.get()].unpack();
                                if (dep_file.content == .css_root) {
                                    try entry_points.appendCss(alloc, keys[dep.get()]);
                                }

                                it = entry.next_dependency.unwrap();
                            }
                        },
                        .asset => {
                            var it = g.first_dep.items[index].unwrap();
                            while (it) |edge_index| {
                                const entry = g.edges.items[edge_index.get()];
                                const dep = entry.dependency;
                                g.markStale(dep);

                                const dep_file = values[dep.get()].unpack();
                                // Assets violate the "do not reprocess
                                // unchanged files" rule by reprocessing ALL
                                // dependencies, instead of just the CSS roots.
                                //
                                // This is currently required to force HTML
                                // bundles to become up to date with the new
                                // asset URL. Additionally, it is currently seen
                                // as a bit nicer in HMR to do this for all JS
                                // files, though that could be reconsidered.
                                if (dep_file.content == .css_root) {
                                    try entry_points.appendCss(alloc, keys[dep.get()]);
                                } else {
                                    try entry_points.appendJs(alloc, keys[dep.get()], .client);
                                }

                                it = entry.next_dependency.unwrap();
                            }

                            try entry_points.appendJs(alloc, owned_path, .client);
                        },
                        // When re-bundling SCBs, only bundle the server. Otherwise
                        // the bundler gets confused and bundles both sides without
                        // knowledge of the boundary between them.
                        .js, .unknown => if (!data.is_hmr_root) {
                            try entry_points.appendJs(alloc, owned_path, .client);
                        },
                    },
                    .server => {
                        if (data.is_rsc)
                            try entry_points.appendJs(alloc, owned_path, .server);
                        if (data.is_ssr and !data.is_client_component_boundary)
                            try entry_points.appendJs(alloc, owned_path, .ssr);
                    },
                }
            }
        }

        pub fn reset(g: *Self) void {
            g.owner().graph_safety_lock.assertLocked();
            g.current_chunk_len = 0;

            if (comptime side == .client) {
                g.current_css_files.clearRetainingCapacity();
            } else if (comptime side == .server) {
                for (g.current_chunk_parts.items) |*part| part.deinit();

                for (g.current_chunk_source_maps.items) |*sourcemap| sourcemap.deinit();
                g.current_chunk_source_maps.clearRetainingCapacity();
            }

            g.current_chunk_parts.clearRetainingCapacity();
        }

        const TakeJSBundleOptions = switch (side) {
            .client => struct {
                kind: ChunkKind,
                script_id: SourceMapStore.Key,
                initial_response_entry_point: []const u8 = "",
                react_refresh_entry_point: []const u8 = "",
                console_log: bool,
            },
            .server => struct {
                kind: ChunkKind,
                script_id: SourceMapStore.Key,
            },
        };

        pub fn takeJSBundle(
            g: *Self,
            options: *const TakeJSBundleOptions,
        ) ![]u8 {
            var chunk = std.array_list.Managed(u8).init(g.allocator());
            errdefer chunk.deinit();
            try g.takeJSBundleToList(&chunk, options);
            bun.assert(chunk.items.len == chunk.capacity);
            return chunk.items;
        }

        pub fn takeJSBundleToList(
            g: *Self,
            list: *std.array_list.Managed(u8),
            options: *const TakeJSBundleOptions,
        ) !void {
            const kind = options.kind;
            g.owner().graph_safety_lock.assertLocked();
            if (kind == .initial_response)
                assert(g.current_chunk_len > 0);

            const runtime: BakeCore.HmrRuntime = switch (kind) {
                .initial_response => BakeCore.getHmrRuntime(g.owner().vm.io, side),
                .hmr_chunk => switch (side) {
                    .server => comptime .init("({"),
                    .client => comptime .init("self[Symbol.for(\"bun:hmr\")]({\n"),
                },
            };

            var end_sfa_buffer: [65536]u8 = undefined;
            var end_sfa: std.heap.BufferFirstAllocator = .init(&end_sfa_buffer, g.allocator());
            var end_list = try std.array_list.Managed(u8).initCapacity(end_sfa.allocator(), 65536);
            defer end_list.deinit();
            const end = end: {
                var end_writer = bun.ManagedWriter.init(&end_list);
                const w = end_writer.writer();
                switch (kind) {
                    .initial_response => {
                        if (comptime side == .server) @panic("unreachable");
                        w.writeAll("}, {\n  main: ") catch return error.OutOfMemory;
                        const initial_response_entry_point = options.initial_response_entry_point;
                        if (initial_response_entry_point.len > 0) {
                            const relative_path = try g.owner().relativePath(end_sfa.allocator(), initial_response_entry_point);
                            defer end_sfa.allocator().free(relative_path);
                            bun.js_printer.writeJSONString(
                                relative_path,
                                @TypeOf(w),
                                w,
                                .utf8,
                            ) catch return error.OutOfMemory;
                        } else {
                            w.writeAll("null") catch return error.OutOfMemory;
                        }
                        w.writeAll(",\n  bun: \"" ++ bun.Global.package_json_version_with_canary ++ "\"") catch return error.OutOfMemory;
                        w.writeAll(",\n  generation: \"") catch return error.OutOfMemory;
                        const generation: u32 = @intCast(options.script_id.get() >> 32);
                        w.print("{x}", .{std.mem.asBytes(&generation)}) catch return error.OutOfMemory;
                        w.writeAll("\",\n  version: \"") catch return error.OutOfMemory;
                        w.writeAll(&g.owner().configuration_hash_key) catch return error.OutOfMemory;

                        if (options.console_log) {
                            w.writeAll("\",\n  console: true") catch return error.OutOfMemory;
                        } else {
                            w.writeAll("\",\n  console: false") catch return error.OutOfMemory;
                        }

                        if (options.react_refresh_entry_point.len > 0) {
                            w.writeAll(",\n  refresh: ") catch return error.OutOfMemory;
                            const relative_path = try g.owner().relativePath(end_sfa.allocator(), options.react_refresh_entry_point);
                            defer end_sfa.allocator().free(relative_path);
                            bun.js_printer.writeJSONString(
                                relative_path,
                                @TypeOf(w),
                                w,
                                .utf8,
                            ) catch return error.OutOfMemory;
                        }
                        w.writeAll("\n})") catch return error.OutOfMemory;
                    },
                    .hmr_chunk => switch (side) {
                        .client => {
                            w.writeAll("}, \"") catch return error.OutOfMemory;
                            w.writeAll(&std.fmt.bytesToHex(std.mem.asBytes(&options.script_id), .lower)) catch return error.OutOfMemory;
                            w.writeAll("\")") catch return error.OutOfMemory;
                        },
                        .server => w.writeAll("})") catch return error.OutOfMemory,
                    },
                }
                if (comptime side == .client) {
                    w.writeAll("\n//# sourceMappingURL=" ++ DevServer.client_prefix ++ "/") catch return error.OutOfMemory;
                    w.writeAll(&std.fmt.bytesToHex(std.mem.asBytes(&options.script_id), .lower)) catch return error.OutOfMemory;
                    w.writeAll(".js.map\n") catch return error.OutOfMemory;
                }
                end_writer.finish();
                break :end end_list.items;
            };

            const files = g.bundled_files.values();

            const start = list.items.len;
            const code_len = std.math.add(usize, g.current_chunk_len, runtime.code.len) catch return error.OutOfMemory;
            const bundle_len = std.math.add(usize, code_len, end.len) catch return error.OutOfMemory;
            if (start == 0)
                try list.ensureTotalCapacityPrecise(bundle_len)
            else
                try list.ensureUnusedCapacity(bundle_len);

            list.appendSliceAssumeCapacity(runtime.code);
            for (g.current_chunk_parts.items) |entry| {
                list.appendSliceAssumeCapacity(switch (side) {
                    // entry is an index into files
                    // will return null if the chunk is a non-js (like css)
                    .client => files[entry.get()].unpack().jsCode() orelse continue,
                    // entry is the '[]const u8' itself
                    .server => entry.get(),
                });
            }
            list.appendSliceAssumeCapacity(end);

            if (bun.FeatureFlags.bake_debugging_features) if (g.owner().dump_dir) |dump_dir| {
                const rel_path_escaped = switch (kind) {
                    .initial_response => "latest_chunk.js",
                    .hmr_chunk => "latest_hmr.js",
                };
                DevServer.dumpBundle(g.owner().vm.io, dump_dir, switch (side) {
                    .client => .client,
                    .server => .server,
                }, rel_path_escaped, list.items[start..], false) catch |err| {
                    bun.handleErrorReturnTrace(err, @errorReturnTrace());
                    Output.warn("Could not dump bundle: {}", .{err});
                };
            };
        }

        pub fn createSourceMap(g: *Self) bun.OOM!SourceMapStore.Entry {
            const paths = g.bundled_files.keys();
            const alloc = g.allocator();
            const count = switch (side) {
                .client => g.current_chunk_parts.items.len,
                .server => g.current_chunk_source_maps.items.len,
            };
            const file_paths = try alloc.alloc([]const u8, count);
            var initialized_paths: usize = 0;
            errdefer {
                for (file_paths[0..initialized_paths]) |path| alloc.free(path);
                alloc.free(file_paths);
            }
            var contained_maps = try std.MultiArrayList(PackedMap.Shared).initCapacity(alloc, count);
            errdefer {
                const slice = contained_maps.slice();
                for (0..slice.len) |i| {
                    var map = slice.get(i);
                    map.deinit();
                }
                contained_maps.deinit(alloc);
            }
            var overlapping_memory_cost = std.math.add(
                usize,
                @TypeOf(contained_maps).capacityInBytes(contained_maps.capacity),
                DevServer.memoryCostSlice(file_paths),
            ) catch return error.OutOfMemory;
            for (0..count) |i| {
                const file_index = switch (side) {
                    .client => g.current_chunk_parts.items[i],
                    .server => g.current_chunk_source_maps.items[i].file_index,
                };
                const source_map = switch (side) {
                    .client => g.bundled_files.values()[file_index.get()].unpack().source_map,
                    .server => g.current_chunk_source_maps.items[i].source_map,
                };
                file_paths[i] = try alloc.dupe(u8, paths[file_index.get()]);
                initialized_paths += 1;
                contained_maps.appendAssumeCapacity(source_map.clone());
                overlapping_memory_cost = std.math.add(usize, overlapping_memory_cost, file_paths[i].len) catch return error.OutOfMemory;
                if (source_map.get()) |map| {
                    overlapping_memory_cost = std.math.add(usize, overlapping_memory_cost, map.memoryCost()) catch return error.OutOfMemory;
                }
            }
            return .{
                .dev_allocator = g.dev_allocator(),
                .ref_count = 0,
                .paths = file_paths,
                .files = contained_maps,
                .overlapping_memory_cost = std.math.cast(u32, overlapping_memory_cost) orelse return error.OutOfMemory,
            };
        }

        fn newEdgeAssumeCapacity(g: *Self, edge: Edge) EdgeIndex {
            bun.assert(edge.targets != 0);
            if (g.free_edge_head.unwrap()) |index| {
                bun.assert(g.edges.items[index.get()].targets == 0);
                g.free_edge_head = g.edges.items[index.get()].next_import;
                g.free_edge_count -= 1;
                g.edges.items[index.get()] = edge;
                return index;
            }

            const index = EdgeIndex.init(@intCast(g.edges.items.len));
            g.edges.appendAssumeCapacity(edge);
            return index;
        }

        /// Releases an unlinked edge for reuse.
        /// Caller must detach the dependency from the linked list it is in.
        fn freeEdge(g: *Self, edge_index: EdgeIndex) void {
            igLog("IncrementalGraph(0x{x}, {s}).freeEdge({d})", .{ @intFromPtr(g), @tagName(side), edge_index.get() });
            defer g.checkEdgeRemoval(edge_index);
            const edge = &g.edges.items[edge_index.get()];
            bun.assert(edge.targets != 0);
            edge.targets = 0;
            edge.next_import = g.free_edge_head;
            g.free_edge_head = edge_index.toOptional();
            g.free_edge_count += 1;
        }

        /// It is very easy to call `g.freeEdge(idx)` but still keep references
        /// to the idx around, basically causing use-after-free with more steps
        /// and no asan to check it since we are dealing with indices and not
        /// pointers to memory.
        ///
        /// So we'll check it manually by making sure there are no references to
        /// `edge_index` in the graph.
        fn checkEdgeRemoval(g: *Self, edge_index: EdgeIndex) void {
            // Enable this on any builds with asan enabled so we can catch stuff
            // in CI too
            const enabled = bun.asan.enabled or bun.Environment.ci_assert;
            if (comptime !enabled) return;

            for (g.first_dep.items) |maybe_first_dep| {
                if (maybe_first_dep.unwrap()) |first_dep| {
                    bun.assert_neql(first_dep.get(), edge_index.get());
                }
            }

            for (g.first_import.items) |maybe_first_import| {
                if (maybe_first_import.unwrap()) |first_import| {
                    bun.assert_neql(first_import.get(), edge_index.get());
                }
            }

            for (g.edges.items) |edge| {
                if (edge.targets == 0) continue;

                bun.assert_neql(edge.prev_dependency.unwrapGet(), edge_index.get());
                bun.assert_neql(edge.next_import.unwrapGet(), edge_index.get());
                bun.assert_neql(edge.next_dependency.unwrapGet(), edge_index.get());
            }
        }

        pub fn owner(g: *Self) *DevServer {
            return @alignCast(@fieldParentPtr(@tagName(side) ++ "_graph", g));
        }

        fn allocator(g: *const Self) Allocator {
            return g.dev_allocator().allocator();
        }

        fn dev_allocator(g: *const Self) DevAllocator {
            const dev_server: *const DevServer = @constCast(g).owner();
            return dev_server.dev_allocator();
        }
    };
}

const bun = @import("bun");
const Environment = bun.Environment;
const Output = bun.Output;
const assert = bun.assert;
const assert_eql = bun.assert_eql;
const Log = bun.logger.Log;
const useAllFields = bun.meta.useAllFields;

const SourceMap = bun.SourceMap;
const VLQ = SourceMap.VLQ;

const BakeCore = @import("../BakeCore.zig");
const DevServerCore = @import("../DevServerCore.zig");
const ChunkKind = DevServerCore.ChunkKind;
const EntryPointList = DevServerCore.EntryPointList;
const FileKind = DevServerCore.FileKind;
const GraphTraceState = DevServerCore.GraphTraceState;

const FrameworkRouter = @import("../FrameworkRouter.zig");
const Route = FrameworkRouter.Route;

const BundleV2 = bun.bundle_v2.BundleV2;
const Chunk = bun.bundle_v2.Chunk;

const Owned = bun.ptr.Owned;
const Shared = bun.ptr.Shared;

const std = @import("std");
const AutoArrayHashMap = std.array_hash_map.Auto;
const Allocator = std.mem.Allocator;
