const std = @import("std");
const ui = @import("zGUI");
const ui_glfw = @import("zGUI_glfw");

const toolbar_height: f32 = 44;
const main_padding: f32 = 8;
const resize_handle_thickness: f32 = 6;

const min_side_width: f32 = 160;
const min_center_width: f32 = 240;
const min_bottom_height: f32 = 96;
const min_main_height: f32 = 240;

const idle_handle_color = ui.Color.rgba(0, 0, 0, 0);
const active_handle_color = ui.Color.rgba(80, 116, 176, 255);

const DemoNodes = struct {
    click_button: ui.NodeId,
    click_label: ui.NodeId,
    stats_label: ui.NodeId,
    main_area: ui.NodeId,
    left_panel: ui.NodeId,
    left_handle: ui.NodeId,
    center_panel: ui.NodeId,
    right_handle: ui.NodeId,
    right_panel: ui.NodeId,
    bottom_handle: ui.NodeId,
    console_panel: ui.NodeId,
};

const DemoDockRefs = struct {
    bottom_split: ui.DockNodeId,
    left_split: ui.DockNodeId,
    right_split: ui.DockNodeId,
    main_node: ui.DockNodeId,
    left_leaf: ui.DockNodeId,
    center_leaf: ui.DockNodeId,
    right_leaf: ui.DockNodeId,
    console_leaf: ui.DockNodeId,
};

