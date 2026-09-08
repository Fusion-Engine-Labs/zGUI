const std = @import("std");
const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const node_mod = @import("../core/node.zig");
const app = @import("../core/ui_context.zig");
const theme_mod = @import("../theme.zig");
const events = @import("../platform/events.zig");
const dock_node = @import("dock_node.zig");
const dock_manager_mod = @import("dock_manager.zig");
const window_manager_mod = @import("../windowing/window_manager.zig");
const window_mod = @import("../windowing/window.zig");
const dock_gesture = @import("dock_gesture.zig");
const dock_view = @import("dock_view.zig");

pub const DockWindowId = types.WindowId;

pub const DockSpaceOptions = struct {
    rect: types.Rect,
    handle_thickness: f32 = 4,
    tab_height: f32 = 30,
    gap: f32 = 0,
};

pub const DockSpaceResult = struct {
    changed: bool = false,
    cursor: events.CursorKind = .arrow,
    active_window: ?DockWindowId = null,
};

const tab_nominal_width: f32 = 92;
const tab_min_width: f32 = 36;
const floating_title_height: f32 = 30;

const LeafNodes = struct {
    host: types.NodeId = types.invalid_node,
    tab_bar: types.NodeId = types.invalid_node,
    content: types.NodeId = types.invalid_node,
    last_sync: u32 = 0,
};

const SplitNodes = struct {
    handle: types.NodeId = types.invalid_node,
    last_sync: u32 = 0,
};

const FloatingNodes = struct {
    host: types.NodeId = types.invalid_node,
    title: types.NodeId = types.invalid_node,
    content: types.NodeId = types.invalid_node,
    last_sync: u32 = 0,
};

const OverlayNodes = struct {
    drop_preview: types.NodeId = types.invalid_node,
    drag_ghost: types.NodeId = types.invalid_node,
    drag_label: types.NodeId = types.invalid_node,
};

const WindowState = struct {
    window: DockWindowId = types.invalid_window,
    content_rect: types.Rect = .{},
    content_visible: bool = false,
    tab: types.NodeId = types.invalid_node,
    tab_label: types.NodeId = types.invalid_node,
    last_sync: u32 = 0,
};

const DragState = dock_gesture.DragState;
pub const DropZone = dock_gesture.DropZone;

