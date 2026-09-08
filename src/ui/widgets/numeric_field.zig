const std = @import("std");
const types = @import("../core/types.zig");
const app = @import("../core/ui_context.zig");
const theme_mod = @import("../theme.zig");
const button = @import("button.zig");
const label = @import("label.zig");
const text_field = @import("text_field.zig");

const stepper_width: f32 = 21;

pub const Options = struct {
    min: ?f32 = null,
    max: ?f32 = null,
    step: ?f32 = null,
    max_bytes: usize = 64,
    width: @import("../core/style.zig").Size = .fill,
    trailing_label: []const u8 = "",
    trailing_label_color: theme_mod.ColorRole = .text_muted,
};

pub const NumericResult = struct { changed: bool = false, committed: bool = false, invalid: bool = false };

pub const NumericField = struct {
    text: text_field.TextField,
    stepper_node: types.NodeId,
    increment_button: types.NodeId,
    decrement_button: types.NodeId,
    trailing_label_node: types.NodeId,
    /// Width of the right-hand gutter the stepper and the trailing label share.
    affordance_width: f32,
    kind: Kind,
    invalid: bool = false,

    const Kind = enum { i32, u32, f32 };

    pub fn initI32(allocator: std.mem.Allocator, ui: *app.Ui, parent: types.NodeId, value: i32, options: Options) !NumericField {
        return initFormatted(allocator, ui, parent, .i32, value, options);
    }
    pub fn initU32(allocator: std.mem.Allocator, ui: *app.Ui, parent: types.NodeId, value: u32, options: Options) !NumericField {
        return initFormatted(allocator, ui, parent, .u32, value, options);
    }
    pub fn initF32(allocator: std.mem.Allocator, ui: *app.Ui, parent: types.NodeId, value: f32, options: Options) !NumericField {
        return initFormatted(allocator, ui, parent, .f32, value, options);
    }

    fn initFormatted(allocator: std.mem.Allocator, ui: *app.Ui, parent: types.NodeId, kind: Kind, value: anytype, options: Options) !NumericField {
        var buf: [64]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, "{d}", .{value});
        const field_height = ui.theme.metrics.control_height;
        // Holds either the stepper arrows or a trailing label, so it has to
        // stay wide enough for a glyph at whatever size the theme asks for.
        const affordance_width = @max(stepper_width, ui.theme.font.tiny + 10);
        var text = try text_field.TextField.init(allocator, ui, parent, .{ .text = formatted, .max_bytes = options.max_bytes, .width = options.width, .height = field_height });
        errdefer text.deinit(ui);

        const frame = ui.tree.get(text.root_node).?;
        // The affordance fills the field's right end, but it sits inside the
        // frame rather than over it: inset by the border on every edge it
        // touches so the field keeps an unbroken outline and no strip of the
        // well shows between the two.
        const border = frame.style.border_width;
        const affordance_height = @max(0, field_height - border * 2);
        // Keep edited text clear of the controls even while their hover-only
        // surface is hidden, so revealing the stepper never shifts the value.
        frame.style.padding.right = affordance_width + border + 3;

        const trailing_label_node = try label.label(ui, text.root_node, options.trailing_label, ui.theme.textStyle(.{
            .width = .{ .px = affordance_width },
            .height = .{ .px = affordance_height },
            .padding = .{ .top = ui.centeredTextTop(affordance_height, ui.theme.font.tiny) },
            .color = options.trailing_label_color,
            .size = ui.theme.font.tiny,
            .text_align = .center,
        }));
        try ui.setVisible(trailing_label_node, false);

        const stepper_node = try ui.createNode(.panel);
        const stepper = ui.tree.get(stepper_node).?;
        stepper.style = ui.theme.style(.{
            .width = .{ .px = affordance_width },
            .height = .{ .px = affordance_height },
            .direction = .column,
        });
        stepper.flags.visible = false;
        stepper.flags.clipped = true;
        try ui.tree.appendChild(text.root_node, stepper_node);

        const increment_button = try button.button(ui, stepper_node, "\u{2303}", stepperButtonStyle(ui, true, affordance_height, border));
        const decrement_button = try button.button(ui, stepper_node, "\u{2304}", stepperButtonStyle(ui, false, affordance_height, border));

        return .{
            .text = text,
            .stepper_node = stepper_node,
            .increment_button = increment_button,
            .decrement_button = decrement_button,
            .trailing_label_node = trailing_label_node,
            .affordance_width = affordance_width,
            .kind = kind,
        };
    }

    pub fn deinit(self: *NumericField, ui: *app.Ui) void {
        self.text.deinit(ui);
        self.* = undefined;
    }

    pub fn updateI32(self: *NumericField, ui: *app.Ui, value: *i32, options: Options) !NumericResult {
        const event = try self.text.update(ui, fieldOptions(self.kind, options, self.invalid));
        const step_count = try self.updateStepper(ui, options);
        if (event.committed) {
            const parsed = std.fmt.parseInt(i32, self.text.text(), 10) catch {
                self.invalid = true;
                try self.syncValue(ui, value.*, options);
                if (step_count == 0) return .{ .committed = true, .invalid = true };
                return self.step(ui, i32, value, options, step_count);
            };
            var next: f32 = @floatFromInt(parsed);
            next = try applyHints(next, options);
            value.* = toI32(next);
            self.invalid = false;
            try self.syncValue(ui, value.*, options);
        }
        if (step_count != 0) return self.step(ui, i32, value, options, step_count);
        if (!event.committed) return .{ .changed = event.changed, .invalid = self.invalid };
        return .{ .changed = true, .committed = true };
    }

    pub fn updateU32(self: *NumericField, ui: *app.Ui, value: *u32, options: Options) !NumericResult {
        const event = try self.text.update(ui, fieldOptions(self.kind, options, self.invalid));
        const step_count = try self.updateStepper(ui, options);
        if (event.committed) {
            const parsed = std.fmt.parseInt(u32, self.text.text(), 10) catch {
                self.invalid = true;
                try self.syncValue(ui, value.*, options);
                if (step_count == 0) return .{ .committed = true, .invalid = true };
                return self.step(ui, u32, value, options, step_count);
            };
            var next: f32 = @floatFromInt(parsed);
            next = try applyHints(next, options);
            value.* = toU32(next);
            self.invalid = false;
            try self.syncValue(ui, value.*, options);
        }
        if (step_count != 0) return self.step(ui, u32, value, options, step_count);
        if (!event.committed) return .{ .changed = event.changed, .invalid = self.invalid };
        return .{ .changed = true, .committed = true };
    }

    pub fn updateF32(self: *NumericField, ui: *app.Ui, value: *f32, options: Options) !NumericResult {
        const event = try self.text.update(ui, fieldOptions(self.kind, options, self.invalid));
        const step_count = try self.updateStepper(ui, options);
        if (event.committed) {
            const parsed = std.fmt.parseFloat(f32, self.text.text()) catch {
                self.invalid = true;
                try self.syncValue(ui, value.*, options);
                if (step_count == 0) return .{ .committed = true, .invalid = true };
                return self.step(ui, f32, value, options, step_count);
            };
            const next = applyHints(parsed, options) catch {
                self.invalid = true;
                try self.syncValue(ui, value.*, options);
                if (step_count == 0) return .{ .committed = true, .invalid = true };
                return self.step(ui, f32, value, options, step_count);
            };
            value.* = next;
            self.invalid = false;
            try self.syncValue(ui, value.*, options);
        }
        if (step_count != 0) return self.step(ui, f32, value, options, step_count);
        if (!event.committed) return .{ .changed = event.changed, .invalid = self.invalid };
        return .{ .changed = true, .committed = true };
    }

    fn updateStepper(self: *NumericField, ui: *app.Ui, options: Options) !i32 {
        const root = ui.tree.getConst(self.text.root_node) orelse return error.InvalidNode;
        if (root.bounds.w <= 0) {
            try ui.setVisible(self.stepper_node, false);
            try ui.setVisible(self.trailing_label_node, false);
            return 0;
        }
        var style = ui.nodeStyle(self.stepper_node) orelse return error.InvalidNode;
        // The field reserves a right gutter for whichever affordance is showing,
        // so park both of them against its inner edge. Measuring back from the
        // frame rather than forward from the text's padding keeps the affordance
        // flush with the border, whatever gap the text is holding.
        const border = root.style.border_width;
        const next_left = @max(0, root.bounds.w - root.style.padding.left - self.affordance_width - border);
        const next_top = border - root.style.padding.top;
        if (style.margin.left != next_left or style.margin.top != next_top) {
            style.margin.left = next_left;
            style.margin.top = next_top;
            try ui.setStyle(self.stepper_node, style);
        }

        var label_style = ui.nodeStyle(self.trailing_label_node) orelse return error.InvalidNode;
        const next_label_top = next_top;
        if (label_style.margin.left != next_left or label_style.margin.top != next_label_top or
            !std.meta.eql(label_style.foreground, ui.theme.color(options.trailing_label_color)))
        {
            label_style.margin.left = next_left;
            label_style.margin.top = next_label_top;
            label_style.foreground = ui.theme.color(options.trailing_label_color);
            try ui.setStyle(self.trailing_label_node, label_style);
        }
        try ui.setText(self.trailing_label_node, options.trailing_label);

        const hovered = ui.tree.isDescendantOf(ui.input.hovered, self.text.root_node);
        try ui.setVisible(self.stepper_node, hovered);
        try ui.setVisible(self.trailing_label_node, !hovered and options.trailing_label.len != 0);
        if (ui.input.hovered == self.increment_button or ui.input.hovered == self.decrement_button) ui.requestCursor(.hand);

        const increment_count: i32 = @intCast(ui.activationCount(self.increment_button));
        const decrement_count: i32 = @intCast(ui.activationCount(self.decrement_button));
        return increment_count - decrement_count;
    }

    /// Stepping is one rule for every value type; only the narrowing back from
    /// the f32 the arithmetic runs in differs.
    fn step(self: *NumericField, ui: *app.Ui, comptime T: type, value: *T, options: Options, count: i32) !NumericResult {
        const previous = value.*;
        const current: f32 = if (T == f32) previous else @floatFromInt(previous);
        value.* = narrow(T, try steppedValue(current, options, count));
        self.invalid = false;
        try self.syncValue(ui, value.*, options);
        return .{ .changed = value.* != previous, .committed = true };
    }

    fn syncValue(self: *NumericField, ui: *app.Ui, value: anytype, options: Options) !void {
        var buf: [64]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.text.setTextContent(ui, formatted, options.max_bytes);
    }
};

