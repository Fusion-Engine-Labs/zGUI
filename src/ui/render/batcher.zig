const std = @import("std");
const types = @import("../core/types.zig");
const style_mod = @import("../core/style.zig");
const text_mod = @import("../core/text.zig");
const color_mod = @import("../core/color.zig");
const paint = @import("../core/paint.zig");
const draw_data = @import("draw_data.zig");
const font_atlas_mod = @import("font_atlas.zig");

const default_clip: types.Rect = .{ .x = 0, .y = 0, .w = 100000, .h = 100000 };
const max_corner_segments: usize = 10;
const rounded_point_count: usize = 4 * (max_corner_segments + 1);
const max_antialias_width: f32 = 1;
const color_wheel_segments: usize = 96;
const marker_segments: usize = 24;

const CornerSegments = [4]usize;

const unit_arc_table = blk: {
    var table: [max_corner_segments + 1][4][max_corner_segments + 1]types.Vec2 = @splat(@splat(@splat(.{})));
    const quarter_turn = std.math.pi * 0.5;
    const starts = [_]f32{ -quarter_turn, 0, quarter_turn, std.math.pi };
    var count: usize = 1;
    while (count <= max_corner_segments) : (count += 1) {
        var corner: usize = 0;
        while (corner < 4) : (corner += 1) {
            var segment: usize = 0;
            while (segment <= count) : (segment += 1) {
                const progress = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(count));
                const angle = starts[corner] + quarter_turn * progress;
                table[count][corner][segment] = .{ .x = @cos(angle), .y = @sin(angle) };
            }
        }
    }
    break :blk table;
};

pub const FontAtlas = font_atlas_mod.FontAtlas;