const DemoState = struct {
    dock: ui.DockManager,
    refs: DemoDockRefs,
    nodes: DemoNodes,

    pub fn init(allocator: std.mem.Allocator, app_state: *ui.Ui) !DemoState {
        var dock = try ui.DockManager.init(allocator);
        errdefer dock.deinit();

        const refs = try createDockTree(&dock);
        const nodes = try createEditorUi(app_state);

        return .{
            .dock = dock,
            .refs = refs,
            .nodes = nodes,
        };
    }

    pub fn deinit(self: *DemoState) void {
        self.dock.deinit();
    }

    pub fn layoutDock(self: *DemoState, window_size: ui.Vec2) void {
        const available_width = @max(1, window_size.x - main_padding * 2 - resize_handle_thickness * 2);
        const available_height = @max(1, window_size.y - toolbar_height - resize_handle_thickness);
        self.dock.layout(.{
            .x = main_padding,
            .y = toolbar_height,
            .w = available_width,
            .h = available_height,
        });
    }

    pub fn updateResizeInput(self: *DemoState, app_state: *ui.Ui, platform: *ui_glfw.GlfwPlatform) bool {
        const hovered_split = self.hoveredSplit(app_state);
        if (app_state.mousePressed(.left)) {
            if (hovered_split) |split| {
                self.dock.beginResize(split, app_state.mousePosition()) catch {};
            }
        }

        const changed = if (app_state.mouseDown(.left))
            self.dock.updateResize(app_state.mousePosition())
        else
            false;

        if (app_state.mouseReleased(.left)) {
            self.dock.endResize();
        }

        const cursor = if (self.dock.activeResizeSplit()) |split|
            self.cursorForSplit(split)
        else if (hovered_split) |split|
            self.cursorForSplit(split)
        else
            ui.CursorKind.arrow;
        platform.setCursor(cursor);

        self.updateHandleStyles(app_state, hovered_split);
        return changed;
    }

    pub fn applyPanelStyles(self: *DemoState, app_state: *ui.Ui) void {
        const main_rect = self.dock.nodeRect(self.refs.main_node) orelse ui.Rect{};
        const console_rect = self.dock.nodeRect(self.refs.console_leaf) orelse ui.Rect{};
        const left_rect = self.dock.nodeRect(self.refs.left_leaf) orelse ui.Rect{};
        const center_rect = self.dock.nodeRect(self.refs.center_leaf) orelse ui.Rect{};
        const right_rect = self.dock.nodeRect(self.refs.right_leaf) orelse ui.Rect{};

        setNodeHeight(app_state, self.nodes.main_area, main_rect.h);
        setNodeHeight(app_state, self.nodes.console_panel, console_rect.h);
        setNodeWidth(app_state, self.nodes.left_panel, left_rect.w);
        setNodeWidth(app_state, self.nodes.center_panel, center_rect.w);
        setNodeWidth(app_state, self.nodes.right_panel, right_rect.w);
    }

    fn hoveredSplit(self: *const DemoState, app_state: *const ui.Ui) ?ui.DockNodeId {
        if (app_state.interaction(self.nodes.left_handle).hovered) return self.refs.left_split;
        if (app_state.interaction(self.nodes.right_handle).hovered) return self.refs.right_split;
        if (app_state.interaction(self.nodes.bottom_handle).hovered) return self.refs.bottom_split;
        return null;
    }

    fn cursorForSplit(self: *const DemoState, split: ui.DockNodeId) ui.CursorKind {
        return switch (self.dock.splitAxis(split) orelse .x) {
            .x => .resize_x,
            .y => .resize_y,
        };
    }

    fn updateHandleStyles(self: *const DemoState, app_state: *ui.Ui, hovered_split: ?ui.DockNodeId) void {
        const active_split = self.dock.activeResizeSplit();
        self.setHandleStyle(app_state, self.nodes.left_handle, isSplitHighlighted(self.refs.left_split, hovered_split, active_split));
        self.setHandleStyle(app_state, self.nodes.right_handle, isSplitHighlighted(self.refs.right_split, hovered_split, active_split));
        self.setHandleStyle(app_state, self.nodes.bottom_handle, isSplitHighlighted(self.refs.bottom_split, hovered_split, active_split));
    }

    fn setHandleStyle(self: *const DemoState, app_state: *ui.Ui, handle: ui.NodeId, highlighted: bool) void {
        _ = self;
        var style = app_state.nodeStyle(handle) orelse return;
        style.background = if (highlighted) active_handle_color else idle_handle_color;
        app_state.setStyle(handle, style) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    var platform = try ui_glfw.GlfwPlatform.init(init.gpa, 1280, 800, "zGUI retained editor demo");
    defer platform.deinit();
    platform.makeContextCurrent();

    var gl = try ui.OpenGlRenderer.init(init.gpa, ui_glfw.GlfwPlatform.getProcAddress);
    defer gl.deinit();
    std.debug.print("OpenGL: {s}\n", .{ui.OpenGlRenderer.versionString()});
    const initial_window_size = platform.getWindowSize();
    const initial_framebuffer_size = platform.getFramebufferSize();
    const initial_content_scale = platform.getContentScale();
    std.debug.print(
        "Window: {d:.0}x{d:.0}  Framebuffer: {d:.0}x{d:.0}  Content scale: {d:.2}x{d:.2}\n",
        .{
            initial_window_size.x,
            initial_window_size.y,
            initial_framebuffer_size.x,
            initial_framebuffer_size.y,
            initial_content_scale.x,
            initial_content_scale.y,
        },
    );

    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, "assets/fonts/Inter-Regular.ttf", init.gpa, .limited(4 * 1024 * 1024));
    defer init.gpa.free(font_bytes);

    var font_atlas = try ui.FontAtlas.init(init.gpa, font_bytes, 1024, 1024);
    defer font_atlas.deinit();
    // Warm exactly the sizes the theme can ask for; a hand-written list drifts
    // from the tokens and leaves the first themed frame rasterizing inline.
    const theme_font_sizes = (ui.Theme{}).font.sizes();
    try font_atlas.prewarmAscii(&theme_font_sizes, @max(initial_content_scale.x, initial_content_scale.y));
    try gl.syncFontAtlas(&font_atlas);

    var state = try ui.Ui.init(init.gpa);
    defer state.deinit();
    state.setFontAtlas(&font_atlas);

    var demo = try DemoState.init(init.gpa, &state);
    defer demo.deinit();
    var click_count: u32 = 0;
    try state.setActivationHandler(demo.nodes.click_button, ui.EventHandler.bind(&click_count, incrementClickCount));

    while (!platform.shouldClose()) {
        const platform_events = platform.pollEvents();
        const size = platform.getWindowSize();
        const framebuffer_size = platform.getFramebufferSize();
        const text_raster_scale = framebufferScale(size, framebuffer_size);

        try state.beginFrame(.{
            .events = platform_events,
            .window_size = size,
            .dt = 1.0 / 60.0,
            .clipboard = platform.clipboard(),
        });

        demo.layoutDock(size);
        if (demo.updateResizeInput(&state, &platform)) {
            demo.layoutDock(size);
        }
        demo.applyPanelStyles(&state);

        var click_buf: [64]u8 = undefined;
        try state.setText(demo.nodes.click_label, try std.fmt.bufPrint(&click_buf, "Clicks {d}", .{click_count}));

        var stats_buf: [160]u8 = undefined;
        const stats = state.statsSnapshot();
        try state.setText(demo.nodes.stats_label, try std.fmt.bufPrint(
            &stats_buf,
            "Nodes {d}  Commands {d}  Vertices {d}  Batches {d}",
            .{
                stats.node_count,
                stats.paint_command_count,
                stats.vertex_count,
                stats.batch_count,
            },
        ));

        state.setTextRasterScale(text_raster_scale);
        try state.endFrame();
        try gl.syncFontAtlas(&font_atlas);

        const framebuffer_width: u32 = @intFromFloat(@max(1, framebuffer_size.x));
        const framebuffer_height: u32 = @intFromFloat(@max(1, framebuffer_size.y));
        try gl.beginFrameLogical(framebuffer_width, framebuffer_height, size.x, size.y);
        try gl.render(state.drawData());
        try gl.endFrame();
        platform.swapBuffers();
    }
}

