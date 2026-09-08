const std = @import("std");
const types = @import("types.zig");
const style_mod = @import("style.zig");
const tree_mod = @import("tree.zig");
const node_mod = @import("node.zig");
const text_mod = @import("text.zig");
const font_atlas_mod = @import("../render/font_atlas.zig");

pub const Layout = struct {
    intrinsic: types.Vec2 = .{},
    content_size: types.Vec2 = .{},
    /// Conservative union of this node and all visible descendant bounds.
    visual_bounds: types.Rect = .{},
};

pub const LayoutStats = struct {
    measured_nodes: u32 = 0,
    positioned_nodes: u32 = 0,
    skipped_clean_subtrees: u32 = 0,
    skipped_hidden_nodes: u32 = 0,

    pub fn add(self: *LayoutStats, other: LayoutStats) void {
        self.measured_nodes += other.measured_nodes;
        self.positioned_nodes += other.positioned_nodes;
        self.skipped_clean_subtrees += other.skipped_clean_subtrees;
        self.skipped_hidden_nodes += other.skipped_hidden_nodes;
    }
};

const Axis = enum { x, y };

pub fn layoutTree(tree: *tree_mod.UiTree, root: types.NodeId, available: types.Vec2, font_atlas: ?*font_atlas_mod.FontAtlas) void {
    _ = layoutTreeMeasured(tree, root, available, font_atlas, true);
}

pub fn layoutTreeMeasured(tree: *tree_mod.UiTree, root: types.NodeId, available: types.Vec2, font_atlas: ?*font_atlas_mod.FontAtlas, force_full: bool) LayoutStats {
    var stats: LayoutStats = .{};
    const root_node = tree.get(root) orelse return stats;
    const next_root: types.Rect = .{ .x = 0, .y = 0, .w = available.x, .h = available.y };
    const root_changed = !std.meta.eql(root_node.bounds, next_root);
    root_node.bounds = next_root;
    _ = measureNode(tree, root, font_atlas, force_full, &stats);
    layoutChildren(tree, root, force_full or root_changed, &stats);
    return stats;
}

fn measureNode(tree: *tree_mod.UiTree, id: types.NodeId, font_atlas: ?*font_atlas_mod.FontAtlas, force_full: bool, stats: *LayoutStats) types.Vec2 {
    const node = tree.get(id) orelse return .{};
    if (!force_full and !node.dirty.layout) {
        stats.skipped_clean_subtrees += 1;
        return preferredSize(node);
    }
    stats.measured_nodes += 1;
    var measured: types.Vec2 = .{};

    if (node.text) |bytes| {
        if (!node.dirty.text and node.measured_text_font_size == node.style.font_size) {
            measured = node.measured_text;
        } else {
            const metrics = if (font_atlas) |atlas|
                atlas.measure(bytes, node.style.font_size)
            else
                text_mod.measureFallback(bytes, node.style.font_size);
            measured = metrics.size;
            node.measured_text = metrics.size;
            node.measured_text_font_size = node.style.font_size;
        }
    }

    var child = node.first_child;
    var child_count: usize = 0;
    while (child != types.invalid_node) {
        const child_node = tree.get(child) orelse break;
        if (!child_node.flags.visible) {
            stats.skipped_hidden_nodes += 1;
            child = child_node.next_sibling;
            continue;
        }
        const child_size = measureNode(tree, child, font_atlas, force_full, stats);
        child_count += 1;
        switch (node.style.direction) {
            .row => {
                measured.x += child_size.x + child_node.style.margin.horizontal();
                measured.y = @max(measured.y, child_size.y + child_node.style.margin.vertical());
            },
            .column, .absolute => {
                measured.x = @max(measured.x, child_size.x + child_node.style.margin.horizontal());
                measured.y += child_size.y + child_node.style.margin.vertical();
            },
        }
        child = child_node.next_sibling;
    }

    if (child_count > 1 and node.style.direction != .absolute) {
        const gaps = @as(f32, @floatFromInt(child_count - 1)) * node.style.gap;
        if (node.style.direction == .row) measured.x += gaps else measured.y += gaps;
    }

    measured.x += node.style.padding.horizontal();
    measured.y += node.style.padding.vertical();
    measured.x = @max(measured.x, node.style.min_width);
    measured.y = @max(measured.y, node.style.min_height);
    node.layout.intrinsic = measured;
    node.layout.content_size = .{
        .x = @max(0, measured.x - node.style.padding.horizontal()),
        .y = @max(0, measured.y - node.style.padding.vertical()),
    };
    return preferredSize(node);
}

