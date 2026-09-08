const std = @import("std");
const types = @import("../core/types.zig");
const color_mod = @import("../core/color.zig");
const dirty = @import("../core/dirty.zig");
const app = @import("../core/ui_context.zig");
const primitives = @import("primitives.zig");
const label_mod = @import("label.zig");
const text_field = @import("text_field.zig");

const channel_count = 4;
const channel_gap: f32 = 6;
const section_gap: f32 = 8;

pub const Options = struct {
    wheel_diameter: f32 = 224,
};

const DragMode = enum { none, hue, saturation_value };

const EditSource = union(enum) {
    channel: usize,
    hex,
};

pub const ColorPicker = struct {
    root_node: types.NodeId,
    wheel_node: types.NodeId,
    channel_fields: [channel_count]text_field.TextField,
    hex_field: text_field.TextField,
    channel_invalid: [channel_count]bool = @splat(false),
    hex_invalid: bool = false,
    hsv: color_mod.Hsv,
    last_color: types.Color,
    drag_mode: DragMode = .none,

    pub fn init(
        allocator: std.mem.Allocator,
        ui: *app.Ui,
        parent: types.NodeId,
        initial: types.Color,
        options: Options,
    ) !ColorPicker {
        if (!std.math.isFinite(options.wheel_diameter) or options.wheel_diameter < 120) {
            return error.InvalidColorPickerSize;
        }

        const root = try primitives.column(ui, parent, .{
            .width = .{ .px = options.wheel_diameter },
            .height = .hug,
            .gap = section_gap,
        });
        errdefer ui.destroySubtree(root);

        const wheel = try ui.createNode(.custom);
        const wheel_ptr = ui.tree.get(wheel).?;
        wheel_ptr.style = .{
            .width = .{ .px = options.wheel_diameter },
            .height = .{ .px = options.wheel_diameter },
        };
        wheel_ptr.flags.interactive = true;
        wheel_ptr.flags.focusable = true;
        try ui.tree.appendChild(root, wheel);

        const row = try primitives.row(ui, root, .{
            .width = .fill,
            .height = .{ .px = ui.theme.metrics.control_height },
            .gap = channel_gap,
        });

        var fields: [channel_count]text_field.TextField = undefined;
        var initialized_fields: usize = 0;
        errdefer for (fields[0..initialized_fields]) |*field| field.deinit(ui);

        const labels = [_][]const u8{ "R", "G", "B", "A" };
        const channels = [_]u8{ initial.r, initial.g, initial.b, initial.a };
        const field_width = (options.wheel_diameter - channel_gap * 3) / 4;
        for (&fields, labels, channels) |*field, field_label, channel| {
            var buffer: [3]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&buffer, "{d}", .{channel});
            field.* = try text_field.TextField.init(allocator, ui, row, .{
                .text = formatted,
                .max_bytes = 3,
                .width = .fill,
                .input_mode = .unsigned_integer,
            });
            initialized_fields += 1;

            const frame = ui.tree.get(field.root_node).?;
            frame.style.padding.left = 6;
            frame.style.padding.right = 17;
            _ = try label_mod.label(ui, field.root_node, field_label, ui.theme.textStyle(.{
                .width = .{ .px = 14 },
                .height = .fill,
                // Absolute children start at the field's padded content edge.
                // Account for that inset and the border so the suffix sits
                // fully inside the frame instead of being clipped on its right.
                .margin = .{ .left = field_width - 21 },
                .padding = .{ .top = ui.centeredTextTop(ui.theme.metrics.control_height, ui.theme.font.tiny) },
                .color = .text_muted,
                .size = ui.theme.font.tiny,
                .text_align = .center,
            }));
        }

        var hex_buffer: [9]u8 = undefined;
        formatHex(initial, &hex_buffer);
        var hex = try text_field.TextField.init(allocator, ui, root, .{
            .text = &hex_buffer,
            .max_bytes = 9,
            .width = .fill,
        });
        errdefer hex.deinit(ui);

        const hsv = color_mod.rgbToHsv(initial, 0);
        try ui.setColorWheelVisual(wheel, wheelVisual(hsv));
        return .{
            .root_node = root,
            .wheel_node = wheel,
            .channel_fields = fields,
            .hex_field = hex,
            .hsv = hsv,
            .last_color = initial,
        };
    }

    pub fn deinit(self: *ColorPicker, ui: *app.Ui) void {
        for (&self.channel_fields) |*field| field.deinit(ui);
        self.hex_field.deinit(ui);
        ui.destroySubtree(self.root_node);
        self.* = undefined;
    }

    pub fn update(self: *ColorPicker, ui: *app.Ui, value: *types.Color) !bool {
        var changed = false;

        if (!std.meta.eql(value.*, self.last_color)) {
            if (ui.tree.isDescendantOf(ui.focusedNode(), self.root_node)) ui.clearFocus();
            self.acceptColor(value.*);
            try self.syncFields(ui, value.*, null);
        }

        if (try self.updateWheel(ui, value)) {
            changed = true;
            try self.syncFields(ui, value.*, null);
        }

        for (&self.channel_fields, 0..) |*field, index| {
            const event = try field.update(ui, channelOptions(self.channel_invalid[index]));
            if (event.changed) {
                if (parseChannel(field.text())) |channel| {
                    var next = value.*;
                    setChannel(&next, index, channel);
                    self.channel_invalid[index] = false;
                    if (!std.meta.eql(next, value.*)) {
                        value.* = next;
                        self.acceptColor(next);
                        changed = true;
                        try self.syncFields(ui, next, .{ .channel = index });
                    }
                } else {
                    self.channel_invalid[index] = true;
                }
                setFieldInvalid(ui, field, self.channel_invalid[index]);
            }
            if (event.committed or event.cancelled) {
                self.channel_invalid[index] = false;
                try setChannelText(ui, field, channelAt(value.*, index));
                setFieldInvalid(ui, field, false);
            }
        }

        const hex_event = try self.hex_field.update(ui, hexOptions(self.hex_invalid));
        if (hex_event.changed) {
            if (parseHex(self.hex_field.text())) |next| {
                self.hex_invalid = false;
                if (!std.meta.eql(next, value.*)) {
                    value.* = next;
                    self.acceptColor(next);
                    changed = true;
                    try self.syncFields(ui, next, .hex);
                }
            } else {
                self.hex_invalid = true;
            }
            setFieldInvalid(ui, &self.hex_field, self.hex_invalid);
        }
        if (hex_event.committed or hex_event.cancelled) {
            self.hex_invalid = false;
            try setHexText(ui, &self.hex_field, value.*);
            setFieldInvalid(ui, &self.hex_field, false);
        }

        try ui.setColorWheelVisual(self.wheel_node, wheelVisual(self.hsv));
        self.last_color = value.*;
        return changed;
    }

    fn updateWheel(self: *ColorPicker, ui: *app.Ui, value: *types.Color) !bool {
        const bounds = ui.bounds(self.wheel_node) orelse return false;
        const geometry = color_mod.WheelGeometry.init(bounds, self.hsv.h);
        if (ui.mousePressed(.left) and ui.input.hovered == self.wheel_node) {
            const pointer = ui.mousePosition();
            if (geometry.isInRing(pointer)) {
                self.drag_mode = .hue;
                ui.requestFocus(self.wheel_node);
            } else if (geometry.containsTriangle(pointer)) {
                self.drag_mode = .saturation_value;
                ui.requestFocus(self.wheel_node);
            }
        }

        var changed = false;
        if (self.drag_mode != .none and ui.mouseDown(.left)) {
            switch (self.drag_mode) {
                .none => {},
                .hue => self.hsv.h = color_mod.hueAtPoint(geometry.center, ui.mousePosition()),
                .saturation_value => {
                    const point = geometry.clampToTriangle(ui.mousePosition());
                    const weights = geometry.triangleWeights(point) orelse return false;
                    self.hsv = color_mod.hsvFromTriangleWeights(self.hsv.h, weights);
                },
            }
            const next = color_mod.hsvToRgb(self.hsv, value.a);
            if (!std.meta.eql(next, value.*)) {
                value.* = next;
                self.last_color = next;
                changed = true;
            }
            ui.capturePointer();
        }
        if (ui.mouseReleased(.left)) self.drag_mode = .none;
        return changed;
    }

    fn acceptColor(self: *ColorPicker, color: types.Color) void {
        self.hsv = color_mod.rgbToHsv(color, self.hsv.h);
        self.last_color = color;
    }

    fn syncFields(self: *ColorPicker, ui: *app.Ui, color: types.Color, preserve: ?EditSource) !void {
        for (&self.channel_fields, 0..) |*field, index| {
            if (!preservesChannel(preserve, index)) try setChannelText(ui, field, channelAt(color, index));
            self.channel_invalid[index] = false;
            setFieldInvalid(ui, field, false);
        }
        if (!preservesHex(preserve)) try setHexText(ui, &self.hex_field, color);
        self.hex_invalid = false;
        setFieldInvalid(ui, &self.hex_field, false);
    }
};

