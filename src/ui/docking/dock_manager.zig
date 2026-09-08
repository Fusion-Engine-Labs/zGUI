const std = @import("std");
const types = @import("../core/types.zig");
const dock_node = @import("dock_node.zig");

pub const DockManager = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(dock_node.DockNode) = .empty,
    generations: std.ArrayList(u8) = .empty,
    alive: std.ArrayList(bool) = .empty,
    // Slots vacated by collapsed splits are reused with a new generation so
    // the array stays bounded without allowing stale IDs to alias new nodes.
    free_list: std.ArrayList(u32) = .empty,
    window_leaves: std.AutoHashMap(types.WindowId, types.DockNodeId),
    root: types.DockNodeId = types.invalid_dock_node,
    active_resize: ?ResizeState = null,
    layout_dirty: bool = true,
    last_layout_rect: ?types.Rect = null,
    revision: u32 = 1,

    pub const SplitResult = struct {
        split: types.DockNodeId,
        old_node: types.DockNodeId,
        new_leaf: types.DockNodeId,
    };

    pub const ResizeState = struct {
        split: types.DockNodeId,
        start_mouse_pos: types.Vec2,
        start_ratio: f32,
    };

    pub fn init(allocator: std.mem.Allocator) !DockManager {
        var self: DockManager = .{
            .allocator = allocator,
            .window_leaves = std.AutoHashMap(types.WindowId, types.DockNodeId).init(allocator),
        };
        self.root = try self.appendNode(.{ .leaf = .{} });
        return self;
    }

    pub fn deinit(self: *DockManager) void {
        self.window_leaves.deinit();
        for (self.nodes.items, self.alive.items) |*node, alive| {
            if (alive) node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        self.alive.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dockWindow(
        self: *DockManager,
        window: types.WindowId,
        target: types.DockNodeId,
        position: dock_node.DockPosition,
    ) !void {
        try self.window_leaves.ensureTotalCapacity(self.window_leaves.count() + 1);
        // Validate the target before removeWindow can collapse leaves under it.
        _ = self.resolveNode(target) orelse return error.InvalidDockTarget;
        try self.removeWindow(window, false);

        if (position == .center_tab) {
            try self.attachToLeaf(target, window);
            self.cleanupEmptyLeaves();
            self.revision +%= 1;
            return;
        }

        const result = try self.splitNode(target, position, defaultDockSplitRatio(position));
        self.attachToLeaf(result.new_leaf, window) catch unreachable;
        self.cleanupEmptyLeaves();
        self.revision +%= 1;
    }

    /// Adds a window as the active tab of a leaf. Callers must have reserved
    /// `window_leaves` capacity, which is what lets the map write not fail
    /// after the tab list has already been appended to.
    fn attachToLeaf(self: *DockManager, leaf_id: types.DockNodeId, window: types.WindowId) !void {
        const node = self.resolveNode(leaf_id) orelse return error.InvalidDockTarget;
        switch (node.*) {
            .leaf => |*leaf| {
                try leaf.tabs.append(self.allocator, window);
                leaf.active_tab = leaf.tabs.items.len - 1;
                self.window_leaves.putAssumeCapacity(window, leaf_id);
            },
            .split => return error.InvalidDockTarget,
        }
    }

    pub fn moveWindowToLeaf(self: *DockManager, window: types.WindowId, target: types.DockNodeId) !void {
        try self.window_leaves.ensureTotalCapacity(self.window_leaves.count() + 1);
        _ = self.resolveNode(target) orelse return error.InvalidDockTarget;
        try self.removeWindow(window, false);
        try self.attachToLeaf(target, window);
        self.cleanupEmptyLeaves();
        self.revision +%= 1;
    }

    pub fn splitNode(
        self: *DockManager,
        target: types.DockNodeId,
        position: dock_node.DockPosition,
        ratio: f32,
    ) !SplitResult {
        const target_index = self.slotIndex(target) orelse return error.InvalidDockTarget;
        if (position == .center_tab) return error.InvalidDockTarget;

        const old = self.nodes.items[target_index];
        const new_id = try self.appendNode(.{ .leaf = .{} });
        errdefer self.releaseSubtree(new_id);
        const old_id = try self.appendNode(old);
        switch (old) {
            .leaf => |leaf| for (leaf.tabs.items) |window| self.window_leaves.putAssumeCapacity(window, old_id),
            .split => {},
        }
        const axis: dock_node.Axis = switch (position) {
            .left, .right => .x,
            .top, .bottom => .y,
            .center_tab => unreachable,
        };

        const first = switch (position) {
            .left, .top => new_id,
            .right, .bottom => old_id,
            .center_tab => unreachable,
        };
        const second = if (first == new_id) old_id else new_id;

        self.nodes.items[target_index] = .{ .split = .{
            .axis = axis,
            .ratio = sanitizeRatio(ratio),
            .first = first,
            .second = second,
        } };
        self.layout_dirty = true;
        self.revision +%= 1;

        return .{
            .split = target,
            .old_node = old_id,
            .new_leaf = new_id,
        };
    }

    pub fn undockWindow(self: *DockManager, window: types.WindowId) !void {
        try self.removeWindow(window, true);
    }

    fn removeWindow(self: *DockManager, window: types.WindowId, cleanup: bool) !void {
        const leaf_id = self.window_leaves.get(window) orelse return;
        const node = self.resolveNode(leaf_id) orelse {
            _ = self.window_leaves.remove(window);
            return;
        };
        switch (node.*) {
            .leaf => |*leaf| {
                for (leaf.tabs.items, 0..) |tab, i| {
                    if (tab != window) continue;
                    _ = leaf.tabs.orderedRemove(i);
                    _ = self.window_leaves.remove(window);
                    if (leaf.active_tab >= leaf.tabs.items.len) {
                        leaf.active_tab = if (leaf.tabs.items.len == 0) 0 else leaf.tabs.items.len - 1;
                    }
                    if (cleanup) self.cleanupEmptyLeaves();
                    self.revision +%= 1;
                    return;
                }
            },
            .split => {},
        }
        _ = self.window_leaves.remove(window);
    }

    pub fn leafForWindow(self: *const DockManager, window: types.WindowId) ?types.DockNodeId {
        const leaf = self.window_leaves.get(window) orelse return null;
        return if (self.resolveNodeConst(leaf) != null) leaf else null;
    }

    pub fn activeWindow(self: *const DockManager, leaf_id: types.DockNodeId) ?types.WindowId {
        const leaf_node = self.resolveNodeConst(leaf_id) orelse return null;
        return switch (leaf_node.*) {
            .leaf => |leaf| if (leaf.tabs.items.len == 0) null else leaf.tabs.items[@min(leaf.active_tab, leaf.tabs.items.len - 1)],
            .split => null,
        };
    }

    pub fn setActiveWindow(self: *DockManager, leaf_id: types.DockNodeId, window: types.WindowId) bool {
        const leaf_node = self.resolveNode(leaf_id) orelse return false;
        switch (leaf_node.*) {
            .leaf => |*leaf| {
                for (leaf.tabs.items, 0..) |tab, i| {
                    if (tab == window) {
                        leaf.active_tab = i;
                        return true;
                    }
                }
            },
            .split => {},
        }
        return false;
    }

    pub fn layout(self: *DockManager, available: types.Rect) void {
        if (!self.layout_dirty) {
            if (self.last_layout_rect) |last| if (std.meta.eql(last, available)) return;
        }
        self.layoutNode(self.root, available);
        self.last_layout_rect = available;
        self.layout_dirty = false;
    }

    pub fn setSplitMinimums(self: *DockManager, split_id: types.DockNodeId, min_first_size: f32, min_second_size: f32) !void {
        const split = self.splitPtr(split_id) orelse return error.InvalidDockTarget;
        split.min_first_size = @max(0, min_first_size);
        split.min_second_size = @max(0, min_second_size);
        split.ratio = clampRatio(split.*, split.ratio, split.rect);
        self.layout_dirty = true;
    }

    pub fn splitRatio(self: *const DockManager, split_id: types.DockNodeId) ?f32 {
        const split = self.splitConstPtr(split_id) orelse return null;
        return split.ratio;
    }

    pub fn splitAxis(self: *const DockManager, split_id: types.DockNodeId) ?dock_node.Axis {
        const split = self.splitConstPtr(split_id) orelse return null;
        return split.axis;
    }

    pub fn nodeRect(self: *const DockManager, id: types.DockNodeId) ?types.Rect {
        const dock = self.resolveNodeConst(id) orelse return null;
        return switch (dock.*) {
            .leaf => |leaf| leaf.rect,
            .split => |split| split.rect,
        };
    }

    pub fn beginResize(self: *DockManager, split_id: types.DockNodeId, mouse_pos: types.Vec2) !void {
        const split = self.splitConstPtr(split_id) orelse return error.InvalidDockTarget;
        self.active_resize = .{
            .split = split_id,
            .start_mouse_pos = mouse_pos,
            .start_ratio = split.ratio,
        };
    }

    pub fn updateResize(self: *DockManager, mouse_pos: types.Vec2) bool {
        const resize = self.active_resize orelse return false;
        const split = self.splitPtr(resize.split) orelse {
            self.active_resize = null;
            return false;
        };

        const major = majorSize(split.rect, split.axis);
        if (major <= 0) return false;

        const delta = switch (split.axis) {
            .x => mouse_pos.x - resize.start_mouse_pos.x,
            .y => mouse_pos.y - resize.start_mouse_pos.y,
        };
        const next_ratio = clampRatio(split.*, resize.start_ratio + delta / major, split.rect);
        const changed = @abs(split.ratio - next_ratio) > 0.0001;
        split.ratio = next_ratio;
        if (changed) self.layout_dirty = true;
        return changed;
    }

    pub fn endResize(self: *DockManager) void {
        self.active_resize = null;
    }

    pub fn activeResizeSplit(self: *const DockManager) ?types.DockNodeId {
        return if (self.active_resize) |resize| resize.split else null;
    }

    pub fn resizeHandleRect(self: *const DockManager, split_id: types.DockNodeId, thickness: f32) ?types.Rect {
        const split = self.splitConstPtr(split_id) orelse return null;
        return handleRectForSplit(split.*, @max(0, thickness));
    }

    pub fn hitTestResizeHandle(self: *const DockManager, mouse_pos: types.Vec2, thickness: f32) ?types.DockNodeId {
        return self.hitTestResizeHandleNode(self.root, mouse_pos, @max(0, thickness));
    }

    pub fn hitTestLeaf(self: *const DockManager, mouse_pos: types.Vec2) ?types.DockNodeId {
        return self.hitTestLeafNode(self.root, mouse_pos);
    }

    fn layoutNode(self: *DockManager, id: types.DockNodeId, rect: types.Rect) void {
        const dock = self.resolveNode(id) orelse return;
        switch (dock.*) {
            .leaf => |*leaf| leaf.rect = rect,
            .split => |*split| {
                split.rect = rect;
                split.ratio = clampRatio(split.*, split.ratio, rect);
                if (split.axis == .x) {
                    const first_w = rect.w * split.ratio;
                    self.layoutNode(split.first, .{ .x = rect.x, .y = rect.y, .w = first_w, .h = rect.h });
                    self.layoutNode(split.second, .{ .x = rect.x + first_w, .y = rect.y, .w = rect.w - first_w, .h = rect.h });
                } else {
                    const first_h = rect.h * split.ratio;
                    self.layoutNode(split.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_h });
                    self.layoutNode(split.second, .{ .x = rect.x, .y = rect.y + first_h, .w = rect.w, .h = rect.h - first_h });
                }
            },
        }
    }

    fn appendNode(self: *DockManager, node: dock_node.DockNode) !types.DockNodeId {
        if (self.free_list.pop()) |index| {
            const generation = types.nextGeneration(self.generations.items[index]);
            self.nodes.items[index] = node;
            self.generations.items[index] = generation;
            self.alive.items[index] = true;
            return types.makeDockNodeId(index, generation);
        }
        const index: u32 = @intCast(self.nodes.items.len);
        if (index > types.max_node_index) return error.TooManyDockNodes;
        try self.nodes.append(self.allocator, node);
        errdefer _ = self.nodes.pop();
        try self.generations.append(self.allocator, 1);
        errdefer _ = self.generations.pop();
        try self.alive.append(self.allocator, true);
        return types.makeDockNodeId(index, 1);
    }

    /// Recycles a subtree that is no longer reachable from the root,
    /// releasing tab storage and returning every slot to the free list.
    fn releaseSubtree(self: *DockManager, id: types.DockNodeId) void {
        const index = self.slotIndex(id) orelse return;
        switch (self.nodes.items[index]) {
            .leaf => |*leaf| {
                for (leaf.tabs.items) |window| _ = self.window_leaves.remove(window);
                leaf.tabs.deinit(self.allocator);
            },
            .split => |split| {
                self.releaseSubtree(split.first);
                self.releaseSubtree(split.second);
            },
        }
        self.nodes.items[index] = .{ .leaf = .{} };
        self.alive.items[index] = false;
        self.free_list.append(self.allocator, index) catch {};
    }

    fn splitPtr(self: *DockManager, id: types.DockNodeId) ?*dock_node.DockSplit {
        const dock = self.resolveNode(id) orelse return null;
        return switch (dock.*) {
            .leaf => null,
            .split => |*split| split,
        };
    }

    fn splitConstPtr(self: *const DockManager, id: types.DockNodeId) ?*const dock_node.DockSplit {
        const dock = self.resolveNodeConst(id) orelse return null;
        return switch (dock.*) {
            .leaf => null,
            .split => |*split| split,
        };
    }

    fn hitTestResizeHandleNode(self: *const DockManager, id: types.DockNodeId, mouse_pos: types.Vec2, thickness: f32) ?types.DockNodeId {
        const dock = self.resolveNodeConst(id) orelse return null;
        switch (dock.*) {
            .leaf => return null,
            .split => |split| {
                if (self.hitTestResizeHandleNode(split.first, mouse_pos, thickness)) |hit| return hit;
                if (self.hitTestResizeHandleNode(split.second, mouse_pos, thickness)) |hit| return hit;
                if (handleRectForSplit(split, thickness).contains(mouse_pos)) return id;
                return null;
            },
        }
    }

    fn hitTestLeafNode(self: *const DockManager, id: types.DockNodeId, mouse_pos: types.Vec2) ?types.DockNodeId {
        const dock = self.resolveNodeConst(id) orelse return null;
        switch (dock.*) {
            .leaf => |leaf| return if (leaf.rect.contains(mouse_pos)) id else null,
            .split => |split| {
                if (self.hitTestLeafNode(split.first, mouse_pos)) |hit| return hit;
                if (self.hitTestLeafNode(split.second, mouse_pos)) |hit| return hit;
                return null;
            },
        }
    }

    fn cleanupEmptyLeaves(self: *DockManager) void {
        _ = self.collapseEmptyChild(self.root);
        self.layout_dirty = true;
    }

    fn collapseEmptyChild(self: *DockManager, id: types.DockNodeId) bool {
        const dock = self.resolveNodeConst(id) orelse return false;
        switch (dock.*) {
            .leaf => |leaf| return leaf.tabs.items.len == 0,
            .split => |split| {
                const first_empty = self.collapseEmptyChild(split.first);
                const second_empty = self.collapseEmptyChild(split.second);
                if (first_empty and !second_empty) {
                    self.replaceNodeWith(id, split.second);
                    self.releaseSubtree(split.first);
                    return self.collapseEmptyChild(id);
                }
                if (second_empty and !first_empty) {
                    self.replaceNodeWith(id, split.first);
                    self.releaseSubtree(split.second);
                    return self.collapseEmptyChild(id);
                }
                return first_empty and second_empty;
            },
        }
    }

    fn replaceNodeWith(self: *DockManager, dst: types.DockNodeId, src: types.DockNodeId) void {
        const dst_index = self.slotIndex(dst) orelse return;
        const src_index = self.slotIndex(src) orelse return;
        const moved = self.nodes.items[src_index];
        self.nodes.items[src_index] = .{ .leaf = .{} };
        self.nodes.items[dst_index] = moved;
        switch (moved) {
            .leaf => |leaf| for (leaf.tabs.items) |window| self.window_leaves.put(window, dst) catch {},
            .split => {},
        }
        self.alive.items[src_index] = false;
        // The src slot's content now lives at dst; recycle the vacated slot.
        self.free_list.append(self.allocator, src_index) catch {};
    }

    pub fn resolveNode(self: *DockManager, id: types.DockNodeId) ?*dock_node.DockNode {
        const index = self.slotIndex(id) orelse return null;
        return &self.nodes.items[index];
    }

    pub fn resolveNodeConst(self: *const DockManager, id: types.DockNodeId) ?*const dock_node.DockNode {
        const index = self.slotIndex(id) orelse return null;
        return &self.nodes.items[index];
    }

    pub fn idForSlot(self: *const DockManager, index: usize) ?types.DockNodeId {
        if (index >= self.nodes.items.len or !self.alive.items[index]) return null;
        return types.makeDockNodeId(@intCast(index), self.generations.items[index]);
    }

    fn slotIndex(self: *const DockManager, id: types.DockNodeId) ?u32 {
        if (id == types.invalid_dock_node) return null;
        const index = types.dockNodeIndex(id);
        if (index >= self.nodes.items.len or !self.alive.items[index]) return null;
        if (self.generations.items[index] != types.dockNodeGeneration(id)) return null;
        return index;
    }
};