fn stepperButtonStyle(ui: *const app.Ui, top: bool, height: f32, border: f32) @import("../core/style.zig").Style {
    // Each arrow owns half the gutter, so centre the glyph in that half rather
    // than nudging it with a fixed inset: the pair then reads as one column
    // whatever width the theme's type asks the gutter to be.
    const button_height = height / 2;
    // Nested inside the field's border, so the outer corner curves one border
    // width tighter than the frame it sits in.
    const radius = @max(0, ui.theme.radius_tokens.control - border);
    return ui.theme.style(.{
        .width = .fill,
        .height = .{ .px = button_height },
        .padding = .{ .top = ui.centeredTextTop(button_height, ui.theme.font.tiny) },
        .text_align = .center,
        .background = .panel_soft,
        .foreground = .text_dim,
        .hover_background = .accent_soft,
        .pressed_background = .accent,
        .border = .stroke,
        .hover_border = .accent,
        .pressed_border = .accent,
        .border_width = 0,
        .border_edges = if (top) .{ .left = 1, .bottom = 1 } else .{ .left = 1 },
        .radius_corners = if (top)
            .{ .top_right = radius }
        else
            .{ .bottom_right = radius },
        .font_size = ui.theme.font.tiny,
    });
}

fn steppedValue(value: f32, options: Options, count: i32) !f32 {
    const increment = options.step orelse 1;
    if (increment <= 0 or !std.math.isFinite(increment)) return error.InvalidStep;
    return applyHints(value + increment * @as(f32, @floatFromInt(count)), options);
}