pub const DockSpace = struct {
    allocator: std.mem.Allocator,
    dock: dock_manager_mod.DockManager,
    windows: window_manager_mod.WindowManager,
    leaf_nodes: std.ArrayList(LeafNodes) = .empty,
    split_nodes: std.ArrayList(SplitNodes) = .empty,
    floating_nodes: std.ArrayList(FloatingNodes) = .empty,
    window_state: std.ArrayList(WindowState) = .empty,
    overlays: OverlayNodes = .{},
    drag: ?DragState = null,
    // Frame counter used to detect support nodes that were not touched by
    // the current sync pass; those get hidden without a hide/show round trip
    // that would dirty the tree every frame.
    sync_stamp: u32 = 0,
    order_scratch: std.ArrayList(types.NodeId) = .empty,
    float_scratch: std.ArrayList(DockWindowId) = .empty,
    // Nodes owned by the embedding application that should render above all
    // dock chrome (for example, application menus and context popups).
    external_overlays: std.ArrayList(types.NodeId) = .empty,
    overlay_revision: u32 = 1,
    ordered_dock_revision: u32 = std.math.maxInt(u32),
    ordered_window_revision: u32 = std.math.maxInt(u32),
    ordered_overlay_revision: u32 = std.math.maxInt(u32),

    pub fn init(allocator: std.mem.Allocator) !DockSpace {
        return .{
            .allocator = allocator,
            .dock = try dock_manager_mod.DockManager.init(allocator),
            .windows = window_manager_mod.WindowManager.init(allocator),
        };
    }

    pub fn deinit(self: *DockSpace) void {
        self.external_overlays.deinit(self.allocator);
        self.float_scratch.deinit(self.allocator);
        self.order_scratch.deinit(self.allocator);
        self.window_state.deinit(self.allocator);
        self.floating_nodes.deinit(self.allocator);
        self.split_nodes.deinit(self.allocator);
        self.leaf_nodes.deinit(self.allocator);
        self.windows.deinit();
        self.dock.deinit();
        self.* = undefined;
    }

    pub fn createWindow(
        self: *DockSpace,
        title: []const u8,
        root_node: types.NodeId,
        min_size: types.Vec2,
        flags: window_mod.WindowFlags,
    ) !DockWindowId {
        const id = try self.windows.createWindow(title, .{}, root_node, flags);
        errdefer self.windows.closeWindow(id);
        self.windows.get(id).?.min_size = min_size;
        const index = types.windowIndex(id);
        try self.ensureWindowCapacity(index + 1);
        const tab = self.window_state.items[index].tab;
        const tab_label = self.window_state.items[index].tab_label;
        self.window_state.items[index] = .{ .window = id, .tab = tab, .tab_label = tab_label };
        return id;
    }

    /// Removes a window from docking while leaving its root subtree under the
    /// ownership of the caller that supplied it to createWindow.
    pub fn closeWindow(self: *DockSpace, window: DockWindowId) !void {
        if (self.windows.get(window) == null) return error.InvalidWindow;
        try self.dock.undockWindow(window);
        if (self.drag) |drag| {
            if (drag.window == window) self.drag = null;
        }
        self.windows.closeWindow(window);

        const index = types.windowIndex(window);
        if (index < self.window_state.items.len and self.window_state.items[index].window == window) {
            self.window_state.items[index].window = types.invalid_window;
            self.window_state.items[index].content_rect = .{};
            self.window_state.items[index].content_visible = false;
            self.window_state.items[index].last_sync = 0;
        }
    }

    pub fn isWindowOpen(self: *const DockSpace, window: DockWindowId) bool {
        return self.windows.getConst(window) != null;
    }

    pub fn setWindowTitle(self: *DockSpace, window: DockWindowId, title: []const u8) !void {
        try self.windows.setTitle(window, title);
    }

    pub fn splitNode(
        self: *DockSpace,
        target: types.DockNodeId,
        position: dock_node.DockPosition,
        ratio: f32,
    ) !dock_manager_mod.DockManager.SplitResult {
        return self.dock.splitNode(target, position, ratio);
    }

    pub fn dockWindow(
        self: *DockSpace,
        window: DockWindowId,
        target: types.DockNodeId,
        position: dock_node.DockPosition,
    ) !void {
        try self.dock.dockWindow(window, target, position);
    }

    pub fn setSplitMinimums(self: *DockSpace, split_id: types.DockNodeId, min_first_size: f32, min_second_size: f32) !void {
        try self.dock.setSplitMinimums(split_id, min_first_size, min_second_size);
    }

    pub fn rootLeaf(self: *const DockSpace) types.DockNodeId {
        return self.dock.root;
    }

    pub fn moveWindowToLeaf(self: *DockSpace, window: DockWindowId, target: types.DockNodeId) !void {
        try self.dock.moveWindowToLeaf(window, target);
    }

    pub fn isInteracting(self: *const DockSpace) bool {
        return self.drag != null or self.dock.activeResizeSplit() != null;
    }

    /// Registers an application-owned node to be painted above dock chrome.
    /// The caller retains ownership and must unregister it before destroying
    /// the node.
    pub fn registerOverlay(self: *DockSpace, node: types.NodeId) !void {
        for (self.external_overlays.items) |existing| {
            if (existing == node) return;
        }
        try self.external_overlays.append(self.allocator, node);
        self.overlay_revision +%= 1;
    }

    pub fn unregisterOverlay(self: *DockSpace, node: types.NodeId) void {
        for (self.external_overlays.items, 0..) |existing, index| {
            if (existing != node) continue;
            _ = self.external_overlays.orderedRemove(index);
            self.overlay_revision +%= 1;
            return;
        }
    }

    pub fn windowContentRect(self: *const DockSpace, window: DockWindowId) ?types.Rect {
        if (self.windows.getConst(window) == null) return null;
        const index = types.windowIndex(window);
        if (index >= self.window_state.items.len) return null;
        const state = self.window_state.items[index];
        if (state.window != window or state.last_sync != self.sync_stamp or !state.content_visible) return null;
        return state.content_rect;
    }

    pub fn run(self: *DockSpace, ui: *app.Ui, parent: types.NodeId, options: DockSpaceOptions) !DockSpaceResult {
        self.sync_stamp +%= 1;
        try self.ensureNodeCapacity(ui, parent);
        self.dock.layout(options.rect);

        var result: DockSpaceResult = .{};
        var resize: ResizeUpdate = .{};
        const overlay_captures_pointer = self.externalOverlayContains(ui);
        if (!overlay_captures_pointer) {
            resize = self.updateResize(ui, options);
            result.changed = resize.changed;
            if (self.updateTabsAndDrops(ui, options)) result.changed = true;
        }
        try self.ensureNodeCapacity(ui, parent);
        try self.ensureOverlayNodes(ui, parent);

        self.syncDockNode(ui, parent, self.dock.root, options);
        try self.syncFloatingNodes(ui, parent);
        self.hideStaleNodes(ui);
        try self.applyPaintOrder(ui, parent);
        self.syncDragFeedback(ui, parent);

        if (resize.hovered_split) |split| {
            result.cursor = cursorForSplit(self.dock.splitAxis(split) orelse .x);
        }
        if (self.dock.activeResizeSplit()) |split| {
            result.cursor = cursorForSplit(self.dock.splitAxis(split) orelse .x);
        }
        if (result.cursor == .arrow and self.tabAt(ui.input.mouse_pos, options) != null) {
            result.cursor = .hand;
        }
        if (result.cursor != .arrow) {
            ui.requestCursor(result.cursor);
        }
        if (self.isInteracting()) {
            ui.capturePointer();
        }
        if (overlay_captures_pointer) ui.capturePointer();

        result.active_window = self.firstActiveWindow();
        return result;
    }

    fn externalOverlayContains(self: *const DockSpace, ui: *const app.Ui) bool {
        for (self.external_overlays.items) |id| {
            const node = ui.tree.getConst(id) orelse continue;
            if (node.flags.visible and node.bounds.contains(ui.input.mouse_pos)) return true;
        }
        return false;
    }

    const ResizeUpdate = struct {
        changed: bool = false,
        hovered_split: ?types.DockNodeId = null,
    };

    fn updateResize(self: *DockSpace, ui: *app.Ui, options: DockSpaceOptions) ResizeUpdate {
        const hovered_split = self.dock.hitTestResizeHandle(ui.input.mouse_pos, options.handle_thickness);
        if (ui.mousePressed(.left)) {
            if (hovered_split) |split| {
                self.dock.beginResize(split, ui.input.mouse_pos) catch {};
            }
        }

        const changed = if (ui.mouseDown(.left))
            self.dock.updateResize(ui.input.mouse_pos)
        else
            false;

        if (ui.mouseReleased(.left)) self.dock.endResize();
        return .{ .changed = changed, .hovered_split = hovered_split };
    }

    fn updateTabsAndDrops(self: *DockSpace, ui: *app.Ui, options: DockSpaceOptions) bool {
        var changed = false;
        if (ui.mousePressed(.left)) {
            if (self.tabAt(ui.input.mouse_pos, options)) |hit| {
                _ = self.dock.setActiveWindow(hit.leaf, hit.window);
                self.drag = .{
                    .window = hit.window,
                    .source_leaf = hit.leaf,
                    .start_mouse = ui.input.mouse_pos,
                };
                changed = true;
            } else if (self.floatingTitleAt(ui.input.mouse_pos)) |window| {
                self.windows.bringToFront(window);
                self.drag = .{
                    .window = window,
                    .start_mouse = ui.input.mouse_pos,
                    .floating = true,
                };
            }
        }

        if (ui.mouseDown(.left)) {
            if (self.drag) |*drag| {
                const dx = ui.input.mouse_pos.x - drag.start_mouse.x;
                const dy = ui.input.mouse_pos.y - drag.start_mouse.y;
                if (@abs(dx) + @abs(dy) > 4) drag.dragging = true;
                if (drag.floating and drag.dragging) {
                    if (self.windows.get(drag.window)) |window| {
                        window.rect.x += ui.input.mouse_pos.x - ui.input.prev_mouse_pos.x;
                        window.rect.y += ui.input.mouse_pos.y - ui.input.prev_mouse_pos.y;
                        changed = true;
                    }
                }
            }
        }

        if (ui.mouseReleased(.left)) {
            if (self.drag) |drag| {
                if (drag.dragging) {
                    changed = self.finishDrag(ui.input.mouse_pos, drag) or changed;
                }
                self.drag = null;
            }
        }
        return changed;
    }

    fn finishDrag(self: *DockSpace, mouse_pos: types.Vec2, drag: DragState) bool {
        if (self.dock.hitTestLeaf(mouse_pos)) |target_leaf| {
            const zone = dropZoneFor(self.dock.nodeRect(target_leaf) orelse return false, mouse_pos);
            if (drag.source_leaf) |source| {
                if (source == target_leaf and zone == .center_tab) return false;
                if (source == target_leaf and self.leafTabCount(source) <= 1) return false;
            }
            if (zone == .center_tab) {
                self.dock.moveWindowToLeaf(drag.window, target_leaf) catch return false;
            } else {
                self.dock.dockWindow(drag.window, target_leaf, @enumFromInt(@intFromEnum(zone))) catch return false;
            }
            return true;
        }

        if (!drag.floating) {
            self.dock.undockWindow(drag.window) catch {};
            if (self.windows.get(drag.window)) |window| {
                window.rect = .{ .x = mouse_pos.x - 120, .y = mouse_pos.y - 14, .w = @max(240, window.min_size.x), .h = @max(180, window.min_size.y) };
            }
            return true;
        }
        return false;
    }

    fn syncDockNode(self: *DockSpace, ui: *app.Ui, parent: types.NodeId, id: types.DockNodeId, options: DockSpaceOptions) void {
        const dock = self.dock.resolveNodeConst(id) orelse return;
        switch (dock.*) {
            .leaf => |leaf| self.syncLeaf(ui, parent, id, leaf, options),
            .split => |split| {
                self.syncSplit(ui, parent, id, split, options);
                self.syncDockNode(ui, parent, split.first, options);
                self.syncDockNode(ui, parent, split.second, options);
            },
        }
    }

    /// Hides every support node the current sync pass did not touch:
    /// leaves/splits collapsed out of the dock tree, tabs of windows that
    /// left their leaf (including newly floating ones), and floating chrome
    /// of windows that were docked.
    fn hideStaleNodes(self: *DockSpace, ui: *app.Ui) void {
        for (self.leaf_nodes.items) |nodes| {
            if (nodes.last_sync == self.sync_stamp) continue;
            hideNode(ui, nodes.host);
            hideNode(ui, nodes.tab_bar);
            hideNode(ui, nodes.content);
        }
        for (self.split_nodes.items) |nodes| {
            if (nodes.last_sync == self.sync_stamp) continue;
            hideNode(ui, nodes.handle);
        }
        for (self.floating_nodes.items) |nodes| {
            if (nodes.last_sync == self.sync_stamp) continue;
            hideNode(ui, nodes.host);
            hideNode(ui, nodes.title);
            hideNode(ui, nodes.content);
        }
        for (self.window_state.items) |state| {
            if (state.last_sync == self.sync_stamp) continue;
            hideNode(ui, state.tab);
        }
    }

    /// Keeps overlay chrome painting in the right order: split handles above
    /// panels, floating windows above the docked layout in ascending z-index,
    /// and drag overlays on top. Re-appends only when the order is wrong, so
    /// the steady state leaves the tree untouched.
    fn applyPaintOrder(self: *DockSpace, ui: *app.Ui, parent: types.NodeId) !void {
        if (self.ordered_dock_revision == self.dock.revision and
            self.ordered_window_revision == self.windows.order_revision and
            self.ordered_overlay_revision == self.overlay_revision)
        {
            return;
        }
        self.order_scratch.clearRetainingCapacity();
        try self.collectSplitHandles(self.dock.root);

        self.float_scratch.clearRetainingCapacity();
        for (self.windows.windows.items) |*window| {
            const window_id = window.id;
            if (!window.open or self.dock.leafForWindow(window_id) != null) continue;
            const window_index = types.windowIndex(window_id);
            if (window_index >= self.floating_nodes.items.len) continue;
            try self.float_scratch.append(self.allocator, window_id);
        }
        std.mem.sort(DockWindowId, self.float_scratch.items, @as(*const window_manager_mod.WindowManager, &self.windows), floatZLessThan);
        for (self.float_scratch.items) |window_id| {
            try self.order_scratch.append(self.allocator, self.floating_nodes.items[types.windowIndex(window_id)].host);
        }

        try self.order_scratch.append(self.allocator, self.overlays.drop_preview);
        try self.order_scratch.append(self.allocator, self.overlays.drag_ghost);
        try self.order_scratch.appendSlice(self.allocator, self.external_overlays.items);
        ensureTailOrder(ui, parent, self.order_scratch.items);
        self.ordered_dock_revision = self.dock.revision;
        self.ordered_window_revision = self.windows.order_revision;
        self.ordered_overlay_revision = self.overlay_revision;
    }

    fn collectSplitHandles(self: *DockSpace, id: types.DockNodeId) !void {
        const dock = self.dock.resolveNodeConst(id) orelse return;
        switch (dock.*) {
            .leaf => {},
            .split => |split| {
                try self.order_scratch.append(self.allocator, self.split_nodes.items[types.dockNodeIndex(id)].handle);
                try self.collectSplitHandles(split.first);
                try self.collectSplitHandles(split.second);
            },
        }
    }

    fn syncLeaf(self: *DockSpace, ui: *app.Ui, parent: types.NodeId, id: types.DockNodeId, leaf: dock_node.DockLeaf, options: DockSpaceOptions) void {
        const parent_origin = nodeOrigin(ui, parent);
        const index = types.dockNodeIndex(id);
        self.leaf_nodes.items[index].last_sync = self.sync_stamp;
        const nodes = self.leaf_nodes.items[index];
        const active = if (leaf.tabs.items.len == 0) null else leaf.tabs.items[@min(leaf.active_tab, leaf.tabs.items.len - 1)];
        setPanel(ui, nodes.host, leaf.rect, parent_origin, .panel, false);
        // The tab strip shares its surface with the content below and is
        // closed by a hairline; an active tab's rule sits on top of that line.
        setPanelStyledWithShape(
            ui,
            nodes.tab_bar,
            .{ .x = leaf.rect.x, .y = leaf.rect.y, .w = leaf.rect.w, .h = options.tab_height },
            .{ .x = leaf.rect.x, .y = leaf.rect.y },
            .shell,
            .stroke_soft,
            .{ .bottom = 1 },
            false,
            style_mod.CornerRadii.all(0),
        );
        const content_rect: types.Rect = .{
            .x = leaf.rect.x,
            .y = leaf.rect.y + options.tab_height,
            .w = leaf.rect.w,
            .h = @max(0, leaf.rect.h - options.tab_height),
        };
        setPanel(ui, nodes.content, content_rect, .{ .x = leaf.rect.x, .y = leaf.rect.y }, .transparent, false);

        for (leaf.tabs.items, 0..) |window_id, tab_index| {
            if (self.windows.get(window_id)) |window| {
                self.ensureWindowTab(ui, nodes.tab_bar, window_id) catch {};
                const tab_rect = tabRect(leaf.rect, tab_index, leaf.tabs.items.len, options.tab_height);
                const is_active = active != null and active.? == window_id;
                const window_index = types.windowIndex(window_id);
                if (window_index < self.window_state.items.len) {
                    self.window_state.items[window_index].last_sync = self.sync_stamp;
                    self.window_state.items[window_index].content_visible = is_active;
                    const tab = self.window_state.items[window_index].tab;
                    const label = self.window_state.items[window_index].tab_label;
                    const is_hovered = tab_rect.contains(ui.input.mouse_pos);
                    const is_dragged = if (self.drag) |drag| drag.window == window_id else false;
                    ensureRootParent(ui, tab, nodes.tab_bar);
                    // Tabs carry no chip of their own: every tab sits flat on
                    // the strip, and the current one is marked by an accent
                    // rule along its bottom edge, riding the strip's hairline.
                    // Label contrast carries the rest, so selection never
                    // depends on the accent colour alone.
                    const tab_background: theme_mod.ColorRole = if (is_dragged)
                        .accent_soft
                    else if (is_hovered and !is_active)
                        .interaction_hover
                    else
                        .transparent;
                    const tab_border: theme_mod.ColorRole = if (is_dragged or is_active) .accent else .transparent;
                    setPanelStyledWithShape(ui, tab, tab_rect, .{ .x = leaf.rect.x, .y = leaf.rect.y }, tab_background, tab_border, .{
                        .bottom = if (is_dragged or is_active) 2 else 0,
                    }, true, style_mod.CornerRadii.all(0));
                    setLabel(ui, label, window.title, is_active);
                }
                ensureRootParent(ui, window.root_node, if (is_active) nodes.content else types.invalid_node);
                if (is_active) {
                    setContentRoot(ui, window.root_node);
                    if (window_index < self.window_state.items.len) self.window_state.items[window_index].content_rect = content_rect;
                }
            }
        }
    }

    fn syncSplit(self: *DockSpace, ui: *app.Ui, parent: types.NodeId, id: types.DockNodeId, split: dock_node.DockSplit, options: DockSpaceOptions) void {
        const parent_origin = nodeOrigin(ui, parent);
        const index = types.dockNodeIndex(id);
        self.split_nodes.items[index].last_sync = self.sync_stamp;
        const nodes = self.split_nodes.items[index];
        const hit_rect = self.dock.resizeHandleRect(id, options.handle_thickness) orelse return;
        const active = if (self.dock.activeResizeSplit()) |active_split| active_split == id else false;
        const hovered = !active and hit_rect.contains(ui.input.mouse_pos);
        const visual_rect = if (active or hovered)
            resizeHandleVisualRect(hit_rect, split.axis, options.handle_thickness)
        else
            hit_rect;
        // Idle handles read as the grey seam separating panels; they only
        // light up in the accent while being grabbed.
        setPanel(ui, nodes.handle, visual_rect, parent_origin, if (active or hovered) .accent else .stroke_soft, true);
    }

    fn syncFloatingNodes(self: *DockSpace, ui: *app.Ui, parent: types.NodeId) !void {
        const parent_origin = nodeOrigin(ui, parent);
        for (self.windows.windows.items) |*window| {
            const window_id = window.id;
            if (!window.open or self.dock.leafForWindow(window_id) != null) continue;
            const window_index = types.windowIndex(window_id);
            try self.ensureFloatingCapacity(ui, parent, window_index + 1);
            self.floating_nodes.items[window_index].last_sync = self.sync_stamp;
            const nodes = self.floating_nodes.items[window_index];
            if (window.rect.w <= 0 or window.rect.h <= 0) {
                window.rect.w = @max(260, window.min_size.x);
                window.rect.h = @max(190, window.min_size.y);
            }
            setPanel(ui, nodes.host, window.rect, parent_origin, .panel, false);
            setPanel(ui, nodes.title, .{ .x = window.rect.x, .y = window.rect.y, .w = window.rect.w, .h = floating_title_height }, .{ .x = window.rect.x, .y = window.rect.y }, .shell, true);
            const content_rect: types.Rect = .{
                .x = window.rect.x,
                .y = window.rect.y + floating_title_height,
                .w = window.rect.w,
                .h = @max(0, window.rect.h - floating_title_height),
            };
            setPanel(ui, nodes.content, content_rect, .{ .x = window.rect.x, .y = window.rect.y }, .transparent, false);
            ensureRootParent(ui, window.root_node, nodes.content);
            setContentRoot(ui, window.root_node);
            if (window_index < self.window_state.items.len) self.window_state.items[window_index].content_rect = content_rect;
            if (window_index < self.window_state.items.len) self.window_state.items[window_index].content_visible = true;
        }
    }

    fn tabAt(self: *const DockSpace, mouse_pos: types.Vec2, options: DockSpaceOptions) ?struct { leaf: types.DockNodeId, window: DockWindowId } {
        for (self.dock.nodes.items, 0..) |*node, i| {
            const leaf_id = self.dock.idForSlot(i) orelse continue;
            switch (node.*) {
                .leaf => |leaf| {
                    for (leaf.tabs.items, 0..) |window_id, tab_index| {
                        const rect = tabRect(leaf.rect, tab_index, leaf.tabs.items.len, options.tab_height);
                        if (rect.contains(mouse_pos)) return .{ .leaf = leaf_id, .window = window_id };
                    }
                },
                .split => {},
            }
        }
        return null;
    }

    fn floatingTitleAt(self: *const DockSpace, mouse_pos: types.Vec2) ?DockWindowId {
        for (self.windows.windows.items) |window| {
            const window_id = window.id;
            if (!window.open or self.dock.leafForWindow(window_id) != null) continue;
            const title_rect: types.Rect = .{ .x = window.rect.x, .y = window.rect.y, .w = window.rect.w, .h = floating_title_height };
            if (title_rect.contains(mouse_pos)) return window_id;
        }
        return null;
    }

    fn firstActiveWindow(self: *const DockSpace) ?DockWindowId {
        // activeWindow already yields null for splits, so no kind check here.
        for (0..self.dock.nodes.items.len) |i| {
            const id = self.dock.idForSlot(i) orelse continue;
            if (self.dock.activeWindow(id)) |window| return window;
        }
        return null;
    }

    fn leafTabCount(self: *const DockSpace, leaf_id: types.DockNodeId) usize {
        const dock = self.dock.resolveNodeConst(leaf_id) orelse return 0;
        return switch (dock.*) {
            .leaf => |leaf| leaf.tabs.items.len,
            .split => 0,
        };
    }

    fn ensureNodeCapacity(self: *DockSpace, ui: *app.Ui, parent: types.NodeId) !void {
        while (self.leaf_nodes.items.len < self.dock.nodes.items.len) {
            const nodes = try createLeafNodes(ui, parent);
            errdefer ui.destroySubtree(nodes.host);
            try self.leaf_nodes.append(self.allocator, nodes);
        }
        while (self.split_nodes.items.len < self.dock.nodes.items.len) {
            const handle = try createPanel(ui, parent);
            errdefer ui.destroySubtree(handle);
            try self.split_nodes.append(self.allocator, .{ .handle = handle });
        }
    }

    fn ensureFloatingCapacity(self: *DockSpace, ui: *app.Ui, parent: types.NodeId, count: usize) !void {
        while (self.floating_nodes.items.len < count) {
            const nodes = try createFloatingNodes(ui, parent);
            errdefer ui.destroySubtree(nodes.host);
            try self.floating_nodes.append(self.allocator, nodes);
        }
    }

    fn ensureWindowCapacity(self: *DockSpace, count: usize) !void {
        while (self.window_state.items.len < count) {
            try self.window_state.append(self.allocator, .{});
        }
    }

    fn ensureWindowTab(self: *DockSpace, ui: *app.Ui, parent: types.NodeId, window: DockWindowId) !void {
        const index = types.windowIndex(window);
        try self.ensureWindowCapacity(index + 1);
        const state = &self.window_state.items[index];
        if (state.window != window) {
            state.window = window;
            state.content_rect = .{};
            state.content_visible = false;
            state.last_sync = 0;
        }
        if (state.tab != types.invalid_node) return;
        const tab = try createPanel(ui, parent);
        errdefer ui.destroySubtree(tab);
        const label = try ui.createNode(.label);
        errdefer ui.destroySubtree(label);
        try ui.tree.appendChild(tab, label);
        state.tab = tab;
        state.tab_label = label;
    }

    fn ensureOverlayNodes(self: *DockSpace, ui: *app.Ui, parent: types.NodeId) !void {
        if (self.overlays.drop_preview == types.invalid_node) {
            self.overlays.drop_preview = try createPanel(ui, parent);
        }
        if (self.overlays.drag_ghost == types.invalid_node) {
            const ghost = try createPanel(ui, parent);
            errdefer ui.destroySubtree(ghost);
            const label = try ui.createNode(.label);
            errdefer ui.destroySubtree(label);
            try ui.tree.appendChild(ghost, label);
            self.overlays.drag_ghost = ghost;
            self.overlays.drag_label = label;
        }
    }

    fn syncDragFeedback(self: *DockSpace, ui: *app.Ui, parent: types.NodeId) void {
        const parent_origin = nodeOrigin(ui, parent);
        const active_drag = if (self.drag) |drag| (if (drag.dragging) drag else null) else null;
        const drag = active_drag orelse {
            hideNode(ui, self.overlays.drop_preview);
            hideNode(ui, self.overlays.drag_ghost);
            return;
        };

        const preview_rect: ?types.Rect = blk: {
            const target_leaf = self.dock.hitTestLeaf(ui.input.mouse_pos) orelse break :blk null;
            const leaf_rect = self.dock.nodeRect(target_leaf) orelse break :blk null;
            break :blk dropPreviewRect(leaf_rect, dropZoneFor(leaf_rect, ui.input.mouse_pos));
        };
        if (preview_rect) |rect| {
            setPanelStyled(ui, self.overlays.drop_preview, rect, parent_origin, .accent_soft, .accent, 2, false, 8);
        } else {
            hideNode(ui, self.overlays.drop_preview);
        }

        const title = if (self.windows.get(drag.window)) |window| window.title else "Window";
        const ghost_rect: types.Rect = .{
            .x = ui.input.mouse_pos.x + 14,
            .y = ui.input.mouse_pos.y + 16,
            .w = @max(128, @min(220, 24 + @as(f32, @floatFromInt(title.len)) * 8)),
            .h = 30,
        };
        setPanelStyled(ui, self.overlays.drag_ghost, ghost_rect, parent_origin, .control, .accent, 1, false, 8);
        setLabel(ui, self.overlays.drag_label, title, true);
    }
};