fn handleRectForSplit(split: dock_node.DockSplit, thickness: f32) types.Rect {
    const half = thickness * 0.5;
    return switch (split.axis) {
        .x => .{
            .x = split.rect.x + split.rect.w * split.ratio - half,
            .y = split.rect.y,
            .w = thickness,
            .h = split.rect.h,
        },
        .y => .{
            .x = split.rect.x,
            .y = split.rect.y + split.rect.h * split.ratio - half,
            .w = split.rect.w,
            .h = thickness,
        },
    };
}

fn clampRatio(split: dock_node.DockSplit, ratio: f32, rect: types.Rect) f32 {
    const clean_ratio = sanitizeRatio(ratio);
    const major = majorSize(rect, split.axis);
    if (major <= 0) return clean_ratio;

    const min_ratio = @min(1, split.min_first_size / major);
    const max_ratio = @max(0, 1 - split.min_second_size / major);
    if (min_ratio > max_ratio) {
        const total_min = split.min_first_size + split.min_second_size;
        if (total_min > 0) return split.min_first_size / total_min;
        return 0.5;
    }
    return @min(max_ratio, @max(min_ratio, clean_ratio));
}

fn majorSize(rect: types.Rect, axis: dock_node.Axis) f32 {
    return switch (axis) {
        .x => rect.w,
        .y => rect.h,
    };
}

