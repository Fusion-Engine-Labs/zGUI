const std = @import("std");
const types = @import("../core/types.zig");
const text_mod = @import("../core/text.zig");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub const GlyphKey = struct {
    codepoint: u21,
    px_size: u16,
};

const KernKey = struct {
    left: u21,
    right: u21,
    px_size: u16,
};

pub const DirtyRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Glyph = struct {
    codepoint: u21,
    px_size: u16,
    advance: f32,
    offset: types.Vec2 = .{},
    size: types.Vec2 = .{},
    uv0: types.Vec2 = .{},
    uv1: types.Vec2 = .{},
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    atlas_w: u32 = 0,
    atlas_h: u32 = 0,
};

pub const TextAdvance = struct {
    codepoint: u21,
    advance: f32,
};

pub const FontAtlas = struct {
    allocator: std.mem.Allocator,
    font_bytes: []u8,
    font_info: c.stbtt_fontinfo,
    pixels: []u8,
    width: u32,
    height: u32,
    texture: types.TextureHandle = .none,
    glyphs: std.AutoHashMap(GlyphKey, Glyph),
    advances: std.AutoHashMap(GlyphKey, f32),
    kern_pairs: std.AutoHashMap(KernKey, f32),
    renderable: std.AutoHashMap(u21, u21),
    coverage_scratch: std.ArrayList(u8) = .empty,
    ascent: c_int = 0,
    descent: c_int = 0,
    line_gap: c_int = 0,
    shelf_x: u32 = 1,
    shelf_y: u32 = 1,
    shelf_height: u32 = 0,
    /// Region of `pixels` a backend has yet to upload; null once it is in sync.
    /// This is the whole of the atlas's upload state — a separate dirty flag
    /// would only ever restate `dirty_rect != null`.
    dirty_rect: ?DirtyRect = null,
    warned_full: bool = false,

    pub fn init(allocator: std.mem.Allocator, font_bytes: []const u8, atlas_width: u32, atlas_height: u32) !FontAtlas {
        if (atlas_width == 0 or atlas_height == 0) return error.InvalidAtlasSize;

        const owned_font = try allocator.dupe(u8, font_bytes);
        errdefer allocator.free(owned_font);

        var info: c.stbtt_fontinfo = undefined;
        const offset = c.stbtt_GetFontOffsetForIndex(owned_font.ptr, 0);
        if (offset < 0) return error.InvalidFont;
        if (c.stbtt_InitFont(&info, owned_font.ptr, offset) == 0) return error.InvalidFont;

        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);

        const pixel_count = try std.math.mul(usize, @intCast(atlas_width), @intCast(atlas_height));
        const byte_count = try std.math.mul(usize, pixel_count, 4);
        const pixels = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(pixels);
        clearPixels(pixels);
        // Texel zero is permanently reserved as an opaque-white sample. Solid
        // UI geometry can therefore share this texture with text and avoid a
        // texture switch between a control background and its label.
        pixels[3] = 255;

        return .{
            .allocator = allocator,
            .font_bytes = owned_font,
            .font_info = info,
            .pixels = pixels,
            .width = atlas_width,
            .height = atlas_height,
            .glyphs = std.AutoHashMap(GlyphKey, Glyph).init(allocator),
            .advances = std.AutoHashMap(GlyphKey, f32).init(allocator),
            .kern_pairs = std.AutoHashMap(KernKey, f32).init(allocator),
            .renderable = std.AutoHashMap(u21, u21).init(allocator),
            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,
            .dirty_rect = .{ .x = 0, .y = 0, .w = atlas_width, .h = atlas_height },
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        self.coverage_scratch.deinit(self.allocator);
        self.renderable.deinit();
        self.kern_pairs.deinit();
        self.advances.deinit();
        self.glyphs.deinit();
        self.allocator.free(self.pixels);
        self.allocator.free(self.font_bytes);
        self.* = undefined;
    }

    pub fn measure(self: *FontAtlas, bytes: []const u8, size: f32) text_mod.TextMetrics {
        const line_height = self.lineHeight(size);
        var current_width: f32 = 0;
        var max_width: f32 = 0;
        var line_count: u32 = 1;
        var previous: ?u21 = null;

        var it = text_mod.Utf8Iterator.init(bytes);
        while (it.next()) |raw_codepoint| {
            switch (raw_codepoint) {
                '\n' => {
                    max_width = @max(max_width, current_width);
                    current_width = 0;
                    line_count += 1;
                    previous = null;
                },
                '\t' => {
                    current_width += self.spaceAdvance(size) * 4;
                    previous = null;
                },
                else => {
                    const codepoint = self.renderableCodepoint(raw_codepoint);
                    if (previous) |left| current_width += self.kerning(left, codepoint, size);
                    current_width += self.cachedAdvance(codepoint, size);
                    previous = codepoint;
                },
            }
        }

        max_width = @max(max_width, current_width);
        return .{
            .size = .{
                .x = max_width,
                .y = line_height * @as(f32, @floatFromInt(line_count)),
            },
            .line_height = line_height,
        };
    }

    pub fn getGlyph(self: *FontAtlas, codepoint: u21, size: f32) !Glyph {
        return self.getGlyphForPixelSize(codepoint, quantizeSize(size));
    }

    pub fn getGlyphScaled(self: *FontAtlas, codepoint: u21, size: f32, raster_scale: f32) !Glyph {
        const safe_scale = sanitizeRasterScale(raster_scale);
        var glyph = try self.getGlyphForPixelSize(codepoint, quantizeSize(size * safe_scale));
        scaleGlyphToLogical(&glyph, safe_scale);
        return glyph;
    }

    pub fn lineHeightScaled(self: *const FontAtlas, size: f32, raster_scale: f32) f32 {
        const safe_scale = sanitizeRasterScale(raster_scale);
        return self.lineHeight(@floatFromInt(quantizeSize(size * safe_scale))) / safe_scale;
    }

    pub fn spaceAdvanceScaled(self: *FontAtlas, size: f32, raster_scale: f32) f32 {
        const safe_scale = sanitizeRasterScale(raster_scale);
        return self.spaceAdvance(@floatFromInt(quantizeSize(size * safe_scale))) / safe_scale;
    }

    pub fn kerningScaled(self: *FontAtlas, left: u21, right: u21, size: f32, raster_scale: f32) f32 {
        const safe_scale = sanitizeRasterScale(raster_scale);
        return self.kerning(left, right, @floatFromInt(quantizeSize(size * safe_scale))) / safe_scale;
    }

    fn getGlyphForPixelSize(self: *FontAtlas, codepoint: u21, px_size: u16) !Glyph {
        const resolved = self.renderableCodepoint(codepoint);
        const key: GlyphKey = .{ .codepoint = resolved, .px_size = px_size };
        if (self.glyphs.get(key)) |glyph| return glyph;

        const glyph = self.createGlyph(key) catch |err| switch (err) {
            error.AtlasFull => {
                if (!self.warned_full) {
                    self.warned_full = true;
                    std.log.warn("font atlas is full ({d}x{d}); further new glyphs render as '?'", .{ self.width, self.height });
                }
                if (resolved != '?') return self.getGlyphForPixelSize('?', px_size);
                return emptyGlyph(key, self.advanceForCodepoint('?', @floatFromInt(px_size)));
            },
            else => return err,
        };
        try self.glyphs.put(key, glyph);
        return glyph;
    }

    pub fn glyphCount(self: *const FontAtlas) usize {
        return self.glyphs.count();
    }

    /// Rasterizes a known working set up front so first interaction does not
    /// pay allocator, stb_truetype, and texture-upload costs glyph by glyph.
    pub fn prewarmGlyphs(self: *FontAtlas, codepoints: []const u21, logical_sizes: []const f32, raster_scale: f32) !void {
        const entry_count = std.math.mul(usize, codepoints.len, logical_sizes.len) catch return error.TooManyGlyphs;
        try self.glyphs.ensureTotalCapacity(@intCast(@min(entry_count + self.glyphs.count(), std.math.maxInt(u32))));
        try self.advances.ensureTotalCapacity(@intCast(@min(entry_count + self.advances.count(), std.math.maxInt(u32))));
        try self.renderable.ensureTotalCapacity(@intCast(@min(codepoints.len + self.renderable.count(), std.math.maxInt(u32))));
        for (logical_sizes) |size| {
            for (codepoints) |codepoint| _ = try self.getGlyphScaled(codepoint, size, raster_scale);
        }
    }

    pub fn prewarmAscii(self: *FontAtlas, logical_sizes: []const f32, raster_scale: f32) !void {
        var codepoints: [95]u21 = undefined;
        for (&codepoints, 0..) |*codepoint, index| codepoint.* = @intCast(0x20 + index);
        try self.prewarmGlyphs(&codepoints, logical_sizes, raster_scale);
    }

    pub fn lineHeight(self: *const FontAtlas, size: f32) f32 {
        const scale = self.scaleForSize(size);
        const height = @as(f32, @floatFromInt(self.ascent - self.descent + self.line_gap)) * scale;
        return if (height > 0) height else size * 1.25;
    }

    pub fn whiteUv(self: *const FontAtlas) types.Vec2 {
        return .{
            .x = 0.5 / @as(f32, @floatFromInt(self.width)),
            .y = 0.5 / @as(f32, @floatFromInt(self.height)),
        };
    }

    /// Distance from the top of a line box to the baseline at `size`. Renderer
    /// backends add this to a `TextPaint.pos` to place a run's baseline.
    pub fn baselineOffset(self: *const FontAtlas, size: f32) f32 {
        return @as(f32, @floatFromInt(self.ascent)) * self.scaleForSize(size);
    }

    pub fn spaceAdvance(self: *FontAtlas, size: f32) f32 {
        return self.cachedAdvance(' ', size);
    }

    pub fn kerning(self: *FontAtlas, left: u21, right: u21, size: f32) f32 {
        const key: KernKey = .{ .left = left, .right = right, .px_size = quantizeSize(size) };
        if (self.kern_pairs.get(key)) |kern| return kern;
        const scale = self.scaleForSize(size);
        const kern = c.stbtt_GetCodepointKernAdvance(&self.font_info, @intCast(left), @intCast(right));
        const scaled = @as(f32, @floatFromInt(kern)) * scale;
        self.kern_pairs.put(key, scaled) catch {};
        return scaled;
    }

    /// Returns the resolved codepoint and horizontal advance used by text
    /// layout, including kerning from `previous` when present.
    pub fn textAdvance(self: *FontAtlas, previous: ?u21, raw_codepoint: u21, size: f32) TextAdvance {
        const codepoint = self.renderableCodepoint(raw_codepoint);
        const kern = if (previous) |left| self.kerning(left, codepoint, size) else 0;
        return .{ .codepoint = codepoint, .advance = kern + self.cachedAdvance(codepoint, size) };
    }

    fn cachedAdvance(self: *FontAtlas, codepoint: u21, size: f32) f32 {
        const key: GlyphKey = .{ .codepoint = codepoint, .px_size = quantizeSize(size) };
        if (self.advances.get(key)) |advance| return advance;
        const advance = self.advanceForCodepoint(codepoint, size);
        self.advances.put(key, advance) catch {};
        return advance;
    }

    pub fn markClean(self: *FontAtlas) void {
        self.dirty_rect = null;
    }

    fn createGlyph(self: *FontAtlas, key: GlyphKey) !Glyph {
        const size = @as(f32, @floatFromInt(key.px_size));
        const scale = self.scaleForSize(size);
        const advance = self.advanceForCodepoint(key.codepoint, size);

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.stbtt_GetCodepointBitmapBox(&self.font_info, @intCast(key.codepoint), scale, scale, &x0, &y0, &x1, &y1);

        const bitmap_w_i = @max(0, x1 - x0);
        const bitmap_h_i = @max(0, y1 - y0);
        if (bitmap_w_i == 0 or bitmap_h_i == 0) {
            return emptyGlyph(key, advance);
        }

        const bitmap_w: u32 = @intCast(bitmap_w_i);
        const bitmap_h: u32 = @intCast(bitmap_h_i);
        const padding: u32 = 1;
        const allocation = self.allocate(bitmap_w + padding * 2, bitmap_h + padding * 2) orelse return error.AtlasFull;

        const coverage_len = @as(usize, bitmap_w) * @as(usize, bitmap_h);
        try self.coverage_scratch.resize(self.allocator, coverage_len);
        const coverage = self.coverage_scratch.items;
        c.stbtt_MakeCodepointBitmap(
            &self.font_info,
            coverage.ptr,
            @intCast(bitmap_w),
            @intCast(bitmap_h),
            @intCast(bitmap_w),
            scale,
            scale,
            @intCast(key.codepoint),
        );

        const dst_x = allocation.x + padding;
        const dst_y = allocation.y + padding;
        // Every atlas texel holds RGB 255 from init (see clearPixels) and
        // nothing ever changes it, so the blit only writes the alpha channel.
        var row: u32 = 0;
        while (row < bitmap_h) : (row += 1) {
            const src_row = coverage[@as(usize, row) * @as(usize, bitmap_w) ..][0..bitmap_w];
            const dst_row = (@as(usize, dst_y + row) * @as(usize, self.width) + @as(usize, dst_x)) * 4;
            for (src_row, 0..) |value, col| {
                self.pixels[dst_row + col * 4 + 3] = value;
            }
        }

        self.markDirty(allocation);

        return .{
            .codepoint = key.codepoint,
            .px_size = key.px_size,
            .advance = advance,
            .offset = .{
                .x = @floatFromInt(x0),
                .y = @floatFromInt(y0),
            },
            .size = .{
                .x = @floatFromInt(bitmap_w),
                .y = @floatFromInt(bitmap_h),
            },
            .uv0 = .{
                .x = @as(f32, @floatFromInt(dst_x)) / @as(f32, @floatFromInt(self.width)),
                .y = @as(f32, @floatFromInt(dst_y)) / @as(f32, @floatFromInt(self.height)),
            },
            .uv1 = .{
                .x = @as(f32, @floatFromInt(dst_x + bitmap_w)) / @as(f32, @floatFromInt(self.width)),
                .y = @as(f32, @floatFromInt(dst_y + bitmap_h)) / @as(f32, @floatFromInt(self.height)),
            },
            .atlas_x = dst_x,
            .atlas_y = dst_y,
            .atlas_w = bitmap_w,
            .atlas_h = bitmap_h,
        };
    }

    fn allocate(self: *FontAtlas, w: u32, h: u32) ?DirtyRect {
        if (w > self.width or h > self.height) return null;
        if (self.shelf_x + w > self.width) {
            self.shelf_x = 1;
            self.shelf_y += self.shelf_height;
            self.shelf_height = 0;
        }
        if (self.shelf_y + h > self.height) return null;

        const rect: DirtyRect = .{ .x = self.shelf_x, .y = self.shelf_y, .w = w, .h = h };
        self.shelf_x += w;
        self.shelf_height = @max(self.shelf_height, h);
        return rect;
    }

    fn markDirty(self: *FontAtlas, rect: DirtyRect) void {
        if (self.dirty_rect) |existing| {
            const min_x = @min(existing.x, rect.x);
            const min_y = @min(existing.y, rect.y);
            const max_x = @max(existing.x + existing.w, rect.x + rect.w);
            const max_y = @max(existing.y + existing.h, rect.y + rect.h);
            self.dirty_rect = .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
        } else {
            self.dirty_rect = rect;
        }
    }

    fn advanceForCodepoint(self: *const FontAtlas, codepoint: u21, size: f32) f32 {
        const scale = self.scaleForSize(size);
        var advance_width: c_int = 0;
        var left_side_bearing: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&self.font_info, @intCast(codepoint), &advance_width, &left_side_bearing);
        return @as(f32, @floatFromInt(advance_width)) * scale;
    }

    /// Resolves a codepoint to the one actually rendered, substituting '?' when
    /// the font has no glyph. stbtt_FindGlyphIndex searches the font's cmap, and
    /// this runs for every character of every measure and raster pass, so the
    /// answer is memoized alongside the advance and kerning caches.
    fn renderableCodepoint(self: *FontAtlas, codepoint: u21) u21 {
        if (codepoint == '\n' or codepoint == '\t') return codepoint;
        if (self.renderable.get(codepoint)) |resolved| return resolved;
        const resolved: u21 = if (c.stbtt_FindGlyphIndex(&self.font_info, @intCast(codepoint)) != 0)
            codepoint
        else
            '?';
        self.renderable.put(codepoint, resolved) catch {};
        return resolved;
    }

    fn scaleForSize(self: *const FontAtlas, size: f32) f32 {
        // Same computation as stbtt_ScaleForPixelHeight, using the vmetrics
        // cached at init.
        const px_size = quantizeSize(size);
        const extent = self.ascent - self.descent;
        if (extent <= 0) return 0;
        return @as(f32, @floatFromInt(px_size)) / @as(f32, @floatFromInt(extent));
    }
};

