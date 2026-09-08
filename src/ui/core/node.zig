const types = @import("types.zig");
const style_mod = @import("style.zig");
const layout_mod = @import("layout.zig");
const dirty_mod = @import("dirty.zig");

pub const ColorWheelVisual = struct {
    hue: f32 = 0,
    saturation: f32 = 0,
    value: f32 = 0,
};

pub const CustomPaint = union(enum) {
    color_wheel: ColorWheelVisual,
};

pub const NodeKind = enum {
    root,
    panel,
    label,
    button,
    image,
    custom,
};

pub const Image = struct {
    texture: types.TextureHandle = .none,
    uv0: types.Vec2 = .{ .x = 0, .y = 0 },
    uv1: types.Vec2 = .{ .x = 1, .y = 1 },
    tint: types.Color = types.Color.rgba(255, 255, 255, 255),
    hover_tint: ?types.Color = null,
    pressed_tint: ?types.Color = null,
};

pub const NodeFlags = packed struct {
    visible: bool = true,
    interactive: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    clipped: bool = false,
    focusable: bool = false,
    accepts_text_input: bool = false,
};

pub const Node = struct {
    /// Nothing reads this today — the slot index plus `generation` already
    /// identify a node. It stays because removing it shifts every field after
    /// it and measurably slows the layout traversal (~5% on the 10k-node
    /// incremental-layout benchmark); it is padding that happens to be useful.
    id: types.NodeId,
    generation: u8,
    alive: bool = true,

    kind: NodeKind,

    parent: types.NodeId = types.invalid_node,
    first_child: types.NodeId = types.invalid_node,
    last_child: types.NodeId = types.invalid_node,
    next_sibling: types.NodeId = types.invalid_node,
    prev_sibling: types.NodeId = types.invalid_node,

    bounds: types.Rect = .{},
    scroll_offset: types.Vec2 = .{},
    scroll_target_offset: types.Vec2 = .{},

    style: style_mod.Style = .{},
    layout: layout_mod.Layout = .{},
    dirty: dirty_mod.DirtyFlags = .{ .layout = true, .paint = true },

    flags: NodeFlags = .{},

    /// View into `text_storage`; updated through UiTree.setText.
    text: ?[]const u8 = null,
    /// Retained allocation used by changing labels to avoid per-update churn.
    text_storage: ?[]u8 = null,
    text_revision: u32 = 0,
    image: ?Image = null,
    custom_paint: ?CustomPaint = null,

    // Cached text measurement, valid while the text is unchanged and the
    // font size matches. A negative size marks the cache invalid.
    measured_text: types.Vec2 = .{},
    measured_text_font_size: f32 = -1,

    pub fn init(id: types.NodeId, generation: u8, kind: NodeKind) Node {
        return .{
            .id = id,
            .generation = generation,
            .kind = kind,
            .flags = .{ .interactive = kind == .button },
        };
    }
};
