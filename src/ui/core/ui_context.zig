const std = @import("std");
const types = @import("types.zig");
const tree_mod = @import("tree.zig");
const layout_mod = @import("layout.zig");
const input_mod = @import("input.zig");
const paint_mod = @import("paint.zig");
const text_mod = @import("text.zig");
const theme_mod = @import("../theme.zig");
const platform_events = @import("../platform/events.zig");
const events_mod = @import("events.zig");
const batcher_mod = @import("../render/batcher.zig");
const draw_data_mod = @import("../render/draw_data.zig");
const node_mod = @import("node.zig");
const style_mod = @import("style.zig");
const dirty_mod = @import("dirty.zig");

const scroll_wheel_scale: f32 = 46;
const scroll_animation_rate: f32 = 18;

pub const BeginFrame = struct {
    events: []const platform_events.PlatformEvent = &.{},
    window_size: types.Vec2,
    dt: f32 = 0,
    clipboard: ?platform_events.Clipboard = null,
};

pub const UiStats = struct {
    node_count: u32 = 0,
    dirty_layout_count: u32 = 0,
    dirty_paint_count: u32 = 0,
    paint_command_count: u32 = 0,
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    batch_count: u32 = 0,
    draw_call_count: u32 = 0,
    layout_measured_count: u32 = 0,
    layout_positioned_count: u32 = 0,
    layout_skipped_subtree_count: u32 = 0,
    hidden_layout_node_count: u32 = 0,
    paint_visited_count: u32 = 0,
    paint_culled_subtree_count: u32 = 0,
    paint_culled_command_count: u32 = 0,
    geometry_rebuild_count: u32 = 0,
    shaped_glyph_count: u32 = 0,
    reused_glyph_count: u32 = 0,
};

pub const InputCapture = struct {
    wants_mouse: bool = false,
    has_pointer_capture: bool = false,
    wants_keyboard: bool = false,
    wants_text_input: bool = false,
};

pub const Interaction = struct {
    hovered: bool = false,
    active: bool = false,
    focused: bool = false,
    clicked: bool = false,
};

const HandlerSlot = struct {
    node: types.NodeId = types.invalid_node,
    activate: ?events_mod.EventHandler = null,
};

const ActivationSlot = struct {
    node: types.NodeId = types.invalid_node,
    count: u32 = 0,
};

