const std = @import("std");
const types = @import("../core/types.zig");
const app = @import("../core/ui_context.zig");
const primitives = @import("primitives.zig");
const text_field = @import("text_field.zig");

pub const SearchOptions = struct {
    placeholder: []const u8 = "Search",
    max_bytes: usize = 256,
    empty_label: []const u8 = "No matching items",
    clear_on_show: bool = true,
};

pub const Options = struct {
    width: f32 = 220,
    max_visible_items: ?usize = null,
    search: ?SearchOptions = null,
};

/// A retained popup/list building block. The caller supplies an overlay host
/// (normally a last child of the root or dock overlay host).
pub const SelectionList = struct {
    allocator: std.mem.Allocator,
    root_node: types.NodeId,
    items_node: types.NodeId,
    item_nodes: std.ArrayListUnmanaged(types.NodeId) = .empty,
    labels: std.ArrayListUnmanaged([]u8) = .empty,
    visible_indices: std.ArrayListUnmanaged(usize) = .empty,
    search: ?text_field.TextField = null,
    empty_label: ?types.NodeId = null,
    options: Options,
    item_height: f32,
    open: bool = false,
    highlighted: usize = 0,

    pub fn init(allocator: std.mem.Allocator, ui: *app.Ui, overlay_host: types.NodeId) !SelectionList {
        return initWithOptions(allocator, ui, overlay_host, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        ui: *app.Ui,
        overlay_host: types.NodeId,
        options: Options,
    ) !SelectionList {
        const root = try primitives.surface(ui, overlay_host, .{
            .width = .{ .px = options.width },
            .height = .hug,
            .direction = .column,
            .gap = ui.theme.space.sm,
            // Inset the rows so a highlighted one keeps clear of the rounded
            // border instead of squaring off against it.
            .padding = types.Edges.all(ui.theme.space.xs),
            .background = .card,
            .border = .stroke,
            .border_width = 1,
            .radius = .control,
        });
        errdefer ui.destroySubtree(root);
        ui.tree.get(root).?.flags.interactive = true;
        try ui.setVisible(root, false);

        var search: ?text_field.TextField = null;
        if (options.search) |search_options| {
            search = try text_field.TextField.init(allocator, ui, root, .{
                .placeholder = search_options.placeholder,
                .max_bytes = search_options.max_bytes,
            });
        }
        errdefer if (search) |*field| field.deinit(ui);

        const items_node = try primitives.column(ui, root, .{
            .width = .fill,
            .height = .hug,
            .gap = ui.theme.space.xxs,
            .overflow_y = .scroll,
            .background = .transparent,
        });

        const font_size = ui.theme.font.body + 2;
        const item_height = @max(
            ui.theme.metrics.compact_control_height,
            ui.textLineHeight(font_size) + ui.theme.space.md,
        );

        var empty_label: ?types.NodeId = null;
        if (options.search) |search_options| {
            empty_label = try primitives.text(ui, items_node, search_options.empty_label, .{
                .width = .fill,
                .height = .{ .px = item_height },
                .padding = .{
                    .left = ui.theme.space.lg,
                    .top = ui.centeredTextTop(item_height, ui.theme.font.small),
                },
                .color = .text_muted,
                .size = ui.theme.font.small,
            });
            try ui.setVisible(empty_label.?, false);
        }

        return .{
            .allocator = allocator,
            .root_node = root,
            .items_node = items_node,
            .search = search,
            .empty_label = empty_label,
            .options = options,
            .item_height = item_height,
        };
    }

    pub fn deinit(self: *SelectionList, ui: *app.Ui) void {
        if (self.search) |*search| search.deinit(ui);
        ui.destroySubtree(self.root_node);
        self.item_nodes.deinit(self.allocator);
        self.clearLabels();
        self.labels.deinit(self.allocator);
        self.visible_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn show(self: *SelectionList, ui: *app.Ui, position: types.Vec2) !void {
        var style = ui.nodeStyle(self.root_node) orelse return error.InvalidNode;
        style.margin.left = position.x;
        style.margin.top = position.y;
        try ui.setStyle(self.root_node, style);
        if (self.search) |*search| {
            const search_options = self.options.search.?;
            if (search_options.clear_on_show) {
                try search.setTextContent(ui, "", search_options.max_bytes);
                try self.applyFilter(ui);
            }
        }
        try ui.setVisible(self.root_node, true);
        if (self.search) |*search|
            ui.requestFocus(search.root_node)
        else
            ui.requestFocus(self.root_node);
        self.highlighted = 0;
        self.open = true;
    }

    pub fn close(self: *SelectionList, ui: *app.Ui) !void {
        if (ui.tree.isDescendantOf(ui.focusedNode(), self.root_node)) ui.clearFocus();
        try ui.setVisible(self.root_node, false);
        self.open = false;
    }

    pub fn setItems(self: *SelectionList, ui: *app.Ui, labels: []const []const u8) !void {
        var owned_labels: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (owned_labels.items) |label| self.allocator.free(label);
            owned_labels.deinit(self.allocator);
        }
        try owned_labels.ensureTotalCapacity(self.allocator, labels.len);
        for (labels) |label| owned_labels.appendAssumeCapacity(try self.allocator.dupe(u8, label));

        while (self.item_nodes.items.len > labels.len) {
            const node = self.item_nodes.pop().?;
            ui.destroySubtree(node);
        }
        const font_size = ui.theme.font.body + 2;
        while (self.item_nodes.items.len < labels.len) {
            const item = try primitives.themedButton(ui, self.items_node, "", .{
                .width = .fill,
                .height = .{ .px = self.item_height },
                .padding = .{
                    .left = ui.theme.space.lg,
                    .right = ui.theme.space.lg,
                    .top = ui.centeredTextTop(self.item_height, font_size),
                },
                .variant = .ghost,
                .border = .transparent,
                .border_width = 0,
                .font_size = font_size,
            });
            errdefer ui.destroySubtree(item);
            applyItemStyle(ui, item);
            try self.item_nodes.append(self.allocator, item);
        }
        for (labels, self.item_nodes.items) |label, node| try ui.setText(node, label);

        self.clearLabels();
        self.labels = owned_labels;
        owned_labels = .empty;
        try self.applyFilter(ui);
    }

    pub fn update(self: *SelectionList, ui: *app.Ui) !?usize {
        if (!self.open) return null;
        ui.capturePointer();
        if (ui.keyPressed(.escape)) {
            try self.close(ui);
            return null;
        }
        if (self.search) |*search| {
            const search_options = self.options.search.?;
            const event = try search.update(ui, .{
                .placeholder = search_options.placeholder,
                .max_bytes = search_options.max_bytes,
            });
            if (event.changed) try self.applyFilter(ui);
        }
        if (self.visible_indices.items.len != 0) {
            if (ui.keyPressed(.down)) self.highlighted = @min(self.highlighted + 1, self.visible_indices.items.len - 1);
            if (ui.keyPressed(.up)) self.highlighted -|= 1;
            if (ui.keyPressed(.enter) or (self.search == null and ui.keyPressed(.space))) {
                const selected = self.visible_indices.items[self.highlighted];
                try self.close(ui);
                return selected;
            }
        }
        if (ui.mousePressed(.left) and !ui.tree.isDescendantOf(ui.input.hovered, self.root_node)) {
            try self.close(ui);
            return null;
        }
        for (self.item_nodes.items, 0..) |node, index| {
            if (ui.input.hovered == node) {
                ui.requestCursor(.hand);
                self.highlightVisibleIndex(index);
            }
            if (ui.activated(node)) {
                try self.close(ui);
                return index;
            }
        }
        return null;
    }

    pub fn labelAt(self: *const SelectionList, index: usize) ?[]const u8 {
        if (index >= self.labels.items.len) return null;
        return self.labels.items[index];
    }

    pub fn showAnchored(
        self: *SelectionList,
        ui: *app.Ui,
        anchor_bounds: types.Rect,
        overlay_bounds: types.Rect,
        gap: f32,
    ) !void {
        if (self.search) |*search| {
            const search_options = self.options.search.?;
            if (search_options.clear_on_show) {
                try search.setTextContent(ui, "", search_options.max_bytes);
                try self.applyFilter(ui);
            }
        }
        const width = @min(self.options.width, overlay_bounds.w);
        const height = @min(self.preferredHeight(ui), overlay_bounds.h);
        const relative_x = anchor_bounds.x - overlay_bounds.x;
        const relative_y = anchor_bounds.y - overlay_bounds.y;
        const x = std.math.clamp(relative_x, 0, @max(0, overlay_bounds.w - width));
        const below = relative_y + anchor_bounds.h + gap;
        const y = if (below + height <= overlay_bounds.h)
            below
        else
            @max(0, relative_y - height - gap);

        var style = ui.nodeStyle(self.root_node) orelse return error.InvalidNode;
        style.width = .{ .px = width };
        try ui.setStyle(self.root_node, style);
        try self.show(ui, .{ .x = x, .y = y });
    }

    pub fn preferredHeight(self: *const SelectionList, ui: *const app.Ui) f32 {
        const visible_count = if (self.visible_indices.items.len == 0 and self.empty_label != null)
            @as(usize, 1)
        else
            self.visible_indices.items.len;
        const displayed_count = if (self.options.max_visible_items) |maximum|
            @min(visible_count, maximum)
        else
            visible_count;
        const row_gaps: f32 = @floatFromInt(displayed_count -| 1);
        const items_height = self.item_height * @as(f32, @floatFromInt(displayed_count)) +
            ui.theme.space.xxs * row_gaps;
        const search_height = if (self.search != null) ui.theme.metrics.control_height + ui.theme.space.sm else 0;
        return ui.theme.space.xs * 2 + search_height + items_height;
    }

    fn applyFilter(self: *SelectionList, ui: *app.Ui) !void {
        self.visible_indices.clearRetainingCapacity();
        const query = if (self.search) |*search| search.text() else "";
        for (self.labels.items, self.item_nodes.items, 0..) |label, node, index| {
            const visible = containsIgnoreCase(label, query);
            try ui.setVisible(node, visible);
            if (visible) try self.visible_indices.append(self.allocator, index);
        }
        if (self.empty_label) |label| try ui.setVisible(label, self.visible_indices.items.len == 0);
        self.highlighted = @min(self.highlighted, self.visible_indices.items.len -| 1);
        try self.syncItemsHeight(ui);
    }

    fn syncItemsHeight(self: *SelectionList, ui: *app.Ui) !void {
        const max_visible = self.options.max_visible_items orelse return;
        const visible_count = if (self.visible_indices.items.len == 0 and self.empty_label != null)
            @as(usize, 1)
        else
            self.visible_indices.items.len;
        var style = ui.nodeStyle(self.items_node) orelse return error.InvalidNode;
        if (visible_count <= max_visible) {
            style.height = .hug;
        } else {
            const gap_count: f32 = @floatFromInt(max_visible -| 1);
            style.height = .{ .px = self.item_height * @as(f32, @floatFromInt(max_visible)) + ui.theme.space.xxs * gap_count };
        }
        try ui.setStyle(self.items_node, style);
    }

    fn highlightVisibleIndex(self: *SelectionList, item_index: usize) void {
        for (self.visible_indices.items, 0..) |visible_index, index| {
            if (visible_index == item_index) {
                self.highlighted = index;
                return;
            }
        }
    }

    fn clearLabels(self: *SelectionList) void {
        for (self.labels.items) |label| self.allocator.free(label);
        self.labels.clearRetainingCapacity();
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (haystack[start .. start + needle.len], needle) |actual, expected| {
            if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn applyItemStyle(ui: *app.Ui, item: types.NodeId) void {
    const current = ui.nodeStyle(item) orelse return;
    var next = current;
    next.hover_background = ui.theme.color(.interaction_hover);
    next.pressed_background = ui.theme.color(.interaction_pressed);
    ui.setStyle(item, next) catch {};
}

test "optional search owns labels and filters case insensitively" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();

    var list = try SelectionList.initWithOptions(std.testing.allocator, &ui, ui.rootNode(), .{
        .search = .{},
        .max_visible_items = 4,
    });
    defer list.deinit(&ui);

    var first = [_]u8{ 'M', 'o', 'n', 'k', 'e', 'y' };
    try list.setItems(&ui, &.{ &first, "Triangle" });
    first[0] = 'X';
    try std.testing.expectEqualStrings("Monkey", list.labelAt(0).?);
    try std.testing.expect(containsIgnoreCase(list.labelAt(0).?, "MONK"));
    try std.testing.expectEqual(@as(@import("../core/style.zig").Size, .hug), ui.nodeStyle(list.items_node).?.height);
    for (list.item_nodes.items) |item| {
        try std.testing.expect(ui.nodeStyle(item).?.hover_background != null);
    }
}

test "rows centre their labels and stay clear of the popup border" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();

    var list = try SelectionList.init(std.testing.allocator, &ui, ui.rootNode());
    defer list.deinit(&ui);
    try list.setItems(&ui, &.{ "Camera", "Fly Camera Controller" });

    const root_style = ui.nodeStyle(list.root_node).?;
    try std.testing.expect(root_style.padding.top > 0);
    try std.testing.expect(root_style.padding.left > 0);

    for (list.item_nodes.items) |item| {
        const style = ui.nodeStyle(item).?;
        const height = style.height.px;
        try std.testing.expect(height >= ui.textLineHeight(style.font_size));
        try std.testing.expectApproxEqAbs(
            ui.centeredTextTop(height, style.font_size),
            style.padding.top,
            0.01,
        );
        try std.testing.expectEqual(style.padding.left, style.padding.right);
    }
}
