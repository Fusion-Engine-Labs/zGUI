const std = @import("std");
const types = @import("types.zig");
const node_mod = @import("node.zig");

pub const DirtyCounts = struct {
    layout: u32 = 0,
    paint: u32 = 0,
};

pub const UiTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(node_mod.Node) = .empty,
    free_list: std.ArrayList(u32) = .empty,
    dirty_nodes: std.ArrayList(types.NodeId) = .empty,
    dirty_tracking_lost: bool = false,

    pub fn init(allocator: std.mem.Allocator) UiTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *UiTree) void {
        for (self.nodes.items) |*node| {
            if (node.text_storage) |storage| self.allocator.free(storage);
        }
        self.nodes.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.dirty_nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createNode(self: *UiTree, kind: node_mod.NodeKind) !types.NodeId {
        if (self.free_list.pop()) |index| {
            const slot = &self.nodes.items[index];
            const next_generation = types.nextGeneration(slot.generation);
            const id = types.makeNodeId(index, next_generation);
            slot.* = node_mod.Node.init(id, next_generation, kind);
            try self.dirty_nodes.append(self.allocator, id);
            slot.dirty.queued = true;
            return id;
        }

        const index: u32 = @intCast(self.nodes.items.len);
        if (index > types.max_node_index) return error.TooManyNodes;
        const id = types.makeNodeId(index, 1);
        try self.nodes.append(self.allocator, node_mod.Node.init(id, 1, kind));
        try self.dirty_nodes.append(self.allocator, id);
        self.nodes.items[index].dirty.queued = true;
        return id;
    }

    /// Removes node storage without clearing Ui-owned interaction or handler
    /// state. Application and widget code must use Ui.destroySubtree instead.
    pub fn destroyNodeUnmanaged(self: *UiTree, id: types.NodeId) void {
        var node = self.get(id) orelse return;

        while (node.first_child != types.invalid_node) {
            const child = node.first_child;
            self.destroyNodeUnmanaged(child);
            node = self.get(id) orelse return;
        }

        if (node.parent != types.invalid_node) {
            self.removeChild(node.parent, id);
            node = self.get(id) orelse return;
        }

        if (node.text_storage) |storage| self.allocator.free(storage);
        node.text = null;
        node.text_storage = null;
        node.alive = false;
        node.parent = types.invalid_node;
        node.first_child = types.invalid_node;
        node.last_child = types.invalid_node;
        node.next_sibling = types.invalid_node;
        node.prev_sibling = types.invalid_node;
        node.image = null;
        node.flags = .{ .visible = false };
        self.free_list.append(self.allocator, types.nodeIndex(id)) catch {};
    }

    /// Copies `bytes` into tree-owned storage. No-op when the text is
    /// unchanged, so it is safe (and cheap) to call every frame.
    pub fn setText(self: *UiTree, id: types.NodeId, bytes: []const u8) !void {
        const node = self.get(id) orelse return;
        if (node.text) |existing| {
            if (std.mem.eql(u8, existing, bytes)) return;
        }
        if (node.text_storage) |storage| {
            if (storage.len >= bytes.len) {
                @memcpy(storage[0..bytes.len], bytes);
                node.text = storage[0..bytes.len];
            } else {
                const capacity = @max(bytes.len, storage.len * 2);
                const next = try self.allocator.alloc(u8, capacity);
                @memcpy(next[0..bytes.len], bytes);
                self.allocator.free(storage);
                node.text_storage = next;
                node.text = next[0..bytes.len];
            }
        } else {
            const capacity = @max(bytes.len, 16);
            const storage = try self.allocator.alloc(u8, capacity);
            @memcpy(storage[0..bytes.len], bytes);
            node.text_storage = storage;
            node.text = storage[0..bytes.len];
        }
        node.dirty.text = true;
        node.text_revision +%= 1;
        self.markLayoutDirty(id);
    }

    pub fn appendChild(self: *UiTree, parent: types.NodeId, child: types.NodeId) !void {
        if (parent == child) return;
        const parent_node = self.get(parent) orelse return;
        const child_node = self.get(child) orelse return;

        // Already the last child of this parent: nothing to do, and no dirty
        // marks, so per-frame re-appends stay free in the steady state.
        if (child_node.parent == parent and parent_node.last_child == child) return;

        if (child_node.parent != types.invalid_node) {
            self.removeChild(child_node.parent, child);
        }

        child_node.parent = parent;
        child_node.prev_sibling = parent_node.last_child;
        child_node.next_sibling = types.invalid_node;

        if (parent_node.last_child != types.invalid_node) {
            self.get(parent_node.last_child).?.next_sibling = child;
        } else {
            parent_node.first_child = child;
        }
        parent_node.last_child = child;
        parent_node.dirty.children = true;
        self.markLayoutDirty(parent);
    }

    pub fn removeChild(self: *UiTree, parent: types.NodeId, child: types.NodeId) void {
        const parent_node = self.get(parent) orelse return;
        const child_node = self.get(child) orelse return;
        if (child_node.parent != parent) return;

        if (child_node.prev_sibling != types.invalid_node) {
            self.get(child_node.prev_sibling).?.next_sibling = child_node.next_sibling;
        } else {
            parent_node.first_child = child_node.next_sibling;
        }

        if (child_node.next_sibling != types.invalid_node) {
            self.get(child_node.next_sibling).?.prev_sibling = child_node.prev_sibling;
        } else {
            parent_node.last_child = child_node.prev_sibling;
        }

        child_node.parent = types.invalid_node;
        child_node.next_sibling = types.invalid_node;
        child_node.prev_sibling = types.invalid_node;
        parent_node.dirty.children = true;
        self.markLayoutDirty(parent);
    }

    pub fn get(self: *UiTree, id: types.NodeId) ?*node_mod.Node {
        if (id == types.invalid_node) return null;
        const index = types.nodeIndex(id);
        if (index >= self.nodes.items.len) return null;
        const node = &self.nodes.items[index];
        if (!node.alive or node.generation != types.nodeGeneration(id)) return null;
        return node;
    }

    pub fn getConst(self: *const UiTree, id: types.NodeId) ?*const node_mod.Node {
        if (id == types.invalid_node) return null;
        const index = types.nodeIndex(id);
        if (index >= self.nodes.items.len) return null;
        const node = &self.nodes.items[index];
        if (!node.alive or node.generation != types.nodeGeneration(id)) return null;
        return node;
    }

    pub fn queueDirty(self: *UiTree, id: types.NodeId) void {
        const node = self.get(id) orelse return;
        if (node.dirty.queued) return;
        self.dirty_nodes.append(self.allocator, id) catch {
            self.dirty_tracking_lost = true;
            return;
        };
        node.dirty.queued = true;
    }

    /// True when `candidate` is `ancestor` or sits anywhere beneath it. The
    /// tree owns the parent pointers, so containment questions — popup
    /// dismissal, focus and hover scoping — are answered here rather than by a
    /// hand-rolled walk per widget.
    pub fn isDescendantOf(self: *const UiTree, candidate: types.NodeId, ancestor: types.NodeId) bool {
        var current = candidate;
        while (current != types.invalid_node) {
            if (current == ancestor) return true;
            current = (self.getConst(current) orelse return false).parent;
        }
        return false;
    }

    /// Marks a node and every layout-dependent ancestor. Once a previously
    /// propagated node is reached, all remaining ancestors are already dirty.
    pub fn markLayoutDirty(self: *UiTree, id: types.NodeId) void {
        var current = id;
        while (self.get(current)) |node| {
            if (node.dirty.layout_propagated) break;
            node.dirty.layout = true;
            node.dirty.paint = true;
            self.queueDirty(current);
            node.dirty.layout_propagated = true;
            current = node.parent;
            if (current == types.invalid_node) break;
        }
    }

    /// Marks a whole subtree for re-measurement. Layout skips a hidden subtree
    /// entirely, yet the frame that hid it still clears its dirty flags, so any
    /// measurement inside it goes stale with nothing left to record the debt.
    /// Revealing the subtree is where that debt comes due.
    pub fn markSubtreeDirty(self: *UiTree, id: types.NodeId) void {
        const node = self.get(id) orelse return;
        node.dirty.layout = true;
        node.dirty.paint = true;
        node.dirty.text = true;
        self.queueDirty(id);

        var child = node.first_child;
        while (child != types.invalid_node) {
            const next = (self.getConst(child) orelse break).next_sibling;
            self.markSubtreeDirty(child);
            child = next;
        }
    }

    pub fn dirtyCounts(self: *const UiTree) DirtyCounts {
        var result: DirtyCounts = .{};
        if (self.dirty_tracking_lost) {
            for (self.nodes.items) |node| {
                if (!node.alive) continue;
                if (node.dirty.layout) result.layout += 1;
                if (node.dirty.paint) result.paint += 1;
            }
            return result;
        }
        for (self.dirty_nodes.items) |id| {
            const node = self.getConst(id) orelse continue;
            if (node.dirty.layout) result.layout += 1;
            if (node.dirty.paint) result.paint += 1;
        }
        return result;
    }

    pub fn clearTrackedDirty(self: *UiTree) void {
        if (self.dirty_tracking_lost) {
            for (self.nodes.items) |*node| {
                if (node.alive) node.dirty = .{};
            }
        } else {
            for (self.dirty_nodes.items) |id| {
                if (self.get(id)) |node| node.dirty = .{};
            }
        }
        self.dirty_nodes.clearRetainingCapacity();
        self.dirty_tracking_lost = false;
    }
};

