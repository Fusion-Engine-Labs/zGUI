const std = @import("std");
const types = @import("../core/types.zig");
const draw_data = @import("draw_data.zig");
const font_atlas_mod = @import("font_atlas.zig");

const c = @cImport({
    @cInclude("glad/glad.h");
});

pub const ProcAddressFn = *const fn (name: [*:0]const u8) ?*const anyopaque;

var active_proc_address_fn: ?ProcAddressFn = null;

pub const OpenGlRenderer = struct {
    const TextureSlot = struct {
        native: c.GLuint = 0,
        generation: u8 = 0,
        owned: bool = false,
        alive: bool = false,
    };

    allocator: std.mem.Allocator,
    textures: std.ArrayList(TextureSlot) = .empty,
    free_textures: std.ArrayList(u32) = .empty,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
    ibo: c.GLuint = 0,
    program: c.GLuint = 0,
    white_texture: c.GLuint = 0,
    projection_location: c.GLint = -1,
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    logical_width: f32 = 0,
    logical_height: f32 = 0,
    uploaded_generation: ?u32 = null,
    vertex_buffer_capacity: usize = 0,
    index_buffer_capacity: usize = 0,

    pub fn init(allocator: std.mem.Allocator, proc_address_fn: ProcAddressFn) !OpenGlRenderer {
        try loadGlad(proc_address_fn);
        c.glEnable(c.GL_MULTISAMPLE);

        var self: OpenGlRenderer = .{ .allocator = allocator };
        errdefer self.deinit();
        self.program = try createProgram();
        self.projection_location = c.glGetUniformLocation(self.program, "u_projection");
        const texture_location = c.glGetUniformLocation(self.program, "u_texture");
        c.glUseProgram(self.program);
        c.glUniform1i(texture_location, 0);
        c.glUseProgram(0);

        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glGenBuffers(1, &self.ibo);

        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, self.ibo);

        const stride: c.GLsizei = @intCast(@sizeOf(draw_data.Vertex));
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(draw_data.Vertex, "pos")));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(@offsetOf(draw_data.Vertex, "uv")));
        c.glEnableVertexAttribArray(2);
        c.glVertexAttribPointer(2, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, stride, @ptrFromInt(@offsetOf(draw_data.Vertex, "color")));

        selectTextureUnit();
        c.glGenTextures(1, &self.white_texture);
        c.glBindTexture(c.GL_TEXTURE_2D, self.white_texture);
        const white = [_]u8{ 255, 255, 255, 255 };
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &white);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);

        return self;
    }

    pub fn deinit(self: *OpenGlRenderer) void {
        for (self.textures.items) |*slot| {
            if (slot.alive and slot.owned and slot.native != 0) {
                c.glDeleteTextures(1, &slot.native);
            }
        }
        self.free_textures.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        if (self.white_texture != 0) c.glDeleteTextures(1, &self.white_texture);
        if (self.ibo != 0) c.glDeleteBuffers(1, &self.ibo);
        if (self.vbo != 0) c.glDeleteBuffers(1, &self.vbo);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        if (self.program != 0) c.glDeleteProgram(self.program);
        self.* = undefined;
    }

    pub fn beginFrame(self: *OpenGlRenderer, width: u32, height: u32) !void {
        try self.beginFrameLogical(width, height, @floatFromInt(width), @floatFromInt(height));
    }

    pub fn beginFrameLogical(self: *OpenGlRenderer, framebuffer_width: u32, framebuffer_height: u32, logical_width: f32, logical_height: f32) !void {
        self.framebuffer_width = framebuffer_width;
        self.framebuffer_height = framebuffer_height;
        self.logical_width = @max(1, logical_width);
        self.logical_height = @max(1, logical_height);
        c.glViewport(0, 0, @intCast(framebuffer_width), @intCast(framebuffer_height));
        c.glClearColor(0.055, 0.06, 0.075, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    }

    pub fn render(self: *OpenGlRenderer, data: draw_data.DrawData) !void {
        if (data.vertices.len == 0 or data.indices.len == 0) return;

        selectTextureUnit();
        c.glUseProgram(self.program);
        c.glBindVertexArray(self.vao);
        c.glEnable(c.GL_BLEND);
        c.glBlendEquation(c.GL_FUNC_ADD);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glEnable(c.GL_MULTISAMPLE);
        c.glDisable(c.GL_DEPTH_TEST);
        c.glDisable(c.GL_CULL_FACE);
        c.glEnable(c.GL_SCISSOR_TEST);

        const projection = ortho(0, self.logical_width, self.logical_height, 0);
        c.glUniformMatrix4fv(self.projection_location, 1, c.GL_FALSE, &projection);

        // Geometry is retained between frames; skip the upload when the UI
        // produced the same draw data generation as the last upload.
        if (self.uploaded_generation == null or self.uploaded_generation.? != data.generation) {
            uploadVertexBuffer(self.vbo, data.vertices, &self.vertex_buffer_capacity);
            uploadIndexBuffer(self.ibo, data.indices, &self.index_buffer_capacity);
            self.uploaded_generation = data.generation;
        }

        // Batches split on either a texture or a clip change, so consecutive
        // batches routinely share one of the two; only push what actually moved.
        var bound_texture: ?c.GLuint = null;
        var bound_scissor: ?Scissor = null;
        for (data.batches) |batch| {
            if (batch.index_count == 0) continue;
            const native_texture = if (batch.texture == .none)
                self.white_texture
            else
                self.resolveTexture(batch.texture) orelse continue;
            const scissor = scissorRect(batch.clip_rect, self.logical_width, self.logical_height, self.framebuffer_width, self.framebuffer_height);
            if (scissor.w == 0 or scissor.h == 0) continue;
            if (bound_scissor == null or !std.meta.eql(bound_scissor.?, scissor)) {
                c.glScissor(scissor.x, scissor.y, scissor.w, scissor.h);
                bound_scissor = scissor;
            }
            if (bound_texture != native_texture) {
                c.glBindTexture(c.GL_TEXTURE_2D, native_texture);
                bound_texture = native_texture;
            }
            c.glDrawElements(
                c.GL_TRIANGLES,
                @intCast(batch.index_count),
                c.GL_UNSIGNED_INT,
                @ptrFromInt(@as(usize, batch.index_offset) * @sizeOf(u32)),
            );
        }

        c.glDisable(c.GL_SCISSOR_TEST);
        c.glBindVertexArray(0);
        c.glUseProgram(0);
    }

    pub fn createTextureRgba(self: *OpenGlRenderer, width: u32, height: u32, pixels: []const u8) !types.TextureHandle {
        try validateTexturePixels(width, height, pixels);

        var texture: c.GLuint = 0;
        c.glGenTextures(1, &texture);
        if (texture == 0) return error.OpenGlTextureCreateFailed;

        selectTextureUnit();
        c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @intCast(width),
            @intCast(height),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pixels.ptr,
        );
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
        return self.registerTexture(texture, true) catch |err| {
            c.glDeleteTextures(1, &texture);
            return err;
        };
    }

    /// Registers a texture whose OpenGL lifetime remains owned by the caller.
    pub fn registerExternalTexture(self: *OpenGlRenderer, native: u32) !types.TextureHandle {
        if (native == 0) return error.InvalidTexture;
        return self.registerTexture(native, false);
    }

    /// Releases a registered texture and clears the caller's handle. Textures
    /// created by this renderer are deleted; external textures are only unregistered.
    pub fn destroyTexture(self: *OpenGlRenderer, texture: *types.TextureHandle) void {
        if (texture.* == .none) return;
        defer texture.* = .none;
        const index = texture.*.index() orelse return;
        if (index >= self.textures.items.len) return;
        const slot = &self.textures.items[index];
        if (!slot.alive or slot.generation != texture.*.generation()) return;

        if (slot.owned and slot.native != 0) c.glDeleteTextures(1, &slot.native);
        slot.native = 0;
        slot.owned = false;
        slot.alive = false;
        slot.generation +%= 1;
        self.free_textures.append(self.allocator, index) catch {};
    }

    pub fn uploadTextureRgba(self: *OpenGlRenderer, texture: types.TextureHandle, width: u32, height: u32, pixels: []const u8) !void {
        const native = self.resolveTexture(texture) orelse return error.InvalidTexture;
        try validateTexturePixels(width, height, pixels);

        selectTextureUnit();
        c.glBindTexture(c.GL_TEXTURE_2D, native);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            @intCast(width),
            @intCast(height),
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pixels.ptr,
        );
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    pub fn syncFontAtlas(self: *OpenGlRenderer, font_atlas: *font_atlas_mod.FontAtlas) !void {
        if (!font_atlas.texture.isValid()) {
            font_atlas.texture = try self.createTextureRgba(font_atlas.width, font_atlas.height, font_atlas.pixels);
            font_atlas.markClean();
            return;
        }

        if (font_atlas.dirty_rect) |rect| {
            try self.uploadTextureSubRgba(font_atlas.texture, font_atlas.width, rect, font_atlas.pixels);
            font_atlas.markClean();
        }
    }

    pub fn endFrame(self: *OpenGlRenderer) !void {
        _ = self;
    }

    fn uploadTextureSubRgba(self: *OpenGlRenderer, texture: types.TextureHandle, atlas_width: u32, rect: font_atlas_mod.DirtyRect, pixels: []const u8) !void {
        if (rect.w == 0 or rect.h == 0) return;
        const native = self.resolveTexture(texture) orelse return error.InvalidTexture;
        const row_end = try std.math.mul(usize, @as(usize, rect.y) + rect.h, atlas_width);
        if (row_end * 4 > pixels.len) return error.InvalidTextureData;

        const offset = (@as(usize, rect.y) * @as(usize, atlas_width) + @as(usize, rect.x)) * 4;
        selectTextureUnit();
        c.glBindTexture(c.GL_TEXTURE_2D, native);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @intCast(atlas_width));
        c.glTexSubImage2D(
            c.GL_TEXTURE_2D,
            0,
            @intCast(rect.x),
            @intCast(rect.y),
            @intCast(rect.w),
            @intCast(rect.h),
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            pixels.ptr + offset,
        );
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    fn registerTexture(self: *OpenGlRenderer, native: c.GLuint, owned: bool) !types.TextureHandle {
        if (self.free_textures.pop()) |index| {
            const slot = &self.textures.items[index];
            slot.native = native;
            slot.owned = owned;
            slot.alive = true;
            return .fromParts(index, slot.generation);
        }

        if (self.textures.items.len >= (1 << 24) - 1) return error.TooManyTextures;
        const index: u32 = @intCast(self.textures.items.len);
        try self.textures.append(self.allocator, .{
            .native = native,
            .owned = owned,
            .alive = true,
        });
        return .fromParts(index, 0);
    }

    fn resolveTexture(self: *const OpenGlRenderer, texture: types.TextureHandle) ?c.GLuint {
        const index = texture.index() orelse return null;
        if (index >= self.textures.items.len) return null;
        const slot = self.textures.items[index];
        if (!slot.alive or slot.generation != texture.generation()) return null;
        return slot.native;
    }

    pub fn versionString() []const u8 {
        const ptr = c.glGetString(c.GL_VERSION) orelse return "unknown";
        return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    }
};

