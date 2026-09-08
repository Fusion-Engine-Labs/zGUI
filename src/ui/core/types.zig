const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Edges = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, p: Vec2) bool {
        return p.x >= self.x and p.x <= self.x + self.w and
            p.y >= self.y and p.y <= self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn inset(self: Rect, edges: Edges) Rect {
        return .{
            .x = self.x + edges.left,
            .y = self.y + edges.top,
            .w = @max(0, self.w - edges.left - edges.right),
            .h = @max(0, self.h - edges.top - edges.bottom),
        };
    }

    /// Grow the rect by `amount` on every side. Culling and antialiasing both
    /// need to test against a rect slightly larger than the drawn one.
    pub fn outset(self: Rect, amount: f32) Rect {
        return .{
            .x = self.x - amount,
            .y = self.y - amount,
            .w = self.w + amount * 2,
            .h = self.h + amount * 2,
        };
    }

    /// The overlap of two rects, empty when they do not touch. Clip stacks and
    /// paint culling must agree on this exactly, so it lives here rather than
    /// being restated per layer.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return !self.isEmpty() and !other.isEmpty() and
            self.x < other.x + other.w and self.x + self.w > other.x and
            self.y < other.y + other.h and self.y + self.h > other.y;
    }
};

pub const Color = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn toU32(self: Color) u32 {
        return (@as(u32, self.a) << 24) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.g) << 8) |
            @as(u32, self.r);
    }
};

/// NodeId packs a slot index in the low bits and a generation counter in the
/// high bits, so a stale id held after destroyNode never resolves to a node
/// that later reused the same slot.
pub const NodeId = u32;
/// WindowId uses the same slot-plus-generation representation as NodeId.
/// Closing and reopening a window slot never makes an old handle valid again.
pub const WindowId = u32;
/// DockNodeId uses the same slot-plus-generation encoding as NodeId. A handle
/// to a collapsed dock node cannot resolve after its storage slot is reused.
pub const DockNodeId = u32;

/// Renderer texture handle. The handle is intentionally opaque to widgets and
/// draw-data consumers; renderer backends are responsible for translating it
/// to their native texture representation.
pub const TextureHandle = enum(u32) {
    none = 0,
    _,

    const index_bits = 24;
    const index_mask: u32 = (1 << index_bits) - 1;

    pub fn fromParts(index_value: u32, generation_value: u8) TextureHandle {
        std.debug.assert(index_value < index_mask);
        return @enumFromInt((@as(u32, generation_value) << index_bits) | (index_value + 1));
    }

    pub fn index(self: TextureHandle) ?u32 {
        const encoded_index = @intFromEnum(self) & index_mask;
        if (encoded_index == 0) return null;
        return encoded_index - 1;
    }

    pub fn generation(self: TextureHandle) u8 {
        return @intCast(@intFromEnum(self) >> index_bits);
    }

    pub fn isValid(self: TextureHandle) bool {
        return self != .none;
    }
};

pub const node_index_bits = 24;
pub const node_index_mask: u32 = (1 << node_index_bits) - 1;
pub const max_node_index: u32 = node_index_mask - 1;

pub fn makeNodeId(index: u32, generation: u8) NodeId {
    return (@as(u32, generation) << node_index_bits) | index;
}

pub fn nodeIndex(id: NodeId) u32 {
    return id & node_index_mask;
}

pub fn nodeGeneration(id: NodeId) u8 {
    return @intCast(id >> node_index_bits);
}

// WindowId and DockNodeId share NodeId's slot-plus-generation encoding, so they
// share its accessors rather than restating the shift convention three times.
pub const makeWindowId = makeNodeId;
pub const windowIndex = nodeIndex;
pub const windowGeneration = nodeGeneration;

pub const makeDockNodeId = makeNodeId;
pub const dockNodeIndex = nodeIndex;
pub const dockNodeGeneration = nodeGeneration;

/// A recycled slot always advances to a fresh generation, wrapping to 1 rather
/// than 0 so a stale handle can never resolve against the slot that replaced it.
pub fn nextGeneration(current: u8) u8 {
    return if (current == std.math.maxInt(u8)) 1 else current + 1;
}

pub const invalid_node: NodeId = std.math.maxInt(NodeId);
pub const invalid_window: WindowId = std.math.maxInt(WindowId);
pub const invalid_dock_node: DockNodeId = std.math.maxInt(DockNodeId);

test "rect hit testing includes edges" {
    const rect: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(rect.contains(.{ .x = 10, .y = 20 }));
    try std.testing.expect(rect.contains(.{ .x = 40, .y = 60 }));
    try std.testing.expect(!rect.contains(.{ .x = 41, .y = 60 }));
    try std.testing.expect(!rect.contains(.{ .x = 40, .y = 61 }));
}

test "texture handles reject a reused slot generation" {
    const first = TextureHandle.fromParts(7, 2);
    const reused = TextureHandle.fromParts(7, 3);

    try std.testing.expect(first != reused);
    try std.testing.expectEqual(@as(?u32, 7), first.index());
    try std.testing.expectEqual(@as(u8, 2), first.generation());
    try std.testing.expect(TextureHandle.none.index() == null);
}