pub const Ui = struct {
    allocator: std.mem.Allocator,
    tree: tree_mod.UiTree,
    paint_list: paint_mod.PaintList,
    batcher: batcher_mod.Batcher,
    input: input_mod.InputState = .{},
    frame_events: std.ArrayList(events_mod.Event) = .empty,
    handlers: std.ArrayList(HandlerSlot) = .empty,
    activation_slots: std.ArrayList(ActivationSlot) = .empty,
    activation_touched: std.ArrayList(u32) = .empty,
    root: types.NodeId = types.invalid_node,
    window_size: types.Vec2 = .{},
    last_window_size: types.Vec2 = .{ .x = -1, .y = -1 },
    dt: f32 = 0,
    stats: UiStats = .{},
    current_draw_data: draw_data_mod.DrawData = .empty,
    font_atlas: ?*batcher_mod.FontAtlas = null,
    text_raster_scale: f32 = 1,
    theme: theme_mod.Theme = theme_mod.zephyr_dark,
    requested_cursor: platform_events.CursorKind = .arrow,
    pointer_capture: bool = false,
    force_layout: bool = true,
    force_paint: bool = true,
    draw_generation: u32 = 0,
    active_scroll_nodes: std.ArrayList(types.NodeId) = .empty,
    clipboard: ?platform_events.Clipboard = null,

    pub fn init(allocator: std.mem.Allocator) !Ui {
        var tree = tree_mod.UiTree.init(allocator);
        errdefer tree.deinit();

        const root = try tree.createNode(.root);
        if (tree.get(root)) |node| {
            node.style.width = .fill;
            node.style.height = .fill;
            node.flags.visible = true;
        }

        return .{
            .allocator = allocator,
            .tree = tree,
            .paint_list = paint_mod.PaintList.init(allocator),
            .batcher = batcher_mod.Batcher.init(allocator),
            .root = root,
        };
    }

    pub fn deinit(self: *Ui) void {
        self.active_scroll_nodes.deinit(self.allocator);
        self.activation_touched.deinit(self.allocator);
        self.activation_slots.deinit(self.allocator);
        self.handlers.deinit(self.allocator);
        self.frame_events.deinit(self.allocator);
        self.batcher.deinit();
        self.paint_list.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *Ui, frame: BeginFrame) !void {
        self.window_size = frame.window_size;
        self.dt = frame.dt;
        self.requested_cursor = .arrow;
        self.pointer_capture = false;
        self.clipboard = frame.clipboard;
        self.input.beginFrame();
        for (self.activation_touched.items) |index| {
            if (index < self.activation_slots.items.len) self.activation_slots.items[index].count = 0;
        }
        self.activation_touched.clearRetainingCapacity();
        self.frame_events.clearRetainingCapacity();
        var pending_mouse_move: ?types.Vec2 = null;
        for (frame.events) |event| {
            switch (event) {
                .mouse_move => |pos| pending_mouse_move = pos,
                else => {
                    if (pending_mouse_move) |pos| {
                        try self.routePlatformEvent(.{ .mouse_move = pos });
                        pending_mouse_move = null;
                    }
                    try self.routePlatformEvent(event);
                },
            }
        }
        if (pending_mouse_move) |pos| try self.routePlatformEvent(.{ .mouse_move = pos });
        self.dispatchFrameEvents();
    }

    pub fn endFrame(self: *Ui) !void {
        const dirty_counts = self.tree.dirtyCounts();
        var layout_stats: layout_mod.LayoutStats = .{};

        const resized = self.window_size.x != self.last_window_size.x or
            self.window_size.y != self.last_window_size.y;
        const needs_layout = self.force_layout or resized or dirty_counts.layout > 0;

        if (needs_layout) {
            layout_stats.add(layout_mod.layoutTreeMeasured(
                &self.tree,
                self.root,
                self.window_size,
                self.font_atlas,
                self.force_layout or resized,
            ));
        }

        const input_scroll = self.applyScrollInput();
        const scrolled = if (input_scroll or self.active_scroll_nodes.items.len != 0)
            self.updateActiveScrollNodes() or input_scroll
        else
            false;
        if (scrolled) {
            layout_stats.add(layout_mod.layoutTreeMeasured(&self.tree, self.root, self.window_size, self.font_atlas, false));
        }

        // Geometry can change while the pointer stays still. Refresh hover
        // after the final layout, rather than hit-testing the whole tree at
        // every beginFrame. This both keeps hover state in sync with relayouts
        // and makes idle retained frames avoid an otherwise redundant walk.
        var hover_changed = false;
        if (needs_layout or scrolled) {
            const previous_hovered = self.input.hovered;
            input_mod.updateHovered(&self.tree, self.root, &self.input);
            hover_changed = self.input.hovered != previous_hovered;
        }

        const needs_paint = self.force_paint or needs_layout or scrolled or hover_changed or dirty_counts.paint > 0;
        var paint_stats: paint_mod.PaintStats = .{};
        if (needs_paint) {
            self.paint_list.clearRetainingCapacity();
            paint_stats = try paint_mod.buildPaintListMeasured(&self.tree, self.root, &self.paint_list);
            self.draw_generation +%= 1;
            self.current_draw_data = try self.batcher.build(self.paint_list.commands.items, self.font_atlas, self.text_raster_scale);
            self.current_draw_data.generation = self.draw_generation;
        }

        self.last_window_size = self.window_size;
        self.force_layout = false;
        self.force_paint = false;
        self.updateStats(dirty_counts.layout, dirty_counts.paint, layout_stats, paint_stats, needs_paint);
        self.tree.clearTrackedDirty();
    }

    pub fn setFontAtlas(self: *Ui, font_atlas: ?*batcher_mod.FontAtlas) void {
        self.font_atlas = font_atlas;
        self.invalidateTextMeasurements();
    }

    pub fn setTextRasterScale(self: *Ui, raster_scale: f32) void {
        const next = if (std.math.isFinite(raster_scale)) @max(0.25, raster_scale) else 1;
        if (next != self.text_raster_scale) self.force_paint = true;
        self.text_raster_scale = next;
    }

    pub fn textLineHeight(self: *const Ui, size: f32) f32 {
        return if (self.font_atlas) |atlas| atlas.lineHeight(size) else text_mod.measureFallback("", size).line_height;
    }

    pub fn centeredTextTop(self: *const Ui, height: f32, size: f32) f32 {
        return @max(0, (height - self.textLineHeight(size)) / 2);
    }

    pub fn setTheme(self: *Ui, theme: theme_mod.Theme) void {
        self.theme = theme;
        self.force_layout = true;
        self.force_paint = true;
    }

    fn invalidateTextMeasurements(self: *Ui) void {
        self.force_layout = true;
        for (self.tree.nodes.items) |*node| {
            node.measured_text_font_size = -1;
        }
    }

    pub fn drawData(self: *const Ui) draw_data_mod.DrawData {
        return self.current_draw_data;
    }

    pub fn rootNode(self: *const Ui) types.NodeId {
        return self.root;
    }

    pub fn createNode(self: *Ui, kind: node_mod.NodeKind) !types.NodeId {
        return self.tree.createNode(kind);
    }

    /// Destroys an owned node subtree and releases every Ui-side reference to
    /// it before its generational node slots become reusable.
    pub fn destroySubtree(self: *Ui, id: types.NodeId) void {
        if (id == self.root or self.tree.getConst(id) == null) return;
        self.clearSubtreeState(id);
        self.tree.destroyNodeUnmanaged(id);
    }

    pub fn nodeExists(self: *const Ui, id: types.NodeId) bool {
        return self.tree.getConst(id) != null;
    }

    pub fn setStyle(self: *Ui, id: types.NodeId, next_style: style_mod.Style) !void {
        const node = self.tree.get(id) orelse return error.InvalidNode;
        if (std.meta.eql(node.style, next_style)) return;
        const layout_changed = !layoutStyleEqual(node.style, next_style);
        node.style = next_style;
        if (layout_changed) {
            dirty_mod.markLayoutDirty(&self.tree, id);
        } else {
            dirty_mod.markPaintDirty(&self.tree, id);
        }
    }

    pub fn nodeStyle(self: *const Ui, id: types.NodeId) ?style_mod.Style {
        const node = self.tree.getConst(id) orelse return null;
        return node.style;
    }

    pub fn setVisible(self: *Ui, id: types.NodeId, visible: bool) !void {
        const node = self.tree.get(id) orelse return error.InvalidNode;
        if (node.flags.visible == visible) return;
        node.flags.visible = visible;
        // Nothing inside a hidden subtree is measured, so what it shows on the
        // frame it reappears has to be measured again rather than trusted.
        if (visible) self.tree.markSubtreeDirty(id);
        dirty_mod.markLayoutDirty(&self.tree, id);
    }

    pub fn setInteractive(self: *Ui, id: types.NodeId, interactive: bool) !void {
        const node = self.tree.get(id) orelse return error.InvalidNode;
        if (node.flags.interactive == interactive) return;
        node.flags.interactive = interactive;
        dirty_mod.markPaintDirty(&self.tree, id);
    }

    pub fn setText(self: *Ui, id: types.NodeId, bytes: []const u8) !void {
        try self.tree.setText(id, bytes);
    }

    pub fn setImage(self: *Ui, id: types.NodeId, image: node_mod.Image) !void {
        const node = self.tree.get(id) orelse return error.InvalidNode;
        if (node.image) |existing| {
            if (std.meta.eql(existing, image)) {
                return;
            }
        }
        node.image = image;
        dirty_mod.markPaintDirty(&self.tree, id);
    }

    pub fn setColorWheelVisual(self: *Ui, id: types.NodeId, visual: node_mod.ColorWheelVisual) !void {
        const node = self.tree.get(id) orelse return error.InvalidNode;
        const next = node_mod.CustomPaint{ .color_wheel = visual };
        if (node.custom_paint) |existing| {
            if (std.meta.eql(existing, next)) return;
        }
        node.custom_paint = next;
        dirty_mod.markPaintDirty(&self.tree, id);
    }

    pub fn bounds(self: *const Ui, id: types.NodeId) ?types.Rect {
        const node = self.tree.getConst(id) orelse return null;
        return node.bounds;
    }

    pub fn interaction(self: *const Ui, id: types.NodeId) Interaction {
        return .{
            .hovered = self.input.hovered == id,
            .active = self.input.active == id,
            .focused = self.input.focused == id,
            .clicked = self.activated(id),
        };
    }

    /// Compatibility alias for `activated`. Activation is the semantic widget
    /// action and can later be produced by keyboard or gamepad input as well.
    pub fn clicked(self: *const Ui, id: types.NodeId) bool {
        return self.activated(id);
    }

    pub fn activated(self: *const Ui, id: types.NodeId) bool {
        return self.activationCount(id) != 0;
    }

    pub fn activationCount(self: *const Ui, id: types.NodeId) usize {
        if (id == types.invalid_node) return 0;
        const index = types.nodeIndex(id);
        if (index >= self.activation_slots.items.len) return 0;
        const slot = self.activation_slots.items[index];
        return if (slot.node == id) slot.count else 0;
    }

    pub fn frameEvents(self: *const Ui) []const events_mod.Event {
        return self.frame_events.items;
    }

    pub fn setActivationHandler(self: *Ui, id: types.NodeId, handler: ?events_mod.EventHandler) !void {
        if (self.tree.getConst(id) == null) return error.InvalidNode;
        const index = types.nodeIndex(id);
        if (index >= self.handlers.items.len) {
            const old_len = self.handlers.items.len;
            try self.handlers.resize(self.allocator, index + 1);
            @memset(self.handlers.items[old_len..], .{});
        }
        self.handlers.items[index] = .{ .node = id, .activate = handler };
    }

    pub fn mousePosition(self: *const Ui) types.Vec2 {
        return self.input.mouse_pos;
    }

    pub fn mouseDown(self: *const Ui, button: platform_events.MouseButton) bool {
        return input_mod.mouseDown(&self.input, button);
    }

    pub fn mousePressed(self: *const Ui, button: platform_events.MouseButton) bool {
        return input_mod.mousePressed(&self.input, button);
    }

    pub fn mouseReleased(self: *const Ui, button: platform_events.MouseButton) bool {
        return input_mod.mouseReleased(&self.input, button);
    }

    pub fn keyDown(self: *const Ui, key: platform_events.Key) bool {
        return input_mod.keyDown(&self.input, key);
    }

    pub fn keyPressed(self: *const Ui, key: platform_events.Key) bool {
        return input_mod.keyPressed(&self.input, key);
    }

    pub fn keyReleased(self: *const Ui, key: platform_events.Key) bool {
        return input_mod.keyReleased(&self.input, key);
    }

    pub fn textInput(self: *const Ui) []const u8 {
        return self.input.text_input[0..self.input.text_input_len];
    }

    pub fn keyboardEvents(self: *const Ui) []const input_mod.OrderedEvent {
        return self.input.orderedEvents();
    }

    pub fn shiftDown(self: *const Ui) bool {
        return self.keyDown(.left_shift) or self.keyDown(.right_shift);
    }

    pub fn controlDown(self: *const Ui) bool {
        return self.keyDown(.left_control) or self.keyDown(.right_control);
    }

    pub fn superDown(self: *const Ui) bool {
        return self.keyDown(.left_super) or self.keyDown(.right_super);
    }

    pub fn altDown(self: *const Ui) bool {
        return self.keyDown(.left_alt) or self.keyDown(.right_alt);
    }

    pub fn commandDown(self: *const Ui) bool {
        return self.controlDown() or self.superDown();
    }

    pub fn textInputOverflowed(self: *const Ui) bool {
        return self.input.text_overflowed;
    }

    pub fn requestFocus(self: *Ui, id: types.NodeId) void {
        const next = self.tree.get(id) orelse return;
        if (self.input.focused == id) return;
        if (self.tree.get(self.input.focused)) |old| old.flags.focused = false;
        dirty_mod.markPaintDirty(&self.tree, self.input.focused);
        self.input.focused = id;
        next.flags.focused = true;
        dirty_mod.markPaintDirty(&self.tree, id);
    }

    pub fn clearFocus(self: *Ui) void {
        if (self.tree.get(self.input.focused)) |old| old.flags.focused = false;
        dirty_mod.markPaintDirty(&self.tree, self.input.focused);
        self.input.focused = types.invalid_node;
    }

    pub fn focusedNode(self: *const Ui) types.NodeId {
        return if (self.tree.getConst(self.input.focused) != null) self.input.focused else types.invalid_node;
    }

    pub fn isFocused(self: *const Ui, id: types.NodeId) bool {
        return self.focusedNode() == id;
    }

    pub fn readClipboard(self: *const Ui) []const u8 {
        const clipboard = self.clipboard orelse return "";
        const value = clipboard.read();
        return if (std.unicode.utf8ValidateSlice(value)) value else "";
    }

    pub fn writeClipboard(self: *const Ui, text: []const u8) void {
        if (!std.unicode.utf8ValidateSlice(text)) return;
        if (self.clipboard) |clipboard| clipboard.write(text);
    }

    pub fn statsSnapshot(self: *const Ui) UiStats {
        return self.stats;
    }

    pub fn capturePointer(self: *Ui) void {
        self.pointer_capture = true;
    }

    pub fn requestCursor(self: *Ui, cursor: platform_events.CursorKind) void {
        self.requested_cursor = cursor;
    }

    pub fn requestedCursor(self: *const Ui) platform_events.CursorKind {
        return self.requested_cursor;
    }

    pub fn inputCapture(self: *const Ui) InputCapture {
        const focused = if (self.tree.getConst(self.input.focused)) |node|
            if (self.nodeEffectivelyVisible(self.input.focused)) node else null
        else
            null;
        return .{
            .wants_mouse = self.pointer_capture or self.input.hovered != types.invalid_node or self.input.active != types.invalid_node,
            .has_pointer_capture = self.pointer_capture or self.input.active != types.invalid_node,
            .wants_keyboard = focused != null,
            .wants_text_input = if (focused) |node| node.flags.accepts_text_input else false,
        };
    }

    fn nodeEffectivelyVisible(self: *const Ui, id: types.NodeId) bool {
        var current = id;
        while (current != types.invalid_node) {
            const node = self.tree.getConst(current) orelse return false;
            if (!node.flags.visible) return false;
            current = node.parent;
        }
        return true;
    }

    pub fn processPlatformEvent(self: *Ui, event: platform_events.PlatformEvent) !void {
        const first_event = self.frame_events.items.len;
        try self.routePlatformEvent(event);
        for (self.frame_events.items[first_event..]) |widget_event| self.dispatchEvent(widget_event);
    }

    fn routePlatformEvent(self: *Ui, event: platform_events.PlatformEvent) !void {
        const target = input_mod.routeEvent(&self.tree, self.root, &self.input, event) orelse return;
        try self.recordActivation(target);
        try self.frame_events.append(self.allocator, .{ .activate = .{
            .target = target,
            .source = .{ .pointer = .{
                .button = .left,
                .position = self.input.mouse_pos,
            } },
        } });
    }

    fn recordActivation(self: *Ui, target: types.NodeId) !void {
        const index = types.nodeIndex(target);
        if (index >= self.activation_slots.items.len) {
            const old_len = self.activation_slots.items.len;
            try self.activation_slots.resize(self.allocator, index + 1);
            @memset(self.activation_slots.items[old_len..], .{});
        }
        const slot = &self.activation_slots.items[index];
        if (slot.node != target) slot.* = .{ .node = target };
        if (slot.count == 0) try self.activation_touched.append(self.allocator, index);
        slot.count +|= 1;
    }

    fn dispatchFrameEvents(self: *Ui) void {
        const event_count = self.frame_events.items.len;
        for (0..event_count) |index| {
            const event = self.frame_events.items[index];
            self.dispatchEvent(event);
        }
    }

    fn dispatchEvent(self: *Ui, event: events_mod.Event) void {
        const target = event.target();
        if (self.tree.getConst(target) == null) return;
        const index = types.nodeIndex(target);
        if (index >= self.handlers.items.len) return;
        const slot = self.handlers.items[index];
        if (slot.node != target) return;

        switch (event) {
            .activate => if (slot.activate) |handler| handler.call(event),
        }
    }

    fn clearSubtreeState(self: *Ui, id: types.NodeId) void {
        const node = self.tree.getConst(id) orelse return;
        var child = node.first_child;
        while (child != types.invalid_node) {
            const next = if (self.tree.getConst(child)) |child_node| child_node.next_sibling else types.invalid_node;
            self.clearSubtreeState(child);
            child = next;
        }

        if (self.input.hovered == id) self.input.hovered = types.invalid_node;
        if (self.input.active == id) self.input.active = types.invalid_node;
        if (self.input.focused == id) self.input.focused = types.invalid_node;

        const index = types.nodeIndex(id);
        if (index < self.activation_slots.items.len and self.activation_slots.items[index].node == id) {
            self.activation_slots.items[index] = .{};
        }
        if (index < self.handlers.items.len and self.handlers.items[index].node == id) {
            self.handlers.items[index] = .{};
        }
    }

    fn updateStats(self: *Ui, dirty_layout_count: u32, dirty_paint_count: u32, layout_stats: layout_mod.LayoutStats, paint_stats: paint_mod.PaintStats, geometry_rebuilt: bool) void {
        self.stats = .{
            .node_count = @intCast(self.tree.nodes.items.len - self.tree.free_list.items.len),
            .dirty_layout_count = dirty_layout_count,
            .dirty_paint_count = dirty_paint_count,
            .paint_command_count = @intCast(self.paint_list.commands.items.len),
            .vertex_count = @intCast(self.batcher.vertices.items.len),
            .index_count = @intCast(self.batcher.indices.items.len),
            .batch_count = @intCast(self.batcher.batches.items.len),
            .draw_call_count = @intCast(self.batcher.batches.items.len),
            .layout_measured_count = layout_stats.measured_nodes,
            .layout_positioned_count = layout_stats.positioned_nodes,
            .layout_skipped_subtree_count = layout_stats.skipped_clean_subtrees,
            .hidden_layout_node_count = layout_stats.skipped_hidden_nodes,
            .paint_visited_count = paint_stats.visited_nodes,
            .paint_culled_subtree_count = paint_stats.culled_subtrees,
            .paint_culled_command_count = paint_stats.culled_commands,
            .geometry_rebuild_count = if (geometry_rebuilt) 1 else 0,
            .shaped_glyph_count = self.batcher.shaped_glyph_count,
            .reused_glyph_count = self.batcher.reused_glyph_count,
        };
    }

    fn applyScrollInput(self: *Ui) bool {
        if (self.input.scroll_delta.x == 0 and self.input.scroll_delta.y == 0) return false;
        const target = scrollTargetAt(&self.tree, self.root, self.input.mouse_pos, self.input.scroll_delta) orelse return false;
        const node = self.tree.get(target) orelse return false;
        const before = node.scroll_target_offset;

        if (node.style.overflow_x == .scroll) {
            node.scroll_target_offset.x -= self.input.scroll_delta.x * scroll_wheel_scale;
        }
        if (node.style.overflow_y == .scroll) {
            node.scroll_target_offset.y -= self.input.scroll_delta.y * scroll_wheel_scale;
        }

        layout_mod.clampScrollOffsets(node);
        const changed = before.x != node.scroll_target_offset.x or before.y != node.scroll_target_offset.y;
        if (changed) {
            self.tree.markLayoutDirty(target);
            self.trackActiveScroll(target);
        }
        return changed;
    }

    fn trackActiveScroll(self: *Ui, id: types.NodeId) void {
        for (self.active_scroll_nodes.items) |existing| if (existing == id) return;
        self.active_scroll_nodes.append(self.allocator, id) catch {};
    }

    /// Advances only scroll containers with an outstanding animation rather
    /// than walking the complete UI tree on every animated frame.
    fn updateActiveScrollNodes(self: *Ui) bool {
        var any_changed = false;
        var index: usize = 0;
        while (index < self.active_scroll_nodes.items.len) {
            const id = self.active_scroll_nodes.items[index];
            const node = self.tree.get(id) orelse {
                _ = self.active_scroll_nodes.swapRemove(index);
                continue;
            };
            if (!node.flags.visible) {
                _ = self.active_scroll_nodes.swapRemove(index);
                continue;
            }

            const before = node.scroll_offset;
            const before_target = node.scroll_target_offset;
            layout_mod.clampScrollOffsets(node);
            var changed = before_target.x != node.scroll_target_offset.x or
                before_target.y != node.scroll_target_offset.y;
            changed = animateNodeScroll(node, self.dt) or changed;
            changed = changed or before.x != node.scroll_offset.x or before.y != node.scroll_offset.y;
            if (changed) {
                self.tree.markLayoutDirty(id);
                any_changed = true;
            }
            const settled = node.scroll_offset.x == node.scroll_target_offset.x and
                node.scroll_offset.y == node.scroll_target_offset.y;
            if (settled) {
                _ = self.active_scroll_nodes.swapRemove(index);
            } else index += 1;
        }
        return any_changed;
    }
};