fn uploadVertexBuffer(buffer: c.GLuint, data: []const draw_data.Vertex, capacity: *usize) void {
    const byte_len = data.len * @sizeOf(draw_data.Vertex);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, buffer);
    if (byte_len > capacity.*) {
        capacity.* = nextBufferCapacity(byte_len);
    }
    // Orphan storage before writing so a changed frame never waits for the GPU
    // to finish consuming the previous frame's buffer contents.
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(capacity.*), null, c.GL_STREAM_DRAW);
    c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(byte_len), data.ptr);
}

fn uploadIndexBuffer(buffer: c.GLuint, data: []const u32, capacity: *usize) void {
    const byte_len = data.len * @sizeOf(u32);
    c.glBindBuffer(c.GL_ELEMENT_ARRAY_BUFFER, buffer);
    if (byte_len > capacity.*) {
        capacity.* = nextBufferCapacity(byte_len);
    }
    c.glBufferData(c.GL_ELEMENT_ARRAY_BUFFER, @intCast(capacity.*), null, c.GL_STREAM_DRAW);
    c.glBufferSubData(c.GL_ELEMENT_ARRAY_BUFFER, 0, @intCast(byte_len), data.ptr);
}

fn nextBufferCapacity(required: usize) usize {
    if (required <= 4096) {
        return 4096;
    }
    return std.math.ceilPowerOfTwo(usize, required) catch required;
}

