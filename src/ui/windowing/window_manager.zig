const std = @import("std");
const types = @import("../core/types.zig");
const window_mod = @import("window.zig");

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(window_mod.Window) = .empty,
    free_list: std.ArrayList(u32) = .empty,
    next_z: u32 = 1,
    focused: types.WindowId = types.invalid_window,
    order_revision: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) WindowManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WindowManager) void {
        for (self.windows.items) |*window| {
            if (window.open) self.allocator.free(window.title);
        }
        self.windows.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createWindow(
        self: *WindowManager,
        title: []const u8,
        rect: types.Rect,
        root_node: types.NodeId,
        flags: window_mod.WindowFlags,
    ) !types.WindowId {
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);
        try self.free_list.ensureTotalCapacity(self.allocator, self.windows.items.len + 1);

        const reused_index = self.free_list.pop();
        const index = reused_index orelse blk: {
            const next: u32 = @intCast(self.windows.items.len);
            try self.windows.append(self.allocator, undefined);
            break :blk next;
        };
        const generation: u8 = if (reused_index != null)
            types.nextGeneration(types.windowGeneration(self.windows.items[index].id))
        else
            1;
        const id = types.makeWindowId(index, generation);

        self.windows.items[index] = .{
            .id = id,
            .title = owned_title,
            .rect = rect,
            .root_node = root_node,
            .flags = flags,
            .z_index = self.nextZ(),
        };
        self.focused = id;
        self.order_revision +%= 1;
        return id;
    }

    pub fn closeWindow(self: *WindowManager, id: types.WindowId) void {
        const window = self.get(id) orelse return;
        self.allocator.free(window.title);
        window.title = &.{};
        window.open = false;
        self.free_list.appendAssumeCapacity(types.windowIndex(id));
        if (self.focused == id) self.focused = types.invalid_window;
        self.order_revision +%= 1;
    }

    pub fn setTitle(self: *WindowManager, id: types.WindowId, title: []const u8) !void {
        const window = self.get(id) orelse return error.InvalidWindow;
        if (std.mem.eql(u8, window.title, title)) return;
        const owned_title = try self.allocator.dupe(u8, title);
        self.allocator.free(window.title);
        window.title = owned_title;
    }

    pub fn bringToFront(self: *WindowManager, id: types.WindowId) void {
        const window = self.get(id) orelse return;
        window.z_index = self.nextZ();
        self.focused = id;
        self.order_revision +%= 1;
    }

    pub fn get(self: *WindowManager, id: types.WindowId) ?*window_mod.Window {
        if (id == types.invalid_window) return null;
        const index = types.windowIndex(id);
        if (index >= self.windows.items.len) return null;
        const window = &self.windows.items[index];
        if (!window.open or window.id != id) return null;
        return window;
    }

    pub fn getConst(self: *const WindowManager, id: types.WindowId) ?*const window_mod.Window {
        if (id == types.invalid_window) return null;
        const index = types.windowIndex(id);
        if (index >= self.windows.items.len) return null;
        const window = &self.windows.items[index];
        if (!window.open or window.id != id) return null;
        return window;
    }

    fn nextZ(self: *WindowManager) u32 {
        const z = self.next_z;
        self.next_z +%= 1;
        if (self.next_z == 0) self.next_z = 1;
        return z;
    }
};

test "closed window slots are reused with a fresh generation" {
    var windows = WindowManager.init(std.testing.allocator);
    defer windows.deinit();

    const first = try windows.createWindow("First", .{}, types.invalid_node, .{});
    windows.closeWindow(first);
    const second = try windows.createWindow("Second", .{}, types.invalid_node, .{});

    try std.testing.expectEqual(types.windowIndex(first), types.windowIndex(second));
    try std.testing.expect(first != second);
    try std.testing.expect(windows.get(first) == null);
    try std.testing.expect(windows.get(second) != null);
}

test "window titles can be updated" {
    var windows = WindowManager.init(std.testing.allocator);
    defer windows.deinit();

    const window = try windows.createWindow("Inspector", .{}, types.invalid_node, .{});
    try windows.setTitle(window, "*Inspector");

    try std.testing.expectEqualStrings("*Inspector", windows.getConst(window).?.title);
}