fn channelOptions(invalid: bool) text_field.Options {
    return .{ .max_bytes = 3, .width = .fill, .invalid = invalid, .input_mode = .unsigned_integer };
}

fn hexOptions(invalid: bool) text_field.Options {
    return .{ .max_bytes = 9, .width = .fill, .invalid = invalid };
}

fn wheelVisual(hsv: color_mod.Hsv) @import("../core/node.zig").ColorWheelVisual {
    return .{ .hue = hsv.h, .saturation = hsv.s, .value = hsv.v };
}

fn parseChannel(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u8, text, 10) catch null;
}

fn parseHex(text: []const u8) ?types.Color {
    if (text.len != 9 or text[0] != '#') return null;
    const value = std.fmt.parseInt(u32, text[1..], 16) catch return null;
    return .{
        .r = @intCast((value >> 24) & 0xff),
        .g = @intCast((value >> 16) & 0xff),
        .b = @intCast((value >> 8) & 0xff),
        .a = @intCast(value & 0xff),
    };
}

fn formatHex(color: types.Color, buffer: *[9]u8) void {
    const digits = "0123456789ABCDEF";
    buffer[0] = '#';
    const channels = [_]u8{ color.r, color.g, color.b, color.a };
    for (channels, 0..) |channel, index| {
        buffer[1 + index * 2] = digits[channel >> 4];
        buffer[2 + index * 2] = digits[channel & 0x0f];
    }
}

