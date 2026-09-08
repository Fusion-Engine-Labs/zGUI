const std = @import("std");
const types = @import("../core/types.zig");
const app = @import("../core/ui_context.zig");
const input_mod = @import("../core/input.zig");
const text_mod = @import("../core/text.zig");
const dirty = @import("../core/dirty.zig");
const node_mod = @import("../core/node.zig");
const panel_mod = @import("panel.zig");
const label_mod = @import("label.zig");

pub const InputMode = enum {
    text,
    signed_integer,
    unsigned_integer,
    decimal,
};

pub const Options = struct {
    text: []const u8 = "",
    placeholder: []const u8 = "",
    max_bytes: usize = 4096,
    multiline: bool = false,
    width: @import("../core/style.zig").Size = .fill,
    height: ?f32 = null,
    invalid: bool = false,
    input_mode: InputMode = .text,
};

pub const TextFieldResult = struct {
    changed: bool = false,
    committed: bool = false,
    cancelled: bool = false,
};

pub const TextField = struct {
    const CaretStop = struct { index: usize, x: f32 };

    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    original: std.ArrayListUnmanaged(u8) = .empty,
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    candidate: std.ArrayListUnmanaged(u8) = .empty,
    caret_stops: std.ArrayListUnmanaged(CaretStop) = .empty,
    cursor: usize = 0,
    selection_anchor: ?usize = null,
    horizontal_scroll: f32 = 0,
    root_node: types.NodeId = types.invalid_node,
    text_node: types.NodeId = types.invalid_node,
    selection_node: types.NodeId = types.invalid_node,
    caret_node: types.NodeId = types.invalid_node,
    dirty: bool = false,
    focused_last_frame: bool = false,
    suppress_focus_loss_commit: bool = false,
    text_revision: u32 = 1,
    caret_revision: u32 = 0,
    caret_font_size: f32 = -1,
    caret_atlas: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, ui: *app.Ui, parent: types.NodeId, options: Options) !TextField {
        var self = TextField{ .allocator = allocator };
        errdefer self.buffer.deinit(allocator);
        errdefer self.original.deinit(allocator);
        if (!std.unicode.utf8ValidateSlice(options.text) or options.text.len > options.max_bytes) return error.InvalidInitialText;
        try self.buffer.appendSlice(allocator, options.text);
        try self.original.appendSlice(allocator, options.text);
        self.cursor = options.text.len;

        const field_height = options.height orelse ui.theme.metrics.control_height;
        const line_height = ui.textLineHeight(ui.theme.font.body);
        const line_top = if (options.multiline) 1 else ui.centeredTextTop(field_height, ui.theme.font.body);
        const text_top = if (options.multiline) 0 else ui.centeredTextTop(field_height, ui.theme.font.body);

        self.root_node = try ui.createNode(.panel);
        errdefer ui.destroySubtree(self.root_node);
        const root = ui.tree.get(self.root_node).?;
        root.style = ui.theme.style(.{
            .width = options.width,
            .height = .{ .px = field_height },
            .padding = .{
                .left = ui.theme.space.lg,
                .right = ui.theme.space.lg,
                .top = if (options.multiline) ui.theme.space.md else 0,
                .bottom = if (options.multiline) ui.theme.space.md else 0,
            },
            .direction = .absolute,
            .overflow_x = .visible,
            .background = .control,
            .border = if (options.invalid) .danger else .stroke,
            .border_width = 1,
            .radius = .control,
            .font_size = ui.theme.font.body,
        });
        root.flags.interactive = true;
        root.flags.focusable = true;
        root.flags.accepts_text_input = true;
        root.flags.clipped = true;
        try ui.tree.appendChild(parent, self.root_node);

        self.selection_node = try panel_mod.panel(ui, self.root_node, ui.theme.style(.{ .width = .{ .px = 0 }, .height = .{ .px = line_height }, .margin = .{ .top = line_top }, .background = .accent_soft }));
        ui.tree.get(self.selection_node).?.flags.visible = false;

        self.text_node = try label_mod.label(ui, self.root_node, displayText(&self, options), ui.theme.textStyle(.{ .width = .hug, .height = .fill, .margin = .{ .top = text_top }, .size = ui.theme.font.body }));

        self.caret_node = try panel_mod.panel(ui, self.root_node, ui.theme.style(.{ .width = .{ .px = 1 }, .height = .{ .px = line_height }, .margin = .{ .top = line_top }, .background = .text }));
        ui.tree.get(self.caret_node).?.flags.visible = false;
        return self;
    }

    pub fn deinit(self: *TextField, ui: *app.Ui) void {
        ui.destroySubtree(self.root_node);
        self.buffer.deinit(self.allocator);
        self.original.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.candidate.deinit(self.allocator);
        self.caret_stops.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: *const TextField) []const u8 {
        return self.buffer.items;
    }

    pub fn setTextContent(self: *TextField, ui: *app.Ui, bytes: []const u8, max_bytes: usize) !void {
        if (!std.unicode.utf8ValidateSlice(bytes) or bytes.len > max_bytes) return error.InvalidText;
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, bytes);
        self.text_revision +%= 1;
        self.cursor = bytes.len;
        self.selection_anchor = null;
        if (!ui.isFocused(self.root_node)) try self.snapshotOriginal();
        try ui.setText(self.text_node, bytes);
    }

    pub fn selectAll(self: *TextField) void {
        self.selection_anchor = 0;
        self.cursor = self.buffer.items.len;
    }

    pub fn update(self: *TextField, ui: *app.Ui, options: Options) !TextFieldResult {
        var result: TextFieldResult = .{};
        const focused = ui.isFocused(self.root_node);

        if (ui.input.hovered == self.root_node) {
            ui.requestCursor(.text);
            if (ui.mousePressed(.left)) {
                self.cursor = self.cursorAtX(ui, ui.mousePosition().x);
                self.selection_anchor = null;
            } else if (ui.mouseDown(.left) and ui.input.active == self.root_node) {
                if (self.selection_anchor == null) self.selection_anchor = self.cursor;
                self.cursor = self.cursorAtX(ui, ui.mousePosition().x);
            }
        }

        if (focused and !self.focused_last_frame) {
            try self.snapshotOriginal();
            self.dirty = false;
            self.suppress_focus_loss_commit = false;
        } else if (!focused and self.focused_last_frame) {
            if (self.suppress_focus_loss_commit) {
                self.suppress_focus_loss_commit = false;
            } else if (self.dirty) {
                result.committed = true;
                self.dirty = false;
                try self.snapshotOriginal();
            }
        }

        if (focused) {
            var shift = keyAtStart(ui, .left_shift) or keyAtStart(ui, .right_shift);
            var command = keyAtStart(ui, .left_control) or keyAtStart(ui, .right_control) or
                keyAtStart(ui, .left_super) or keyAtStart(ui, .right_super);
            for (ui.keyboardEvents()) |event| switch (event) {
                .key_down => |key| {
                    updateModifier(key, true, &shift, &command);
                    const action = try self.handleKey(ui, key, shift, command, options);
                    result.changed = result.changed or action.changed;
                    result.committed = result.committed or action.committed;
                    result.cancelled = result.cancelled or action.cancelled;
                },
                .key_up => |key| updateModifier(key, false, &shift, &command),
                .text_input => |range| {
                    const bytes = ui.input.text_input[range.offset .. range.offset + range.len];
                    if (try self.insertFiltered(bytes, options)) {
                        result.changed = true;
                        self.dirty = true;
                    }
                },
            };
        }

        self.focused_last_frame = ui.isFocused(self.root_node);
        try self.syncVisuals(ui, options);
        return result;
    }

    fn handleKey(self: *TextField, ui: *app.Ui, key: @import("../platform/events.zig").Key, shift: bool, command: bool, options: Options) !TextFieldResult {
        var result: TextFieldResult = .{};
        switch (key) {
            .left => self.moveCursor(prevBoundary(self.buffer.items, self.cursor), shift),
            .right => self.moveCursor(nextBoundary(self.buffer.items, self.cursor), shift),
            .home => self.moveCursor(lineStart(self.buffer.items, self.cursor), shift),
            .end => self.moveCursor(lineEnd(self.buffer.items, self.cursor), shift),
            .backspace => if (try self.eraseBackward()) {
                result.changed = true;
                self.dirty = true;
            },
            .delete => if (try self.eraseForward()) {
                result.changed = true;
                self.dirty = true;
            },
            .a => if (command) self.selectAll(),
            .c => if (command) self.copySelection(ui),
            .x => if (command) {
                self.copySelection(ui);
                if (try self.eraseSelection()) {
                    result.changed = true;
                    self.dirty = true;
                }
            },
            .v => if (command) {
                if (try self.insertFiltered(ui.readClipboard(), options)) {
                    result.changed = true;
                    self.dirty = true;
                }
            },
            .escape => {
                try self.restoreOriginal();
                self.dirty = false;
                self.suppress_focus_loss_commit = true;
                ui.clearFocus();
                result.changed = true;
                result.cancelled = true;
            },
            .enter, .kp_enter => {
                if (!options.multiline or command) {
                    result.committed = true;
                    self.dirty = false;
                    try self.snapshotOriginal();
                    self.suppress_focus_loss_commit = true;
                    ui.clearFocus();
                } else if (try self.insertFiltered("\n", options)) {
                    result.changed = true;
                    self.dirty = true;
                }
            },
            else => {},
        }
        return result;
    }

    fn insertFiltered(self: *TextField, bytes: []const u8, options: Options) !bool {
        if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return false;
        self.scratch.clearRetainingCapacity();
        var index: usize = 0;
        while (index < bytes.len) {
            const start = index;
            const cp = text_mod.decodeNext(bytes, &index) orelse break;
            if (!allowedCodepoint(cp, options)) continue;
            try self.scratch.appendSlice(self.allocator, bytes[start..index]);
        }
        if (self.scratch.items.len == 0) return false;
        const selection_len = if (self.selectionRange()) |range| range.end - range.start else 0;
        const available = options.max_bytes -| (self.buffer.items.len - selection_len);
        const insert_len = utf8PrefixLen(self.scratch.items, available);
        if (insert_len == 0) return false;

        const replacement = self.selectionRange() orelse Range{ .start = self.cursor, .end = self.cursor };
        self.candidate.clearRetainingCapacity();
        try self.candidate.appendSlice(self.allocator, self.buffer.items[0..replacement.start]);
        try self.candidate.appendSlice(self.allocator, self.scratch.items[0..insert_len]);
        try self.candidate.appendSlice(self.allocator, self.buffer.items[replacement.end..]);
        if (!validInput(self.candidate.items, options.input_mode)) return false;

        _ = try self.eraseSelection();
        try self.buffer.ensureUnusedCapacity(self.allocator, insert_len);
        const old_len = self.buffer.items.len;
        self.buffer.items.len += insert_len;
        std.mem.copyBackwards(u8, self.buffer.items[self.cursor + insert_len .. old_len + insert_len], self.buffer.items[self.cursor..old_len]);
        @memcpy(self.buffer.items[self.cursor .. self.cursor + insert_len], self.scratch.items[0..insert_len]);
        self.cursor += insert_len;
        self.text_revision +%= 1;
        return true;
    }

    fn eraseBackward(self: *TextField) !bool {
        if (try self.eraseSelection()) return true;
        if (self.cursor == 0) return false;
        const start = prevBoundary(self.buffer.items, self.cursor);
        self.eraseRange(start, self.cursor);
        self.cursor = start;
        return true;
    }

    fn eraseForward(self: *TextField) !bool {
        if (try self.eraseSelection()) return true;
        if (self.cursor == self.buffer.items.len) return false;
        self.eraseRange(self.cursor, nextBoundary(self.buffer.items, self.cursor));
        return true;
    }

    fn eraseSelection(self: *TextField) !bool {
        const range = self.selectionRange() orelse {
            // A click-drag that ends where it began can leave an anchor with
            // no actual selection. Clear it before an insertion or deletion
            // moves the cursor, otherwise it becomes a stale out-of-bounds
            // selection on the edited buffer.
            self.selection_anchor = null;
            return false;
        };
        self.eraseRange(range.start, range.end);
        self.cursor = range.start;
        self.selection_anchor = null;
        return true;
    }

    fn eraseRange(self: *TextField, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer.items[start .. self.buffer.items.len - (end - start)], self.buffer.items[end..]);
        self.buffer.items.len -= end - start;
        self.text_revision +%= 1;
    }

    const Range = struct { start: usize, end: usize };
    fn selectionRange(self: *const TextField) ?Range {
        const raw_anchor = self.selection_anchor orelse return null;
        const anchor = @min(raw_anchor, self.buffer.items.len);
        const cursor = @min(self.cursor, self.buffer.items.len);
        if (anchor == cursor) return null;
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) };
    }

    fn copySelection(self: *const TextField, ui: *app.Ui) void {
        const range = self.selectionRange() orelse return;
        ui.writeClipboard(self.buffer.items[range.start..range.end]);
    }

    fn moveCursor(self: *TextField, next: usize, selecting: bool) void {
        if (selecting) {
            if (self.selection_anchor == null) self.selection_anchor = self.cursor;
        } else self.selection_anchor = null;
        self.cursor = next;
    }

    fn snapshotOriginal(self: *TextField) !void {
        self.original.clearRetainingCapacity();
        try self.original.appendSlice(self.allocator, self.buffer.items);
    }

    fn restoreOriginal(self: *TextField) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, self.original.items);
        self.text_revision +%= 1;
        self.cursor = self.buffer.items.len;
        self.selection_anchor = null;
    }

    fn cursorAtX(self: *TextField, ui: *app.Ui, pointer_x: f32) usize {
        const bounds = ui.bounds(self.root_node) orelse return self.cursor;
        const x = pointer_x - bounds.x - 8 + self.horizontal_scroll;
        self.ensureCaretStops(ui) catch return self.cursor;
        var best = self.caret_stops.items[0].index;
        var best_distance = @abs(x - self.caret_stops.items[0].x);
        for (self.caret_stops.items[1..]) |stop| {
            const distance = @abs(x - stop.x);
            if (distance < best_distance) {
                best = stop.index;
                best_distance = distance;
            }
        }
        return best;
    }

    fn ensureCaretStops(self: *TextField, ui: *app.Ui) !void {
        const atlas_ptr: ?*anyopaque = if (ui.font_atlas) |atlas| @ptrCast(atlas) else null;
        const font_size = ui.theme.font.body;
        if (self.caret_revision == self.text_revision and self.caret_font_size == font_size and self.caret_atlas == atlas_ptr) return;

        self.caret_stops.clearRetainingCapacity();
        try self.caret_stops.append(self.allocator, .{ .index = 0, .x = 0 });
        var index: usize = 0;
        var x: f32 = 0;
        var previous: ?u21 = null;
        while (index < self.buffer.items.len) {
            const codepoint = text_mod.decodeNext(self.buffer.items, &index) orelse break;
            switch (codepoint) {
                '\n' => {
                    x = 0;
                    previous = null;
                },
                '\t' => {
                    x += if (ui.font_atlas) |atlas| atlas.spaceAdvance(font_size) * 4 else text_mod.fallbackAdvance(font_size) * 4;
                    previous = null;
                },
                else => if (ui.font_atlas) |atlas| {
                    const advance = atlas.textAdvance(previous, codepoint, font_size);
                    x += advance.advance;
                    previous = advance.codepoint;
                } else {
                    x += text_mod.fallbackAdvance(font_size);
                    previous = codepoint;
                },
            }
            try self.caret_stops.append(self.allocator, .{ .index = index, .x = x });
        }
        self.caret_revision = self.text_revision;
        self.caret_font_size = font_size;
        self.caret_atlas = atlas_ptr;
    }

    fn xAtIndex(self: *TextField, ui: *app.Ui, target: usize) f32 {
        self.ensureCaretStops(ui) catch return measure(ui, self.buffer.items[0..@min(target, self.buffer.items.len)], ui.theme.font.body);
        // caret_stops is built in increasing index order, so the last stop at
        // or before `target` is one binary search rather than a scan from the
        // start of the buffer on every caret and selection sync.
        const stops = self.caret_stops.items;
        var low: usize = 0;
        var high: usize = stops.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (stops[mid].index <= target) low = mid + 1 else high = mid;
        }
        return if (low == 0) 0 else stops[low - 1].x;
    }

    fn syncVisuals(self: *TextField, ui: *app.Ui, options: Options) !void {
        const focused = ui.isFocused(self.root_node);
        const root = ui.tree.get(self.root_node) orelse return;
        const border = if (options.invalid) ui.theme.palette.danger else if (focused) ui.theme.palette.accent else ui.theme.palette.stroke;
        if (!std.meta.eql(root.style.border_color, border)) {
            root.style.border_color = border;
            dirty.markPaintDirty(&ui.tree, self.root_node);
        }
        try ui.setText(self.text_node, displayText(self, options));
        const text_node = ui.tree.get(self.text_node).?;
        const muted = self.buffer.items.len == 0 and !focused;
        const foreground = if (muted) ui.theme.palette.text_muted else ui.theme.palette.text;
        if (!std.meta.eql(text_node.style.foreground, foreground)) {
            text_node.style.foreground = foreground;
            dirty.markPaintDirty(&ui.tree, self.text_node);
        }

        const caret_x = if (focused or self.selectionRange() != null) self.xAtIndex(ui, self.cursor) else 0;
        const inner_width = @max(0, root.bounds.w - root.style.padding.horizontal());
        if (!focused) {
            // Display inactive values from the beginning. Keeping the caret at
            // the end is useful when editing, but must not make ordinary form
            // values look truncated before the user focuses the control.
            self.horizontal_scroll = 0;
        } else if (!options.multiline) {
            if (caret_x - self.horizontal_scroll > inner_width) self.horizontal_scroll = caret_x - inner_width;
            if (caret_x - self.horizontal_scroll < 0) self.horizontal_scroll = caret_x;
        } else self.horizontal_scroll = 0;
        var layout_changed = false;
        if (!options.multiline and root.bounds.h > 0) {
            const next_text_top = ui.centeredTextTop(root.bounds.h, ui.theme.font.body);
            if (text_node.style.margin.top != next_text_top) {
                text_node.style.margin.top = next_text_top;
                layout_changed = true;
            }
        }
        if (text_node.style.margin.left != -self.horizontal_scroll) {
            text_node.style.margin.left = -self.horizontal_scroll;
            layout_changed = true;
        }
        const caret = ui.tree.get(self.caret_node).?;
        if (!options.multiline and root.bounds.h > 0) {
            if (syncLineBox(ui, caret, root.bounds.h)) layout_changed = true;
        }
        if (caret.flags.visible != focused) {
            caret.flags.visible = focused;
            dirty.markPaintDirty(&ui.tree, self.caret_node);
        }
        if (caret.style.margin.left != caret_x - self.horizontal_scroll) {
            caret.style.margin.left = caret_x - self.horizontal_scroll;
            layout_changed = true;
        }

        const selection = ui.tree.get(self.selection_node).?;
        if (!options.multiline and root.bounds.h > 0) {
            if (syncLineBox(ui, selection, root.bounds.h)) layout_changed = true;
        }
        if (self.selectionRange()) |range| {
            const start_x = self.xAtIndex(ui, range.start);
            const end_x = self.xAtIndex(ui, range.end);
            if (!selection.flags.visible) {
                selection.flags.visible = true;
                dirty.markPaintDirty(&ui.tree, self.selection_node);
            }
            const selection_width: @TypeOf(selection.style.width) = .{ .px = end_x - start_x };
            if (selection.style.margin.left != start_x - self.horizontal_scroll or
                !std.meta.eql(selection.style.width, selection_width))
            {
                selection.style.margin.left = start_x - self.horizontal_scroll;
                selection.style.width = .{ .px = end_x - start_x };
                layout_changed = true;
            }
        } else if (selection.flags.visible) {
            selection.flags.visible = false;
            dirty.markPaintDirty(&ui.tree, self.selection_node);
        }
        if (layout_changed) dirty.markLayoutDirty(&ui.tree, self.root_node);
    }
};