pub const Batcher = struct {
    const PositionedGlyph = struct {
        rect: types.Rect,
        glyph: font_atlas_mod.Glyph,
    };

    const TextRunCache = struct {
        node: types.NodeId = types.invalid_node,
        revision: u32 = 0,
        size: f32 = 0,
        raster_scale: f32 = 0,
        atlas: ?*FontAtlas = null,
        text_hash: u64 = 0,
        glyphs: std.ArrayList(PositionedGlyph) = .empty,

        fn deinit(self: *TextRunCache, allocator: std.mem.Allocator) void {
            self.glyphs.deinit(allocator);
        }
    };

    allocator: std.mem.Allocator,
    vertices: std.ArrayList(draw_data.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    batches: std.ArrayList(draw_data.DrawBatch) = .empty,
    clip_stack: std.ArrayList(types.Rect) = .empty,
    text_runs: std.ArrayList(TextRunCache) = .empty,
    antialias_width: f32 = max_antialias_width,
    solid_texture: types.TextureHandle = .none,
    solid_uv: types.Vec2 = .{},
    shaped_glyph_count: u32 = 0,
    reused_glyph_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Batcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Batcher) void {
        for (self.text_runs.items) |*run| run.deinit(self.allocator);
        self.text_runs.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *Batcher) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
        self.clip_stack.clearRetainingCapacity();
    }

    pub fn build(self: *Batcher, commands: []const paint.PaintCommand, font_atlas: ?*FontAtlas, text_raster_scale: f32) !draw_data.DrawData {
        self.clearRetainingCapacity();
        self.antialias_width = antialiasWidth(text_raster_scale);
        self.shaped_glyph_count = 0;
        self.reused_glyph_count = 0;
        self.solid_texture = .none;
        self.solid_uv = .{};
        if (font_atlas) |atlas| if (atlas.texture.isValid()) {
            self.solid_texture = atlas.texture;
            self.solid_uv = atlas.whiteUv();
        };

        for (commands) |command| {
            switch (command) {
                .rect => |rect| try self.addFilledRect(rect.rect, rect.color, rect.radius),
                .border => |border| try self.addBorder(border),
                .image => |image| try self.addImage(image),
                .color_wheel => |wheel| try self.addColorWheel(wheel),
                .text => |text| {
                    if (font_atlas) |atlas| {
                        try self.addText(text, atlas, text_raster_scale);
                    }
                },
                .clip_push => |clip| try self.clip_stack.append(self.allocator, self.currentClip().intersect(clip)),
                .clip_pop => _ = self.clip_stack.pop(),
            }
        }

        return .{
            .vertices = self.vertices.items,
            .indices = self.indices.items,
            .batches = self.batches.items,
        };
    }

    fn addFilledRect(self: *Batcher, rect: types.Rect, color: types.Color, radius: style_mod.CornerRadii) !void {
        if (rect.isEmpty() or color.a == 0) return;
        if (hasRoundedCorner(rect, radius)) {
            try self.addRoundedTexturedRect(
                rect,
                self.solid_uv,
                self.solid_uv,
                color,
                self.solid_texture,
                radius,
            );
            return;
        }

        try self.addTexturedRect(
            rect,
            self.solid_uv,
            self.solid_uv,
            color,
            self.solid_texture,
        );
    }

    fn addBorder(self: *Batcher, border: paint.BorderPaint) !void {
        const r = border.rect;
        const widths = border.widths;
        if (uniformBorderWidth(widths)) |width| {
            if (width > 0 and hasRoundedCorner(r, border.radius)) {
                try self.addRoundedBorder(border, width);
                return;
            }
        }

        if (widths.top > 0) {
            try self.addFilledRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = widths.top }, border.color, .{});
        }
        if (widths.bottom > 0) {
            try self.addFilledRect(.{ .x = r.x, .y = r.y + r.h - widths.bottom, .w = r.w, .h = widths.bottom }, border.color, .{});
        }

        const side_y = r.y + widths.top;
        const side_h = @max(0, r.h - widths.top - widths.bottom);
        if (widths.left > 0) {
            try self.addFilledRect(.{ .x = r.x, .y = side_y, .w = widths.left, .h = side_h }, border.color, .{});
        }
        if (widths.right > 0) {
            try self.addFilledRect(.{ .x = r.x + r.w - widths.right, .y = side_y, .w = widths.right, .h = side_h }, border.color, .{});
        }
    }

    fn addRoundedBorder(self: *Batcher, border: paint.BorderPaint, width: f32) !void {
        const outer = border.rect;
        if (outer.isEmpty() or border.color.a == 0) return;

        const border_width = @min(width, @min(outer.w, outer.h) * 0.5);
        const inner: types.Rect = .{
            .x = outer.x + border_width,
            .y = outer.y + border_width,
            .w = @max(0, outer.w - border_width * 2),
            .h = @max(0, outer.h - border_width * 2),
        };

        if (inner.isEmpty()) {
            try self.addRoundedTexturedRect(
                outer,
                self.solid_uv,
                self.solid_uv,
                border.color,
                self.solid_texture,
                border.radius,
            );
            return;
        }

        const segments = cornerSegmentCounts(outer, border.radius);
        var outer_points: [rounded_point_count]types.Vec2 = undefined;
        var inner_points: [rounded_point_count]types.Vec2 = undefined;
        const outer_count = roundedRectPoints(outer, border.radius, segments, &outer_points);
        const inner_count = roundedRectPoints(inner, insetRadii(border.radius, border_width), segments, &inner_points);
        if (outer_count < 3 or inner_count != outer_count) return;

        // The band between the two rings is exactly a textured ring whose uv is
        // constant, since uv0 and uv1 are both the atlas's solid texel.
        try self.addTexturedRing(
            outer,
            self.solid_uv,
            self.solid_uv,
            self.solid_texture,
            outer_points[0..outer_count],
            inner_points[0..inner_count],
            border.color,
            border.color,
        );

        try self.addFringe(
            outer,
            self.solid_uv,
            self.solid_uv,
            self.solid_texture,
            border.radius,
            segments,
            outer_points[0..outer_count],
            border.color,
        );
    }

    fn addText(self: *Batcher, text: paint.TextPaint, atlas: *FontAtlas, text_raster_scale: f32) !void {
        if (text.color.a == 0 or text.size <= 0) return;

        const raster_scale = font_atlas_mod.sanitizeRasterScale(text_raster_scale);
        const run = try self.textRun(text, atlas, raster_scale);
        if (run.glyphs.items.len == 0) return;
        try self.ensureBatch(atlas.texture, self.currentClip());
        // `text.pos` is the top of the line box; the baseline sits one ascent
        // below it, and the atlas is the only thing that knows the ascent.
        const baseline = atlas.baselineOffset(text.size);
        for (run.glyphs.items) |positioned| {
            try self.addGlyphQuadToCurrentBatch(.{
                .x = text.pos.x + positioned.rect.x,
                .y = text.pos.y + baseline + positioned.rect.y,
                .w = positioned.rect.w,
                .h = positioned.rect.h,
            }, positioned.glyph, text.color);
        }
    }

    fn textRun(self: *Batcher, text: paint.TextPaint, atlas: *FontAtlas, raster_scale: f32) !*TextRunCache {
        const index = types.nodeIndex(text.source_node);
        const text_hash = if (text.source_node == 0) std.hash.Wyhash.hash(0, text.text) else 0;
        if (index >= self.text_runs.items.len) {
            const old_len = self.text_runs.items.len;
            try self.text_runs.resize(self.allocator, index + 1);
            @memset(self.text_runs.items[old_len..], .{});
        }
        const run = &self.text_runs.items[index];
        if (run.node == text.source_node and run.revision == text.text_revision and
            run.size == text.size and run.raster_scale == raster_scale and run.atlas == atlas and
            run.text_hash == text_hash)
        {
            self.reused_glyph_count += @intCast(run.glyphs.items.len);
            return run;
        }

        run.node = text.source_node;
        run.revision = text.text_revision;
        run.size = text.size;
        run.raster_scale = raster_scale;
        run.atlas = atlas;
        run.text_hash = text_hash;
        run.glyphs.clearRetainingCapacity();
        try self.shapeTextRun(run, text, atlas, raster_scale);
        self.shaped_glyph_count += @intCast(run.glyphs.items.len);
        return run;
    }

    fn shapeTextRun(self: *Batcher, run: *TextRunCache, text: paint.TextPaint, atlas: *FontAtlas, raster_scale: f32) !void {
        var x: f32 = 0;
        var baseline_y: f32 = 0;
        var previous: ?u21 = null;
        const line_height = atlas.lineHeightScaled(text.size, raster_scale);
        const space_advance = atlas.spaceAdvanceScaled(text.size, raster_scale);
        var it = text_mod.Utf8Iterator.init(text.text);

        while (it.next()) |codepoint| {
            switch (codepoint) {
                '\n' => {
                    x = 0;
                    baseline_y += line_height;
                    previous = null;
                },
                '\t' => {
                    x += space_advance * 4;
                    previous = null;
                },
                ' ' => {
                    x += space_advance;
                    previous = null;
                },
                else => {
                    const glyph = try atlas.getGlyphScaled(codepoint, text.size, raster_scale);
                    if (previous) |left| x += atlas.kerningScaled(left, glyph.codepoint, text.size, raster_scale);

                    if (glyph.size.x > 0 and glyph.size.y > 0) {
                        try run.glyphs.append(self.allocator, .{ .rect = .{
                            .x = snapToRasterPixel(x + glyph.offset.x, raster_scale),
                            .y = snapToRasterPixel(baseline_y + glyph.offset.y, raster_scale),
                            .w = glyph.size.x,
                            .h = glyph.size.y,
                        }, .glyph = glyph });
                    }

                    x += glyph.advance;
                    previous = glyph.codepoint;
                },
            }
        }
    }

    fn addImage(self: *Batcher, image: paint.ImagePaint) !void {
        if (!image.texture.isValid() or image.tint.a == 0) return;
        if (hasRoundedCorner(image.rect, image.radius)) {
            try self.addRoundedTexturedRect(image.rect, image.uv0, image.uv1, image.tint, image.texture, image.radius);
            return;
        }
        try self.addTexturedRect(image.rect, image.uv0, image.uv1, image.tint, image.texture);
    }

    fn addColorWheel(self: *Batcher, wheel: paint.ColorWheelPaint) !void {
        if (wheel.rect.isEmpty()) return;
        const geometry = color_mod.WheelGeometry.init(wheel.rect, wheel.hue);
        if (geometry.outer_radius <= 0 or geometry.inner_radius <= 0) return;
        try self.ensureBatch(self.solid_texture, self.currentClip());

        var segment: usize = 0;
        while (segment < color_wheel_segments) : (segment += 1) {
            const hue0 = @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(color_wheel_segments));
            const hue1 = @as(f32, @floatFromInt(segment + 1)) / @as(f32, @floatFromInt(color_wheel_segments));
            const angle0 = hue0 * std.math.tau;
            const angle1 = hue1 * std.math.tau;
            const color0 = color_mod.hsvToRgb(.{ .h = hue0, .s = 1, .v = 1 }, 255);
            const color1 = color_mod.hsvToRgb(.{ .h = hue1, .s = 1, .v = 1 }, 255);
            const outer0 = circlePoint(geometry.center, geometry.outer_radius, angle0);
            const outer1 = circlePoint(geometry.center, geometry.outer_radius, angle1);
            const inner0 = circlePoint(geometry.center, geometry.inner_radius, angle0);
            const inner1 = circlePoint(geometry.center, geometry.inner_radius, angle1);
            try self.addColoredQuadToCurrentBatch(inner0, outer0, outer1, inner1, color0, color0, color1, color1);

            if (self.antialias_width > 0) {
                const fringe_outer0 = circlePoint(geometry.center, geometry.outer_radius + self.antialias_width, angle0);
                const fringe_outer1 = circlePoint(geometry.center, geometry.outer_radius + self.antialias_width, angle1);
                try self.addColoredQuadToCurrentBatch(
                    outer0,
                    fringe_outer0,
                    fringe_outer1,
                    outer1,
                    color0,
                    withAlpha(color0, 0),
                    withAlpha(color1, 0),
                    color1,
                );

                const fringe_inner0 = circlePoint(geometry.center, @max(0, geometry.inner_radius - self.antialias_width), angle0);
                const fringe_inner1 = circlePoint(geometry.center, @max(0, geometry.inner_radius - self.antialias_width), angle1);
                try self.addColoredQuadToCurrentBatch(
                    fringe_inner0,
                    inner0,
                    inner1,
                    fringe_inner1,
                    withAlpha(color0, 0),
                    color0,
                    color1,
                    withAlpha(color1, 0),
                );
            }
        }

        const hue_color = color_mod.hsvToRgb(.{ .h = wheel.hue, .s = 1, .v = 1 }, 255);
        const white = types.Color.rgba(255, 255, 255, 255);
        const black = types.Color.rgba(0, 0, 0, 255);
        try self.addColoredTriangleToCurrentBatch(
            geometry.hue_point,
            geometry.white_point,
            geometry.black_point,
            hue_color,
            white,
            black,
        );
        try self.addTriangleFringe(
            geometry.hue_point,
            geometry.white_point,
            geometry.black_point,
            hue_color,
            white,
            black,
        );

        const marker_dark = types.Color.rgba(12, 12, 15, 230);
        const marker_light = types.Color.rgba(255, 255, 255, 245);
        const hue_angle = wheel.hue * std.math.tau;
        const hue_marker = circlePoint(geometry.center, (geometry.inner_radius + geometry.outer_radius) * 0.5, hue_angle);
        const selected = color_mod.hsvToRgb(.{ .h = wheel.hue, .s = wheel.saturation, .v = wheel.value }, 255);
        const sv_marker = geometry.pointForSv(wheel.saturation, wheel.value);
        try self.addMarker(hue_marker, hue_color, marker_dark, marker_light);
        try self.addMarker(sv_marker, selected, marker_dark, marker_light);
    }

    fn addTriangleFringe(
        self: *Batcher,
        a: types.Vec2,
        b: types.Vec2,
        c: types.Vec2,
        color_a: types.Color,
        color_b: types.Color,
        color_c: types.Color,
    ) !void {
        if (self.antialias_width <= 0) return;
        const center: types.Vec2 = .{ .x = (a.x + b.x + c.x) / 3, .y = (a.y + b.y + c.y) / 3 };
        const outer_a = outsetPoint(a, center, self.antialias_width);
        const outer_b = outsetPoint(b, center, self.antialias_width);
        const outer_c = outsetPoint(c, center, self.antialias_width);
        try self.addColoredQuadToCurrentBatch(a, outer_a, outer_b, b, color_a, withAlpha(color_a, 0), withAlpha(color_b, 0), color_b);
        try self.addColoredQuadToCurrentBatch(b, outer_b, outer_c, c, color_b, withAlpha(color_b, 0), withAlpha(color_c, 0), color_c);
        try self.addColoredQuadToCurrentBatch(c, outer_c, outer_a, a, color_c, withAlpha(color_c, 0), withAlpha(color_a, 0), color_a);
    }

    fn addMarker(self: *Batcher, center: types.Vec2, selected: types.Color, dark: types.Color, light: types.Color) !void {
        try self.addColoredCircleToCurrentBatch(center, 7, dark);
        try self.addColoredCircleToCurrentBatch(center, 5, light);
        try self.addColoredCircleToCurrentBatch(center, 3, selected);
    }

    fn addColoredCircleToCurrentBatch(self: *Batcher, center: types.Vec2, radius: f32, color: types.Color) !void {
        const base: u32 = @intCast(self.vertices.items.len);
        try self.vertices.ensureUnusedCapacity(self.allocator, marker_segments + 1);
        self.vertices.appendAssumeCapacity(.{ .pos = .{ center.x, center.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color.toU32() });
        for (0..marker_segments) |index| {
            const angle = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(marker_segments)) * std.math.tau;
            const point = circlePoint(center, radius, angle);
            self.vertices.appendAssumeCapacity(.{ .pos = .{ point.x, point.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color.toU32() });
        }
        try self.indices.ensureUnusedCapacity(self.allocator, marker_segments * 3);
        for (0..marker_segments) |index| {
            const current = base + 1 + @as(u32, @intCast(index));
            const next = base + 1 + @as(u32, @intCast((index + 1) % marker_segments));
            self.indices.appendSliceAssumeCapacity(&.{ base, current, next });
        }
        self.batches.items[self.batches.items.len - 1].index_count += marker_segments * 3;
    }

    fn addColoredTriangleToCurrentBatch(
        self: *Batcher,
        a: types.Vec2,
        b: types.Vec2,
        c: types.Vec2,
        color_a: types.Color,
        color_b: types.Color,
        color_c: types.Color,
    ) !void {
        const base: u32 = @intCast(self.vertices.items.len);
        try self.vertices.ensureUnusedCapacity(self.allocator, 3);
        self.vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = .{ a.x, a.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_a.toU32() },
            .{ .pos = .{ b.x, b.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_b.toU32() },
            .{ .pos = .{ c.x, c.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_c.toU32() },
        });
        try self.indices.appendSlice(self.allocator, &.{ base, base + 1, base + 2 });
        self.batches.items[self.batches.items.len - 1].index_count += 3;
    }

    fn addColoredQuadToCurrentBatch(
        self: *Batcher,
        a: types.Vec2,
        b: types.Vec2,
        c: types.Vec2,
        d: types.Vec2,
        color_a: types.Color,
        color_b: types.Color,
        color_c: types.Color,
        color_d: types.Color,
    ) !void {
        const base: u32 = @intCast(self.vertices.items.len);
        try self.vertices.ensureUnusedCapacity(self.allocator, 4);
        self.vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = .{ a.x, a.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_a.toU32() },
            .{ .pos = .{ b.x, b.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_b.toU32() },
            .{ .pos = .{ c.x, c.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_c.toU32() },
            .{ .pos = .{ d.x, d.y }, .uv = .{ self.solid_uv.x, self.solid_uv.y }, .color = color_d.toU32() },
        });
        try self.indices.appendSlice(self.allocator, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
        self.batches.items[self.batches.items.len - 1].index_count += 6;
    }

    fn addGlyphQuadToCurrentBatch(self: *Batcher, rect: types.Rect, glyph: font_atlas_mod.Glyph, color: types.Color) !void {
        try self.addTexturedRectToCurrentBatch(
            rect,
            .{ .x = glyph.uv0.x, .y = glyph.uv0.y },
            .{ .x = glyph.uv1.x, .y = glyph.uv1.y },
            color,
        );
    }

    fn addTexturedRect(
        self: *Batcher,
        rect: types.Rect,
        uv0: types.Vec2,
        uv1: types.Vec2,
        color: types.Color,
        texture: types.TextureHandle,
    ) !void {
        if (rect.isEmpty() or color.a == 0) return;
        try self.ensureBatch(texture, self.currentClip());
        try self.addTexturedRectToCurrentBatch(rect, uv0, uv1, color);
    }

    /// Appends geometry after its texture and clip have been selected by the
    /// caller. Text uses this for every glyph in one command.
    fn addTexturedRectToCurrentBatch(
        self: *Batcher,
        rect: types.Rect,
        uv0: types.Vec2,
        uv1: types.Vec2,
        color: types.Color,
    ) !void {
        if (rect.isEmpty() or color.a == 0) return;

        const packed_color = color.toU32();
        const right = rect.x + rect.w;
        const bottom = rect.y + rect.h;
        const base: u32 = @intCast(self.vertices.items.len);
        try self.vertices.ensureUnusedCapacity(self.allocator, 4);
        self.vertices.appendSliceAssumeCapacity(&.{
            .{ .pos = .{ rect.x, rect.y }, .uv = .{ uv0.x, uv0.y }, .color = packed_color },
            .{ .pos = .{ right, rect.y }, .uv = .{ uv1.x, uv0.y }, .color = packed_color },
            .{ .pos = .{ right, bottom }, .uv = .{ uv1.x, uv1.y }, .color = packed_color },
            .{ .pos = .{ rect.x, bottom }, .uv = .{ uv0.x, uv1.y }, .color = packed_color },
        });

        try self.indices.ensureUnusedCapacity(self.allocator, 6);
        self.indices.appendSliceAssumeCapacity(&.{
            base, base + 1, base + 2,
            base, base + 2, base + 3,
        });
        self.batches.items[self.batches.items.len - 1].index_count += 6;
    }

    fn addRoundedTexturedRect(
        self: *Batcher,
        rect: types.Rect,
        uv0: types.Vec2,
        uv1: types.Vec2,
        color: types.Color,
        texture: types.TextureHandle,
        radius: style_mod.CornerRadii,
    ) !void {
        if (rect.isEmpty() or color.a == 0) return;
        if (!hasRoundedCorner(rect, radius)) {
            try self.addTexturedRect(rect, uv0, uv1, color, texture);
            return;
        }

        const segments = cornerSegmentCounts(rect, radius);
        var points: [rounded_point_count]types.Vec2 = undefined;
        const count = roundedRectPoints(rect, radius, segments, &points);
        if (count < 3) return;

        try self.ensureBatch(texture, self.currentClip());
        const color_u32 = color.toU32();
        const base: u32 = @intCast(self.vertices.items.len);
        const center: types.Vec2 = .{ .x = rect.x + rect.w * 0.5, .y = rect.y + rect.h * 0.5 };
        const center_uv = uvForPoint(rect, uv0, uv1, center);
        try self.vertices.ensureUnusedCapacity(self.allocator, count + 1);
        self.vertices.appendAssumeCapacity(.{
            .pos = .{ center.x, center.y },
            .uv = .{ center_uv.x, center_uv.y },
            .color = color_u32,
        });

        for (points[0..count]) |point| {
            const uv = uvForPoint(rect, uv0, uv1, point);
            self.vertices.appendAssumeCapacity(.{
                .pos = .{ point.x, point.y },
                .uv = .{ uv.x, uv.y },
                .color = color_u32,
            });
        }

        try self.indices.ensureUnusedCapacity(self.allocator, count * 3);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const current = base + 1 + @as(u32, @intCast(i));
            const next = base + 1 + @as(u32, @intCast((i + 1) % count));
            self.indices.appendSliceAssumeCapacity(&.{ base, current, next });
        }
        self.batches.items[self.batches.items.len - 1].index_count += @intCast(count * 3);

        try self.addFringe(rect, uv0, uv1, texture, radius, segments, points[0..count], color);
    }

    /// Fades the shape's edge out over one antialias width. Both the filled and
    /// the bordered path need it, and it must use the same segment counts as the
    /// shape it wraps or the two rings will not correspond.
    fn addFringe(
        self: *Batcher,
        rect: types.Rect,
        uv0: types.Vec2,
        uv1: types.Vec2,
        texture: types.TextureHandle,
        radius: style_mod.CornerRadii,
        segments: CornerSegments,
        inner_points: []const types.Vec2,
        color: types.Color,
    ) !void {
        if (self.antialias_width <= 0) return;
        var fringe_points: [rounded_point_count]types.Vec2 = undefined;
        const fringe_rect = rect.outset(self.antialias_width);
        const fringe_count = roundedRectPoints(fringe_rect, outsetRadii(radius, self.antialias_width), segments, &fringe_points);
        if (fringe_count != inner_points.len) return;
        try self.addTexturedRing(rect, uv0, uv1, texture, inner_points, fringe_points[0..fringe_count], color, withAlpha(color, 0));
    }

    fn addTexturedRing(
        self: *Batcher,
        uv_rect: types.Rect,
        uv0: types.Vec2,
        uv1: types.Vec2,
        texture: types.TextureHandle,
        inner_points: []const types.Vec2,
        outer_points: []const types.Vec2,
        inner_color: types.Color,
        outer_color: types.Color,
    ) !void {
        if (inner_points.len < 3 or inner_points.len != outer_points.len) return;

        try self.ensureBatch(texture, self.currentClip());
        const inner_u32 = inner_color.toU32();
        const outer_u32 = outer_color.toU32();
        const base: u32 = @intCast(self.vertices.items.len);
        try self.vertices.ensureUnusedCapacity(self.allocator, inner_points.len + outer_points.len);
        for (inner_points) |point| {
            const uv = uvForPoint(uv_rect, uv0, uv1, point);
            self.vertices.appendAssumeCapacity(.{
                .pos = .{ point.x, point.y },
                .uv = .{ uv.x, uv.y },
                .color = inner_u32,
            });
        }
        for (outer_points) |point| {
            const uv = uvForPoint(uv_rect, uv0, uv1, point);
            self.vertices.appendAssumeCapacity(.{
                .pos = .{ point.x, point.y },
                .uv = .{ uv.x, uv.y },
                .color = outer_u32,
            });
        }

        try self.indices.ensureUnusedCapacity(self.allocator, inner_points.len * 6);
        var i: usize = 0;
        while (i < inner_points.len) : (i += 1) {
            const next = (i + 1) % inner_points.len;
            const inner_current = base + @as(u32, @intCast(i));
            const inner_next = base + @as(u32, @intCast(next));
            const outer_current = base + @as(u32, @intCast(inner_points.len + i));
            const outer_next = base + @as(u32, @intCast(inner_points.len + next));
            self.indices.appendSliceAssumeCapacity(&.{
                inner_current, inner_next, outer_next,
                inner_current, outer_next, outer_current,
            });
        }
        self.batches.items[self.batches.items.len - 1].index_count += @intCast(inner_points.len * 6);
    }

    fn ensureBatch(self: *Batcher, texture: types.TextureHandle, clip: types.Rect) !void {
        if (self.batches.items.len > 0) {
            const last = &self.batches.items[self.batches.items.len - 1];
            if (last.texture == texture and rectEqual(last.clip_rect, clip)) return;
        }

        try self.batches.append(self.allocator, .{
            .texture = texture,
            .clip_rect = clip,
            .index_offset = @intCast(self.indices.items.len),
            .index_count = 0,
        });
    }

    fn currentClip(self: *const Batcher) types.Rect {
        if (self.clip_stack.items.len == 0) return default_clip;
        return self.clip_stack.items[self.clip_stack.items.len - 1];
    }
};