test "GPU buffer capacity grows geometrically" {
    try std.testing.expectEqual(@as(usize, 4096), nextBufferCapacity(1));
    try std.testing.expectEqual(@as(usize, 8192), nextBufferCapacity(4097));
    try std.testing.expectEqual(@as(usize, 16384), nextBufferCapacity(9000));
}

fn selectTextureUnit() void {
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindSampler(0, 0);
}

pub fn loadGlad(proc_address_fn: ProcAddressFn) !void {
    active_proc_address_fn = proc_address_fn;
    if (c.gladLoadGLLoader(gladLoader) == 0) return error.GladLoadFailed;
}

fn gladLoader(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const loader = active_proc_address_fn orelse return null;
    const sentinel_name: [*:0]const u8 = @ptrCast(name);
    const ptr = loader(sentinel_name) orelse return null;
    return @ptrCast(@constCast(ptr));
}

fn createProgram() !c.GLuint {
    const vertex = try compileShader(c.GL_VERTEX_SHADER, vertex_shader_source);
    defer c.glDeleteShader(vertex);
    const fragment = try compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_source);
    defer c.glDeleteShader(fragment);

    const program = c.glCreateProgram();
    c.glAttachShader(program, vertex);
    c.glAttachShader(program, fragment);
    c.glLinkProgram(program);

    var ok: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        c.glDeleteProgram(program);
        return error.OpenGlProgramLinkFailed;
    }
    return program;
}