/// Sizes a full-height overlay (the caret or the selection band) to one line of
/// body text, centred in the field. Returns true when the node moved, so the
/// caller can mark layout dirty once for the whole sync.
fn syncLineBox(ui: *app.Ui, node: *node_mod.Node, root_height: f32) bool {
    const line_height = ui.textLineHeight(ui.theme.font.body);
    const next_height: @TypeOf(node.style.height) = .{ .px = line_height };
    const next_top = ui.centeredTextTop(root_height, ui.theme.font.body);
    if (std.meta.eql(node.style.height, next_height) and node.style.margin.top == next_top) return false;
    node.style.height = next_height;
    node.style.margin.top = next_top;
    return true;
}

fn displayText(self: *const TextField, options: Options) []const u8 {
    return if (self.buffer.items.len == 0 and options.placeholder.len != 0) options.placeholder else self.buffer.items;
}

fn allowedCodepoint(codepoint: u21, options: Options) bool {
    if (options.input_mode == .text) {
        return codepoint >= 0x20 or (options.multiline and codepoint == '\n');
    }
    if (codepoint >= '0' and codepoint <= '9') return true;
    return switch (options.input_mode) {
        .text => unreachable,
        .signed_integer => codepoint == '+' or codepoint == '-',
        .unsigned_integer => false,
        .decimal => codepoint == '+' or codepoint == '-' or codepoint == '.' or codepoint == 'e' or codepoint == 'E',
    };
}