fn layoutStyleEqual(a: style_mod.Style, b: style_mod.Style) bool {
    return std.meta.eql(a.width, b.width) and
        std.meta.eql(a.height, b.height) and
        a.min_width == b.min_width and
        a.min_height == b.min_height and
        std.meta.eql(a.padding, b.padding) and
        std.meta.eql(a.margin, b.margin) and
        a.gap == b.gap and
        a.direction == b.direction and
        a.overflow_x == b.overflow_x and
        a.overflow_y == b.overflow_y and
        a.border_width == b.border_width and
        std.meta.eql(a.border_edges, b.border_edges) and
        a.font_size == b.font_size;
}

fn scrollTargetAt(tree: *const tree_mod.UiTree, id: types.NodeId, pos: types.Vec2, delta: types.Vec2) ?types.NodeId {
    const node = tree.getConst(id) orelse return null;
    if (!node.flags.visible or !node.bounds.contains(pos)) return null;

    var child = node.last_child;
    while (child != types.invalid_node) {
        if (scrollTargetAt(tree, child, pos, delta)) |hit| return hit;
        const child_node = tree.getConst(child) orelse break;
        child = child_node.prev_sibling;
    }

    if (canScrollForDelta(node, delta)) return id;
    return null;
}

fn canScrollForDelta(node: *const node_mod.Node, delta: types.Vec2) bool {
    if (delta.x != 0 and node.style.overflow_x == .scroll and layout_mod.maxScroll(node, .x) > 0) return true;
    if (delta.y != 0 and node.style.overflow_y == .scroll and layout_mod.maxScroll(node, .y) > 0) return true;
    return false;
}