fn clearPixels(pixels: []u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i + 0] = 255;
        pixels[i + 1] = 255;
        pixels[i + 2] = 255;
        pixels[i + 3] = 0;
    }
}

fn emptyGlyph(key: GlyphKey, advance: f32) Glyph {
    return .{
        .codepoint = key.codepoint,
        .px_size = key.px_size,
        .advance = advance,
    };
}

fn scaleGlyphToLogical(glyph: *Glyph, raster_scale: f32) void {
    const inv_scale = 1.0 / raster_scale;
    glyph.advance *= inv_scale;
    glyph.offset.x *= inv_scale;
    glyph.offset.y *= inv_scale;
    glyph.size.x *= inv_scale;
    glyph.size.y *= inv_scale;
}

fn quantizeSize(size: f32) u16 {
    const clamped = @min(@as(f32, @floatFromInt(std.math.maxInt(u16))), @max(1, size));
    return @intFromFloat(@round(clamped));
}

pub fn sanitizeRasterScale(raster_scale: f32) f32 {
    if (!std.math.isFinite(raster_scale)) return 1;
    return @max(0.25, raster_scale);
}

fn loadTestFont(allocator: std.mem.Allocator) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/fonts/Inter-Regular.ttf", allocator, .limited(4 * 1024 * 1024));
}