pub fn dockSpace(ui: *app.Ui, parent: types.NodeId, dock_space: *DockSpace, options: DockSpaceOptions) !DockSpaceResult {
    return dock_space.run(ui, parent, options);
}

// View and gesture helpers live in dock_view/dock_gesture; these aliases keep
// the sync passes above reading in one vocabulary without a forwarding layer.
const createPanel = dock_view.createPanel;
const setPanel = dock_view.setPanel;
const setPanelStyled = dock_view.setPanelStyled;
const setPanelStyledWithShape = dock_view.setPanelStyledWithShape;
const hideNode = dock_view.hideNode;
const setContentRoot = dock_view.setContentRoot;
const setLabel = dock_view.setLabel;
const nodeOrigin = dock_view.nodeOrigin;
const ensureRootParent = dock_view.ensureRootParent;
/// Ensures `desired` are the trailing children of `parent`, in order.
/// Re-appends (and therefore dirties the tree) only when the order differs.
const ensureTailOrder = dock_view.ensureTailOrder;
const cursorForSplit = dock_gesture.cursorForSplit;
const resizeHandleVisualRect = dock_gesture.resizeHandleVisualRect;
const dropZoneFor = dock_gesture.dropZoneFor;
const dropPreviewRect = dock_gesture.dropPreviewRect;