fn validInput(bytes: []const u8, mode: InputMode) bool {
    return switch (mode) {
        .text => true,
        .signed_integer => validInteger(bytes, true),
        .unsigned_integer => validInteger(bytes, false),
        .decimal => validDecimal(bytes),
    };
}

fn validInteger(bytes: []const u8, signed: bool) bool {
    var index: usize = 0;
    if (signed and bytes.len != 0 and (bytes[0] == '+' or bytes[0] == '-')) index = 1;
    while (index < bytes.len) : (index += 1) {
        if (!std.ascii.isDigit(bytes[index])) return false;
    }
    return true;
}

fn validDecimal(bytes: []const u8) bool {
    var index: usize = 0;
    if (index < bytes.len and (bytes[index] == '+' or bytes[index] == '-')) index += 1;

    var mantissa_digits: usize = 0;
    while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) mantissa_digits += 1;
    if (index < bytes.len and bytes[index] == '.') {
        index += 1;
        while (index < bytes.len and std.ascii.isDigit(bytes[index])) : (index += 1) mantissa_digits += 1;
    }
    if (index == bytes.len) return true;
    if (mantissa_digits == 0 or (bytes[index] != 'e' and bytes[index] != 'E')) return false;

    index += 1;
    if (index < bytes.len and (bytes[index] == '+' or bytes[index] == '-')) index += 1;
    while (index < bytes.len) : (index += 1) {
        if (!std.ascii.isDigit(bytes[index])) return false;
    }
    return true;
}