fn preferredSize(node: *const @import("node.zig").Node) types.Vec2 {
    return .{
        .x = preferredIntrinsicSize(node.style.width, node.layout.intrinsic.x),
        .y = preferredIntrinsicSize(node.style.height, node.layout.intrinsic.y),
    };
}

fn preferredIntrinsicSize(size: style_mod.Size, measured: f32) f32 {
    return switch (size) {
        .px => |v| v,
        else => measured,
    };
}

fn layoutChildren(tree: *tree_mod.UiTree, id: types.NodeId, force_descend: bool, stats: *LayoutStats) void {
    const parent = tree.get(id) orelse return;
    stats.positioned_nodes += 1;
    // Content or viewport changes can invalidate a previously settled scroll
    // position without producing a wheel event. Clamp while the affected
    // branch is already being laid out so no separate whole-tree scroll walk
    // is needed.
    clampScrollOffsets(parent);
    const direction = parent.style.direction;
    const padding = parent.style.padding;
    const gap = parent.style.gap;
    var content: types.Rect = parent.bounds.inset(padding);
    content.x -= scrollForAxis(parent.style, parent.scroll_offset, .x);
    content.y -= scrollForAxis(parent.style, parent.scroll_offset, .y);

    switch (direction) {
        .absolute => layoutAbsolute(tree, parent.first_child, content, force_descend, stats),
        .row => layoutLinear(tree, parent.first_child, content, gap, .x, force_descend, stats),
        .column => layoutLinear(tree, parent.first_child, content, gap, .y, force_descend, stats),
    }
    updateVisualBounds(tree, id);
}

/// How far a node can scroll on each axis. Layout is the pass that knows
/// `content_size` is current, so it owns the limit and every other caller asks
/// it rather than restating the viewport arithmetic. Both axes come back at
/// once because this runs per node in the layout pass.
pub fn maxScrollOffsets(node: *const node_mod.Node) types.Vec2 {
    const viewport_width = @max(0, node.bounds.w - node.style.padding.horizontal());
    const viewport_height = @max(0, node.bounds.h - node.style.padding.vertical());
    return .{
        .x = @max(0, node.layout.content_size.x - viewport_width),
        .y = @max(0, node.layout.content_size.y - viewport_height),
    };
}

pub fn maxScroll(node: *const node_mod.Node, axis: enum { x, y }) f32 {
    const limits = maxScrollOffsets(node);
    return switch (axis) {
        .x => limits.x,
        .y => limits.y,
    };
}

pub fn clampScrollOffsets(node: *node_mod.Node) void {
    const limits = maxScrollOffsets(node);
    const max_x = limits.x;
    const max_y = limits.y;

    if (node.style.overflow_x == .scroll) {
        node.scroll_offset.x = std.math.clamp(node.scroll_offset.x, 0, max_x);
        node.scroll_target_offset.x = std.math.clamp(node.scroll_target_offset.x, 0, max_x);
    } else {
        node.scroll_offset.x = 0;
        node.scroll_target_offset.x = 0;
    }
    if (node.style.overflow_y == .scroll) {
        node.scroll_offset.y = std.math.clamp(node.scroll_offset.y, 0, max_y);
        node.scroll_target_offset.y = std.math.clamp(node.scroll_target_offset.y, 0, max_y);
    } else {
        node.scroll_offset.y = 0;
        node.scroll_target_offset.y = 0;
    }
}

fn layoutAbsolute(tree: *tree_mod.UiTree, first_child: types.NodeId, content: types.Rect, force_descend: bool, stats: *LayoutStats) void {
    var child = first_child;
    while (child != types.invalid_node) {
        const child_node = tree.get(child) orelse break;
        const next = child_node.next_sibling;
        if (!child_node.flags.visible) {
            stats.skipped_hidden_nodes += 1;
            child = next;
            continue;
        }
        const margin = child_node.style.margin;
        const width = resolveSize(child_node.style.width, .x, content, child_node.layout.intrinsic);
        const height = resolveSize(child_node.style.height, .y, content, child_node.layout.intrinsic);
        const next_bounds: types.Rect = .{
            .x = content.x + margin.left,
            .y = content.y + margin.top,
            .w = @max(width, child_node.style.min_width),
            .h = @max(height, child_node.style.min_height),
        };
        const bounds_changed = !std.meta.eql(child_node.bounds, next_bounds);
        child_node.bounds = next_bounds;
        if (force_descend or child_node.dirty.layout or bounds_changed) {
            layoutChildren(tree, child, force_descend or bounds_changed, stats);
        } else stats.skipped_clean_subtrees += 1;
        child = next;
    }
}

