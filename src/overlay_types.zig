const std = @import("std");

pub const window_size: i32 = 72;
pub const ball_radius: i32 = 36;

pub const Position = struct { x: i32, y: i32 };
pub const State = enum { idle, recording, working };
pub const Event = union(enum) {
    drag_start: Position,
    drag_moved: Position,
    drag_end: Position,
};
pub const OverlayConfig = struct {};

pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// One monitor in global desktop coordinates (may be negative on
/// multi-monitor layouts; primary is usually at 0,0 but never assume it).
pub const Display = struct { x: i32, y: i32, w: i32, h: i32 };

pub fn stateTint(s: State) Rgba {
    return switch (s) {
        .idle => .{ .r = 0x99, .g = 0x99, .b = 0x99, .a = 230 },
        .recording => .{ .r = 0xE0, .g = 0x3B, .b = 0x30, .a = 230 },
        .working => .{ .r = 0xE0, .g = 0xA0, .b = 0x20, .a = 230 },
    };
}

/// Window-local coords (0..72). True inside the inscribed circle (radius 36).
pub fn hitTestCircle(lx: i32, ly: i32) bool {
    const dx = lx - ball_radius;
    const dy = ly - ball_radius;
    return dx * dx + dy * dy <= ball_radius * ball_radius;
}

pub fn clampPosition(p: Position, display_w: i32, display_h: i32) Position {
    return clampToDisplay(p, .{ .x = 0, .y = 0, .w = display_w, .h = display_h });
}

pub fn defaultPosition(display_w: i32, display_h: i32) Position {
    return clampPosition(.{ .x = display_w - 100, .y = display_h - 100 }, display_w, display_h);
}

/// Parses "x y\n" (surrounding whitespace tolerated). Null on corrupt input.
pub fn parsePosition(text: []const u8) ?Position {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const xs = it.next() orelse return null;
    const ys = it.next() orelse return null;
    if (it.next() != null) return null;
    const x = std.fmt.parseInt(i32, xs, 10) catch return null;
    const y = std.fmt.parseInt(i32, ys, 10) catch return null;
    return .{ .x = x, .y = y };
}

pub fn formatPosition(buf: []u8, p: Position) ![]u8 {
    return try std.fmt.bufPrint(buf, "{d} {d}\n", .{ p.x, p.y });
}

/// Global desktop coords: negative x/y are valid second-monitor positions,
/// so visibility is tested per-display, never against a single origin.
fn ballCenter(p: Position) Position {
    return .{ .x = p.x + ball_radius, .y = p.y + ball_radius };
}

/// Index of the display containing the ball center, or null (unplugged /
/// off-screen / headless). The center (not the corner) decides, so a ball
/// straddling a bezel sticks to the monitor holding most of it.
pub fn findDisplayFor(p: Position, displays: []const Display) ?usize {
    const c = ballCenter(p);
    for (displays, 0..) |d, i| {
        if (c.x >= d.x and c.x < d.x + d.w and c.y >= d.y and c.y < d.y + d.h) return i;
    }
    return null;
}

pub fn isVisible(p: Position, displays: []const Display) bool {
    return findDisplayFor(p, displays) != null;
}

/// Bottom-right inset of the first display (primary first — the backend
/// lists it first); safe (64,64) corner when headless.
pub fn defaultForDisplays(displays: []const Display) Position {
    if (displays.len == 0) return .{ .x = 64, .y = 64 };
    const d = displays[0];
    return clampToDisplay(.{ .x = d.x + d.w - 100, .y = d.y + d.h - 100 }, d);
}

/// Clamp inside one display rect (which may start at negative coords).
pub fn clampToDisplay(p: Position, d: Display) Position {
    const min_x = d.x;
    const min_y = d.y;
    const max_x: i32 = @max(d.x, d.x + d.w - window_size);
    const max_y: i32 = @max(d.y, d.y + d.h - window_size);
    return .{ .x = std.math.clamp(p.x, min_x, max_x), .y = std.math.clamp(p.y, min_y, max_y) };
}

test "state tints are distinct and opaque-ish" {
    const idle = stateTint(.idle);
    const rec = stateTint(.recording);
    const work = stateTint(.working);
    try std.testing.expect(!std.meta.eql(idle, rec));
    try std.testing.expect(!std.meta.eql(idle, work));
    try std.testing.expect(!std.meta.eql(rec, work));
    for ([_]Rgba{ idle, rec, work }) |t| try std.testing.expect(t.a >= 200);
}

test "hit-test accepts center and rim, rejects corners" {
    try std.testing.expect(hitTestCircle(36, 36));
    try std.testing.expect(hitTestCircle(36 + 36, 36));
    try std.testing.expect(!hitTestCircle(36 + 36, 36 + 1));
    try std.testing.expect(!hitTestCircle(0, 0));
    try std.testing.expect(!hitTestCircle(71, 71));
}

test "clamp keeps the 72px window on-display" {
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, clampPosition(.{ .x = -5, .y = -9 }, 800, 600));
    try std.testing.expectEqual(Position{ .x = 728, .y = 528 }, clampPosition(.{ .x = 9999, .y = 9999 }, 800, 600));
    try std.testing.expectEqual(Position{ .x = 100, .y = 100 }, clampPosition(.{ .x = 100, .y = 100 }, 800, 600));
}

test "default position is bottom-right inset" {
    try std.testing.expectEqual(Position{ .x = 700, .y = 500 }, defaultPosition(800, 600));
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, defaultPosition(50, 50));
}

test "position file round-trips, corrupt input rejected" {
    var buf: [32]u8 = undefined;
    const text = try formatPosition(&buf, .{ .x = 700, .y = 500 });
    try std.testing.expectEqualStrings("700 500\n", text);
    try std.testing.expectEqual(Position{ .x = 700, .y = 500 }, parsePosition(text).?);
    try std.testing.expect(parsePosition("oops\n") == null);
    try std.testing.expect(parsePosition("1 2 3\n") == null);
    try std.testing.expect(parsePosition("") == null);
}

test "multi-monitor: center decides visibility, unplugged falls back" {
    const left = Display{ .x = -1920, .y = 0, .w = 1920, .h = 1080 };
    const primary = Display{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const both = [_]Display{ primary, left };
    // Ball center on the left monitor counts as visible there.
    try std.testing.expectEqual(@as(?usize, 1), findDisplayFor(.{ .x = -1920 + 100, .y = 100 }, &both));
    try std.testing.expectEqual(@as(?usize, 0), findDisplayFor(.{ .x = 100, .y = 100 }, &both));
    try std.testing.expect(isVisible(.{ .x = -1850, .y = 100 }, &both));
    // Saved position from an unplugged monitor is not visible anywhere.
    try std.testing.expect(!isVisible(.{ .x = 5000, .y = 100 }, &both));
    try std.testing.expect(findDisplayFor(.{ .x = 5000, .y = 100 }, &both) == null);
    // Empty display list (headless): nothing visible, default to safe corner.
    try std.testing.expect(!isVisible(.{ .x = 100, .y = 100 }, &.{}));
    try std.testing.expectEqual(Position{ .x = 64, .y = 64 }, defaultForDisplays(&.{}));
    try std.testing.expectEqual(Position{ .x = 1820, .y = 980 }, defaultForDisplays(&both));
}