test "numeric input modes accept partial numeric syntax only" {
    try std.testing.expect(validInput("-", .signed_integer));
    try std.testing.expect(validInput("-42", .signed_integer));
    try std.testing.expect(!validInput("4.2", .signed_integer));
    try std.testing.expect(!validInput("-1", .unsigned_integer));
    try std.testing.expect(validInput("", .decimal));
    try std.testing.expect(validInput("-.", .decimal));
    try std.testing.expect(validInput(".5", .decimal));
    try std.testing.expect(validInput("1e-", .decimal));
    try std.testing.expect(validInput("1e-3", .decimal));
    try std.testing.expect(!validInput("e3", .decimal));
    try std.testing.expect(!validInput("1.2.3", .decimal));
}

fn measure(ui: *app.Ui, bytes: []const u8, size: f32) f32 {
    return if (ui.font_atlas) |atlas| atlas.measure(bytes, size).size.x else text_mod.measureFallback(bytes, size).size.x;
}

fn keyAtStart(ui: *const app.Ui, key: @import("../platform/events.zig").Key) bool {
    return ui.input.key_down_at_frame_start[@intFromEnum(key)];
}

fn updateModifier(key: @import("../platform/events.zig").Key, down: bool, shift: *bool, command: *bool) void {
    switch (key) {
        .left_shift, .right_shift => shift.* = down,
        .left_control, .right_control, .left_super, .right_super => command.* = down,
        else => {},
    }
}