fn createLeafNodes(ui: *app.Ui, parent: types.NodeId) !LeafNodes {
    const host = try createPanel(ui, parent);
    errdefer ui.destroySubtree(host);
    return .{
        .host = host,
        .tab_bar = try createPanel(ui, host),
        .content = try createPanel(ui, host),
    };
}

fn createFloatingNodes(ui: *app.Ui, parent: types.NodeId) !FloatingNodes {
    const host = try createPanel(ui, parent);
    errdefer ui.destroySubtree(host);
    return .{
        .host = host,
        .title = try createPanel(ui, host),
        .content = try createPanel(ui, host),
    };
}

/// Rect of the tab strip entry for `tab_index` inside a leaf. Tabs shrink
/// evenly when the nominal width would overflow the leaf and are clipped to
/// the leaf's right edge; shared by drawing and hit testing so they always
/// agree.
fn tabRect(leaf_rect: types.Rect, tab_index: usize, tab_count: usize, tab_height: f32) types.Rect {
    return dock_gesture.tabRect(leaf_rect, tab_index, tab_count, tab_height, tab_nominal_width, tab_min_width);
}

fn floatZLessThan(windows: *const window_manager_mod.WindowManager, a: DockWindowId, b: DockWindowId) bool {
    const za = if (windows.getConst(a)) |window| window.z_index else 0;
    const zb = if (windows.getConst(b)) |window| window.z_index else 0;
    return za < zb;
}

