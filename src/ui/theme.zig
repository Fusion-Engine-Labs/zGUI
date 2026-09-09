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

    // Cool blue-grey surfaces, from the outer application shell through raised
    // panels and cards. Controls are inset wells rather than raised chips.
    app: types.Color = types.Color.rgba(26, 27, 36, 255),
    shell: types.Color = types.Color.rgba(34, 35, 47, 255),
    panel: types.Color = types.Color.rgba(39, 40, 53, 255),
    panel_soft: types.Color = types.Color.rgba(44, 45, 59, 255),
    card: types.Color = types.Color.rgba(50, 51, 66, 255),
    control: types.Color = types.Color.rgba(24, 24, 33, 255),
    viewport: types.Color = types.Color.rgba(20, 21, 29, 255),

    stroke: types.Color = types.Color.rgba(61, 63, 80, 255),
    stroke_soft: types.Color = types.Color.rgba(46, 47, 58, 255),
    overlay: types.Color = types.Color.rgba(26, 27, 36, 242),
    overlay_soft: types.Color = types.Color.rgba(34, 35, 47, 234),
    overlay_stroke: types.Color = types.Color.rgba(206, 210, 228, 30),
    interaction_hover: types.Color = types.Color.rgba(206, 210, 228, 18),
    interaction_pressed: types.Color = types.Color.rgba(144, 131, 216, 40),

    text: types.Color = types.Color.rgba(226, 229, 241, 255),
    text_dim: types.Color = types.Color.rgba(177, 181, 201, 255),
    text_muted: types.Color = types.Color.rgba(146, 150, 170, 255),
    text_disabled: types.Color = types.Color.rgba(110, 114, 134, 170),
    icon: types.Color = types.Color.rgba(177, 181, 201, 255),
    icon_selected: types.Color = types.Color.rgba(144, 131, 216, 255),
    icon_disabled: types.Color = types.Color.rgba(110, 114, 134, 160),

    // Lavender is the single focus, selection, and primary-action accent.
    accent: types.Color = types.Color.rgba(144, 131, 216, 255),
    accent_soft: types.Color = types.Color.rgba(68, 61, 105, 255),
    accent_hover: types.Color = types.Color.rgba(144, 131, 216, 40),
    accent_pressed: types.Color = types.Color.rgba(144, 131, 216, 70),
    accent_border: types.Color = types.Color.rgba(144, 131, 216, 160),
    accent_border_strong: types.Color = types.Color.rgba(209, 205, 253, 235),
    violet: types.Color = types.Color.rgba(163, 148, 255, 255),
    violet_soft: types.Color = types.Color.rgba(55, 50, 83, 255),

    success: types.Color = types.Color.rgba(140, 205, 160, 255),
    success_soft: types.Color = types.Color.rgba(42, 56, 50, 255),
    warning: types.Color = types.Color.rgba(223, 194, 139, 255),
    warning_soft: types.Color = types.Color.rgba(58, 50, 40, 255),
    danger: types.Color = types.Color.rgba(223, 152, 152, 255),
    danger_soft: types.Color = types.Color.rgba(54, 44, 55, 255),
};

pub const Radius = struct {
    control: f32 = 6,
    card: f32 = 8,
    viewport: f32 = 0,
    pill: f32 = 8,
    round: f32 = 999,
};

pub const Space = struct {
    xxs: f32 = 2,
    xs: f32 = 3,
    sm: f32 = 5,
    md: f32 = 8,
    lg: f32 = 10,
    xl: f32 = 12,
    xxl: f32 = 16,
};

pub const Font = struct {
    tiny: f32 = 13,
    small: f32 = 14,
    body: f32 = 15,
    title: f32 = 18,
    brand: f32 = 20,

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
    control_height: f32 = 32,
    compact_control_height: f32 = 26,
    section_header_height: f32 = 38,
    dock_tab_height: f32 = 30,
    dock_handle_thickness: f32 = 2,
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

pub const fusion_dark = Theme{};

test "style options resolve semantic interaction colors" {
    const value = fusion_dark.style(.{
        .hover_background = .interaction_hover,
        .pressed_background = .accent_pressed,
        .hover_border = .accent_border,
        .pressed_border = .accent_border_strong,
    });
    try std.testing.expectEqual(fusion_dark.palette.interaction_hover, value.hover_background.?);
    try std.testing.expectEqual(fusion_dark.palette.accent_pressed, value.pressed_background.?);
    try std.testing.expectEqual(fusion_dark.palette.accent_border, value.hover_border_color.?);
    try std.testing.expectEqual(fusion_dark.palette.accent_border_strong, value.pressed_border_color.?);
}