fn prevBoundary(bytes: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var result = index - 1;
    while (result > 0 and bytes[result] & 0xc0 == 0x80) result -= 1;
    return result;
}

fn nextBoundary(bytes: []const u8, index: usize) usize {
    if (index >= bytes.len) return bytes.len;
    var result = index + 1;
    while (result < bytes.len and bytes[result] & 0xc0 == 0x80) result += 1;
    return result;
}

fn lineStart(bytes: []const u8, index: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..index], '\n')) |pos| pos + 1 else 0;
}

fn lineEnd(bytes: []const u8, index: usize) usize {
    return if (std.mem.indexOfScalar(u8, bytes[index..], '\n')) |pos| index + pos else bytes.len;
}

fn utf8PrefixLen(bytes: []const u8, maximum: usize) usize {
    var index: usize = 0;
    var last: usize = 0;
    while (index < bytes.len) {
        const next = nextBoundary(bytes, index);
        if (next > maximum) break;
        last = next;
        index = next;
    }
    return last;
}

test "UTF-8 boundaries step over whole codepoints" {
    const value = "aé🙂";
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(value, 0));
    try std.testing.expectEqual(@as(usize, 3), nextBoundary(value, 1));
    try std.testing.expectEqual(@as(usize, 7), nextBoundary(value, 3));
    try std.testing.expectEqual(@as(usize, 3), prevBoundary(value, 7));
    try std.testing.expectEqual(@as(usize, 1), prevBoundary(value, 3));
}

