pub fn TestRunnerState(comptime Types: type) type {
    return struct {
        current_file: CurrentFile = .{},
        files: File.List = .{},
        index: File.Map = .empty,
        only: bool = false,
        run_todo: bool = false,
        concurrent: bool = false,
        randomize_seed: ?u32 = null,
        concurrent_test_glob: ?[]const []const u8 = null,
        bail: u32 = 0,
        max_concurrency: u32,
        allocator: std.mem.Allocator,
        snapshots: Types.Snapshots,
        default_timeout_ms: u32,
        default_timeout_override: u32 = std.math.maxInt(u32),
        test_options: *const Types.TestOptions = undefined,
        filter_regex: ?*Types.RegularExpression,
        unhandled_errors_between_tests: u32 = 0,
        summary: Summary = .{},
        bun_test_root: Types.BunTestRoot,

        const Self = @This();

        pub const CurrentFile = struct {
            title: []const u8 = "",
            prefix: []const u8 = "",
            repeat_info: struct {
                count: u32 = 0,
                index: u32 = 0,
            } = .{},
            has_printed_filename: bool = false,

            pub fn set(
                current: *CurrentFile,
                title: []const u8,
                prefix: []const u8,
                repeat_count: u32,
                repeat_index: u32,
                reporter: *Types.CommandLineReporter,
            ) void {
                if (reporter.worker_ipc_file_idx != null) {
                    current.has_printed_filename = true;
                    return;
                }
                if (reporter.reporters.dots or reporter.reporters.only_failures) {
                    current.freeAndClear();
                    current.title = bun.handleOom(bun.default_allocator.dupe(u8, title));
                    current.prefix = bun.handleOom(bun.default_allocator.dupe(u8, prefix));
                    current.repeat_info.count = repeat_count;
                    current.repeat_info.index = repeat_index;
                    current.has_printed_filename = false;
                    return;
                }

                current.has_printed_filename = true;
                print(title, prefix, repeat_count, repeat_index);
            }

            fn freeAndClear(current: *CurrentFile) void {
                bun.default_allocator.free(current.title);
                bun.default_allocator.free(current.prefix);
            }

            fn print(title: []const u8, prefix: []const u8, repeat_count: u32, repeat_index: u32) void {
                const buffering = Output.enableBufferingScope();
                defer buffering.deinit();
                Output.prettyError("<r>\n", .{});
                if (repeat_count > 1) {
                    Output.prettyErrorln("{s}{s}: <d>(run #{d})<r>\n", .{ prefix, title, repeat_index + 1 });
                } else {
                    Output.prettyErrorln("{s}{s}:\n", .{ prefix, title });
                }
                Output.flush();
            }

            pub fn printIfNeeded(current: *CurrentFile) void {
                if (current.has_printed_filename) return;
                current.has_printed_filename = true;
                print(current.title, current.prefix, current.repeat_info.count, current.repeat_info.index);
            }
        };

        pub const Summary = struct {
            pass: u32 = 0,
            expectations: u32 = 0,
            skip: u32 = 0,
            todo: u32 = 0,
            fail: u32 = 0,
            files: u32 = 0,
            skipped_because_label: u32 = 0,

            pub fn didLabelFilterOutAllTests(summary: *const Summary) bool {
                return summary.skipped_because_label > 0 and
                    (summary.pass + summary.skip + summary.todo + summary.fail + summary.expectations) == 0;
            }
        };

        pub const File = struct {
            source: logger.Source = logger.Source.initEmptyFile(""),
            log: logger.Log = logger.Log.initComptime(bun.default_allocator),

            pub const List = std.MultiArrayList(File);
            pub const ID = u32;
            pub const Map = bun.StringArrayHashMap(ID);
        };

        pub fn snapshotFilePath(context: *const Types.Snapshots.FileContext, file_id: u32) []const u8 {
            const runner: *const Self = @ptrCast(@alignCast(context));
            return runner.files.get(file_id).source.path.text;
        }

        pub fn getActiveTimeout(runner: *const Self) bun.timespec {
            const active_file = runner.bun_test_root.active_file.get() orelse return .epoch;
            if (active_file.timer.state != .ACTIVE or active_file.timer.next.eql(&.epoch)) return .epoch;
            return active_file.timer.next;
        }

        pub fn shouldFileRunConcurrently(runner: *const Self, file_id: File.ID) bool {
            if (runner.concurrent) return true;
            const patterns = runner.concurrent_test_glob orelse return false;
            if (file_id >= runner.files.len) return false;
            const file_path = runner.files.items(.source)[file_id].path.text;
            for (patterns) |pattern| {
                if (bun.glob.match(pattern, file_path) == .match) return true;
            }
            return false;
        }

        pub fn getOrPutFile(runner: *Self, file_path: []const u8) struct { file_id: File.ID } {
            const entry = runner.index.getOrPut(runner.allocator, file_path) catch unreachable;
            if (entry.found_existing) return .{ .file_id = entry.value_ptr.* };
            const file_id: File.ID = @truncate(runner.files.len);
            runner.files.append(runner.allocator, .{ .source = logger.Source.initEmptyFile(file_path) }) catch unreachable;
            entry.value_ptr.* = file_id;
            return .{ .file_id = file_id };
        }
    };
}

const std = @import("std");
const bun = @import("bun");
const Output = bun.Output;
const logger = bun.logger;
