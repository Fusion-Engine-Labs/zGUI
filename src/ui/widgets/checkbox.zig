const types = @import("../core/types.zig");
const app = @import("../core/ui_context.zig");
const primitives = @import("primitives.zig");
const dirty = @import("../core/dirty.zig");

pub const Checkbox = struct {
    root_node: types.NodeId,
    box_node: types.NodeId,
    mark_node: types.NodeId,

    pub fn init(ui: *app.Ui, parent: types.NodeId, label: []const u8) !Checkbox {
        const root = try primitives.row(ui, parent, .{ .width = .hug, .height = .{ .px = 24 }, .gap = 8 });
        errdefer ui.destroySubtree(root);
        const root_ptr = ui.tree.get(root).?;
        root_ptr.flags.interactive = true;
        root_ptr.flags.focusable = true;

        const box = try primitives.surface(ui, root, .{
            .width = .{ .px = 16 },
            .height = .{ .px = 16 },
            .margin = .{ .top = 4 },
            .background = .control,
            .border = .stroke,
            .border_width = 1,
            .radius_px = 4,
            .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        });
        const mark = try primitives.surface(ui, box, .{
            .width = .fill,
            .height = .fill,
            .background = .text,
            .radius_px = 2,
        });
        try ui.setVisible(mark, false);
        _ = try primitives.text(ui, root, label, .{ .height = .fill, .padding = .{ .top = 4 }, .size = ui.theme.font.body });
        return .{ .root_node = root, .box_node = box, .mark_node = mark };
    }

    pub fn deinit(self: *Checkbox, ui: *app.Ui) void {
        ui.destroySubtree(self.root_node);
        self.* = undefined;
    }

    pub fn update(self: *Checkbox, ui: *app.Ui, value: *bool) !bool {
        const activated = ui.activated(self.root_node) or
            (ui.isFocused(self.root_node) and (ui.keyPressed(.space) or ui.keyPressed(.enter)));
        if (activated) value.* = !value.*;
        var next = ui.nodeStyle(self.box_node) orelse return false;
        next.background = if (value.*) ui.theme.palette.accent else ui.theme.palette.control;
        next.border_color = if (ui.isFocused(self.root_node)) ui.theme.palette.accent else if (value.*) ui.theme.palette.accent else ui.theme.palette.stroke;
        try ui.setStyle(self.box_node, next);
        try ui.setVisible(self.mark_node, value.*);
        return activated;
    }
};