test "unfocused fields display from the beginning instead of the caret" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var field = try TextField.init(std.testing.allocator, &ui, ui.rootNode(), .{
        .text = "A value wider than its field",
        .width = .{ .px = 60 },
    });
    defer field.deinit(&ui);

    try ui.beginFrame(.{ .window_size = .{ .x = 100, .y = 50 } });
    _ = try field.update(&ui, .{});
    try std.testing.expectEqual(@as(f32, 0), field.horizontal_scroll);
}

test "single-line fields center text using font vertical metrics" {
    const font_atlas_mod = @import("../render/font_atlas.zig");
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/fonts/Inter-Regular.ttf", std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(font_bytes);
    var atlas = try font_atlas_mod.FontAtlas.init(std.testing.allocator, font_bytes, 256, 256);
    defer atlas.deinit();

    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    ui.setFontAtlas(&atlas);
    var field = try TextField.init(std.testing.allocator, &ui, ui.rootNode(), .{ .text = "Centered", .height = 32 });
    defer field.deinit(&ui);

    const expected_text_top = ui.centeredTextTop(32, ui.theme.font.body);
    const caret_top = (32 - atlas.lineHeight(ui.theme.font.body)) / 2;
    try std.testing.expectApproxEqAbs(expected_text_top, ui.nodeStyle(field.text_node).?.margin.top, 0.001);
    try std.testing.expectApproxEqAbs(caret_top, ui.nodeStyle(field.caret_node).?.margin.top, 0.001);
    // Text and caret occupy the same line box, so they share a top offset.
    try std.testing.expectApproxEqAbs(caret_top, expected_text_top, 0.001);
    // The line box sits wholly inside the field with equal room above and below.
    try std.testing.expect(expected_text_top > 0);
    try std.testing.expectApproxEqAbs(
        expected_text_top,
        32 - expected_text_top - atlas.lineHeight(ui.theme.font.body),
        0.001,
    );
}

