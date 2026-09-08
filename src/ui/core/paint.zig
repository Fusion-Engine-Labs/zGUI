const std = @import("std");
const types = @import("types.zig");
const style_mod = @import("style.zig");
const node_mod = @import("node.zig");
const tree_mod = @import("tree.zig");

pub const PaintCommand = union(enum) {
    rect: RectPaint,
    border: BorderPaint,
    image: ImagePaint,
    color_wheel: ColorWheelPaint,
    text: TextPaint,
    clip_push: types.Rect,
    clip_pop,
};

pub const RectPaint = struct {
    rect: types.Rect,
    color: types.Color,
    radius: style_mod.CornerRadii = .{},
};

pub const BorderPaint = struct {
    rect: types.Rect,
    color: types.Color,
    widths: style_mod.Edges,
    radius: style_mod.CornerRadii = .{},
};

pub const TextPaint = struct {
    source_node: types.NodeId = 0,
    text_revision: u32 = 0,
    /// Top-left of the text's line box, not its baseline. Placing the baseline
    /// needs the font's ascent, which only a renderer's atlas knows, so that
    /// step belongs to the backend rather than to this list.
    pos: types.Vec2,
    text: []const u8,
    size: f32,
    color: types.Color,
};

pub const ImagePaint = struct {
    rect: types.Rect,
    texture: types.TextureHandle,
    uv0: types.Vec2 = .{ .x = 0, .y = 0 },
    uv1: types.Vec2 = .{ .x = 1, .y = 1 },
    tint: types.Color = types.Color.rgba(255, 255, 255, 255),
    radius: style_mod.CornerRadii = .{},
};

pub const ColorWheelPaint = struct {
    rect: types.Rect,
    hue: f32,
    saturation: f32,
    value: f32,
};

pub const PaintList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(PaintCommand) = .empty,

    pub fn init(allocator: std.mem.Allocator) PaintList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PaintList) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *PaintList) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn append(self: *PaintList, command: PaintCommand) !void {
        try self.commands.append(self.allocator, command);
    }
};

pub const PaintStats = struct {
    visited_nodes: u32 = 0,
    culled_subtrees: u32 = 0,
    culled_commands: u32 = 0,
};

pub fn buildPaintListMeasured(tree: *const tree_mod.UiTree, root: types.NodeId, list: *PaintList) !PaintStats {
    var stats: PaintStats = .{};
    try buildPaintNode(tree, root, list, null, &stats);
    return stats;
}