test "node slots are reused with fresh generations" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try tree.createNode(.panel);
    tree.destroyNodeUnmanaged(a);
    const b = try tree.createNode(.label);
    try std.testing.expectEqual(types.nodeIndex(a), types.nodeIndex(b));
    try std.testing.expect(a != b);
    try std.testing.expectEqual(node_mod.NodeKind.label, tree.get(b).?.kind);
}

test "stale node ids do not resolve after slot reuse" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const a = try tree.createNode(.panel);
    tree.destroyNodeUnmanaged(a);
    const b = try tree.createNode(.button);
    try std.testing.expect(tree.get(a) == null);
    try std.testing.expect(tree.getConst(a) == null);
    try std.testing.expect(tree.get(b) != null);
}

test "append and remove child maintain links" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const a = try tree.createNode(.panel);
    const b = try tree.createNode(.button);
    try tree.appendChild(root, a);
    try tree.appendChild(root, b);
    try std.testing.expectEqual(a, tree.get(root).?.first_child);
    try std.testing.expectEqual(b, tree.get(root).?.last_child);
    try std.testing.expectEqual(b, tree.get(a).?.next_sibling);
    tree.removeChild(root, a);
    try std.testing.expectEqual(b, tree.get(root).?.first_child);
    try std.testing.expectEqual(types.invalid_node, tree.get(b).?.prev_sibling);
}