test "deleting after a zero-width selection clears the stale anchor" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var field = try TextField.init(std.testing.allocator, &ui, ui.rootNode(), .{ .text = "1" });
    defer field.deinit(&ui);

    field.cursor = 1;
    field.selection_anchor = 1;
    try std.testing.expect(try field.eraseBackward());
    try std.testing.expectEqualStrings("", field.text());
    try std.testing.expect(field.selection_anchor == null);

    // Regression guard for the inspector crash: painting the edited field
    // must never slice the empty buffer with the old selection endpoint.
    try ui.beginFrame(.{ .window_size = .{ .x = 120, .y = 50 } });
    try field.syncVisuals(&ui, .{});
}

const TestClipboard = struct {
    storage: [64]u8 = undefined,
    len: usize = 0,

    fn interface(self: *TestClipboard) @import("../platform/events.zig").Clipboard {
        return .{ .context = self, .read_fn = read, .write_fn = write };
    }
    fn read(context: ?*anyopaque) []const u8 {
        const self: *TestClipboard = @ptrCast(@alignCast(context.?));
        return self.storage[0..self.len];
    }
    fn write(context: ?*anyopaque, bytes: []const u8) void {
        const self: *TestClipboard = @ptrCast(@alignCast(context.?));
        self.len = @min(bytes.len, self.storage.len);
        @memcpy(self.storage[0..self.len], bytes[0..self.len]);
    }
};