fn compileShader(kind: c.GLenum, source: [:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    var source_ptr: [*c]const u8 = source.ptr;
    c.glShaderSource(shader, 1, &source_ptr, null);
    c.glCompileShader(shader);

    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        c.glDeleteShader(shader);
        return error.OpenGlShaderCompileFailed;
    }
    return shader;
}

fn ortho(left: f32, right: f32, bottom: f32, top: f32) [16]f32 {
    const near: f32 = -1;
    const far: f32 = 1;
    return .{
        2 / (right - left),               0,                                0,                            0,
        0,                                2 / (top - bottom),               0,                            0,
        0,                                0,                                -2 / (far - near),            0,
        -(right + left) / (right - left), -(top + bottom) / (top - bottom), -(far + near) / (far - near), 1,
    };
}

const Scissor = struct {
    x: c.GLint,
    y: c.GLint,
    w: c.GLsizei,
    h: c.GLsizei,
};

fn scissorRect(rect: types.Rect, logical_width: f32, logical_height: f32, framebuffer_width: u32, framebuffer_height: u32) Scissor {
    const fw: f32 = @floatFromInt(framebuffer_width);
    const fh: f32 = @floatFromInt(framebuffer_height);
    const scale_x = fw / @max(1, logical_width);
    const scale_y = fh / @max(1, logical_height);
    const min_x = clamp(rect.x * scale_x, 0, fw);
    const min_y = clamp(rect.y * scale_y, 0, fh);
    const max_x = clamp((rect.x + rect.w) * scale_x, 0, fw);
    const max_y = clamp((rect.y + rect.h) * scale_y, 0, fh);
    return .{
        .x = @intFromFloat(min_x),
        .y = @intFromFloat(fh - max_y),
        .w = @intFromFloat(@max(0, max_x - min_x)),
        .h = @intFromFloat(@max(0, max_y - min_y)),
    };
}

fn clamp(v: f32, lo: f32, hi: f32) f32 {
    return @min(hi, @max(lo, v));
}

fn validateTexturePixels(width: u32, height: u32, pixels: []const u8) !void {
    const pixel_count = try std.math.mul(usize, @intCast(width), @intCast(height));
    const byte_count = try std.math.mul(usize, pixel_count, 4);
    if (pixels.len < byte_count) return error.InvalidTextureData;
}

const vertex_shader_source =
    \\#version 330 core
    \\layout(location = 0) in vec2 in_pos;
    \\layout(location = 1) in vec2 in_uv;
    \\layout(location = 2) in vec4 in_color;
    \\uniform mat4 u_projection;
    \\out vec2 v_uv;
    \\out vec4 v_color;
    \\void main() {
    \\    v_uv = in_uv;
    \\    v_color = in_color;
    \\    gl_Position = u_projection * vec4(in_pos, 0.0, 1.0);
    \\}
;

const fragment_shader_source =
    \\#version 330 core
    \\in vec2 v_uv;
    \\in vec4 v_color;
    \\uniform sampler2D u_texture;
    \\out vec4 out_color;
    \\void main() {
    \\    out_color = v_color * texture(u_texture, v_uv);
    \\}
;