test "re-appending the last child is a no-op" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const a = try tree.createNode(.panel);
    const b = try tree.createNode(.panel);
    try tree.appendChild(root, a);
    try tree.appendChild(root, b);
    tree.get(root).?.dirty = .{};

    try tree.appendChild(root, b);
    try std.testing.expect(!tree.get(root).?.dirty.children);
    try std.testing.expectEqual(b, tree.get(root).?.last_child);

    try tree.appendChild(root, a);
    try std.testing.expect(tree.get(root).?.dirty.children);
    try std.testing.expectEqual(a, tree.get(root).?.last_child);
}

test "setText copies into tree-owned storage and skips unchanged text" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const label = try tree.createNode(.label);
    var buf: [16]u8 = undefined;
    const first = try std.fmt.bufPrint(&buf, "hello {d}", .{1});
    try tree.setText(label, first);
    buf = @splat(0);
    try std.testing.expectEqualStrings("hello 1", tree.get(label).?.text.?);

    tree.get(label).?.dirty = .{};
    try tree.setText(label, "hello 1");
    try std.testing.expect(!tree.get(label).?.dirty.text);

    try tree.setText(label, "hello 2");
    try std.testing.expect(tree.get(label).?.dirty.text);
    try std.testing.expectEqualStrings("hello 2", tree.get(label).?.text.?);
}

test "setText reuses retained capacity for changing labels" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const label = try tree.createNode(.label);
    try tree.setText(label, "a longer value");
    const storage_ptr = tree.get(label).?.text_storage.?.ptr;

    try tree.setText(label, "short");
    try std.testing.expectEqual(storage_ptr, tree.get(label).?.text_storage.?.ptr);
    try std.testing.expectEqualStrings("short", tree.get(label).?.text.?);
}

test "dirty queue tracks the changed subset of a large retained tree" {
    var tree = UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    var last = root;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const panel = try tree.createNode(.panel);
        try tree.appendChild(root, panel);
        last = panel;
    }
    tree.clearTrackedDirty();

    tree.get(last).?.dirty.paint = true;
    tree.queueDirty(last);
    try std.testing.expectEqual(@as(usize, 1), tree.dirty_nodes.items.len);
    try std.testing.expectEqual(@as(u32, 1), tree.dirtyCounts().paint);
}
