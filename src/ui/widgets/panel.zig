const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const app = @import("../core/ui_context.zig");

pub fn panel(ui: *app.Ui, parent: types.NodeId, style: style_mod.Style) !types.NodeId {
    const id = try ui.createNode(.panel);
    errdefer ui.destroySubtree(id);
    const node = ui.tree.get(id).?;
    node.style = style;
    try ui.tree.appendChild(parent, id);
    return id;
}
