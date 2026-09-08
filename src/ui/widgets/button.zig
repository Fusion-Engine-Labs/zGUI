const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const node_mod = @import("../core/node.zig");
const app = @import("../core/ui_context.zig");
const events = @import("../core/events.zig");

pub const IconButtonOptions = struct {
    texture: types.TextureHandle,
    style: style_mod.Style,
    uv0: types.Vec2 = .{ .x = 0, .y = 0 },
    uv1: types.Vec2 = .{ .x = 1, .y = 1 },
    tint: types.Color = types.Color.rgba(255, 255, 255, 255),
    hover_tint: ?types.Color = null,
    pressed_tint: ?types.Color = null,
    on_activate: ?events.EventHandler = null,
};

pub fn button(ui: *app.Ui, parent: types.NodeId, text: []const u8, style: style_mod.Style) !types.NodeId {
    const id = try ui.createNode(.button);
    errdefer ui.destroySubtree(id);
    const node = ui.tree.get(id).?;
    node.style = style;
    try ui.tree.setText(id, text);
    try ui.tree.appendChild(parent, id);
    return id;
}

/// Creates a normal button whose face is rendered from a texture instead of text.
/// It participates in the same hover, press, focus, and click routing as `button`.
pub fn iconButton(ui: *app.Ui, parent: types.NodeId, options: IconButtonOptions) !types.NodeId {
    const id = try button(ui, parent, "", options.style);
    errdefer ui.destroySubtree(id);
    const node = ui.tree.get(id).?;
    node.image = node_mod.Image{
        .texture = options.texture,
        .uv0 = options.uv0,
        .uv1 = options.uv1,
        .tint = options.tint,
        .hover_tint = options.hover_tint,
        .pressed_tint = options.pressed_tint,
    };
    if (options.on_activate) |handler| try ui.setActivationHandler(id, handler);
    return id;
}

pub fn buttonClicked(ui: *const app.Ui, id: types.NodeId) bool {
    return ui.clicked(id);
}