test "font atlas measures ascii whitespace newlines and non-ascii" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    const ascii = atlas.measure("abc", 16);
    const spaced = atlas.measure("a a", 16);
    const tabbed = atlas.measure("a\tb", 16);
    const multiline = atlas.measure("abc\nde", 16);
    const non_ascii = atlas.measure("\xc3\xa9", 16);

    try std.testing.expect(ascii.size.x > 0);
    try std.testing.expect(spaced.size.x > atlas.measure("aa", 16).size.x);
    try std.testing.expect(tabbed.size.x > spaced.size.x);
    try std.testing.expect(multiline.size.y > ascii.size.y);
    try std.testing.expect(non_ascii.size.x > 0);
}

test "font atlas reuses cached glyphs" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    _ = try atlas.getGlyph('A', 16);
    const count = atlas.glyphCount();
    _ = try atlas.getGlyph('A', 16);
    try std.testing.expectEqual(count, atlas.glyphCount());
}

test "font atlas scaled glyphs use larger physical pixels with logical metrics" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    const regular = try atlas.getGlyph('A', 16);
    const scaled = try atlas.getGlyphScaled('A', 16, 2);

    try std.testing.expectEqual(@as(u16, 32), scaled.px_size);
    try std.testing.expect(scaled.atlas_w > regular.atlas_w);
    try std.testing.expect(std.math.approxEqAbs(f32, regular.size.x, scaled.size.x, 3));
}