fn reachableLeafCount(dock: *const dock_manager_mod.DockManager, id: types.DockNodeId) usize {
    const node = dock.resolveNodeConst(id) orelse return 0;
    return switch (node.*) {
        .leaf => 1,
        .split => |split| reachableLeafCount(dock, split.first) + reachableLeafCount(dock, split.second),
    };
}

fn visibleLeafHostCount(ui: *const app.Ui, space: *const DockSpace) usize {
    var count: usize = 0;
    for (space.leaf_nodes.items) |nodes| {
        if (ui.tree.getConst(nodes.host)) |node| {
            if (node.flags.visible) count += 1;
        }
    }
    return count;
}

test "dock space tab click selects active window" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const a_root = try createPanel(&ui_state, ui_state.root);
    const b_root = try createPanel(&ui_state, ui_state.root);

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const a = try space.createWindow("A", a_root, .{ .x = 40, .y = 40 }, .{});
    const b = try space.createWindow("B", b_root, .{ .x = 40, .y = 40 }, .{});
    try space.dock.moveWindowToLeaf(a, space.dock.root);
    try space.dockWindow(b, space.dock.root, .center_tab);

    const frame_events = [_]events.PlatformEvent{
        .{ .mouse_move = .{ .x = 130, .y = 10 } },
        .{ .mouse_down = .left },
    };
    try ui_state.beginFrame(.{ .events = &frame_events, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, .{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } });

    try std.testing.expectEqual(b, space.dock.activeWindow(space.dock.root).?);
}

