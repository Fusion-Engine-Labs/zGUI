const std = @import("std");
const types = @import("types.zig");

pub const Hsv = struct {
    /// Hue is normalized to [0, 1); saturation and value are in [0, 1].
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,
};

pub const TriangleWeights = struct {
    hue: f32,
    white: f32,
    black: f32,
};

pub const WheelGeometry = struct {
    center: types.Vec2,
    outer_radius: f32,
    inner_radius: f32,
    hue_point: types.Vec2,
    white_point: types.Vec2,
    black_point: types.Vec2,

    pub fn init(rect: types.Rect, hue: f32) WheelGeometry {
        const diameter = @max(0, @min(rect.w, rect.h));
        const center: types.Vec2 = .{
            .x = rect.x + rect.w * 0.5,
            .y = rect.y + rect.h * 0.5,
        };
        const outer_radius = @max(0, diameter * 0.5 - 1);
        const ring_width = @max(12, diameter * 0.11);
        const inner_radius = @max(0, outer_radius - ring_width);
        const triangle_radius = @max(0, inner_radius - @max(6, diameter * 0.035));
        const angle = normalizeHue(hue) * std.math.tau;
        return .{
            .center = center,
            .outer_radius = outer_radius,
            .inner_radius = inner_radius,
            .hue_point = radialPoint(center, triangle_radius, angle),
            .white_point = radialPoint(center, triangle_radius, angle + @as(f32, std.math.tau / 3.0)),
            .black_point = radialPoint(center, triangle_radius, angle + @as(f32, std.math.tau * 2.0 / 3.0)),
        };
    }

    pub fn isInRing(self: WheelGeometry, point: types.Vec2) bool {
        const distance_squared = lengthSquared(sub(point, self.center));
        return distance_squared >= self.inner_radius * self.inner_radius and
            distance_squared <= self.outer_radius * self.outer_radius;
    }

    pub fn triangleWeights(self: WheelGeometry, point: types.Vec2) ?TriangleWeights {
        return barycentric(point, self.hue_point, self.white_point, self.black_point);
    }

    pub fn containsTriangle(self: WheelGeometry, point: types.Vec2) bool {
        const weights = self.triangleWeights(point) orelse return false;
        const tolerance: f32 = 0.0001;
        return weights.hue >= -tolerance and weights.white >= -tolerance and weights.black >= -tolerance;
    }

    pub fn clampToTriangle(self: WheelGeometry, point: types.Vec2) types.Vec2 {
        if (self.containsTriangle(point)) return point;
        const hue_edge = closestPointOnSegment(point, self.hue_point, self.white_point);
        const white_edge = closestPointOnSegment(point, self.white_point, self.black_point);
        const black_edge = closestPointOnSegment(point, self.black_point, self.hue_point);
        const hue_distance = lengthSquared(sub(point, hue_edge));
        const white_distance = lengthSquared(sub(point, white_edge));
        const black_distance = lengthSquared(sub(point, black_edge));
        if (hue_distance <= white_distance and hue_distance <= black_distance) return hue_edge;
        if (white_distance <= black_distance) return white_edge;
        return black_edge;
    }

    pub fn pointForSv(self: WheelGeometry, saturation: f32, value: f32) types.Vec2 {
        const s = clamp01(saturation);
        const v = clamp01(value);
        return weightedPoint(self.hue_point, self.white_point, self.black_point, .{
            .hue = v * s,
            .white = v * (1 - s),
            .black = 1 - v,
        });
    }
};

pub fn rgbToHsv(rgb: types.Color, fallback_hue: f32) Hsv {
    const r = @as(f32, @floatFromInt(rgb.r)) / 255;
    const g = @as(f32, @floatFromInt(rgb.g)) / 255;
    const b = @as(f32, @floatFromInt(rgb.b)) / 255;
    const maximum = @max(r, @max(g, b));
    const minimum = @min(r, @min(g, b));
    const delta = maximum - minimum;
    var hue = normalizeHue(fallback_hue);

    if (delta > 0) {
        if (maximum == r) {
            hue = (g - b) / delta / 6;
        } else if (maximum == g) {
            hue = ((b - r) / delta + 2) / 6;
        } else {
            hue = ((r - g) / delta + 4) / 6;
        }
        hue = normalizeHue(hue);
    }

    return .{
        .h = hue,
        .s = if (maximum == 0) 0 else delta / maximum,
        .v = maximum,
    };
}

