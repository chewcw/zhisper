const std = @import("std");

pub const window_size: i32 = 72;
pub const ball_radius: i32 = 36;
pub const window_w: i32 = 240;
pub const window_h: i32 = 72; // == window_size (height alias)
pub const orb_r: i32 = 34;
const morph_ms: u64 = 200;

pub fn breatheRadius(t_ms: u64) f32 {
    const t: f32 = @as(f32, @floatFromInt(t_ms)) / 2400.0;
    return @as(f32, @floatFromInt(orb_r)) + 2.0 * @sin(t * 2.0 * std.math.pi);
}

pub fn morphProgress(elapsed_ms: u64) f32 {
    if (elapsed_ms >= morph_ms) return 1.0;
    const e: f32 = @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(morph_ms));
    const u: f32 = 1.0 - e;
    return 1.0 - u * u * u; // ease-out cubic
}

pub fn waveBar(t_ms: u64, i: usize) f32 {
    const t: f32 = @floatFromInt(t_ms);
    const k: f32 = @floatFromInt(i);
    const a: f32 = t / 180.0 + k * 0.9;
    const b: f32 = t / 97.0 + k * 1.7;
    const v: f32 = 0.5 + 0.28 * @sin(a) + 0.22 * @sin(b);
    return std.math.clamp(v, 0.0, 1.0);
}

pub fn spinnerAngle(t_ms: u64) f32 {
    const frac: f32 = @as(f32, @floatFromInt(t_ms % 1000)) / 1000.0;
    return frac * 2.0 * std.math.pi;
}

/// Stadium hit-test: rect x in [36,204) full height, plus end circles
/// at (36,36) and (204,36) radius 36. Corners outside both are rejected.
pub fn hitTestPill(lx: i32, ly: i32) bool {
    if (lx < 0 or ly < 0 or lx >= window_w or ly >= window_h) return false;
    if (lx >= ball_radius and lx < window_w - ball_radius) return true;
    const cx: i32 = if (lx < ball_radius) ball_radius else window_w - ball_radius;
    const dx = lx - cx;
    const dy = ly - ball_radius;
    return dx * dx + dy * dy <= ball_radius * ball_radius;
}

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
    const max_x: i32 = @max(d.x, d.x + d.w - window_w);
    const max_y: i32 = @max(d.y, d.y + d.h - window_h);
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
    try std.testing.expectEqual(Position{ .x = 560, .y = 528 }, clampPosition(.{ .x = 9999, .y = 9999 }, 800, 600));
    try std.testing.expectEqual(Position{ .x = 100, .y = 100 }, clampPosition(.{ .x = 100, .y = 100 }, 800, 600));
}

test "default position is bottom-right inset" {
    try std.testing.expectEqual(Position{ .x = 560, .y = 500 }, defaultPosition(800, 600));
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
    try std.testing.expectEqual(Position{ .x = 1680, .y = 980 }, defaultForDisplays(&both));
}

test "animation math bounds and determinism" {
    // breathe in [32,36]
    const r0 = breatheRadius(0);
    const r600 = breatheRadius(600);
    const r1200 = breatheRadius(1200);
    for ([_]f32{ r0, r600, r1200 }) |r| {
        try std.testing.expect(r >= 32.0 and r <= 36.0);
    }
    try std.testing.expect(r0 != r600);
    // morph 0 -> 1 over 200ms, monotonic
    try std.testing.expectEqual(@as(f32, 0.0), morphProgress(0));
    const m50 = morphProgress(50);
    const m150 = morphProgress(150);
    try std.testing.expect(m50 > 0.0 and m50 < m150 and m150 < 1.0);
    try std.testing.expectEqual(@as(f32, 1.0), morphProgress(200));
    try std.testing.expectEqual(@as(f32, 1.0), morphProgress(5000));
    // wave deterministic + in [0,1]
    try std.testing.expectEqual(waveBar(1000, 2), waveBar(1000, 2));
    try std.testing.expect(waveBar(1000, 0) != waveBar(1000, 1));
    for (0..5) |i| {
        const w = waveBar(1234, i);
        try std.testing.expect(w >= 0.0 and w <= 1.0);
    }
    // spinner wraps every 1000ms
    try std.testing.expectApproxEqAbs(spinnerAngle(0), spinnerAngle(1000), 1e-5);
    try std.testing.expect(spinnerAngle(250) > spinnerAngle(0));
}

test "hitTestPill accepts orb and capsule, rejects corners" {
    try std.testing.expect(hitTestPill(36, 36)); // orb center
    try std.testing.expect(hitTestPill(120, 36)); // capsule middle
    try std.testing.expect(hitTestPill(204, 36)); // right end center
    try std.testing.expect(!hitTestPill(0, 0)); // top-left corner cutout
    try std.testing.expect(!hitTestPill(239, 0)); // top-right corner cutout
    try std.testing.expect(!hitTestPill(0, 71));
    try std.testing.expect(!hitTestPill(239, 71));
}