fn sanitizeRatio(ratio: f32) f32 {
    if (!std.math.isFinite(ratio)) return 0.5;
    return @min(1, @max(0, ratio));
}

fn defaultDockSplitRatio(position: dock_node.DockPosition) f32 {
    return switch (position) {
        .left, .top => 0.25,
        .right, .bottom => 0.75,
        .center_tab => 0.5,
    };
}

fn expectApprox(expected: f32, actual: f32) !void {
    try std.testing.expect(@abs(expected - actual) < 0.001);
}

test "horizontal split resize updates ratio from pointer delta" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const split = try dock.splitNode(dock.root, .left, 0.25);
    dock.layout(.{ .x = 0, .y = 0, .w = 1000, .h = 600 });

    try dock.beginResize(split.split, .{ .x = 250, .y = 0 });
    try std.testing.expect(dock.updateResize(.{ .x = 350, .y = 0 }));
    try expectApprox(0.35, dock.splitRatio(split.split).?);
}

test "vertical split resize updates ratio from pointer delta" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const split = try dock.splitNode(dock.root, .bottom, 0.8);
    dock.layout(.{ .x = 0, .y = 0, .w = 800, .h = 500 });

    try dock.beginResize(split.split, .{ .x = 0, .y = 400 });
    try std.testing.expect(dock.updateResize(.{ .x = 0, .y = 300 }));
    try expectApprox(0.6, dock.splitRatio(split.split).?);
}