test "dock space dragging tab outside creates floating window" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const root_node = try createPanel(&ui_state, ui_state.root);
    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const window = try space.createWindow("A", root_node, .{ .x = 120, .y = 90 }, .{});
    try space.dock.moveWindowToLeaf(window, space.dock.root);

    try ui_state.beginFrame(.{
        .events = &[_]events.PlatformEvent{
            .{ .mouse_move = .{ .x = 20, .y = 10 } },
            .{ .mouse_down = .left },
        },
        .window_size = .{ .x = 400, .y = 300 },
    });
    _ = try space.run(&ui_state, ui_state.root, .{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } });

    try ui_state.beginFrame(.{
        .events = &[_]events.PlatformEvent{
            .{ .mouse_move = .{ .x = 420, .y = 320 } },
            .{ .mouse_up = .left },
        },
        .window_size = .{ .x = 400, .y = 300 },
    });
    _ = try space.run(&ui_state, ui_state.root, .{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } });

    try std.testing.expect(space.dock.leafForWindow(window) == null);
    try std.testing.expect(space.windows.get(window).?.rect.w >= 120);
}

test "dock space redock split allocates support nodes before syncing same frame" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const a_root = try createPanel(&ui_state, ui_state.root);
    const b_root = try createPanel(&ui_state, ui_state.root);

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const a = try space.createWindow("A", a_root, .{ .x = 80, .y = 80 }, .{});
    const b = try space.createWindow("B", b_root, .{ .x = 80, .y = 80 }, .{});
    try space.dock.moveWindowToLeaf(a, space.dock.root);
    const split = try space.splitNode(space.dock.root, .right, 0.5);
    try space.dock.moveWindowToLeaf(b, split.new_leaf);

    const opts = DockSpaceOptions{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } };
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, opts);

    try ui_state.beginFrame(.{
        .events = &[_]events.PlatformEvent{
            .{ .mouse_move = .{ .x = 20, .y = 10 } },
            .{ .mouse_down = .left },
        },
        .window_size = .{ .x = 400, .y = 300 },
    });
    _ = try space.run(&ui_state, ui_state.root, opts);

    try ui_state.beginFrame(.{
        .events = &[_]events.PlatformEvent{
            .{ .mouse_move = .{ .x = 390, .y = 120 } },
            .{ .mouse_up = .left },
        },
        .window_size = .{ .x = 400, .y = 300 },
    });
    _ = try space.run(&ui_state, ui_state.root, opts);

    try std.testing.expect(space.leaf_nodes.items.len >= space.dock.nodes.items.len);
    try std.testing.expect(space.split_nodes.items.len >= space.dock.nodes.items.len);
    try std.testing.expect(space.dock.leafForWindow(a) != null);
    try std.testing.expectEqual(reachableLeafCount(&space.dock, space.dock.root), visibleLeafHostCount(&ui_state, &space));
}