fn animateNodeScroll(node: *node_mod.Node, dt: f32) bool {
    const t = scrollStep(dt);
    const before = node.scroll_offset;
    node.scroll_offset.x = approach(node.scroll_offset.x, node.scroll_target_offset.x, t);
    node.scroll_offset.y = approach(node.scroll_offset.y, node.scroll_target_offset.y, t);
    return before.x != node.scroll_offset.x or before.y != node.scroll_offset.y;
}

fn scrollStep(dt: f32) f32 {
    if (!std.math.isFinite(dt) or dt <= 0) return 1;
    return 1 - @exp(-scroll_animation_rate * @min(dt, 0.05));
}

fn approach(current: f32, target: f32, t: f32) f32 {
    if (@abs(target - current) < 0.25) return target;
    return current + (target - current) * t;
}

test "idle frames reuse draw data and rebuild on change" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    const panel = try ui_state.createNode(.panel);
    ui_state.tree.get(panel).?.style = .{
        .width = .fill,
        .height = .{ .px = 40 },
        .background = types.Color.rgba(40, 40, 40, 255),
    };
    try ui_state.tree.appendChild(ui_state.root, panel);

    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    const first_generation = ui_state.drawData().generation;
    try std.testing.expect(ui_state.drawData().vertices.len > 0);

    // Nothing changed: geometry must be reused, not rebuilt.
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    try std.testing.expectEqual(first_generation, ui_state.drawData().generation);

    // A style change dirties the node and forces a rebuild.
    ui_state.tree.get(panel).?.style.background = types.Color.rgba(90, 90, 90, 255);
    dirty_mod.markPaintDirty(&ui_state.tree, panel);
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    try std.testing.expect(ui_state.drawData().generation != first_generation);

    // A window resize also forces a rebuild.
    const before_resize = ui_state.drawData().generation;
    try ui_state.beginFrame(.{ .events = &.{}, .window_size = .{ .x = 300, .y = 100 } });
    try ui_state.endFrame();
    try std.testing.expect(ui_state.drawData().generation != before_resize);
}