test "split resize clamps to configured child minimum sizes" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const split = try dock.splitNode(dock.root, .left, 0.5);
    try dock.setSplitMinimums(split.split, 200, 300);
    dock.layout(.{ .x = 0, .y = 0, .w = 1000, .h = 500 });

    try dock.beginResize(split.split, .{ .x = 500, .y = 0 });
    try std.testing.expect(dock.updateResize(.{ .x = 0, .y = 0 }));
    try expectApprox(0.2, dock.splitRatio(split.split).?);

    try dock.beginResize(split.split, .{ .x = 200, .y = 0 });
    try std.testing.expect(dock.updateResize(.{ .x = 1000, .y = 0 }));
    try expectApprox(0.7, dock.splitRatio(split.split).?);
}

test "resize handle hit testing returns split under handle rect" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const split = try dock.splitNode(dock.root, .left, 0.25);
    dock.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });

    try std.testing.expectEqual(split.split, dock.hitTestResizeHandle(.{ .x = 25, .y = 50 }, 10).?);
    try std.testing.expect(dock.hitTestResizeHandle(.{ .x = 10, .y = 50 }, 10) == null);
}

test "repeated dock and undock reuses node slots" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const a: types.WindowId = 1;
    const b: types.WindowId = 2;
    try dock.moveWindowToLeaf(a, dock.root);

    try dock.dockWindow(b, dock.root, .right);
    const baseline = dock.nodes.items.len;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try dock.undockWindow(b);
        try dock.dockWindow(b, dock.leafForWindow(a).?, .right);
    }

    try std.testing.expectEqual(baseline, dock.nodes.items.len);
    try std.testing.expect(dock.leafForWindow(a) != null);
    try std.testing.expect(dock.leafForWindow(b) != null);
}

