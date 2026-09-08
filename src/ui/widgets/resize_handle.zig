const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const app = @import("../core/ui_context.zig");
const panel_mod = @import("panel.zig");

/// A panel that takes the pointer. Everything else about it — creation,
/// styling, parenting — is what `panel` already does.
pub fn resizeHandle(ui: *app.Ui, parent: types.NodeId, style: style_mod.Style) !types.NodeId {
    const id = try panel_mod.panel(ui, parent, style);
    errdefer ui.destroySubtree(id);
    try ui.setInteractive(id, true);
    return id;
}