test "scroll input updates both overflow axes and clamps to content" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    const scroller = try ui_state.createNode(.panel);
    const child = try ui_state.createNode(.panel);
    ui_state.tree.get(scroller).?.style = .{
        .width = .fill,
        .height = .fill,
        .overflow_x = .scroll,
        .overflow_y = .scroll,
    };
    ui_state.tree.get(child).?.style = .{
        .width = .{ .px = 180 },
        .height = .{ .px = 140 },
    };
    try ui_state.tree.appendChild(ui_state.root, scroller);
    try ui_state.tree.appendChild(scroller, child);

    try ui_state.beginFrame(.{
        .events = &[_]platform_events.PlatformEvent{
            .{ .mouse_move = .{ .x = 10, .y = 10 } },
            .{ .scroll = .{ .x = -1, .y = -1 } },
        },
        .window_size = .{ .x = 100, .y = 80 },
        .dt = 1.0 / 60.0,
    });
    try ui_state.endFrame();

    try std.testing.expectEqual(@as(f32, scroll_wheel_scale), ui_state.tree.get(scroller).?.scroll_target_offset.x);
    try std.testing.expectEqual(@as(f32, scroll_wheel_scale), ui_state.tree.get(scroller).?.scroll_target_offset.y);
    try std.testing.expect(ui_state.tree.get(scroller).?.scroll_offset.x > 0);
    try std.testing.expect(ui_state.tree.get(scroller).?.scroll_offset.x < ui_state.tree.get(scroller).?.scroll_target_offset.x);
    try std.testing.expectEqual(-ui_state.tree.get(scroller).?.scroll_offset.x, ui_state.tree.get(child).?.bounds.x);
    try std.testing.expectEqual(-ui_state.tree.get(scroller).?.scroll_offset.y, ui_state.tree.get(child).?.bounds.y);

    try ui_state.beginFrame(.{
        .events = &[_]platform_events.PlatformEvent{
            .{ .scroll = .{ .x = -10, .y = -10 } },
        },
        .window_size = .{ .x = 100, .y = 80 },
        .dt = 1.0 / 60.0,
    });
    try ui_state.endFrame();

    try std.testing.expectEqual(@as(f32, 80), ui_state.tree.get(scroller).?.scroll_target_offset.x);
    try std.testing.expectEqual(@as(f32, 60), ui_state.tree.get(scroller).?.scroll_target_offset.y);
    try std.testing.expect(ui_state.tree.get(scroller).?.scroll_offset.x < ui_state.tree.get(scroller).?.scroll_target_offset.x);
    try std.testing.expect(ui_state.tree.get(scroller).?.scroll_offset.y < ui_state.tree.get(scroller).?.scroll_target_offset.y);

    try ui_state.beginFrame(.{
        .events = &.{},
        .window_size = .{ .x = 220, .y = 180 },
        .dt = 1.0 / 60.0,
    });
    try ui_state.endFrame();

    try std.testing.expectEqual(@as(f32, 0), ui_state.tree.get(scroller).?.scroll_offset.x);
    try std.testing.expectEqual(@as(f32, 0), ui_state.tree.get(scroller).?.scroll_offset.y);
    try std.testing.expectEqual(@as(f32, 0), ui_state.tree.get(scroller).?.scroll_target_offset.x);
    try std.testing.expectEqual(@as(f32, 0), ui_state.tree.get(scroller).?.scroll_target_offset.y);
}