test "reused dock slots reject stale handles" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const a: types.WindowId = 1;
    const b: types.WindowId = 2;
    try dock.moveWindowToLeaf(a, dock.root);
    try dock.dockWindow(b, dock.root, .right);
    const stale = dock.leafForWindow(b).?;

    try dock.undockWindow(b);
    try std.testing.expect(dock.resolveNodeConst(stale) == null);

    try dock.dockWindow(b, dock.leafForWindow(a).?, .right);
    const reused = dock.leafForWindow(b).?;
    try std.testing.expect(stale != reused);
    try std.testing.expectEqual(types.dockNodeIndex(stale), types.dockNodeIndex(reused));
}

test "redocking center leaf into right leaf preserves surrounding dock tree" {
    var dock = try DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const viewport: types.WindowId = 1;
    const console: types.WindowId = 2;
    const scene: types.WindowId = 3;
    const inspector: types.WindowId = 4;

    try dock.moveWindowToLeaf(viewport, dock.root);
    const bottom = try dock.splitNode(dock.root, .bottom, 0.82);
    try dock.moveWindowToLeaf(console, bottom.new_leaf);

    const left = try dock.splitNode(bottom.old_node, .left, 0.18);
    try dock.moveWindowToLeaf(scene, left.new_leaf);

    const right = try dock.splitNode(left.old_node, .right, 0.72);
    try dock.moveWindowToLeaf(inspector, right.new_leaf);

    try dock.dockWindow(viewport, right.new_leaf, .right);
    dock.layout(.{ .x = 0, .y = 0, .w = 1200, .h = 800 });

    try std.testing.expect(dock.leafForWindow(scene) != null);
    try std.testing.expect(dock.leafForWindow(viewport) != null);
    try std.testing.expect(dock.leafForWindow(inspector) != null);
    try std.testing.expect(dock.leafForWindow(console) != null);
    try std.testing.expect((dock.nodeRect(dock.leafForWindow(viewport).?) orelse .{}).w > 0);
    try std.testing.expect((dock.nodeRect(dock.leafForWindow(inspector).?) orelse .{}).w > 0);
}