pub fn hsvToRgb(hsv: Hsv, alpha: u8) types.Color {
    const h = normalizeHue(hsv.h) * 6;
    const sector: u8 = @intFromFloat(@floor(h));
    const fraction = h - @floor(h);
    const saturation = clamp01(hsv.s);
    const value = clamp01(hsv.v);
    const p = value * (1 - saturation);
    const q = value * (1 - saturation * fraction);
    const t = value * (1 - saturation * (1 - fraction));
    const rgb = switch (sector % 6) {
        0 => [3]f32{ value, t, p },
        1 => [3]f32{ q, value, p },
        2 => [3]f32{ p, value, t },
        3 => [3]f32{ p, q, value },
        4 => [3]f32{ t, p, value },
        else => [3]f32{ value, p, q },
    };
    return .{
        .r = channelFromUnit(rgb[0]),
        .g = channelFromUnit(rgb[1]),
        .b = channelFromUnit(rgb[2]),
        .a = alpha,
    };
}

pub fn hueAtPoint(center: types.Vec2, point: types.Vec2) f32 {
    var angle = std.math.atan2(point.y - center.y, point.x - center.x);
    if (angle < 0) angle += std.math.tau;
    return normalizeHue(angle / std.math.tau);
}

pub fn hsvFromTriangleWeights(hue: f32, weights: TriangleWeights) Hsv {
    const hue_weight = clamp01(weights.hue);
    const white_weight = clamp01(weights.white);
    const value = clamp01(hue_weight + white_weight);
    return .{
        .h = normalizeHue(hue),
        .s = if (value <= 0) 0 else clamp01(hue_weight / value),
        .v = value,
    };
}

fn barycentric(point: types.Vec2, a: types.Vec2, b: types.Vec2, c: types.Vec2) ?TriangleWeights {
    const v0 = sub(b, a);
    const v1 = sub(c, a);
    const v2 = sub(point, a);
    const denominator = v0.x * v1.y - v1.x * v0.y;
    if (@abs(denominator) <= 0.000001) return null;
    const white = (v2.x * v1.y - v1.x * v2.y) / denominator;
    const black = (v0.x * v2.y - v2.x * v0.y) / denominator;
    return .{ .hue = 1 - white - black, .white = white, .black = black };
}

fn closestPointOnSegment(point: types.Vec2, a: types.Vec2, b: types.Vec2) types.Vec2 {
    const edge = sub(b, a);
    const denominator = lengthSquared(edge);
    if (denominator <= 0.000001) return a;
    const offset = sub(point, a);
    const t = clamp01((offset.x * edge.x + offset.y * edge.y) / denominator);
    return .{ .x = a.x + edge.x * t, .y = a.y + edge.y * t };
}

fn weightedPoint(a: types.Vec2, b: types.Vec2, c: types.Vec2, weights: TriangleWeights) types.Vec2 {
    return .{
        .x = a.x * weights.hue + b.x * weights.white + c.x * weights.black,
        .y = a.y * weights.hue + b.y * weights.white + c.y * weights.black,
    };
}

fn radialPoint(center: types.Vec2, radius: f32, angle: f32) types.Vec2 {
    return .{ .x = center.x + @cos(angle) * radius, .y = center.y + @sin(angle) * radius };
}

fn sub(a: types.Vec2, b: types.Vec2) types.Vec2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn lengthSquared(value: types.Vec2) f32 {
    return value.x * value.x + value.y * value.y;
}

fn normalizeHue(hue: f32) f32 {
    if (!std.math.isFinite(hue)) return 0;
    return hue - @floor(hue);
}

fn channelFromUnit(value: f32) u8 {
    return @intFromFloat(@round(clamp01(value) * 255));
}

fn clamp01(value: f32) f32 {
    return @min(1, @max(0, value));
}

test "RGB and HSV conversions cover primaries and preserve alpha" {
    const cases = [_]types.Color{
        types.Color.rgba(255, 0, 0, 9),
        types.Color.rgba(0, 255, 0, 19),
        types.Color.rgba(0, 0, 255, 29),
        types.Color.rgba(255, 255, 255, 39),
        types.Color.rgba(0, 0, 0, 49),
        types.Color.rgba(37, 129, 211, 59),
    };
    for (cases) |color| {
        try std.testing.expectEqual(color, hsvToRgb(rgbToHsv(color, 0.37), color.a));
    }
}

test "achromatic conversion preserves the supplied hue" {
    const hsv = rgbToHsv(types.Color.rgba(128, 128, 128, 255), 0.625);
    try std.testing.expectApproxEqAbs(@as(f32, 0.625), hsv.h, 0.0001);
    try std.testing.expectEqual(@as(f32, 0), hsv.s);
}

test "triangle weights round trip saturation and value" {
    const geometry = WheelGeometry.init(.{ .w = 224, .h = 224 }, 0.2);
    const point = geometry.pointForSv(0.65, 0.8);
    const hsv = hsvFromTriangleWeights(0.2, geometry.triangleWeights(point).?);
    try std.testing.expectApproxEqAbs(@as(f32, 0.65), hsv.s, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), hsv.v, 0.0001);
}