fn setChannelText(ui: *app.Ui, field: *text_field.TextField, value: u8) !void {
    var buffer: [3]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    if (std.mem.eql(u8, field.text(), formatted)) return;
    try field.setTextContent(ui, formatted, 3);
}

fn setHexText(ui: *app.Ui, field: *text_field.TextField, color: types.Color) !void {
    var buffer: [9]u8 = undefined;
    formatHex(color, &buffer);
    if (std.mem.eql(u8, field.text(), &buffer)) return;
    try field.setTextContent(ui, &buffer, 9);
}

fn setFieldInvalid(ui: *app.Ui, field: *text_field.TextField, invalid: bool) void {
    const frame = ui.tree.get(field.root_node) orelse return;
    const border = if (invalid) ui.theme.palette.danger else if (ui.isFocused(field.root_node)) ui.theme.palette.accent else ui.theme.palette.stroke;
    if (!std.meta.eql(frame.style.border_color, border)) {
        frame.style.border_color = border;
        dirty.markPaintDirty(&ui.tree, field.root_node);
    }
}

fn channelAt(color: types.Color, index: usize) u8 {
    return switch (index) {
        0 => color.r,
        1 => color.g,
        2 => color.b,
        3 => color.a,
        else => unreachable,
    };
}

fn setChannel(color: *types.Color, index: usize, value: u8) void {
    switch (index) {
        0 => color.r = value,
        1 => color.g = value,
        2 => color.b = value,
        3 => color.a = value,
        else => unreachable,
    }
}

