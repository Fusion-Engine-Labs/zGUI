const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const node_mod = @import("../core/node.zig");
const app = @import("../core/ui_context.zig");

pub const ImageOptions = struct {
    texture: types.TextureHandle,
    style: style_mod.Style,
    uv0: types.Vec2 = .{ .x = 0, .y = 0 },
    uv1: types.Vec2 = .{ .x = 1, .y = 1 },
    tint: types.Color = types.Color.rgba(255, 255, 255, 255),
    interactive: bool = false,
};

pub fn image(ui: *app.Ui, parent: types.NodeId, options: ImageOptions) !types.NodeId {
    const id = try ui.createNode(.image);
    errdefer ui.destroySubtree(id);
    const node = ui.tree.get(id).?;
    node.style = options.style;
    node.image = .{
        .texture = options.texture,
        .uv0 = options.uv0,
        .uv1 = options.uv1,
        .tint = options.tint,
    };
    node.flags.interactive = options.interactive;
    try ui.tree.appendChild(parent, id);
    return id;
}

pub fn setImage(ui: *app.Ui, id: types.NodeId, image_data: node_mod.Image) void {
    ui.setImage(id, image_data) catch {};
}