fn buildPaintNode(tree: *const tree_mod.UiTree, root: types.NodeId, list: *PaintList, inherited_clip: ?types.Rect, stats: *PaintStats) !void {
    const node = tree.getConst(root) orelse return;
    if (!node.flags.visible) return;
    stats.visited_nodes += 1;

    if (inherited_clip) |clip| {
        if (!node.layout.visual_bounds.overlaps(clip)) {
            stats.culled_subtrees += 1;
            return;
        }
    }

    const clipped = node.flags.clipped or node.style.overflow_x == .scroll or node.style.overflow_y == .scroll;
    // Include the node's antialiased edge in its own clip. Its visual bounds
    // already reserve this one-pixel outset, so this keeps control borders
    // from losing their final edge at a clipping boundary.
    const effective_clip = if (clipped)
        if (inherited_clip) |clip| clip.intersect(node.bounds.outset(1)) else node.bounds.outset(1)
    else
        inherited_clip;
    if (effective_clip) |clip| {
        if (clip.isEmpty()) {
            stats.culled_subtrees += 1;
            return;
        }
    }
    if (clipped) try list.append(.{ .clip_push = node.bounds });

    var background = node.style.background;
    var border = node.style.border_color;
    if (node.flags.interactive) {
        // Any interactive node gets the feedback its style asks for. Buttons
        // additionally derive one when the style names no colour, since a bare
        // button is still expected to look pressable; other kinds stay put.
        const derive = node.kind == .button;
        if (node.flags.pressed) {
            background = node.style.pressed_background orelse if (derive) darken(background, 24) else background;
            border = node.style.pressed_border_color orelse if (derive) lighten(border, 36) else border;
        } else if (node.flags.hovered) {
            background = node.style.hover_background orelse if (derive) lighten(background, 20) else background;
            border = node.style.hover_border_color orelse if (derive) lighten(border, 20) else border;
        }
    }

    // Background, image and border all test the same box against the same clip,
    // so the geometry is resolved once and each suppressed command is counted.
    // An empty box is not a cull — it never had anything to draw.
    const box_visible = boxVisible(node.bounds, 1, effective_clip);
    const box_culled = !box_visible and !node.bounds.isEmpty();

    if (background.a != 0) if (box_visible) {
        try list.append(.{ .rect = .{
            .rect = node.bounds,
            .color = background,
            .radius = node.style.radius,
        } });
    } else if (box_culled) {
        stats.culled_commands += 1;
    };

    if (node.image) |image| {
        if (image.texture.isValid()) if (box_visible) {
            const image_rect = if (node.kind == .button) node.bounds.inset(node.style.padding) else node.bounds;
            const tint = if (node.kind == .button and node.flags.pressed)
                image.pressed_tint orelse image.tint
            else if (node.kind == .button and node.flags.hovered)
                image.hover_tint orelse image.tint
            else
                image.tint;
            try list.append(.{ .image = .{
                .rect = image_rect,
                .texture = image.texture,
                .uv0 = image.uv0,
                .uv1 = image.uv1,
                .tint = tint,
                .radius = node.style.radius,
            } });
        } else if (box_culled) {
            stats.culled_commands += 1;
        };
    }

    if (node.custom_paint) |custom| {
        if (box_visible) switch (custom) {
            .color_wheel => |wheel| try list.append(.{ .color_wheel = .{
                .rect = node.bounds,
                .hue = wheel.hue,
                .saturation = wheel.saturation,
                .value = wheel.value,
            } }),
        } else if (box_culled) {
            stats.culled_commands += 1;
        }
    }

    const border_widths = node.style.border_edges orelse style_mod.Edges.all(node.style.border_width);
    if (hasBorder(border_widths) and border.a != 0) if (box_visible) {
        try list.append(.{ .border = .{
            .rect = node.bounds,
            .color = border,
            .widths = border_widths,
            .radius = node.style.radius,
        } });
    } else if (box_culled) {
        stats.culled_commands += 1;
    };

    if (node.text) |text| if (commandVisible(node.bounds, @max(@as(f32, 1), node.style.font_size * 0.25), effective_clip, stats)) {
        try list.append(.{ .text = .{
            .source_node = root,
            .text_revision = node.text_revision,
            .pos = .{
                .x = node.bounds.x + textLeft(node),
                .y = node.bounds.y + node.style.padding.top,
            },
            .text = text,
            .size = node.style.font_size,
            .color = node.style.foreground,
        } });
    };

    var child = node.first_child;
    while (child != types.invalid_node) {
        const child_node = tree.getConst(child) orelse break;
        try buildPaintNode(tree, child, list, effective_clip, stats);
        child = child_node.next_sibling;
    }

    if (clipped) try list.append(.clip_pop);
}

/// Leading edge of a text run inside its node. Centring and trailing alignment
/// need the run's width, which only the layout pass measures, so a node whose
/// cache does not match the size being painted falls back to the padding box's
/// leading edge rather than aligning against a stale measurement.
fn textLeft(node: *const node_mod.Node) f32 {
    const padding = node.style.padding;
    if (node.style.text_align == .start) return padding.left;
    if (node.measured_text_font_size != node.style.font_size) return padding.left;
    const inner = node.bounds.w - padding.horizontal();
    const slack = @max(0, inner - node.measured_text.x);
    return padding.left + switch (node.style.text_align) {
        .start => 0,
        .center => slack / 2,
        .end => slack,
    };
}

