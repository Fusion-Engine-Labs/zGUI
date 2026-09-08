const std = @import("std");
const types = @import("core/types.zig");
const style_mod = @import("core/style.zig");

/// One tag per `Palette` field, derived so the two can never drift. Adding a
/// colour to `Palette` is the only edit a new role needs.
pub const ColorRole = std.meta.FieldEnum(Palette);

pub const RadiusRole = enum {
    none,
    control,
    card,
    viewport,
    pill,
    round,
};

pub const Palette = struct {
    transparent: types.Color = types.Color.rgba(0, 0, 0, 0),

    app: types.Color = types.Color.rgba(13, 14, 17, 255),
    shell: types.Color = types.Color.rgba(20, 20, 24, 255),
    panel: types.Color = types.Color.rgba(25, 25, 30, 255),
    panel_soft: types.Color = types.Color.rgba(30, 30, 36, 255),
    card: types.Color = types.Color.rgba(35, 35, 42, 255),
    control: types.Color = types.Color.rgba(41, 41, 49, 255),
    viewport: types.Color = types.Color.rgba(18, 18, 22, 255),

    stroke: types.Color = types.Color.rgba(58, 58, 68, 255),
    stroke_soft: types.Color = types.Color.rgba(42, 42, 50, 255),
    overlay: types.Color = types.Color.rgba(17, 18, 22, 232),
    overlay_soft: types.Color = types.Color.rgba(30, 30, 36, 220),
    overlay_stroke: types.Color = types.Color.rgba(255, 255, 255, 24),
    interaction_hover: types.Color = types.Color.rgba(255, 255, 255, 18),
    interaction_pressed: types.Color = types.Color.rgba(255, 255, 255, 30),

    text: types.Color = types.Color.rgba(245, 245, 246, 255),
    text_dim: types.Color = types.Color.rgba(177, 179, 187, 255),
    text_muted: types.Color = types.Color.rgba(123, 126, 136, 255),
    text_disabled: types.Color = types.Color.rgba(91, 94, 106, 160),
    icon: types.Color = types.Color.rgba(194, 198, 207, 255),
    icon_selected: types.Color = types.Color.rgba(224, 213, 255, 255),
    icon_disabled: types.Color = types.Color.rgba(112, 115, 124, 160),

    accent: types.Color = types.Color.rgba(139, 92, 246, 255),
    accent_soft: types.Color = types.Color.rgba(48, 36, 78, 255),
    accent_hover: types.Color = types.Color.rgba(139, 92, 246, 50),
    accent_pressed: types.Color = types.Color.rgba(139, 92, 246, 70),
    accent_border: types.Color = types.Color.rgba(139, 92, 246, 150),
    accent_border_strong: types.Color = types.Color.rgba(167, 139, 250, 220),
    violet: types.Color = types.Color.rgba(167, 139, 250, 255),
    violet_soft: types.Color = types.Color.rgba(48, 40, 82, 255),

    success: types.Color = types.Color.rgba(64, 190, 122, 255),
    success_soft: types.Color = types.Color.rgba(31, 58, 43, 255),
    warning: types.Color = types.Color.rgba(245, 158, 11, 255),
    warning_soft: types.Color = types.Color.rgba(69, 48, 19, 255),
    danger: types.Color = types.Color.rgba(239, 68, 68, 255),
    danger_soft: types.Color = types.Color.rgba(74, 32, 32, 255),
};

pub const Radius = struct {
    control: f32 = 10,
    card: f32 = 12,
    viewport: f32 = 14,
    pill: f32 = 12,
    round: f32 = 999,
};

pub const Space = struct {
    xxs: f32 = 2,
    xs: f32 = 4,
    sm: f32 = 6,
    md: f32 = 8,
    lg: f32 = 10,
    xl: f32 = 12,
    xxl: f32 = 16,
};

pub const Font = struct {
    tiny: f32 = 11,
    small: f32 = 12,
    body: f32 = 13,
    title: f32 = 16,
    brand: f32 = 18,

    /// Every size the theme can ask for, so a glyph prewarm covers the real
    /// working set instead of a hand-copied list that drifts when a token moves.
    pub fn sizes(self: Font) [@typeInfo(Font).@"struct".fields.len]f32 {
        var out: [@typeInfo(Font).@"struct".fields.len]f32 = undefined;
        inline for (@typeInfo(Font).@"struct".fields, 0..) |field, i| {
            out[i] = @field(self, field.name);
        }
        return out;
    }
};