fn narrow(comptime T: type, value: f32) T {
    return switch (T) {
        i32 => toI32(value),
        u32 => toU32(value),
        f32 => value,
        else => @compileError("numeric field supports i32, u32 and f32"),
    };
}

fn toI32(value: f32) i32 {
    const rounded = @round(value);
    // The positive integer limits round outward when represented as f32, so
    // branch before @intFromFloat instead of feeding it an out-of-range value.
    if (rounded >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (rounded <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(rounded);
}

fn toU32(value: f32) u32 {
    const rounded = @round(value);
    if (rounded <= 0) return 0;
    if (rounded >= @as(f32, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @intFromFloat(rounded);
}

fn fieldOptions(kind: NumericField.Kind, options: Options, invalid: bool) text_field.Options {
    return .{
        .max_bytes = options.max_bytes,
        .width = options.width,
        .invalid = invalid,
        .input_mode = switch (kind) {
            .i32 => .signed_integer,
            .u32 => .unsigned_integer,
            .f32 => .decimal,
        },
    };
}

pub fn commitFloat(text: []const u8, options: Options) !f32 {
    return applyHints(try std.fmt.parseFloat(f32, text), options);
}

fn applyHints(input: f32, options: Options) !f32 {
    if (!std.math.isFinite(input)) return error.NonFiniteValue;
    var value = input;
    if (options.min) |minimum| value = @max(minimum, value);
    if (options.max) |maximum| value = @min(maximum, value);
    if (options.step) |step| {
        if (step <= 0 or !std.math.isFinite(step)) return error.InvalidStep;
        value = @round(value / step) * step;
        if (options.min) |minimum| value = @max(minimum, value);
        if (options.max) |maximum| value = @min(maximum, value);
    }
    return value;
}

test "float commit is strict, finite, clamped, and stepped" {
    try std.testing.expectError(error.InvalidCharacter, commitFloat("1,5", .{}));
    try std.testing.expectError(error.NonFiniteValue, commitFloat("nan", .{}));
    try std.testing.expectEqual(@as(f32, 1.5), try commitFloat("1.6", .{ .min = 0, .max = 2, .step = 0.5 }));
    try std.testing.expectEqual(@as(f32, 2), try commitFloat("9", .{ .min = 0, .max = 2 }));
}

test "invalid numeric text rolls back without changing committed value" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var field = try NumericField.initI32(std.testing.allocator, &ui, ui.rootNode(), 42, .{});
    defer field.deinit(&ui);
    try field.text.setTextContent(&ui, "not-a-number", 64);
    ui.requestFocus(field.text.root_node);
    var value: i32 = 42;
    try ui.beginFrame(.{ .window_size = .{ .x = 200, .y = 50 } });
    _ = try field.updateI32(&ui, &value, .{});
    try ui.beginFrame(.{ .events = &.{.{ .key_down = .enter }}, .window_size = .{ .x = 200, .y = 50 } });
    const result = try field.updateI32(&ui, &value, .{});
    try std.testing.expect(result.invalid);
    try std.testing.expectEqual(@as(i32, 42), value);
    try std.testing.expectEqualStrings("42", field.text.text());
}

test "numeric fields filter non-numeric keyboard and pasted input" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();

    var signed = try NumericField.initI32(std.testing.allocator, &ui, ui.rootNode(), 0, .{});
    defer signed.deinit(&ui);
    var signed_value: i32 = 0;
    ui.requestFocus(signed.text.root_node);
    signed.text.selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "abc-12.3xyz" }},
        .window_size = .{ .x = 200, .y = 50 },
    });
    const signed_result = try signed.updateI32(&ui, &signed_value, .{});
    try std.testing.expect(signed_result.changed);
    try std.testing.expectEqualStrings("-123", signed.text.text());
    try ui.endFrame();

    var unsigned = try NumericField.initU32(std.testing.allocator, &ui, ui.rootNode(), 0, .{});
    defer unsigned.deinit(&ui);
    var unsigned_value: u32 = 0;
    ui.requestFocus(unsigned.text.root_node);
    unsigned.text.selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "abc-12xyz" }},
        .window_size = .{ .x = 200, .y = 50 },
    });
    const unsigned_result = try unsigned.updateU32(&ui, &unsigned_value, .{});
    try std.testing.expect(unsigned_result.changed);
    try std.testing.expectEqualStrings("12", unsigned.text.text());
    try ui.endFrame();

    var decimal = try NumericField.initF32(std.testing.allocator, &ui, ui.rootNode(), 0, .{});
    defer decimal.deinit(&ui);
    var decimal_value: f32 = 0;
    ui.requestFocus(decimal.text.root_node);
    decimal.text.selectAll();
    try ui.beginFrame(.{
        .events = &.{.{ .text_input = "abc-1.25xyz" }},
        .window_size = .{ .x = 200, .y = 50 },
    });
    const decimal_result = try decimal.updateF32(&ui, &decimal_value, .{});
    try std.testing.expect(decimal_result.changed);
    try std.testing.expectEqualStrings("-1.25", decimal.text.text());
}