test "dock space shows drag ghost and drop preview while dragging over leaf" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const a_root = try createPanel(&ui_state, ui_state.root);
    const b_root = try createPanel(&ui_state, ui_state.root);

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const a = try space.createWindow("A", a_root, .{ .x = 80, .y = 80 }, .{});
    const b = try space.createWindow("B", b_root, .{ .x = 80, .y = 80 }, .{});
    try space.dock.moveWindowToLeaf(a, space.dock.root);
    const split = try space.splitNode(space.dock.root, .right, 0.5);
    try space.dock.moveWindowToLeaf(b, split.new_leaf);

    const opts = DockSpaceOptions{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } };
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, opts);

    try ui_state.beginFrame(.{
        .events = &[_]events.PlatformEvent{
            .{ .mouse_move = .{ .x = 20, .y = 10 } },
            .{ .mouse_down = .left },
        },
        .window_size = .{ .x = 400, .y = 300 },
    });
    _ = try space.run(&ui_state, ui_state.root, opts);

    try ui_state.beginFrame(.{
        .events = &[_]events.PlatformEvent{
            .{ .mouse_move = .{ .x = 390, .y = 120 } },
        },
        .window_size = .{ .x = 400, .y = 300 },
    });
    _ = try space.run(&ui_state, ui_state.root, opts);

    try std.testing.expect(ui_state.tree.get(space.overlays.drag_ghost).?.flags.visible);
    try std.testing.expect(ui_state.tree.get(space.overlays.drop_preview).?.flags.visible);
    try std.testing.expectEqualStrings("A", ui_state.tree.get(space.overlays.drag_label).?.text.?);
}