fn rectEqual(a: types.Rect, b: types.Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

fn circlePoint(center: types.Vec2, radius: f32, angle: f32) types.Vec2 {
    return .{ .x = center.x + @cos(angle) * radius, .y = center.y + @sin(angle) * radius };
}

fn outsetPoint(point: types.Vec2, center: types.Vec2, amount: f32) types.Vec2 {
    const dx = point.x - center.x;
    const dy = point.y - center.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length <= 0.0001) return point;
    const scale = (length + amount) / length;
    return .{ .x = center.x + dx * scale, .y = center.y + dy * scale };
}

fn uniformBorderWidth(widths: style_mod.Edges) ?f32 {
    if (widths.top != widths.right or widths.top != widths.bottom or widths.top != widths.left) return null;
    return widths.top;
}

fn clampedRadiusValue(rect: types.Rect, radius: f32) f32 {
    if (!std.math.isFinite(radius) or radius <= 0) return 0;
    return @min(radius, @min(rect.w, rect.h) * 0.5);
}

fn clampedRadii(rect: types.Rect, radius: style_mod.CornerRadii) style_mod.CornerRadii {
    return .{
        .top_left = clampedRadiusValue(rect, radius.top_left),
        .top_right = clampedRadiusValue(rect, radius.top_right),
        .bottom_right = clampedRadiusValue(rect, radius.bottom_right),
        .bottom_left = clampedRadiusValue(rect, radius.bottom_left),
    };
}