test "pointer capture is explicit and resets at the next frame" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    try ui_state.beginFrame(.{ .window_size = .{ .x = 100, .y = 100 } });
    ui_state.capturePointer();
    try std.testing.expect(ui_state.inputCapture().wants_mouse);
    try std.testing.expect(ui_state.inputCapture().has_pointer_capture);

    try ui_state.beginFrame(.{ .window_size = .{ .x = 100, .y = 100 } });
    try std.testing.expect(!ui_state.inputCapture().has_pointer_capture);
}

test "focused text capability controls capture and destruction clears it" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    const button = try ui_state.createNode(.button);
    try ui_state.tree.appendChild(ui_state.root, button);
    ui_state.requestFocus(button);
    try std.testing.expect(ui_state.inputCapture().wants_keyboard);
    try std.testing.expect(!ui_state.inputCapture().wants_text_input);

    const field = try ui_state.createNode(.panel);
    const field_node = ui_state.tree.get(field).?;
    field_node.flags.focusable = true;
    field_node.flags.accepts_text_input = true;
    try ui_state.tree.appendChild(ui_state.root, field);
    ui_state.requestFocus(field);
    try std.testing.expect(ui_state.inputCapture().wants_text_input);
    ui_state.destroySubtree(field);
    try std.testing.expectEqual(types.invalid_node, ui_state.focusedNode());
    try std.testing.expect(!ui_state.inputCapture().wants_keyboard);
}