test "numeric stepper reveals on hover and increments and decrements" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    const options = Options{ .width = .{ .px = 120 }, .trailing_label = "X", .trailing_label_color = .danger };
    var field = try NumericField.initI32(std.testing.allocator, &ui, ui.rootNode(), 10, options);
    defer field.deinit(&ui);
    var value: i32 = 10;

    // First retained frame establishes geometry. The controls remain hidden
    // until the following update observes the field under the pointer.
    try ui.beginFrame(.{ .window_size = .{ .x = 200, .y = 50 } });
    _ = try field.updateI32(&ui, &value, options);
    try ui.endFrame();
    try std.testing.expect(!ui.tree.getConst(field.stepper_node).?.flags.visible);

    try ui.beginFrame(.{
        .events = &.{.{ .mouse_move = .{ .x = 60, .y = 17 } }},
        .window_size = .{ .x = 200, .y = 50 },
    });
    _ = try field.updateI32(&ui, &value, options);
    try ui.endFrame();
    try std.testing.expect(ui.tree.getConst(field.stepper_node).?.flags.visible);
    try std.testing.expect(!ui.tree.getConst(field.trailing_label_node).?.flags.visible);

    const up = ui.bounds(field.increment_button).?;
    const up_center = types.Vec2{ .x = up.x + up.w / 2, .y = up.y + up.h / 2 };
    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = up_center }, .{ .mouse_down = .left }, .{ .mouse_up = .left } },
        .window_size = .{ .x = 200, .y = 50 },
    });
    const incremented = try field.updateI32(&ui, &value, options);
    try std.testing.expect(incremented.changed and incremented.committed);
    try std.testing.expectEqual(@as(i32, 11), value);
    try std.testing.expectEqualStrings("11", field.text.text());
    try std.testing.expectEqual(@import("../platform/events.zig").CursorKind.hand, ui.requestedCursor());
    try ui.endFrame();

    const down = ui.bounds(field.decrement_button).?;
    const down_center = types.Vec2{ .x = down.x + down.w / 2, .y = down.y + down.h / 2 };
    try ui.beginFrame(.{
        .events = &.{ .{ .mouse_move = down_center }, .{ .mouse_down = .left }, .{ .mouse_up = .left } },
        .window_size = .{ .x = 200, .y = 50 },
    });
    const decremented = try field.updateI32(&ui, &value, options);
    try std.testing.expect(decremented.changed and decremented.committed);
    try std.testing.expectEqual(@as(i32, 10), value);
    try std.testing.expectEqualStrings("10", field.text.text());
    try ui.endFrame();

    try ui.beginFrame(.{
        .events = &.{.{ .mouse_move = .{ .x = 180, .y = 40 } }},
        .window_size = .{ .x = 200, .y = 50 },
    });
    _ = try field.updateI32(&ui, &value, options);
    try std.testing.expect(!ui.tree.getConst(field.stepper_node).?.flags.visible);
    try std.testing.expect(ui.tree.getConst(field.trailing_label_node).?.flags.visible);
    try std.testing.expectEqualStrings("X", ui.tree.getConst(field.trailing_label_node).?.text.?);
    try std.testing.expectEqual(ui.theme.color(.danger), ui.nodeStyle(field.trailing_label_node).?.foreground);
}