/// Equivalent to testing `clampedRadii` for a positive corner, without paying
/// for the four clamps: clamping only ever shrinks a radius toward zero, and it
/// zeroes every corner of a degenerate rect.
fn hasRoundedCorner(rect: types.Rect, radius: style_mod.CornerRadii) bool {
    if (rect.isEmpty()) return false;
    return isPositiveRadius(radius.top_left) or
        isPositiveRadius(radius.top_right) or
        isPositiveRadius(radius.bottom_right) or
        isPositiveRadius(radius.bottom_left);
}

fn isPositiveRadius(radius: f32) bool {
    return radius > 0 and std.math.isFinite(radius);
}

fn insetRadii(radius: style_mod.CornerRadii, amount: f32) style_mod.CornerRadii {
    return .{
        .top_left = @max(0, radius.top_left - amount),
        .top_right = @max(0, radius.top_right - amount),
        .bottom_right = @max(0, radius.bottom_right - amount),
        .bottom_left = @max(0, radius.bottom_left - amount),
    };
}

fn outsetRadii(radius: style_mod.CornerRadii, amount: f32) style_mod.CornerRadii {
    return .{
        .top_left = radius.top_left + amount,
        .top_right = radius.top_right + amount,
        .bottom_right = radius.bottom_right + amount,
        .bottom_left = radius.bottom_left + amount,
    };
}