fn preservesChannel(source: ?EditSource, index: usize) bool {
    const active = source orelse return false;
    return switch (active) {
        .channel => |channel| channel == index,
        .hex => false,
    };
}

fn preservesHex(source: ?EditSource) bool {
    const active = source orelse return false;
    return active == .hex;
}

test "hex parser round trips canonical RGBA" {
    const color = types.Color.rgba(10, 187, 204, 17);
    var buffer: [9]u8 = undefined;
    formatHex(color, &buffer);
    try std.testing.expectEqualStrings("#0ABBCC11", &buffer);
    try std.testing.expectEqual(color, parseHex("#0abbcc11").?);
    try std.testing.expect(parseHex("0ABBCC11") == null);
    try std.testing.expect(parseHex("#0ABBCX11") == null);
}

test "channel parser rejects partial and out of range values" {
    try std.testing.expectEqual(@as(?u8, 0), parseChannel("0"));
    try std.testing.expectEqual(@as(?u8, 255), parseChannel("255"));
    try std.testing.expect(parseChannel("") == null);
    try std.testing.expect(parseChannel("256") == null);
}

test "channel and hex edits update the color live" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var picker = try ColorPicker.init(std.testing.allocator, &ui, ui.rootNode(), types.Color.rgba(10, 20, 30, 40), .{});
    defer picker.deinit(&ui);
    var value = types.Color.rgba(10, 20, 30, 40);

    try ui.beginFrame(.{ .window_size = .{ .x = 300, .y = 340 } });
    _ = try picker.update(&ui, &value);
    try ui.endFrame();

    ui.requestFocus(picker.channel_fields[0].root_node);
    picker.channel_fields[0].selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "128" }},
        .window_size = .{ .x = 300, .y = 340 },
    });
    try std.testing.expect(try picker.update(&ui, &value));
    try std.testing.expectEqual(types.Color.rgba(128, 20, 30, 40), value);
    try std.testing.expectEqualStrings("#80141E28", picker.hex_field.text());
    try ui.endFrame();

    ui.requestFocus(picker.hex_field.root_node);
    picker.hex_field.selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "#0102fe04" }},
        .window_size = .{ .x = 300, .y = 340 },
    });
    try std.testing.expect(try picker.update(&ui, &value));
    try std.testing.expectEqual(types.Color.rgba(1, 2, 254, 4), value);
    try std.testing.expectEqualStrings("1", picker.channel_fields[0].text());
    try std.testing.expectEqualStrings("2", picker.channel_fields[1].text());
    try std.testing.expectEqualStrings("254", picker.channel_fields[2].text());
    try std.testing.expectEqualStrings("4", picker.channel_fields[3].text());
}

test "invalid live text retains the last valid color and recovers" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var picker = try ColorPicker.init(std.testing.allocator, &ui, ui.rootNode(), types.Color.rgba(10, 20, 30, 40), .{});
    defer picker.deinit(&ui);
    var value = types.Color.rgba(10, 20, 30, 40);

    try ui.beginFrame(.{ .window_size = .{ .x = 300, .y = 340 } });
    _ = try picker.update(&ui, &value);
    try ui.endFrame();

    ui.requestFocus(picker.channel_fields[1].root_node);
    picker.channel_fields[1].selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "256" }},
        .window_size = .{ .x = 300, .y = 340 },
    });
    try std.testing.expect(!(try picker.update(&ui, &value)));
    try std.testing.expectEqual(types.Color.rgba(10, 20, 30, 40), value);
    try std.testing.expect(picker.channel_invalid[1]);
    try std.testing.expectEqual(ui.theme.palette.danger, ui.nodeStyle(picker.channel_fields[1].root_node).?.border_color);
    try ui.endFrame();

    picker.channel_fields[1].selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "200" }},
        .window_size = .{ .x = 300, .y = 340 },
    });
    try std.testing.expect(try picker.update(&ui, &value));
    try std.testing.expectEqual(types.Color.rgba(10, 200, 30, 40), value);
    try std.testing.expect(!picker.channel_invalid[1]);
}