test "dock space splits active tab from same leaf when dropped on edge" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const viewport_root = try createPanel(&ui_state, ui_state.root);
    const inspector_root = try createPanel(&ui_state, ui_state.root);

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const viewport = try space.createWindow("Viewport", viewport_root, .{ .x = 80, .y = 80 }, .{});
    const inspector = try space.createWindow("Inspector", inspector_root, .{ .x = 80, .y = 80 }, .{});
    try space.dock.moveWindowToLeaf(viewport, space.dock.root);
    try space.dockWindow(inspector, space.dock.root, .center_tab);
    _ = space.dock.setActiveWindow(space.dock.root, inspector);
    space.dock.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 });

    const changed = space.finishDrag(.{ .x = 390, .y = 120 }, .{
        .window = inspector,
        .source_leaf = space.dock.root,
        .start_mouse = .{ .x = 130, .y = 10 },
        .dragging = true,
    });

    try std.testing.expect(changed);
    space.dock.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    try std.testing.expect(space.dock.leafForWindow(viewport) != null);
    try std.testing.expect(space.dock.leafForWindow(inspector) != null);
    try std.testing.expect(space.dock.leafForWindow(viewport).? != space.dock.leafForWindow(inspector).?);
    const viewport_rect = space.dock.nodeRect(space.dock.leafForWindow(viewport).?) orelse .{};
    const inspector_rect = space.dock.nodeRect(space.dock.leafForWindow(inspector).?) orelse .{};
    try std.testing.expect(inspector_rect.x > viewport_rect.x);
    try std.testing.expect(inspector_rect.w < viewport_rect.w);
    try std.testing.expect(inspector_rect.w > 80);
}

fn siblingPosition(ui: *const app.Ui, parent: types.NodeId, id: types.NodeId) ?usize {
    const parent_node = ui.tree.getConst(parent) orelse return null;
    var child = parent_node.first_child;
    var index: usize = 0;
    while (child != types.invalid_node) : (index += 1) {
        if (child == id) return index;
        child = if (ui.tree.getConst(child)) |node| node.next_sibling else types.invalid_node;
    }
    return null;
}

test "floating windows paint in z order after bring to front" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const a_root = try createPanel(&ui_state, ui_state.root);
    const b_root = try createPanel(&ui_state, ui_state.root);

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const a = try space.createWindow("A", a_root, .{ .x = 40, .y = 40 }, .{});
    const b = try space.createWindow("B", b_root, .{ .x = 40, .y = 40 }, .{});
    space.windows.get(a).?.rect = .{ .x = 20, .y = 20, .w = 200, .h = 150 };
    space.windows.get(b).?.rect = .{ .x = 60, .y = 60, .w = 200, .h = 150 };

    const opts = DockSpaceOptions{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } };
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, opts);

    const a_host = space.floating_nodes.items[types.windowIndex(a)].host;
    const b_host = space.floating_nodes.items[types.windowIndex(b)].host;
    var a_pos = siblingPosition(&ui_state, ui_state.root, a_host).?;
    var b_pos = siblingPosition(&ui_state, ui_state.root, b_host).?;
    try std.testing.expect(a_pos < b_pos);

    space.windows.bringToFront(a);
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, opts);

    a_pos = siblingPosition(&ui_state, ui_state.root, a_host).?;
    b_pos = siblingPosition(&ui_state, ui_state.root, b_host).?;
    try std.testing.expect(b_pos < a_pos);
    try std.testing.expect(a_pos < siblingPosition(&ui_state, ui_state.root, space.overlays.drag_ghost).?);
}

test "docking a floating window hides its floating chrome" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.style.direction = .absolute;

    const a_root = try createPanel(&ui_state, ui_state.root);
    const b_root = try createPanel(&ui_state, ui_state.root);

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const a = try space.createWindow("A", a_root, .{ .x = 40, .y = 40 }, .{});
    const b = try space.createWindow("B", b_root, .{ .x = 40, .y = 40 }, .{});
    try space.dock.moveWindowToLeaf(a, space.dock.root);
    space.windows.get(b).?.rect = .{ .x = 60, .y = 60, .w = 200, .h = 150 };

    const opts = DockSpaceOptions{ .rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 } };
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, opts);
    try std.testing.expect(ui_state.tree.get(space.floating_nodes.items[types.windowIndex(b)].host).?.flags.visible);

    try space.dock.dockWindow(b, space.dock.root, .center_tab);
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 400, .y = 300 } });
    _ = try space.run(&ui_state, ui_state.root, opts);
    try std.testing.expect(!ui_state.tree.get(space.floating_nodes.items[types.windowIndex(b)].host).?.flags.visible);
}

test "dock manager moving last tab cleans empty source leaf" {
    var dock = try dock_manager_mod.DockManager.init(std.testing.allocator);
    defer dock.deinit();

    const split = try dock.splitNode(dock.root, .right, 0.5);
    try dock.moveWindowToLeaf(1, split.old_node);
    try dock.moveWindowToLeaf(2, split.new_leaf);
    try dock.moveWindowToLeaf(1, split.new_leaf);

    try std.testing.expect(dock.leafForWindow(1) != null);
    try std.testing.expect(dock.leafForWindow(2) != null);
    try std.testing.expectEqual(dock.leafForWindow(2).?, dock.leafForWindow(1).?);
}

test "closing a dock window preserves caller content and rejects its stale handle" {
    var ui_state = try app.Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    var space = try DockSpace.init(std.testing.allocator);
    defer space.deinit();
    const first_root = try createPanel(&ui_state, ui_state.root);
    const first = try space.createWindow("First", first_root, .{ .x = 80, .y = 80 }, .{});
    try space.moveWindowToLeaf(first, space.rootLeaf());

    try space.closeWindow(first);
    try std.testing.expect(!space.isWindowOpen(first));
    try std.testing.expect(space.dock.leafForWindow(first) == null);
    try std.testing.expect(ui_state.nodeExists(first_root));

    const second_root = try createPanel(&ui_state, ui_state.root);
    const second = try space.createWindow("Second", second_root, .{ .x = 80, .y = 80 }, .{});
    try std.testing.expectEqual(types.windowIndex(first), types.windowIndex(second));
    try std.testing.expect(first != second);
    try std.testing.expectError(error.InvalidWindow, space.closeWindow(first));
    try std.testing.expect(space.isWindowOpen(second));
}
