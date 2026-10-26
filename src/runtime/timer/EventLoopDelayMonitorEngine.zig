const EventLoopDelayMonitor = @This();

js_histogram: ?Histogram = null,

event_loop_timer: jsc.API.Timer.EventLoopTimer = .{
    .next = .epoch,
    .tag = .EventLoopDelayMonitor,
},
resolution_ms: i32 = 10,
last_fire_ns: u64 = 0,
enabled: bool = false,

pub fn enable(this: *EventLoopDelayMonitor, vm: *VirtualMachine, histogram: HistogramView, resolution_ms: i32) bun.JSError!void {
    if (this.enabled) return;
    this.js_histogram = try histogram.toOwned();
    this.resolution_ms = resolution_ms;

    this.enabled = true;

    const now = bun.timespec.now(.force_real_time);
    this.event_loop_timer.next = now.addMs(@intCast(resolution_ms));
    vm.timer.insert(&this.event_loop_timer);
}

pub fn disable(this: *EventLoopDelayMonitor, vm: *VirtualMachine) void {
    if (!this.enabled) return;

    this.enabled = false;
    this.js_histogram.?.deinit();
    this.js_histogram = null;
    this.last_fire_ns = 0;
    vm.timer.remove(&this.event_loop_timer);
}

pub fn isEnabled(this: *const EventLoopDelayMonitor) bool {
    return this.enabled;
}

pub fn onFire(this: *EventLoopDelayMonitor, vm: *VirtualMachine, now: *const bun.timespec) void {
    if (!this.enabled) return;

    const now_ns = now.ns();
    if (this.last_fire_ns > 0) {
        const expected_ns = @as(u64, @intCast(this.resolution_ms)) *| 1_000_000;
        const actual_ns = now_ns - this.last_fire_ns;

        if (actual_ns > expected_ns) {
            const delay_ns = @as(i64, @intCast(actual_ns -| expected_ns));
            var scope: bun.bindgen.FocusedEngineScope = undefined;
            this.js_histogram.?.initScope(&scope);
            defer scope.deinit();
            scope.engine(RecordDelaySchema).call(.{
                .histogram = this.js_histogram.?.operand(&scope),
                .delay = delay_ns,
            }) catch return;
        }
    }

    this.last_fire_ns = now_ns;

    this.event_loop_timer.next = now.addMs(@intCast(this.resolution_ms));
    vm.timer.insert(&this.event_loop_timer);
}

pub fn deinit(this: *EventLoopDelayMonitor, vm: *VirtualMachine) void {
    this.disable(vm);
}

fn bindEnable(
    _: bun.bindgen.CallContext(EnableSchema),
    args: bun.bindgen.Args(EnableSchema),
) bun.JSError!bun.bindgen.Return(EnableSchema) {
    const vm = VirtualMachine.get();
    try vm.timer.event_loop_delay.enable(vm, args.histogram, args.resolution);
}

fn bindDisable(
    _: bun.bindgen.CallContext(DisableSchema),
    _: bun.bindgen.Args(DisableSchema),
) bun.bindgen.Return(DisableSchema) {
    const vm = VirtualMachine.get();
    vm.timer.event_loop_delay.disable(vm);
}

const bun = @import("bun");

const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;

const PerformanceHistogramBindings = bun.bindgen.Module("PerformanceHistogram");
const RecordDelaySchema = PerformanceHistogramBindings.engineShim("recordDelay");
const EnableSchema = PerformanceHistogramBindings.nativeExport("enableEventLoopDelayMonitoring");
const DisableSchema = PerformanceHistogramBindings.nativeExport("disableEventLoopDelayMonitoring");
const HistogramSchema = EnableSchema.args[0].ArgumentType;
const HistogramView = bun.bindgen.BrandedValueView(HistogramSchema);
const Histogram = bun.bindgen.OwnedBrandedValue(HistogramSchema);
const EnableBinding = bun.bindgen.Fn(EnableSchema, bindEnable);
const DisableBinding = bun.bindgen.Fn(DisableSchema, bindDisable);

comptime {
    _ = EnableBinding;
    _ = DisableBinding;
}