fn layoutLinear(tree: *tree_mod.UiTree, first_child: types.NodeId, content: types.Rect, gap: f32, axis: Axis, force_descend: bool, stats: *LayoutStats) void {
    var fixed_major: f32 = 0;
    var fill_count: usize = 0;
    var child_count: usize = 0;

    var child = first_child;
    while (child != types.invalid_node) {
        const child_node = tree.get(child) orelse break;
        if (!child_node.flags.visible) {
            stats.skipped_hidden_nodes += 1;
            child = child_node.next_sibling;
            continue;
        }
        child_count += 1;
        const margin_major = if (axis == .x) child_node.style.margin.horizontal() else child_node.style.margin.vertical();
        const min_major = if (axis == .x) child_node.style.min_width else child_node.style.min_height;
        if (sizeForAxis(child_node.style, axis) == .fill) {
            fill_count += 1;
            fixed_major += margin_major;
        } else {
            const resolved = resolveSize(sizeForAxis(child_node.style, axis), axis, content, child_node.layout.intrinsic);
            fixed_major += @max(resolved, min_major) + margin_major;
        }
        child = child_node.next_sibling;
    }

    if (child_count > 1) {
        fixed_major += @as(f32, @floatFromInt(child_count - 1)) * gap;
    }

    const available_major = if (axis == .x) content.w else content.h;
    const fill_major = if (fill_count == 0) 0 else @max(0, available_major - fixed_major) / @as(f32, @floatFromInt(fill_count));

    var cursor = if (axis == .x) content.x else content.y;
    child = first_child;
    while (child != types.invalid_node) {
        const child_node = tree.get(child) orelse break;
        const next = child_node.next_sibling;
        if (!child_node.flags.visible) {
            child = next;
            continue;
        }
        const margin = child_node.style.margin;
        const old_bounds = child_node.bounds;

        const width = if (axis == .x)
            resolveLinearSize(child_node.style.width, .x, content, child_node.layout.intrinsic, fill_major)
        else
            resolveSize(child_node.style.width, .x, content, child_node.layout.intrinsic);

        const height = if (axis == .y)
            resolveLinearSize(child_node.style.height, .y, content, child_node.layout.intrinsic, fill_major)
        else
            resolveSize(child_node.style.height, .y, content, child_node.layout.intrinsic);

        if (axis == .x) {
            cursor += margin.left;
            child_node.bounds = .{
                .x = cursor,
                .y = content.y + margin.top,
                .w = @max(width, child_node.style.min_width),
                .h = @max(height, child_node.style.min_height),
            };
            cursor += child_node.bounds.w + margin.right + gap;
        } else {
            cursor += margin.top;
            child_node.bounds = .{
                .x = content.x + margin.left,
                .y = cursor,
                .w = @max(width, child_node.style.min_width),
                .h = @max(height, child_node.style.min_height),
            };
            cursor += child_node.bounds.h + margin.bottom + gap;
        }

        const bounds_changed = !std.meta.eql(old_bounds, child_node.bounds);
        if (force_descend or child_node.dirty.layout or bounds_changed) {
            layoutChildren(tree, child, force_descend or bounds_changed, stats);
        } else stats.skipped_clean_subtrees += 1;
        child = next;
    }
}

fn updateVisualBounds(tree: *tree_mod.UiTree, id: types.NodeId) void {
    const node = tree.get(id) orelse return;
    // Text can extend slightly beyond the layout box because of glyph
    // bearings, and every primitive gets an antialiased edge. Keeping this
    // bound conservative makes subtree culling safe at clip boundaries.
    const outset = @max(@as(f32, 1), if (node.text != null) node.style.font_size * 0.25 else 0);
    var result = node.bounds.outset(outset);
    var child = node.first_child;
    while (child != types.invalid_node) {
        const child_node = tree.getConst(child) orelse break;
        if (child_node.flags.visible) result = unionRects(result, child_node.layout.visual_bounds);
        child = child_node.next_sibling;
    }
    node.layout.visual_bounds = result;
}

