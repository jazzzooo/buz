/// Used to keep the bundle thread from spinning on Windows
pub fn timerCallback(_: *bun.windows.libuv.Timer) callconv(.c) void {}

/// CompletionStruct's interface:
///
/// - `isCancelled` skips queued jobs whose owner has stopped waiting.
/// - `configureBundler` is used to configure `Bundler`.
/// - `configureBundleV2` attaches integration capabilities and borrowed inputs.
/// - `bytecodeGenerator` provides the bytecode compiler capability.
/// - `completeOnBundleThread` is used to tell the task that it is done.
pub fn BundleThread(CompletionStruct: type) type {
    return struct {
        const Self = @This();

        waker: bun.Async.Waker,
        ready: std.Io.Event,
        queue: bun.UnboundedQueue(CompletionStruct, .next),
        generation: bun.Generation = 0,

        /// To initialize, put this somewhere in memory, and then call `spawn()`
        pub const uninitialized: Self = .{
            .waker = undefined,
            .queue = .{},
            .generation = 0,
            .ready = .unset,
        };

        pub fn spawn(instance: *Self, io: std.Io) !std.Thread {
            const thread = try std.Thread.spawn(.{}, threadMain, .{ instance, io });
            instance.ready.waitUncancelable(io);
            return thread;
        }

        /// Lazily-initialized singleton. This is used for `Bun.build` since the
        /// bundle thread may not be needed.
        pub const singleton = struct {
            var once = bun.once(loadOnceImpl);

            // Blocks the calling thread until the bun build thread is created.
            // bun.once also blocks other callers of this function until the first caller is done.
            fn loadOnceImpl(io: std.Io) *Self {
                const bundle_thread = bun.handleOom(bun.default_allocator.create(Self));
                bundle_thread.* = uninitialized;

                const os_thread = bundle_thread.spawn(io) catch
                    Output.panic("Failed to spawn bun build thread", .{});
                os_thread.detach();
                return bundle_thread;
            }

            pub fn enqueue(completion: *CompletionStruct) void {
                once.call(completion.io, .{completion.io}).enqueue(completion);
            }
        };

        pub fn enqueue(instance: *Self, completion: *CompletionStruct) void {
            instance.queue.push(completion);
            instance.waker.wake();
        }

        fn threadMain(instance: *Self, io: std.Io) void {
            Output.Source.configureNamedThread("Bundler");

            instance.waker = bun.Async.Waker.init() catch @panic("Failed to create waker");

            // Unblock the calling thread so it can continue.
            instance.ready.set(io);

            var timer: bun.windows.libuv.Timer = undefined;
            if (bun.Environment.isWindows) {
                timer.init(instance.waker.loop.uv_loop);
                timer.start(std.math.maxInt(u64), std.math.maxInt(u64), &timerCallback);
            }

            var has_bundled = false;
            while (true) {
                while (instance.queue.pop()) |completion| {
                    generateInNewThread(completion, instance.generation) catch |err| {
                        completion.result = .{ .err = err };
                    };
                    completion.completeOnBundleThread();
                    has_bundled = true;
                }
                instance.generation +|= 1;

                if (has_bundled) {
                    bun.mimalloc.mi_collect(false);
                    has_bundled = false;
                }

                _ = instance.waker.wait();
            }
        }

        /// This is called from `Bun.build` in JavaScript.
        fn generateInNewThread(completion: *CompletionStruct, generation: bun.Generation) !void {
            if (completion.isCancelled()) return error.Canceled;
            var heap = ThreadLocalArena.init();
            defer heap.deinit();
            var owned_bundle: ?*BundleV2 = null;
            defer if (owned_bundle) |bundle| bundle.deinitWithoutFreeingArena();

            const allocator = heap.allocator();
            var ast_memory_allocator = try allocator.create(js_ast.ASTMemoryAllocator);
            ast_memory_allocator.* = .{ .allocator = allocator };
            ast_memory_allocator.reset();
            ast_memory_allocator.push();
            defer ast_memory_allocator.pop();

            const transpiler = try allocator.create(bun.Transpiler);

            try completion.configureBundler(transpiler, allocator);

            transpiler.resolver.generation = generation;

            const this = try BundleV2.init(
                transpiler,
                null, // TODO: Kit
                allocator,
                null,
                completion.bytecodeGenerator(),
                heap.borrow(),
            );

            owned_bundle = this;
            completion.configureBundleV2(this);

            errdefer {
                // Wait for wait groups to finish. There still may be ongoing work.
                this.linker.source_maps.line_offset_countdown.wait(this.linker.resolver.io);
                this.linker.source_maps.quoted_contents_countdown.wait(this.linker.resolver.io);
            }

            completion.result = .{ .value = try this.runFromJSInNewThread(transpiler.options.entry_points) };
        }
    };
}

pub const Ref = bun.ast.Ref;

pub const Index = bun.ast.Index;

pub const Executor = bun.bundle_v2.Executor;
pub const ParseTask = bun.bundle_v2.ParseTask;

const Timer = @import("../perf/system_timer.zig");
const linker = @import("./linker.zig");
const options = @import("./options.zig");
const std = @import("std");

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;
const Output = bun.Output;
const Transpiler = bun.Transpiler;
const bake = bun.bake;
const default_allocator = bun.default_allocator;
const js_ast = bun.ast;

const allocators = bun.allocators;
const ThreadLocalArena = bun.allocators.MimallocArena;

const bundler = bun.bundle_v2;
const BundleV2 = bundler.BundleV2;