fn antialiasWidth(raster_scale: f32) f32 {
    const scale = font_atlas_mod.sanitizeRasterScale(raster_scale);
    return @min(max_antialias_width, 1 / scale);
}

fn withAlpha(color: types.Color, alpha_factor: f32) types.Color {
    const alpha = clamp01(alpha_factor);
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = @intFromFloat(@round(@as(f32, @floatFromInt(color.a)) * alpha)),
    };
}

/// Segment counts per corner, scaled with the clamped radius so small
/// radii cost few vertices. Computed once per shape and shared by the
/// fill, inner-border, and antialias-fringe outlines so their point
/// counts always match.
fn cornerSegmentCounts(rect: types.Rect, radius: style_mod.CornerRadii) CornerSegments {
    const r = clampedRadii(rect, radius);
    return .{
        segmentsForRadius(r.top_right),
        segmentsForRadius(r.bottom_right),
        segmentsForRadius(r.bottom_left),
        segmentsForRadius(r.top_left),
    };
}

fn segmentsForRadius(radius: f32) usize {
    if (radius <= 0) return 1;
    const segments: usize = @intFromFloat(@ceil(radius * 0.4));
    return @min(max_corner_segments, @max(2, segments));
}

fn roundedRectPoints(rect: types.Rect, radius: style_mod.CornerRadii, segments: CornerSegments, points: *[rounded_point_count]types.Vec2) usize {
    const r = clampedRadii(rect, radius);
    const centers = [_]types.Vec2{
        .{ .x = rect.x + rect.w - r.top_right, .y = rect.y + r.top_right },
        .{ .x = rect.x + rect.w - r.bottom_right, .y = rect.y + rect.h - r.bottom_right },
        .{ .x = rect.x + r.bottom_left, .y = rect.y + rect.h - r.bottom_left },
        .{ .x = rect.x + r.top_left, .y = rect.y + r.top_left },
    };
    const radii = [_]f32{ r.top_right, r.bottom_right, r.bottom_left, r.top_left };

    var count: usize = 0;
    var corner: usize = 0;
    while (corner < centers.len) : (corner += 1) {
        const corner_radius = radii[corner];
        const corner_segments = segments[corner];
        var segment: usize = 0;
        while (segment <= corner_segments) : (segment += 1) {
            const unit = unit_arc_table[corner_segments][corner][segment];
            points[count] = .{
                .x = centers[corner].x + unit.x * corner_radius,
                .y = centers[corner].y + unit.y * corner_radius,
            };
            count += 1;
        }
    }
    return count;
}