fn incrementClickCount(count: *u32, _: ui.Event) void {
    count.* += 1;
}

fn framebufferScale(window_size: ui.Vec2, framebuffer_size: ui.Vec2) f32 {
    const x = framebuffer_size.x / @max(1, window_size.x);
    const y = framebuffer_size.y / @max(1, window_size.y);
    return @max(0.25, @max(x, y));
}

fn createDockTree(dock: *ui.DockManager) !DemoDockRefs {
    const bottom = try dock.splitNode(dock.root, .bottom, 0.82);
    try dock.setSplitMinimums(bottom.split, min_main_height, min_bottom_height);

    const left = try dock.splitNode(bottom.old_node, .left, 0.18);
    try dock.setSplitMinimums(left.split, min_side_width, min_center_width + min_side_width);

    const right = try dock.splitNode(left.old_node, .right, 0.72);
    try dock.setSplitMinimums(right.split, min_center_width, min_side_width);

    return .{
        .bottom_split = bottom.split,
        .left_split = left.split,
        .right_split = right.split,
        .main_node = bottom.old_node,
        .left_leaf = left.new_leaf,
        .center_leaf = right.old_node,
        .right_leaf = right.new_leaf,
        .console_leaf = bottom.new_leaf,
    };
}

/// setStyle already no-ops on an unchanged style and picks layout- vs
/// paint-dirty itself, so these only have to name the axis.
fn setNodeAxis(app_state: *ui.Ui, id: ui.NodeId, comptime axis: []const u8, value: f32) void {
    var style = app_state.nodeStyle(id) orelse return;
    @field(style, axis) = ui.Size{ .px = @max(0, value) };
    app_state.setStyle(id, style) catch {};
}

fn setNodeWidth(app_state: *ui.Ui, id: ui.NodeId, width: f32) void {
    setNodeAxis(app_state, id, "width", width);
}

fn setNodeHeight(app_state: *ui.Ui, id: ui.NodeId, height: f32) void {
    setNodeAxis(app_state, id, "height", height);
}

fn isSplitHighlighted(split: ui.DockNodeId, hovered: ?ui.DockNodeId, active: ?ui.DockNodeId) bool {
    if (active) |active_split| return active_split == split;
    if (hovered) |hovered_split| return hovered_split == split;
    return false;
}