fn unionRects(a: types.Rect, b: types.Rect) types.Rect {
    if (a.isEmpty()) return b;
    if (b.isEmpty()) return a;
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn resolveLinearSize(size: style_mod.Size, axis: Axis, content: types.Rect, intrinsic: types.Vec2, fill_value: f32) f32 {
    return switch (size) {
        .fill => fill_value,
        else => resolveSize(size, axis, content, intrinsic),
    };
}

fn resolveSize(size: style_mod.Size, axis: Axis, content: types.Rect, intrinsic: types.Vec2) f32 {
    return switch (size) {
        .px => |v| v,
        .percent => |v| (if (axis == .x) content.w else content.h) * v,
        .fill => if (axis == .x) content.w else content.h,
        .hug => if (axis == .x) intrinsic.x else intrinsic.y,
    };
}

fn sizeForAxis(style: style_mod.Style, axis: Axis) style_mod.Size {
    return if (axis == .x) style.width else style.height;
}

fn scrollForAxis(style: style_mod.Style, scroll_offset: types.Vec2, axis: Axis) f32 {
    return switch (axis) {
        .x => if (style.overflow_x == .scroll) scroll_offset.x else 0,
        .y => if (style.overflow_y == .scroll) scroll_offset.y else 0,
    };
}

test "column fill lays out remaining height" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const top = try tree.createNode(.panel);
    const fill = try tree.createNode(.panel);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    tree.get(top).?.style = .{ .width = .fill, .height = .{ .px = 20 } };
    tree.get(fill).?.style = .{ .width = .fill, .height = .fill };
    try tree.appendChild(root, top);
    try tree.appendChild(root, fill);

    layoutTree(&tree, root, .{ .x = 100, .y = 80 }, null);
    try std.testing.expectEqual(@as(f32, 20), tree.get(top).?.bounds.h);
    try std.testing.expectEqual(@as(f32, 60), tree.get(fill).?.bounds.h);
}

test "min sizes are respected when distributing fill space" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const fixed = try tree.createNode(.panel);
    const fill = try tree.createNode(.panel);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill, .direction = .row };
    tree.get(fixed).?.style = .{ .width = .{ .px = 50 }, .min_width = 80, .height = .fill };
    tree.get(fill).?.style = .{ .width = .fill, .height = .fill };
    try tree.appendChild(root, fixed);
    try tree.appendChild(root, fill);

    layoutTree(&tree, root, .{ .x = 200, .y = 100 }, null);
    try std.testing.expectEqual(@as(f32, 80), tree.get(fixed).?.bounds.w);
    try std.testing.expectEqual(@as(f32, 120), tree.get(fill).?.bounds.w);
    try std.testing.expectEqual(@as(f32, 80), tree.get(fill).?.bounds.x);
}

test "hug column measures explicit child heights" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const card = try tree.createNode(.panel);
    const row_a = try tree.createNode(.panel);
    const row_b = try tree.createNode(.panel);

    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    tree.get(card).?.style = .{
        .width = .fill,
        .height = .hug,
        .padding = .{ .top = 8, .bottom = 8 },
        .gap = 6,
        .direction = .column,
    };
    tree.get(row_a).?.style = .{ .width = .fill, .height = .{ .px = 28 } };
    tree.get(row_b).?.style = .{ .width = .fill, .height = .{ .px = 28 } };

    try tree.appendChild(root, card);
    try tree.appendChild(card, row_a);
    try tree.appendChild(card, row_b);

    layoutTree(&tree, root, .{ .x = 100, .y = 100 }, null);
    try std.testing.expectEqual(@as(f32, 78), tree.get(card).?.bounds.h);
    try std.testing.expectEqual(@as(f32, 28), tree.get(row_a).?.bounds.h);
    try std.testing.expectEqual(@as(f32, 28), tree.get(row_b).?.bounds.h);
}

