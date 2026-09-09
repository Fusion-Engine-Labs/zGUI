const types = @import("../core/types.zig");
const app = @import("../core/ui_context.zig");
const primitives = @import("primitives.zig");

pub const Modal = struct {
    root_node: types.NodeId,
    content_node: types.NodeId,
    open: bool = false,

    pub fn init(ui: *app.Ui) !Modal {
        const root = try primitives.surface(ui, ui.rootNode(), .{
            .width = .fill,
            .height = .fill,
            .direction = .absolute,
            .background = .shell,
        });
        errdefer ui.destroySubtree(root);
        const node = ui.tree.get(root).?;
        node.flags.interactive = true;
        node.flags.focusable = true;
        node.flags.out_of_flow = true;
        const content = try primitives.card(ui, root, .{ .width = .hug, .height = .hug });
        try ui.setVisible(root, false);
        return .{ .root_node = root, .content_node = content };
    }

    pub fn deinit(self: *Modal, ui: *app.Ui) void {
        ui.destroySubtree(self.root_node);
        self.* = undefined;
    }
    pub fn show(self: *Modal, ui: *app.Ui) !void {
        try ui.tree.appendChild(ui.rootNode(), self.root_node);
        try ui.setVisible(self.root_node, true);
        ui.requestFocus(self.root_node);
        self.open = true;
    }
    pub fn close(self: *Modal, ui: *app.Ui) !void {
        try ui.setVisible(self.root_node, false);
        if (ui.isFocused(self.root_node)) ui.clearFocus();
        self.open = false;
    }
    pub fn update(self: *Modal, ui: *app.Ui) !void {
        if (!self.open) return;
        ui.capturePointer();
        if (ui.keyPressed(.escape)) try self.close(ui);
    }
};

test "modal scrim prevents activation behind it" {
    const std = @import("std");
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    const behind = try primitives.themedButton(&ui, ui.rootNode(), "Behind", .{ .width = .fill, .height = .fill });
    var modal = try Modal.init(&ui);
    defer modal.deinit(&ui);
    try modal.show(&ui);
    try ui.beginFrame(.{ .window_size = .{ .x = 200, .y = 100 } });
    try modal.update(&ui);
    try ui.endFrame();
    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = .{ .x = 190, .y = 90 } }, .{ .mouse_down = .left }, .{ .mouse_up = .left } },
        .window_size = .{ .x = 200, .y = 100 },
    });
    try modal.update(&ui);
    try std.testing.expect(!ui.activated(behind));
}