test "font atlas packs glyphs without overlap" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    const a = try atlas.getGlyph('A', 24);
    const b = try atlas.getGlyph('B', 24);
    const separated = a.atlas_x + a.atlas_w <= b.atlas_x or
        b.atlas_x + b.atlas_w <= a.atlas_x or
        a.atlas_y + a.atlas_h <= b.atlas_y or
        b.atlas_y + b.atlas_h <= a.atlas_y;
    try std.testing.expect(separated);
}

test "rasterized glyphs keep atlas rgb at opaque white" {
    // The glyph blit writes only the alpha channel and relies on this invariant.
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    const glyph = try atlas.getGlyph('W', 32);
    try std.testing.expect(glyph.atlas_w > 0 and glyph.atlas_h > 0);

    var any_coverage = false;
    var row: u32 = 0;
    while (row < glyph.atlas_h) : (row += 1) {
        var col: u32 = 0;
        while (col < glyph.atlas_w) : (col += 1) {
            const i = ((@as(usize, glyph.atlas_y + row) * @as(usize, atlas.width)) +
                @as(usize, glyph.atlas_x + col)) * 4;
            try std.testing.expectEqual(@as(u8, 255), atlas.pixels[i + 0]);
            try std.testing.expectEqual(@as(u8, 255), atlas.pixels[i + 1]);
            try std.testing.expectEqual(@as(u8, 255), atlas.pixels[i + 2]);
            if (atlas.pixels[i + 3] != 0) any_coverage = true;
        }
    }
    try std.testing.expect(any_coverage);
}

test "font atlas falls back to question mark for missing glyphs" {
    const font_bytes = try loadTestFont(std.testing.allocator);
    defer std.testing.allocator.free(font_bytes);

    var atlas = try FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    const glyph = try atlas.getGlyph(0x10ffff, 16);
    try std.testing.expectEqual(@as(u21, '?'), glyph.codepoint);
}