test "numeric stepper respects configured step and bounds" {
    try std.testing.expectEqual(@as(f32, 1.75), try steppedValue(1.5, .{ .step = 0.25 }, 1));
    try std.testing.expectEqual(@as(f32, 2), try steppedValue(1.75, .{ .max = 2, .step = 0.25 }, 2));
    try std.testing.expectEqual(@as(f32, 0), try steppedValue(0, .{ .min = 0 }, -1));
    try std.testing.expectEqual(std.math.maxInt(i32), toI32(@floatFromInt(std.math.maxInt(i32))));
    try std.testing.expectEqual(std.math.maxInt(u32), toU32(@floatFromInt(std.math.maxInt(u32))));
}

test "stepper arrows centre in the gutter they own" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();

    const options = Options{ .width = .{ .px = 120 } };
    var field = try NumericField.initI32(std.testing.allocator, &ui, ui.rootNode(), 10, options);
    defer field.deinit(&ui);
    var value: i32 = 10;

    // The arrows are born hidden, so only the frame that reveals them can
    // measure the glyphs that centring depends on.
    try ui.beginFrame(.{ .window_size = .{ .x = 200, .y = 50 } });
    _ = try field.updateI32(&ui, &value, options);
    try ui.endFrame();
    try ui.beginFrame(.{
        .events = &.{.{ .mouse_move = .{ .x = 60, .y = 17 } }},
        .window_size = .{ .x = 200, .y = 50 },
    });
    _ = try field.updateI32(&ui, &value, options);
    try ui.endFrame();

    for ([_]types.NodeId{ field.increment_button, field.decrement_button }) |button_node| {
        const node = ui.tree.getConst(button_node).?;
        const style = node.style;
        try std.testing.expectEqual(
            @import("../core/style.zig").TextAlign.center,
            style.text_align,
        );
        try std.testing.expectEqual(@as(f32, 0), style.padding.left);
        try std.testing.expectApproxEqAbs(
            ui.centeredTextTop(style.height.px, ui.theme.font.tiny),
            style.padding.top,
            0.01,
        );
        // Centring silently degrades to the leading edge when the run was
        // never measured, which is exactly what a hidden-at-birth control
        // used to hand the paint pass.
        try std.testing.expectEqual(style.font_size, node.measured_text_font_size);
        try std.testing.expect(node.measured_text.x > 0);
        try std.testing.expect(node.measured_text.x < node.bounds.w);
    }
}

