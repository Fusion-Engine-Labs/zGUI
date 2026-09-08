const std = @import("std");
const types = @import("types.zig");

pub const replacement_codepoint: u21 = 0xfffd;

pub const TextMetrics = struct {
    size: types.Vec2 = .{},
    line_height: f32 = 0,
};

pub const Utf8Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Utf8Iterator {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Utf8Iterator) ?u21 {
        return decodeNext(self.bytes, &self.index);
    }
};

/// Per-character advance used when no font atlas is available. Anything that
/// has to reproduce the fallback metrics asks for it here rather than restating
/// the ratio.
pub fn fallbackAdvance(size: f32) f32 {
    return size * 0.55;
}

pub fn measureFallback(bytes: []const u8, size: f32) TextMetrics {
    const advance = fallbackAdvance(size);
    const line_height = size * 1.25;
    var current_width: f32 = 0;
    var max_width: f32 = 0;
    var line_count: u32 = 1;

    var it = Utf8Iterator.init(bytes);
    while (it.next()) |codepoint| {
        switch (codepoint) {
            '\n' => {
                max_width = @max(max_width, current_width);
                current_width = 0;
                line_count += 1;
            },
            '\t' => current_width += advance * 4,
            else => current_width += advance,
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

pub fn decodeNext(bytes: []const u8, index: *usize) ?u21 {
    if (index.* >= bytes.len) return null;

    const start = index.*;
    const first = bytes[start];
    if (first < 0x80) {
        index.* += 1;
        return @intCast(first);
    }

    if (first >= 0xc2 and first <= 0xdf) {
        if (hasContinuation(bytes, start, 1)) {
            index.* += 2;
            return (@as(u21, first & 0x1f) << 6) |
                @as(u21, bytes[start + 1] & 0x3f);
        }
        index.* += 1;
        return replacement_codepoint;
    }

    if (first >= 0xe0 and first <= 0xef) {
        if (validThreeByte(bytes, start, first)) {
            index.* += 3;
            return (@as(u21, first & 0x0f) << 12) |
                (@as(u21, bytes[start + 1] & 0x3f) << 6) |
                @as(u21, bytes[start + 2] & 0x3f);
        }
        index.* += 1;
        return replacement_codepoint;
    }

    if (first >= 0xf0 and first <= 0xf4) {
        if (validFourByte(bytes, start, first)) {
            index.* += 4;
            return (@as(u21, first & 0x07) << 18) |
                (@as(u21, bytes[start + 1] & 0x3f) << 12) |
                (@as(u21, bytes[start + 2] & 0x3f) << 6) |
                @as(u21, bytes[start + 3] & 0x3f);
        }
        index.* += 1;
        return replacement_codepoint;
    }

    index.* += 1;
    return replacement_codepoint;
}

fn hasContinuation(bytes: []const u8, start: usize, count: usize) bool {
    if (start + count >= bytes.len) return false;
    var i: usize = 1;
    while (i <= count) : (i += 1) {
        if (!isContinuation(bytes[start + i])) return false;
    }
    return true;
}

fn validThreeByte(bytes: []const u8, start: usize, first: u8) bool {
    if (!hasContinuation(bytes, start, 2)) return false;
    const second = bytes[start + 1];
    return switch (first) {
        0xe0 => second >= 0xa0 and second <= 0xbf,
        0xed => second >= 0x80 and second <= 0x9f,
        else => true,
    };
}

fn validFourByte(bytes: []const u8, start: usize, first: u8) bool {
    if (!hasContinuation(bytes, start, 3)) return false;
    const second = bytes[start + 1];
    return switch (first) {
        0xf0 => second >= 0x90 and second <= 0xbf,
        0xf4 => second >= 0x80 and second <= 0x8f,
        else => true,
    };
}

fn isContinuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

test "utf8 iterator decodes valid ascii and multibyte codepoints" {
    var it = Utf8Iterator.init("A\xc3\xa9\xf0\x9f\x98\x80");
    try std.testing.expectEqual(@as(?u21, 'A'), it.next());
    try std.testing.expectEqual(@as(?u21, 0x00e9), it.next());
    try std.testing.expectEqual(@as(?u21, 0x1f600), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
}

test "utf8 iterator replaces invalid sequences" {
    var it = Utf8Iterator.init("\xc0\xaf\xe0\x80\x80\xf4\x90\x80\x80");
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, replacement_codepoint), it.next());
    try std.testing.expectEqual(@as(?u21, null), it.next());
}

test "fallback measurement handles tabs and newlines" {
    const metrics = measureFallback("ab\tc\nde", 10);
    try std.testing.expectEqual(@as(f32, 10 * 0.55 * 7), metrics.size.x);
    try std.testing.expectEqual(@as(f32, 25), metrics.size.y);
    try std.testing.expectEqual(@as(f32, 12.5), metrics.line_height);
}