test "scroll offset shifts children without moving container" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const scroller = try tree.createNode(.panel);
    const child = try tree.createNode(.panel);

    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    tree.get(scroller).?.style = .{
        .width = .fill,
        .height = .fill,
        .overflow_x = .scroll,
        .overflow_y = .scroll,
    };
    tree.get(scroller).?.scroll_offset = .{ .x = 12, .y = 18 };
    tree.get(child).?.style = .{ .width = .{ .px = 160 }, .height = .{ .px = 140 } };

    try tree.appendChild(root, scroller);
    try tree.appendChild(scroller, child);

    layoutTree(&tree, root, .{ .x = 100, .y = 80 }, null);
    try std.testing.expectEqual(@as(f32, 0), tree.get(scroller).?.bounds.x);
    try std.testing.expectEqual(@as(f32, 0), tree.get(scroller).?.bounds.y);
    try std.testing.expectEqual(@as(f32, -12), tree.get(child).?.bounds.x);
    try std.testing.expectEqual(@as(f32, -18), tree.get(child).?.bounds.y);
}

test "incremental layout descends only through the dirty branch" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const left = try tree.createNode(.panel);
    const right = try tree.createNode(.panel);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill, .direction = .row };
    tree.get(left).?.style = .{ .width = .fill, .height = .fill, .direction = .column };
    tree.get(right).?.style = .{ .width = .fill, .height = .fill, .direction = .column };
    try tree.appendChild(root, left);
    try tree.appendChild(root, right);

    var changed = types.invalid_node;
    for (0..100) |index| {
        const left_child = try tree.createNode(.panel);
        tree.get(left_child).?.style = .{ .width = .fill, .height = .{ .px = 2 } };
        try tree.appendChild(left, left_child);
        if (index == 50) changed = left_child;

        const right_child = try tree.createNode(.panel);
        tree.get(right_child).?.style = .{ .width = .fill, .height = .{ .px = 2 } };
        try tree.appendChild(right, right_child);
    }

    _ = layoutTreeMeasured(&tree, root, .{ .x = 400, .y = 400 }, null, true);
    tree.clearTrackedDirty();
    // Width does not affect the following children in this column, so only
    // the changed leaf should need its descendant layout refreshed.
    tree.get(changed).?.style.width = .{ .px = 3 };
    tree.markLayoutDirty(changed);

    const stats = layoutTreeMeasured(&tree, root, .{ .x = 400, .y = 400 }, null, false);
    try std.testing.expectEqual(@as(u32, 3), stats.measured_nodes);
    try std.testing.expectEqual(@as(u32, 3), stats.positioned_nodes);
    try std.testing.expect(stats.skipped_clean_subtrees >= 100);
}

test "invisible children do not consume layout space" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const card = try tree.createNode(.panel);
    const visible = try tree.createNode(.panel);
    const hidden = try tree.createNode(.panel);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    tree.get(card).?.style = .{ .width = .fill, .height = .hug, .direction = .column, .gap = 9 };
    tree.get(visible).?.style = .{ .width = .fill, .height = .{ .px = 20 } };
    tree.get(hidden).?.style = .{ .width = .fill, .height = .{ .px = 80 } };
    tree.get(hidden).?.flags.visible = false;
    try tree.appendChild(root, card);
    try tree.appendChild(card, visible);
    try tree.appendChild(card, hidden);

    const stats = layoutTreeMeasured(&tree, root, .{ .x = 100, .y = 100 }, null, true);
    try std.testing.expectEqual(@as(f32, 20), tree.get(card).?.bounds.h);
    try std.testing.expect(stats.skipped_hidden_nodes > 0);
}

test "relayout clamps settled scroll offsets after content shrinks" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const root = try tree.createNode(.root);
    const scroller = try tree.createNode(.panel);
    const child = try tree.createNode(.panel);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    tree.get(scroller).?.style = .{ .width = .fill, .height = .fill, .overflow_y = .scroll };
    tree.get(child).?.style = .{ .width = .fill, .height = .{ .px = 200 } };
    try tree.appendChild(root, scroller);
    try tree.appendChild(scroller, child);
    layoutTree(&tree, root, .{ .x = 100, .y = 100 }, null);
    tree.clearTrackedDirty();

    tree.get(scroller).?.scroll_offset.y = 100;
    tree.get(scroller).?.scroll_target_offset.y = 100;
    tree.get(child).?.style.height = .{ .px = 20 };
    tree.markLayoutDirty(child);
    _ = layoutTreeMeasured(&tree, root, .{ .x = 100, .y = 100 }, null, false);

    try std.testing.expectEqual(@as(f32, 0), tree.get(scroller).?.scroll_offset.y);
    try std.testing.expectEqual(@as(f32, 0), tree.get(scroller).?.scroll_target_offset.y);
}