pub const Metrics = struct {
    control_height: f32 = 34,
    compact_control_height: f32 = 28,
    section_header_height: f32 = 40,
    dock_tab_height: f32 = 30,
    dock_handle_thickness: f32 = 4,
};

pub const StyleOptions = struct {
    width: style_mod.Size = .hug,
    height: style_mod.Size = .hug,
    min_width: f32 = 0,
    min_height: f32 = 0,
    padding: style_mod.Edges = .{},
    margin: style_mod.Edges = .{},
    gap: f32 = 0,
    direction: style_mod.LayoutDirection = .column,
    overflow_x: style_mod.Overflow = .visible,
    overflow_y: style_mod.Overflow = .visible,
    background: ColorRole = .transparent,
    foreground: ColorRole = .text,
    hover_background: ?ColorRole = null,
    pressed_background: ?ColorRole = null,
    border: ColorRole = .transparent,
    hover_border: ?ColorRole = null,
    pressed_border: ?ColorRole = null,
    border_width: f32 = 0,
    border_edges: ?style_mod.Edges = null,
    radius: RadiusRole = .none,
    radius_px: ?f32 = null,
    radius_corners: ?style_mod.CornerRadii = null,
    font_size: f32 = 16,
    text_align: style_mod.TextAlign = .start,
};

pub const TextOptions = struct {
    width: style_mod.Size = .hug,
    height: style_mod.Size = .hug,
    min_width: f32 = 0,
    min_height: f32 = 0,
    padding: style_mod.Edges = .{},
    margin: style_mod.Edges = .{},
    color: ColorRole = .text,
    size: f32 = 13,
    text_align: style_mod.TextAlign = .start,
};

pub const Theme = struct {
    palette: Palette = .{},
    radius_tokens: Radius = .{},
    space: Space = .{},
    font: Font = .{},
    metrics: Metrics = .{},

    pub fn color(self: Theme, role: ColorRole) types.Color {
        return switch (role) {
            inline else => |tag| @field(self.palette, @tagName(tag)),
        };
    }

    pub fn radius(self: Theme, role: RadiusRole) f32 {
        return switch (role) {
            .none => 0,
            inline else => |tag| @field(self.radius_tokens, @tagName(tag)),
        };
    }

    pub fn style(self: Theme, options: StyleOptions) style_mod.Style {
        return .{
            .width = options.width,
            .height = options.height,
            .min_width = options.min_width,
            .min_height = options.min_height,
            .padding = options.padding,
            .margin = options.margin,
            .gap = options.gap,
            .direction = options.direction,
            .overflow_x = options.overflow_x,
            .overflow_y = options.overflow_y,
            .background = self.color(options.background),
            .foreground = self.color(options.foreground),
            .hover_background = if (options.hover_background) |role| self.color(role) else null,
            .pressed_background = if (options.pressed_background) |role| self.color(role) else null,
            .border_color = self.color(options.border),
            .hover_border_color = if (options.hover_border) |role| self.color(role) else null,
            .pressed_border_color = if (options.pressed_border) |role| self.color(role) else null,
            .border_width = options.border_width,
            .border_edges = options.border_edges,
            .radius = options.radius_corners orelse style_mod.CornerRadii.all(options.radius_px orelse self.radius(options.radius)),
            .font_size = options.font_size,
            .text_align = options.text_align,
        };
    }

    pub fn textStyle(self: Theme, options: TextOptions) style_mod.Style {
        return self.style(.{
            .width = options.width,
            .height = options.height,
            .min_width = options.min_width,
            .min_height = options.min_height,
            .padding = options.padding,
            .margin = options.margin,
            .foreground = options.color,
            .font_size = options.size,
            .text_align = options.text_align,
        });
    }
};

pub const zephyr_dark = Theme{};

test "style options resolve semantic interaction colors" {
    const value = zephyr_dark.style(.{
        .hover_background = .interaction_hover,
        .pressed_background = .accent_pressed,
        .hover_border = .accent_border,
        .pressed_border = .accent_border_strong,
    });
    try std.testing.expectEqual(zephyr_dark.palette.interaction_hover, value.hover_background.?);
    try std.testing.expectEqual(zephyr_dark.palette.accent_pressed, value.pressed_background.?);
    try std.testing.expectEqual(zephyr_dark.palette.accent_border, value.hover_border_color.?);
    try std.testing.expectEqual(zephyr_dark.palette.accent_border_strong, value.pressed_border_color.?);
}
