const std = @import("std");
const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const theme_mod = @import("../theme.zig");
const app = @import("../core/ui_context.zig");
const button_mod = @import("button.zig");
const label_mod = @import("label.zig");
const panel_mod = @import("panel.zig");

const chevron_down = "\u{2304}";
const chevron_right = "\u{203a}";

pub const Options = struct {
    initially_expanded: bool = true,
    animation_duration: f32 = 0.18,
    header_height: ?f32 = null,
    body_gap: ?f32 = null,
    body_padding: ?style_mod.Edges = null,
    surface: theme_mod.ColorRole = .card,
    border: theme_mod.ColorRole = .stroke_soft,
    title_color: theme_mod.ColorRole = .text,
};

/// A retained disclosure section with a fixed clickable header and a clipped,
/// smoothly animated body. Callers mount arbitrary controls beneath body().
pub const Collapsible = struct {
    root_node: types.NodeId,
    header_node: types.NodeId,
    body_clip_node: types.NodeId,
    body_node: types.NodeId,
    chevron_node: types.NodeId,
    expanded: bool,
    progress: f32,
    expanded_height: f32 = 0,
    measured: bool = false,
    animation_duration: f32,

    pub fn init(ui: *app.Ui, parent: types.NodeId, title: []const u8, options: Options) !Collapsible {
        const header_height = options.header_height orelse ui.theme.metrics.section_header_height;
        const header_text_top = @floor((header_height - ui.theme.font.body) / 2);
        const root_node = try panel_mod.panel(ui, parent, ui.theme.style(.{
            .width = .fill,
            .height = .hug,
            .direction = .column,
            .background = options.surface,
            .border = options.border,
            .border_width = 1,
            .radius = .card,
        }));
        errdefer ui.destroySubtree(root_node);
        ui.tree.get(root_node).?.flags.clipped = true;

        const header_style = ui.theme.style(.{
            .width = .fill,
            .height = .{ .px = @max(0, header_height - 1) },
            .padding = .{ .left = ui.theme.space.lg, .right = ui.theme.space.md },
            // The interactive fill sits inside the container's outline, so
            // hover and press feedback never overwrite the section border.
            .margin = .{ .left = 1, .right = 1, .top = 1 },
            .direction = .row,
            .background = .transparent,
            .foreground = options.title_color,
            .hover_background = .interaction_hover,
            .pressed_background = .interaction_pressed,
            .border_width = 0,
            .radius_corners = headerRadii(ui, !options.initially_expanded),
            .font_size = ui.theme.font.body,
        });
        const header_node = try button_mod.button(ui, root_node, "", header_style);

        const chevron_node = try label_mod.label(ui, header_node, if (options.initially_expanded) chevron_down else chevron_right, ui.theme.textStyle(.{
            .width = .{ .px = 18 },
            .height = .fill,
            .padding = .{ .left = ui.theme.space.xxs, .top = header_text_top - 1 },
            .color = .text_muted,
            .size = ui.theme.font.body,
        }));
        _ = try label_mod.label(ui, header_node, title, ui.theme.textStyle(.{
            .width = .fill,
            .height = .fill,
            .padding = .{ .top = header_text_top },
            .color = options.title_color,
            .size = ui.theme.font.body,
        }));

        const body_clip_node = try panel_mod.panel(ui, root_node, ui.theme.style(.{
            .width = .fill,
            .height = if (options.initially_expanded) .hug else .{ .px = 0 },
            .direction = .absolute,
        }));
        ui.tree.get(body_clip_node).?.flags.clipped = true;

        const body_node = try panel_mod.panel(ui, body_clip_node, ui.theme.style(.{
            .width = .fill,
            .height = .hug,
            .padding = options.body_padding orelse .{ .left = ui.theme.space.lg, .right = ui.theme.space.lg, .bottom = ui.theme.space.lg },
            .gap = options.body_gap orelse ui.theme.space.md,
            .direction = .column,
        }));
        if (!options.initially_expanded) try ui.setVisible(body_node, false);

        return .{
            .root_node = root_node,
            .header_node = header_node,
            .body_clip_node = body_clip_node,
            .body_node = body_node,
            .chevron_node = chevron_node,
            .expanded = options.initially_expanded,
            .progress = if (options.initially_expanded) 1 else 0,
            .animation_duration = @max(0.01, options.animation_duration),
        };
    }

    pub fn deinit(self: *Collapsible, ui: *app.Ui) void {
        ui.destroySubtree(self.root_node);
        self.* = undefined;
    }

    pub fn body(self: *const Collapsible) types.NodeId {
        return self.body_node;
    }

    pub fn isExpanded(self: *const Collapsible) bool {
        return self.expanded;
    }

    /// Updates interaction and animation state. Returns true when the user
    /// toggles the section.
    pub fn update(self: *Collapsible, ui: *app.Ui) !bool {
        if (ui.input.hovered == self.header_node) ui.requestCursor(.hand);

        const toggled = ui.activated(self.header_node);
        if (toggled) {
            self.expanded = !self.expanded;
            if (!self.expanded and ui.tree.isDescendantOf(ui.focusedNode(), self.body_node)) ui.clearFocus();
            if (self.expanded) try ui.setVisible(self.body_node, true);
        }

        // Intrinsic height remains available while the clip is explicitly
        // sized, allowing content changes and interrupted animations to adapt.
        if (ui.tree.getConst(self.body_node)) |body_node| {
            if (body_node.layout.intrinsic.y > 0 or self.measured) {
                self.expanded_height = body_node.layout.intrinsic.y;
                self.measured = true;
            }
        }

        if (!self.measured) return toggled;

        const target: f32 = if (self.expanded) 1 else 0;
        self.progress = approach(self.progress, target, ui.dt / self.animation_duration);
        const visible_height = self.expanded_height * smoothstep(self.progress);
        var clip_style = ui.nodeStyle(self.body_clip_node) orelse return error.InvalidNode;
        const next_height: style_mod.Size = .{ .px = visible_height };
        if (!std.meta.eql(clip_style.height, next_height)) {
            clip_style.height = next_height;
            try ui.setStyle(self.body_clip_node, clip_style);
        }

        const fully_collapsed = !self.expanded and self.progress == 0;
        try ui.setVisible(self.body_node, !fully_collapsed);
        try ui.setText(self.chevron_node, if (fully_collapsed) chevron_right else chevron_down);
        var header_style = ui.nodeStyle(self.header_node) orelse return error.InvalidNode;
        const next_radii = headerRadii(ui, fully_collapsed);
        if (!std.meta.eql(header_style.radius, next_radii)) {
            header_style.radius = next_radii;
            try ui.setStyle(self.header_node, header_style);
        }
        return toggled;
    }
};