test "text field edits Unicode, commits, cancels, and captures text input" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var field = try TextField.init(std.testing.allocator, &ui, ui.rootNode(), .{ .text = "seed", .max_bytes = 32 });
    defer field.deinit(&ui);

    ui.requestFocus(field.root_node);
    try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 60 } });
    _ = try field.update(&ui, .{ .max_bytes = 32 });
    try ui.endFrame();
    try std.testing.expect(ui.inputCapture().wants_keyboard);
    try std.testing.expect(ui.inputCapture().wants_text_input);

    try ui.beginFrame(.{ .events = &.{.{ .text_input = "é🙂" }}, .window_size = .{ .x = 240, .y = 60 } });
    const inserted = try field.update(&ui, .{ .max_bytes = 32 });
    try std.testing.expect(inserted.changed);
    try std.testing.expectEqualStrings("seedé🙂", field.text());

    try ui.beginFrame(.{ .events = &.{ .{ .key_down = .left }, .{ .key_down = .backspace } }, .window_size = .{ .x = 240, .y = 60 } });
    _ = try field.update(&ui, .{ .max_bytes = 32 });
    try std.testing.expectEqualStrings("seed🙂", field.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.text()));

    try ui.beginFrame(.{ .events = &.{.{ .key_down = .escape }}, .window_size = .{ .x = 240, .y = 60 } });
    const cancelled = try field.update(&ui, .{ .max_bytes = 32 });
    try std.testing.expect(cancelled.cancelled);
    try std.testing.expectEqualStrings("seed", field.text());
}

test "clipboard shortcuts and paste maximum preserve UTF-8" {
    var clipboard: TestClipboard = .{};
    TestClipboard.write(&clipboard, "é🙂tail");
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var field = try TextField.init(std.testing.allocator, &ui, ui.rootNode(), .{ .max_bytes = 5 });
    defer field.deinit(&ui);
    ui.requestFocus(field.root_node);
    try ui.beginFrame(.{
        .events = &.{ .{ .key_down = .left_control }, .{ .key_down = .v } },
        .window_size = .{ .x = 200, .y = 50 },
        .clipboard = clipboard.interface(),
    });
    _ = try field.update(&ui, .{ .max_bytes = 5 });
    try std.testing.expectEqualStrings("é", field.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(field.text()));
}

test "single and multiline commit rules and focus loss are one-shot" {
    var ui = try app.Ui.init(std.testing.allocator);
    defer ui.deinit();
    var field = try TextField.init(std.testing.allocator, &ui, ui.rootNode(), .{ .multiline = true, .height = 80 });
    defer field.deinit(&ui);
    ui.requestFocus(field.root_node);
    try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 100 } });
    _ = try field.update(&ui, .{ .multiline = true, .height = 80 });

    try ui.beginFrame(.{ .events = &.{.{ .key_down = .enter }}, .window_size = .{ .x = 240, .y = 100 } });
    const newline = try field.update(&ui, .{ .multiline = true, .height = 80 });
    try std.testing.expect(newline.changed);
    try std.testing.expect(!newline.committed);
    try std.testing.expectEqualStrings("\n", field.text());

    try ui.beginFrame(.{ .events = &.{ .{ .key_down = .left_super }, .{ .key_down = .enter } }, .window_size = .{ .x = 240, .y = 100 } });
    const submitted = try field.update(&ui, .{ .multiline = true, .height = 80 });
    try std.testing.expect(submitted.committed);

    ui.requestFocus(field.root_node);
    try ui.beginFrame(.{ .events = &.{.{ .text_input = "x" }}, .window_size = .{ .x = 240, .y = 100 } });
    _ = try field.update(&ui, .{ .multiline = true, .height = 80 });
    const button = try ui.createNode(.button);
    try ui.tree.appendChild(ui.rootNode(), button);
    ui.requestFocus(button);
    try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 100 } });
    const blur = try field.update(&ui, .{ .multiline = true, .height = 80 });
    try std.testing.expect(blur.committed);
    try ui.beginFrame(.{ .window_size = .{ .x = 240, .y = 100 } });
    const next = try field.update(&ui, .{ .multiline = true, .height = 80 });
    try std.testing.expect(!next.committed);
}