fn uvForPoint(rect: types.Rect, uv0: types.Vec2, uv1: types.Vec2, point: types.Vec2) types.Vec2 {
    const tx = clamp01((point.x - rect.x) / rect.w);
    const ty = clamp01((point.y - rect.y) / rect.h);
    return .{
        .x = uv0.x + (uv1.x - uv0.x) * tx,
        .y = uv0.y + (uv1.y - uv0.y) * ty,
    };
}

fn clamp01(v: f32) f32 {
    return @min(1, @max(0, v));
}

fn snapToRasterPixel(value: f32, raster_scale: f32) f32 {
    return @round(value * raster_scale) / raster_scale;
}

fn loadTestFont(allocator: std.mem.Allocator) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/fonts/Inter-Regular.ttf", allocator, .limited(4 * 1024 * 1024));
}

test "rounded rect vertex count scales with radius" {
    var small = Batcher.init(std.testing.allocator);
    defer small.deinit();
    var large = Batcher.init(std.testing.allocator);
    defer large.deinit();

    const rect: types.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const color = types.Color.rgba(255, 255, 255, 255);
    const small_data = try small.build(&.{
        .{ .rect = .{ .rect = rect, .color = color, .radius = style_mod.CornerRadii.all(4) } },
    }, null, 1);
    const large_data = try large.build(&.{
        .{ .rect = .{ .rect = rect, .color = color, .radius = style_mod.CornerRadii.all(40) } },
    }, null, 1);

    try std.testing.expect(small_data.vertices.len > 0);
    try std.testing.expect(small_data.vertices.len < large_data.vertices.len);
}