fn headerRadii(ui: *const app.Ui, fully_collapsed: bool) style_mod.CornerRadii {
    const radius = ui.theme.radius_tokens.card;
    return .{
        .top_left = radius,
        .top_right = radius,
        .bottom_right = if (fully_collapsed) radius else 0,
        .bottom_left = if (fully_collapsed) radius else 0,
    };
}

fn approach(value: f32, target: f32, amount: f32) f32 {
    const step = std.math.clamp(amount, 0, 1);
    if (value < target) return @min(target, value + step);
    if (value > target) return @max(target, value - step);
    return value;
}

fn smoothstep(value: f32) f32 {
    const t = std.math.clamp(value, 0, 1);
    return t * t * (3 - 2 * t);
}

test "collapsible smoothly closes to its header and reopens" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var section = try Collapsible.init(&ui, ui.rootNode(), "Transform", .{});
    defer section.deinit(&ui);
    _ = try panel_mod.panel(&ui, section.body(), ui.theme.style(.{
        .width = .fill,
        .height = .{ .px = 60 },
    }));

    // Establish intrinsic geometry, then let the widget adopt an explicit
    // animated height without changing its open appearance.
    try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 180 } });
    _ = try section.update(&ui);
    try ui.endFrame();
    try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 180 } });
    _ = try section.update(&ui);
    try ui.endFrame();
    const open_height = ui.bounds(section.root_node).?.h;
    const header = ui.bounds(section.header_node).?;
    const click = types.Vec2{ .x = header.x + header.w - 10, .y = header.y + header.h / 2 };

    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = click }, .{ .mouse_down = .left }, .{ .mouse_up = .left } },
        .window_size = .{ .x = 240, .y = 180 },
        .dt = 0.045,
    });
    try std.testing.expect(try section.update(&ui));
    try std.testing.expect(!section.isExpanded());
    try std.testing.expectEqualStrings(chevron_down, ui.tree.getConst(section.chevron_node).?.text.?);
    try ui.endFrame();
    try std.testing.expect(ui.bounds(section.root_node).?.h < open_height);

    for (0..3) |_| {
        try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 180 }, .dt = 0.045 });
        _ = try section.update(&ui);
        try ui.endFrame();
    }
    try std.testing.expectEqual(@as(f32, 0), section.progress);
    try std.testing.expect(!ui.tree.getConst(section.body_node).?.flags.visible);
    try std.testing.expectEqualStrings(chevron_right, ui.tree.getConst(section.chevron_node).?.text.?);
    try std.testing.expectApproxEqAbs(header.h, ui.bounds(section.root_node).?.h, 0.001);
    try std.testing.expectEqual(ui.theme.radius_tokens.card, ui.nodeStyle(section.header_node).?.radius.bottom_right);

    const closed_header = ui.bounds(section.header_node).?;
    const reopen_click = types.Vec2{ .x = closed_header.x + closed_header.w - 10, .y = closed_header.y + closed_header.h / 2 };
    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = reopen_click }, .{ .mouse_down = .left }, .{ .mouse_up = .left } },
        .window_size = .{ .x = 240, .y = 180 },
        .dt = 0.045,
    });
    try std.testing.expect(try section.update(&ui));
    try std.testing.expect(section.isExpanded());
    try std.testing.expect(ui.tree.getConst(section.body_node).?.flags.visible);
    try std.testing.expectEqualStrings(chevron_down, ui.tree.getConst(section.chevron_node).?.text.?);
    try std.testing.expectEqual(@as(f32, 0), ui.nodeStyle(section.header_node).?.radius.bottom_right);
}