test "paint-only style changes do not dirty layout" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    const panel = try ui_state.createNode(.panel);
    try ui_state.tree.appendChild(ui_state.root, panel);
    try ui_state.beginFrame(.{ .window_size = .{ .x = 100, .y = 100 } });
    try ui_state.endFrame();

    var next = ui_state.nodeStyle(panel).?;
    next.background = types.Color.rgba(10, 20, 30, 255);
    try ui_state.setStyle(panel, next);
    const counts = ui_state.tree.dirtyCounts();
    try std.testing.expectEqual(@as(u32, 0), counts.layout);
    try std.testing.expectEqual(@as(u32, 1), counts.paint);
}

test "relayout refreshes hover for a stationary pointer" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    const button = try ui_state.createNode(.button);
    try ui_state.tree.appendChild(ui_state.root, button);

    var style = ui_state.nodeStyle(button).?;
    style.width = .{ .px = 20 };
    style.height = .{ .px = 20 };
    style.margin.left = 50;
    try ui_state.setStyle(button, style);

    try ui_state.beginFrame(.{
        .events = &.{.{ .mouse_move = .{ .x = 10, .y = 10 } }},
        .window_size = .{ .x = 100, .y = 100 },
    });
    try ui_state.endFrame();
    try std.testing.expectEqual(types.invalid_node, ui_state.input.hovered);

    style.margin.left = 0;
    try ui_state.setStyle(button, style);
    try ui_state.beginFrame(.{ .window_size = .{ .x = 100, .y = 100 } });
    try ui_state.endFrame();

    try std.testing.expectEqual(button, ui_state.input.hovered);
}

fn createInteractionTestButton(ui_state: *Ui, bounds: types.Rect) !types.NodeId {
    const id = try ui_state.createNode(.button);
    ui_state.tree.get(id).?.bounds = bounds;
    try ui_state.tree.appendChild(ui_state.root, id);
    return id;
}