fn boxVisible(bounds: types.Rect, outset: f32, clip: ?types.Rect) bool {
    if (bounds.isEmpty()) return false;
    const active = clip orelse return true;
    return bounds.outset(outset).overlaps(active);
}

fn commandVisible(bounds: types.Rect, outset: f32, clip: ?types.Rect, stats: *PaintStats) bool {
    if (boxVisible(bounds, outset, clip)) return true;
    if (!bounds.isEmpty()) stats.culled_commands += 1;
    return false;
}

fn lighten(color: types.Color, amount: u8) types.Color {
    return .{
        .r = color.r +| amount,
        .g = color.g +| amount,
        .b = color.b +| amount,
        .a = color.a,
    };
}

fn darken(color: types.Color, amount: u8) types.Color {
    return .{
        .r = color.r -| amount,
        .g = color.g -| amount,
        .b = color.b -| amount,
        .a = color.a,
    };
}

fn hasBorder(edges: style_mod.Edges) bool {
    return edges.left > 0 or edges.right > 0 or edges.top > 0 or edges.bottom > 0;
}

test "clipped containers skip offscreen subtrees" {
    const layout_mod = @import("layout.zig");

    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();
    var list = PaintList.init(std.testing.allocator);
    defer list.deinit();

    const root = try tree.createNode(.root);
    const scroller = try tree.createNode(.panel);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    tree.get(scroller).?.style = .{
        .width = .fill,
        .height = .fill,
        .direction = .column,
        .overflow_y = .scroll,
    };
    try tree.appendChild(root, scroller);
    for (0..100) |_| {
        const row = try tree.createNode(.panel);
        tree.get(row).?.style = .{
            .width = .fill,
            .height = .{ .px = 10 },
            .background = types.Color.rgba(255, 255, 255, 255),
        };
        try tree.appendChild(scroller, row);
    }

    layout_mod.layoutTree(&tree, root, .{ .x = 100, .y = 100 }, null);
    const stats = try buildPaintListMeasured(&tree, root, &list);
    try std.testing.expect(stats.culled_subtrees >= 89);
    try std.testing.expect(list.commands.items.len < 20);
}

test "centred text sits on the middle of its padding box" {
    const layout_mod = @import("layout.zig");

    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();
    var list = PaintList.init(std.testing.allocator);
    defer list.deinit();

    const root = try tree.createNode(.root);
    tree.get(root).?.style = .{ .width = .fill, .height = .fill };
    const label = try tree.createNode(.label);
    tree.get(label).?.style = .{
        .width = .fill,
        .height = .{ .px = 20 },
        .padding = .{ .left = 4, .right = 4 },
        .font_size = 10,
        .text_align = .center,
    };
    try tree.setText(label, "ab");
    try tree.appendChild(root, label);

    layout_mod.layoutTree(&tree, root, .{ .x = 100, .y = 100 }, null);
    _ = try buildPaintListMeasured(&tree, root, &list);

    const node = tree.getConst(label).?;
    try std.testing.expect(node.measured_text.x > 0);
    const expected = node.bounds.x + 4 + (node.bounds.w - 8 - node.measured_text.x) / 2;
    for (list.commands.items) |command| switch (command) {
        .text => |text| {
            try std.testing.expectApproxEqAbs(expected, text.pos.x, 0.01);
            return;
        },
        else => {},
    };
    return error.MissingTextCommand;
}

test "text alignment falls back to the leading edge without a measurement" {
    var tree = tree_mod.UiTree.init(std.testing.allocator);
    defer tree.deinit();

    const id = try tree.createNode(.label);
    const node = tree.get(id).?;
    node.style = .{ .padding = .{ .left = 6 }, .font_size = 10, .text_align = .center };
    node.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 20 };
    try std.testing.expectEqual(@as(f32, 6), textLeft(node));

    node.measured_text = .{ .x = 40, .y = 12 };
    node.measured_text_font_size = 10;
    try std.testing.expectEqual(@as(f32, 6 + 27), textLeft(node));
}