test "rounded border renders when inner radii clamp to zero" {
    var batcher = Batcher.init(std.testing.allocator);
    defer batcher.deinit();

    const data = try batcher.build(&.{
        .{ .border = .{
            .rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 },
            .color = types.Color.rgba(255, 255, 255, 255),
            .widths = style_mod.Edges.all(5),
            .radius = style_mod.CornerRadii.all(2),
        } },
    }, null, 1);

    try std.testing.expect(data.vertices.len > 0);
    try std.testing.expect(data.indices.len > 0);
}

test "batch index ranges tile the index buffer exactly" {
    var batcher = Batcher.init(std.testing.allocator);
    defer batcher.deinit();

    const color = types.Color.rgba(200, 120, 60, 255);
    const data = try batcher.build(&.{
        .{ .rect = .{ .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 }, .color = color } },
        .{ .clip_push = .{ .x = 0, .y = 0, .w = 40, .h = 40 } },
        .{ .rect = .{ .rect = .{ .x = 4, .y = 4, .w = 30, .h = 30 }, .color = color, .radius = style_mod.CornerRadii.all(8) } },
        .{ .border = .{
            .rect = .{ .x = 2, .y = 2, .w = 36, .h = 24 },
            .color = color,
            .widths = style_mod.Edges.all(2),
            .radius = style_mod.CornerRadii.all(6),
        } },
        .clip_pop,
        .{ .border = .{
            .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
            .color = color,
            .widths = .{ .top = 1, .bottom = 3, .left = 2, .right = 4 },
        } },
    }, null, 1);

    try std.testing.expect(data.indices.len > 0);

    // Batches must partition the index buffer with no gap and no overlap.
    var expected_offset: u32 = 0;
    for (data.batches) |batch| {
        try std.testing.expectEqual(expected_offset, batch.index_offset);
        expected_offset += batch.index_count;
    }
    try std.testing.expectEqual(data.indices.len, @as(usize, expected_offset));

    for (data.indices) |index| try std.testing.expect(index < data.vertices.len);
}