test "pointer events preserve ordering and every activation in a frame" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.bounds = .{ .w = 100, .h = 40 };

    const first = try createInteractionTestButton(&ui_state, .{ .w = 50, .h = 40 });
    const second = try createInteractionTestButton(&ui_state, .{ .x = 50, .w = 50, .h = 40 });

    // Releasing over another node must not activate either node.
    try ui_state.beginFrame(.{
        .events = &.{
            .{ .mouse_move = .{ .x = 20, .y = 20 } },
            .{ .mouse_down = .left },
            .{ .mouse_move = .{ .x = 70, .y = 20 } },
            .{ .mouse_up = .left },
        },
        .window_size = .{ .x = 100, .y = 40 },
    });
    try std.testing.expectEqual(@as(usize, 0), ui_state.frameEvents().len);

    try ui_state.beginFrame(.{
        .events = &.{
            .{ .mouse_move = .{ .x = 20, .y = 20 } },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
            .{ .mouse_move = .{ .x = 70, .y = 20 } },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
        },
        .window_size = .{ .x = 100, .y = 40 },
    });

    try std.testing.expect(ui_state.clicked(first));
    try std.testing.expect(ui_state.activated(second));
    try std.testing.expectEqual(@as(usize, 2), ui_state.activationCount(first));
    try std.testing.expectEqual(@as(usize, 1), ui_state.activationCount(second));
    try std.testing.expectEqual(@as(usize, 3), ui_state.frameEvents().len);
}

test "activation callbacks are ordered and stale handlers do not fire" {
    const Tracker = struct {
        targets: [3]types.NodeId = undefined,
        len: usize = 0,

        fn record(self: *@This(), event: events_mod.Event) void {
            self.targets[self.len] = event.target();
            self.len += 1;
        }
    };

    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();
    ui_state.tree.get(ui_state.root).?.bounds = .{ .w = 100, .h = 40 };
    const first = try createInteractionTestButton(&ui_state, .{ .w = 50, .h = 40 });
    const second = try createInteractionTestButton(&ui_state, .{ .x = 50, .w = 50, .h = 40 });

    var tracker: Tracker = .{};
    const handler = events_mod.EventHandler.bind(&tracker, Tracker.record);
    try ui_state.setActivationHandler(first, handler);
    try ui_state.setActivationHandler(second, handler);

    try ui_state.beginFrame(.{
        .events = &.{
            .{ .mouse_move = .{ .x = 20, .y = 20 } },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
            .{ .mouse_move = .{ .x = 70, .y = 20 } },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
        },
        .window_size = .{ .x = 100, .y = 40 },
    });
    try std.testing.expectEqualSlices(types.NodeId, &.{ first, first, second }, tracker.targets[0..tracker.len]);

    ui_state.destroySubtree(first);
    const replacement = try createInteractionTestButton(&ui_state, .{ .w = 50, .h = 40 });
    try std.testing.expectEqual(types.nodeIndex(first), types.nodeIndex(replacement));
    try ui_state.beginFrame(.{
        .events = &.{
            .{ .mouse_move = .{ .x = 20, .y = 20 } },
            .{ .mouse_down = .left },
            .{ .mouse_up = .left },
        },
        .window_size = .{ .x = 100, .y = 40 },
    });
    try std.testing.expectEqual(@as(usize, 3), tracker.len);
}

test "destroySubtree clears interaction state for every descendant" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    const parent = try ui_state.createNode(.panel);
    try ui_state.tree.appendChild(ui_state.root, parent);
    const child = try createInteractionTestButton(&ui_state, .{ .w = 40, .h = 40 });
    try ui_state.tree.appendChild(parent, child);
    ui_state.input.hovered = child;
    ui_state.input.active = child;
    ui_state.input.focused = child;

    ui_state.destroySubtree(parent);

    try std.testing.expect(!ui_state.nodeExists(parent));
    try std.testing.expect(!ui_state.nodeExists(child));
    try std.testing.expectEqual(types.invalid_node, ui_state.input.hovered);
    try std.testing.expectEqual(types.invalid_node, ui_state.input.active);
    try std.testing.expectEqual(types.invalid_node, ui_state.input.focused);
}

test "revealing a subtree re-measures what was skipped while it was hidden" {
    var ui_state = try Ui.init(std.testing.allocator);
    defer ui_state.deinit();

    const host = try ui_state.createNode(.panel);
    ui_state.tree.get(host).?.style = .{ .width = .fill, .height = .{ .px = 40 } };
    try ui_state.tree.appendChild(ui_state.root, host);
    const label = try ui_state.createNode(.label);
    ui_state.tree.get(label).?.style = .{ .width = .hug, .height = .hug, .font_size = 12 };
    try ui_state.tree.setText(label, "hidden at birth");
    try ui_state.tree.appendChild(host, label);
    try ui_state.setVisible(host, false);

    // Layout never reaches a hidden subtree, and the frame still clears its
    // dirty flags, so the label goes into the next frame unmeasured.
    try ui_state.beginFrame(.{ .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    try std.testing.expectEqual(@as(f32, -1), ui_state.tree.getConst(label).?.measured_text_font_size);

    try ui_state.setVisible(host, true);
    try ui_state.beginFrame(.{ .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    const measured_width = ui_state.tree.getConst(label).?.measured_text.x;
    try std.testing.expectEqual(@as(f32, 12), ui_state.tree.getConst(label).?.measured_text_font_size);
    try std.testing.expect(measured_width > 0);

    // Text that changes out of sight is measured again on the way back in.
    try ui_state.setVisible(host, false);
    try ui_state.beginFrame(.{ .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    try ui_state.setText(label, "a much longer label than before");
    try ui_state.setVisible(host, true);
    try ui_state.beginFrame(.{ .window_size = .{ .x = 200, .y = 100 } });
    try ui_state.endFrame();
    try std.testing.expect(ui_state.tree.getConst(label).?.measured_text.x > measured_width);
}