fn createEditorUi(state: *ui.Ui) !DemoNodes {
    const root = state.rootNode();
    try state.setStyle(root, .{
        .width = .fill,
        .height = .fill,
        .direction = .column,
        .background = ui.Color.rgba(14, 16, 22, 255),
    });

    const toolbar = try ui.widgets.toolbar(state, root, .{
        .width = .fill,
        .height = .{ .px = toolbar_height },
        .padding = ui.Edges{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .gap = 10,
        .background = ui.Color.rgba(28, 32, 42, 255),
        .border_color = ui.Color.rgba(60, 68, 86, 255),
        .border_width = 1,
    });

    _ = try ui.widgets.label(state, toolbar, "zGUI Retained", .{
        .width = .{ .px = 170 },
        .height = .fill,
        .padding = ui.Edges{ .top = 4 },
        .foreground = ui.Color.rgba(230, 236, 245, 255),
        .font_size = 17,
    });

    const click_button = try ui.widgets.button(state, toolbar, "Click", .{
        .width = .{ .px = 110 },
        .height = .fill,
        .padding = ui.Edges{ .left = 12, .right = 12, .top = 5, .bottom = 5 },
        .background = ui.Color.rgba(62, 101, 176, 255),
        .foreground = ui.Color.rgba(255, 255, 255, 255),
        .border_color = ui.Color.rgba(104, 142, 220, 255),
        .border_width = 1,
        .radius = ui.CornerRadii.all(5),
    });

    const click_label = try ui.widgets.label(state, toolbar, "Clicks 0", .{
        .width = .{ .px = 130 },
        .height = .fill,
        .padding = ui.Edges{ .top = 4 },
        .foreground = ui.Color.rgba(196, 205, 220, 255),
        .font_size = 15,
    });

    const main_area = try ui.widgets.panel(state, root, .{
        .width = .fill,
        .height = .fill,
        .direction = .row,
        .gap = 0,
        .padding = ui.Edges.all(main_padding),
        .background = ui.Color.rgba(16, 18, 24, 255),
    });

    const left_panel = try sidePanel(state, main_area, "Scene Hierarchy", 230);

    const left_handle = try ui.widgets.resizeHandle(state, main_area, .{
        .width = .{ .px = resize_handle_thickness },
        .height = .fill,
        .background = idle_handle_color,
    });

    const center = try ui.widgets.panel(state, main_area, .{
        .width = .fill,
        .height = .fill,
        .direction = .column,
        .gap = 8,
        .background = ui.Color.rgba(18, 21, 28, 255),
    });

    _ = try ui.widgets.tabBar(state, center, .{
        .width = .fill,
        .height = .{ .px = 34 },
        .direction = .row,
        .gap = 6,
        .padding = ui.Edges{ .left = 8, .right = 8, .top = 6, .bottom = 4 },
        .background = ui.Color.rgba(30, 34, 44, 255),
        .border_color = ui.Color.rgba(61, 69, 88, 255),
        .border_width = 1,
    });

    const viewport = try ui.widgets.panel(state, center, .{
        .width = .fill,
        .height = .fill,
        .direction = .column,
        .padding = ui.Edges.all(14),
        .background = ui.Color.rgba(22, 25, 32, 255),
        .border_color = ui.Color.rgba(58, 68, 88, 255),
        .border_width = 1,
        .radius = ui.CornerRadii.all(6),
    });
    _ = try ui.widgets.label(state, viewport, "Viewport", .{
        .foreground = ui.Color.rgba(206, 216, 232, 255),
        .font_size = 18,
    });

    const right_handle = try ui.widgets.resizeHandle(state, main_area, .{
        .width = .{ .px = resize_handle_thickness },
        .height = .fill,
        .background = idle_handle_color,
    });

    const right_panel = try sidePanel(state, main_area, "Inspector", 290);

    const bottom_handle = try ui.widgets.resizeHandle(state, root, .{
        .width = .fill,
        .height = .{ .px = resize_handle_thickness },
        .background = idle_handle_color,
    });

    const console = try ui.widgets.panel(state, root, .{
        .width = .fill,
        .height = .{ .px = 136 },
        .direction = .column,
        .gap = 8,
        .padding = ui.Edges.all(10),
        .background = ui.Color.rgba(20, 23, 30, 255),
        .border_color = ui.Color.rgba(55, 63, 80, 255),
        .border_width = 1,
    });

    _ = try ui.widgets.label(state, console, "Console", .{
        .foreground = ui.Color.rgba(224, 230, 240, 255),
        .font_size = 16,
    });

    const stats_label = try ui.widgets.label(state, console, "Stats", .{
        .foreground = ui.Color.rgba(160, 174, 196, 255),
        .font_size = 14,
    });

    return .{
        .click_button = click_button,
        .click_label = click_label,
        .stats_label = stats_label,
        .main_area = main_area,
        .left_panel = left_panel,
        .left_handle = left_handle,
        .center_panel = center,
        .right_handle = right_handle,
        .right_panel = right_panel,
        .bottom_handle = bottom_handle,
        .console_panel = console,
    };
}

fn sidePanel(state: *ui.Ui, parent: ui.NodeId, title: []const u8, width: f32) !ui.NodeId {
    const panel = try ui.widgets.panel(state, parent, .{
        .width = .{ .px = width },
        .height = .fill,
        .direction = .column,
        .gap = 10,
        .padding = ui.Edges.all(12),
        .background = ui.Color.rgba(24, 28, 36, 255),
        .border_color = ui.Color.rgba(56, 66, 84, 255),
        .border_width = 1,
        .radius = ui.CornerRadii.all(6),
    });
    _ = try ui.widgets.label(state, panel, title, .{
        .foreground = ui.Color.rgba(226, 232, 242, 255),
        .font_size = 16,
    });
    _ = try ui.widgets.panel(state, panel, .{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = ui.Color.rgba(58, 66, 84, 255),
    });
    _ = try ui.widgets.label(state, panel, "Entity  Camera  Light  Mesh", .{
        .foreground = ui.Color.rgba(155, 168, 188, 255),
        .font_size = 13,
    });
    return panel;
}