test "wheel ring and triangle update RGB while preserving alpha" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var picker = try ColorPicker.init(std.testing.allocator, &ui, ui.rootNode(), types.Color.rgba(255, 0, 0, 77), .{});
    defer picker.deinit(&ui);
    var value = types.Color.rgba(255, 0, 0, 77);
    const size = types.Vec2{ .x = 300, .y = 340 };

    try ui.beginFrame(.{ .window_size = size });
    _ = try picker.update(&ui, &value);
    try ui.endFrame();

    var geometry = color_mod.WheelGeometry.init(ui.bounds(picker.wheel_node).?, picker.hsv.h);
    const ring_point: types.Vec2 = .{
        .x = geometry.center.x,
        .y = geometry.center.y + (geometry.inner_radius + geometry.outer_radius) * 0.5,
    };
    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = ring_point }, .{ .mouse_down = .left } },
        .window_size = size,
    });
    try std.testing.expect(try picker.update(&ui, &value));
    try std.testing.expectEqual(@as(u8, 77), value.a);
    try std.testing.expectEqual(@as(u8, 255), value.g);
    try std.testing.expect(value.r >= 126 and value.r <= 129);
    try std.testing.expect(ui.inputCapture().has_pointer_capture);
    try ui.endFrame();

    try ui.beginFrame(.{ .events = &.{.{ .mouse_up = .left }}, .window_size = size });
    _ = try picker.update(&ui, &value);
    try ui.endFrame();

    geometry = color_mod.WheelGeometry.init(ui.bounds(picker.wheel_node).?, picker.hsv.h);
    const white_point: types.Vec2 = .{
        .x = geometry.white_point.x * 0.995 + geometry.center.x * 0.005,
        .y = geometry.white_point.y * 0.995 + geometry.center.y * 0.005,
    };
    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = white_point }, .{ .mouse_down = .left } },
        .window_size = size,
    });
    try std.testing.expect(try picker.update(&ui, &value));
    try std.testing.expect(value.r >= 253 and value.g >= 253 and value.b >= 253);
    try std.testing.expectEqual(@as(u8, 77), value.a);
}

test "external color replacement synchronizes every field" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var picker = try ColorPicker.init(std.testing.allocator, &ui, ui.rootNode(), types.Color.rgba(1, 2, 3, 4), .{});
    defer picker.deinit(&ui);
    var value = types.Color.rgba(1, 2, 3, 4);
    try ui.beginFrame(.{ .window_size = .{ .x = 300, .y = 340 } });
    _ = try picker.update(&ui, &value);
    try ui.endFrame();

    value = types.Color.rgba(220, 120, 20, 99);
    try ui.beginFrame(.{ .window_size = .{ .x = 300, .y = 340 } });
    try std.testing.expect(!(try picker.update(&ui, &value)));
    try std.testing.expectEqualStrings("220", picker.channel_fields[0].text());
    try std.testing.expectEqualStrings("120", picker.channel_fields[1].text());
    try std.testing.expectEqualStrings("20", picker.channel_fields[2].text());
    try std.testing.expectEqualStrings("99", picker.channel_fields[3].text());
    try std.testing.expectEqualStrings("#DC781463", picker.hex_field.text());
}
