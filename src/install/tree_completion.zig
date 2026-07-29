const std = @import("std");

pub const Transition = enum {
    pending,
    completed,
    already_completed,
};

pub fn initialize(states: anytype, nodes: anytype, invalid_id: anytype) error{InvalidTreeLayout}!void {
    if (states.len != nodes.len) return error.InvalidTreeLayout;

    for (nodes, states, 0..) |node, *state, index| {
        state.remaining_installs = node.dependencies.len;
        state.unfinished_subtree_count = 0;

        const Id = @TypeOf(node.id);
        if (index > std.math.maxInt(Id) or node.id != @as(Id, @intCast(index))) {
            return error.InvalidTreeLayout;
        }
        if (index == 0) {
            if (node.parent != invalid_id) return error.InvalidTreeLayout;
        } else {
            const parent_index: usize = @intCast(node.parent);
            if (node.parent == invalid_id or parent_index >= index) {
                return error.InvalidTreeLayout;
            }
        }
    }

    for (states, nodes) |state, node| {
        if (state.remaining_installs == 0) continue;
        var ancestor_id = node.id;
        while (ancestor_id != invalid_id) {
            const ancestor_index: usize = @intCast(ancestor_id);
            states[ancestor_index].unfinished_subtree_count = std.math.add(
                usize,
                states[ancestor_index].unfinished_subtree_count,
                1,
            ) catch return error.InvalidTreeLayout;
            ancestor_id = nodes[ancestor_index].parent;
        }
    }
}

pub fn complete(states: anytype, nodes: anytype, tree_id: anytype, invalid_id: anytype) Transition {
    const tree_index: usize = @intCast(tree_id);
    std.debug.assert(tree_index < states.len);
    const state = &states[tree_index];
    if (state.remaining_installs == 0) return .already_completed;

    state.remaining_installs -= 1;
    if (state.remaining_installs != 0) return .pending;

    var ancestor_id: @TypeOf(nodes[tree_index].id) = @intCast(tree_id);
    while (ancestor_id != invalid_id) {
        const ancestor_index: usize = @intCast(ancestor_id);
        std.debug.assert(states[ancestor_index].unfinished_subtree_count > 0);
        states[ancestor_index].unfinished_subtree_count -= 1;
        ancestor_id = nodes[ancestor_index].parent;
    }
    return .completed;
}

pub fn ancestorsComplete(states: anytype, nodes: anytype, tree_id: anytype, invalid_id: anytype) bool {
    const tree_index: usize = @intCast(tree_id);
    var ancestor_id = nodes[tree_index].parent;
    while (ancestor_id != invalid_id) {
        const ancestor_index: usize = @intCast(ancestor_id);
        if (states[ancestor_index].remaining_installs != 0) return false;
        ancestor_id = nodes[ancestor_index].parent;
    }
    return true;
}

pub fn subtreeComplete(states: anytype, tree_id: anytype) bool {
    return states[@intCast(tree_id)].unfinished_subtree_count == 0;
}