test "text commands emit atlas glyph quads" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();
    atlas.texture = .fromParts(41, 0);

    var batcher = Batcher.init(std.testing.allocator);
    defer batcher.deinit();

    const commands = [_]paint.PaintCommand{
        .{ .text = .{
            .pos = .{ .x = 10, .y = 20 },
            .text = "A B",
            .size = 16,
            .color = types.Color.rgba(255, 255, 255, 255),
        } },
    };

    const data = try batcher.build(&commands, &atlas, 1);
    try std.testing.expectEqual(@as(usize, 8), data.vertices.len);
    try std.testing.expectEqual(@as(usize, 12), data.indices.len);
    try std.testing.expectEqual(@as(usize, 1), data.batches.len);
    try std.testing.expectEqual(types.TextureHandle.fromParts(41, 0), data.batches[0].texture);
    try std.testing.expect(data.vertices[0].uv[0] > 0);
    try std.testing.expectEqual(@as(u32, 2), batcher.shaped_glyph_count);

    const cached = try batcher.build(&commands, &atlas, 1);
    try std.testing.expectEqual(@as(usize, 8), cached.vertices.len);
    try std.testing.expectEqual(@as(u32, 0), batcher.shaped_glyph_count);
    try std.testing.expectEqual(@as(u32, 2), batcher.reused_glyph_count);
}

test "solid and text commands share the font atlas batch" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();
    atlas.texture = .fromParts(7, 0);
    var batcher = Batcher.init(std.testing.allocator);
    defer batcher.deinit();

    const data = try batcher.build(&.{
        .{ .rect = .{ .rect = .{ .w = 100, .h = 30 }, .color = types.Color.rgba(10, 20, 30, 255) } },
        .{ .text = .{ .pos = .{ .y = 16 }, .text = "Label", .size = 16, .color = types.Color.rgba(255, 255, 255, 255) } },
    }, &atlas, 1);
    try std.testing.expectEqual(@as(usize, 1), data.batches.len);
    try std.testing.expectEqual(atlas.texture, data.batches[0].texture);
    try std.testing.expectEqual(atlas.whiteUv().x, data.vertices[0].uv[0]);
}

test "color wheel emits one solid batch with interpolated hue geometry" {
    var batcher = Batcher.init(std.testing.allocator);
    defer batcher.deinit();

    const data = try batcher.build(&.{.{ .color_wheel = .{
        .rect = .{ .x = 10, .y = 20, .w = 224, .h = 224 },
        .hue = 0.6,
        .saturation = 0.7,
        .value = 0.8,
    } }}, null, 1);

    try std.testing.expectEqual(@as(usize, 1), data.batches.len);
    try std.testing.expect(data.vertices.len > color_wheel_segments * 4);
    try std.testing.expect(data.indices.len > color_wheel_segments * 6);
    for (data.indices) |index| try std.testing.expect(index < data.vertices.len);

    var found_red = false;
    var found_green = false;
    var found_blue = false;
    for (data.vertices) |vertex| {
        found_red = found_red or vertex.color == types.Color.rgba(255, 0, 0, 255).toU32();
        found_green = found_green or vertex.color == types.Color.rgba(0, 255, 0, 255).toU32();
        found_blue = found_blue or vertex.color == types.Color.rgba(0, 0, 255, 255).toU32();
    }
    try std.testing.expect(found_red and found_green and found_blue);
}