test "both affordances sit flush inside the field's frame" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();

    const options = Options{ .width = .{ .px = 160 }, .trailing_label = "X" };
    var field = try NumericField.initI32(std.testing.allocator, &ui, ui.rootNode(), 0, options);
    defer field.deinit(&ui);
    var value: i32 = 0;

    // The pointer starts at the origin, which is inside the field, so park it
    // outside to see the trailing label rather than the stepper.
    const away = types.Vec2{ .x = 280, .y = 55 };
    for (0..3) |_| {
        try ui.beginFrame(.{ .events = &.{.{ .mouse_move = away }}, .window_size = .{ .x = 300, .y = 60 } });
        _ = try field.updateI32(&ui, &value, options);
        try ui.endFrame();
    }

    const frame = ui.bounds(field.text.root_node).?;
    const border = ui.tree.getConst(field.text.root_node).?.style.border_width;
    try std.testing.expect(border > 0);

    // Inside the border on every edge it touches: the frame stays unbroken and
    // no strip of the field's own well shows past the affordance.
    const unit = ui.bounds(field.trailing_label_node).?;
    try std.testing.expectEqual(frame.x + frame.w - border, unit.x + unit.w);
    try std.testing.expectEqual(frame.y + border, unit.y);
    try std.testing.expectEqual(frame.h - border * 2, unit.h);

    try ui.beginFrame(.{
        .events = &.{.{ .mouse_move = .{ .x = frame.x + frame.w / 2, .y = frame.y + frame.h / 2 } }},
        .window_size = .{ .x = 300, .y = 60 },
    });
    _ = try field.updateI32(&ui, &value, options);
    try ui.endFrame();

    const stepper = ui.bounds(field.stepper_node).?;
    try std.testing.expectEqual(unit.x, stepper.x);
    try std.testing.expectEqual(frame.x + frame.w - border, stepper.x + stepper.w);
    try std.testing.expectEqual(frame.y + border, stepper.y);
    try std.testing.expectEqual(frame.h - border * 2, stepper.h);

    // The text keeps clear of whichever affordance is showing.
    const text_right = ui.bounds(field.text.text_node).?;
    try std.testing.expect(text_right.x + text_right.w <= stepper.x);
}
