const Graph = @This();

pool: *Executor,
heap: ThreadLocalArena.Borrowed,

/// Mapping user-specified entry points to their Source Index
entry_points: std.ArrayList(Index) = .empty,
/// Maps entry point source indices to their original specifiers (for virtual entries resolved by plugins)
entry_point_original_names: IndexStringMap = .{},
/// Every source index has an associated InputFile
input_files: std.MultiArrayList(InputFile) = .empty,
/// Every source index has an associated Ast
/// When a parse is in progress / queued, it is `Ast.empty`
ast: std.MultiArrayList(JSAst) = .empty,

/// During the scan + parse phase, this value keeps a count of the remaining
/// tasks. Once it hits zero, the scan phase ends and linking begins. Note
/// that if `deferred_head != null`, it means there are plugin callbacks
/// to invoke before linking, which can initiate another scan phase.
///
/// Increment and decrement this via `incrementScanCounter` and
/// `decrementScanCounter`, as asynchronous bundles check for `0` in the
/// decrement function, instead of at the top of the event loop.
///
/// - Parsing a file (ParseTask and ServerComponentParseTask)
/// - onResolve and onLoad functions
/// - Resolving an onDefer promise
pending_items: u32 = 0,
/// Deferred load callbacks leave `pending_items` until their promise resumes
/// or their result arrives. Nodes retain the completion after an early result.
deferred_head: ?*bun.bundle_v2.PluginLoad.Deferred = null,
deferred_tail: ?*bun.bundle_v2.PluginLoad.Deferred = null,

/// A map of build targets to their corresponding module graphs.
build_graphs: std.EnumArray(options.Target, PathToSourceIndexMap),

/// When Server Components is enabled, this holds a list of all boundary
/// files. This happens for all files with a "use <side>" directive.
server_component_boundaries: ServerComponentBoundary.List = .{},

/// Track HTML imports from server-side code
/// Each entry represents a server file importing an HTML file that needs a client build
///
/// OutputPiece.Kind.HTMLManifest corresponds to indices into the array.
html_imports: struct {
    /// Source index of the server file doing the import
    server_source_indices: BabyList(Index.Int) = .{},
    /// Source index of the HTML file being imported
    html_source_indices: BabyList(Index.Int) = .{},
} = .{},

estimated_file_loader_count: usize = 0,

/// For Bake, a count of the CSS asts is used to make precise
/// pre-allocations without re-iterating the file listing.
css_file_count: usize = 0,

additional_output_files: std.ArrayList(options.OutputFile) = .empty,
/// Paths remain borrowed from output files after those files move to the build result.
additional_output_paths: []const []const u8 = &.{},
metafile_fragments: std.ArrayList([]const u8) = .empty,

kit_referenced_server_data: bool,
kit_referenced_client_data: bool,

/// Do any input_files have a secondary_path.len > 0?
///
/// Helps skip a loop.
has_any_secondary_paths: bool = false,

pub const InputFile = struct {
    source: Logger.Source,
    secondary_path: []const u8 = "",
    loader: options.Loader = options.Loader.file,
    side_effects: _resolver.SideEffects,
    additional_files: BabyList(AdditionalFile) = .{},
    unique_key_for_additional_file: string = "",
    content_hash_for_additional_file: u64 = 0,
    flags: Flags = .{},

    pub const Flags = packed struct(u8) {
        /// Set when a barrel-eligible file has `export * from` this file.
        is_export_star_target: bool = false,
        _: u7 = 0,
    };
};

pub inline fn pathToSourceIndexMap(this: *Graph, target: options.Target) *PathToSourceIndexMap {
    return this.build_graphs.getPtr(target);
}

/// Resume this build's deferrals and report whether any callbacks still owe a result.
pub fn drainDeferredTasks(this: *Graph, transpiler: *BundleV2) bool {
    transpiler.thread_lock.assertLocked();
    bun.assert(this.pending_items == 0);
    var current = this.deferred_head;
    this.deferred_head = null;
    this.deferred_tail = null;
    const failed = transpiler.didCompletionFail();
    while (current) |deferred| {
        current = deferred.next;
        deferred.complete(failed);
    }
    return this.pending_items != 0;
}

pub const Ref = bun.ast.Ref;

pub const Index = bun.ast.Index;

const string = []const u8;

const IndexStringMap = @import("./IndexStringMap.zig");
const Logger = @import("../logger/logger.zig");
const _resolver = @import("../resolver/resolver.zig");
const std = @import("std");

const options = @import("./options.zig");
const Loader = options.Loader;

const bun = @import("bun");
const BabyList = bun.collections.BabyList;
const ThreadLocalArena = bun.allocators.MimallocArena;

const js_ast = bun.ast;
const JSAst = js_ast.BundledAst;
const ServerComponentBoundary = js_ast.ServerComponentBoundary;

const AdditionalFile = bun.bundle_v2.AdditionalFile;
const BundleV2 = bun.bundle_v2.BundleV2;
const ParseTask = bun.bundle_v2.ParseTask;
const PathToSourceIndexMap = bun.bundle_v2.PathToSourceIndexMap;
const Executor = bun.bundle_v2.Executor;
