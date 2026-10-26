pub fn WithTypes(
    comptime ServerFileIndex: type,
    comptime RouteBundleIndex: type,
    comptime SerializedFailure: type,
    comptime RouteIndexAndRecurseFlag: type,
) type {
    return struct {
        const IncrementalResult = @This();

        /// Framework routes reached while tracing changed graph edges.
        framework_routes_affected: std.ArrayListUnmanaged(RouteIndexAndRecurseFlag),
        html_routes_soft_affected: std.ArrayListUnmanaged(RouteBundleIndex),
        /// HTML routes that require a full reload rather than URL rewriting.
        html_routes_hard_affected: std.ArrayListUnmanaged(RouteBundleIndex),
        had_adjusted_edges: bool,
        client_components_added: std.ArrayListUnmanaged(ServerFileIndex),
        client_components_removed: std.ArrayListUnmanaged(ServerFileIndex),
        /// Removed failures retain their bytes until the next update payload is encoded.
        failures_removed: std.ArrayListUnmanaged(SerializedFailure),
        client_components_affected: std.ArrayListUnmanaged(ServerFileIndex),
        /// Borrows published graph failures until their notification is encoded.
        failures_added: std.ArrayListUnmanaged(SerializedFailure),

        pub const empty: IncrementalResult = .{
            .framework_routes_affected = .empty,
            .html_routes_soft_affected = .empty,
            .html_routes_hard_affected = .empty,
            .had_adjusted_edges = false,
            .failures_removed = .empty,
            .failures_added = .empty,
            .client_components_added = .empty,
            .client_components_removed = .empty,
            .client_components_affected = .empty,
        };

        pub fn reset(result: *IncrementalResult) void {
            // Unsent diagnostic changes must survive a failed build round.
            result.framework_routes_affected.clearRetainingCapacity();
            result.html_routes_soft_affected.clearRetainingCapacity();
            result.html_routes_hard_affected.clearRetainingCapacity();
            result.client_components_affected.clearRetainingCapacity();
        }
    };
}

const std = @import("std");
