const std = @import("std");
const types = @import("overlay_types.zig");

var queue: [16]types.Event = undefined;
var queue_len: usize = 0;
var queue_pos: usize = 0;
var last_state: ?types.State = null;
var last_move: ?types.Position = null;
var shown: bool = false;

pub fn pushTestEvent(ev: types.Event) void {
    std.debug.assert(queue_len < queue.len);
    queue[queue_len] = ev;
    queue_len += 1;
}

pub fn reset() void {
    queue_len = 0;
    queue_pos = 0;
    last_state = null;
    last_move = null;
    shown = false;
}

pub fn setup(_: types.OverlayConfig) !void {
    reset();
}

pub fn show() !void {
    shown = true;
}

pub fn hide() void {
    shown = false;
}

pub fn move(pos: types.Position) void {
    last_move = pos;
}

pub fn setState(s: types.State) void {
    last_state = s;
}

/// Headless/tests: no monitors. The SDL backend (Task 5) enumerates real
/// displays; the caller owns the returned slice.
pub fn displayList(gpa: std.mem.Allocator) ![]types.Display {
    return try gpa.alloc(types.Display, 0);
}

pub fn pollEvent() ?types.Event {
    if (queue_pos >= queue_len) return null;
    const ev = queue[queue_pos];
    queue_pos += 1;
    return ev;
}

pub fn destroy() void {
    reset();
}

pub fn testLastState() ?types.State {
    return last_state;
}

pub fn testLastMove() ?types.Position {
    return last_move;
}

pub fn testShown() bool {
    return shown;
}

test "stub replays drag events and records state" {
    reset();
    defer reset();
    pushTestEvent(.{ .drag_start = .{ .x = 1, .y = 2 } });
    pushTestEvent(.{ .drag_end = .{ .x = 10, .y = 20 } });
    try std.testing.expectEqual(1, pollEvent().?.drag_start.x);
    try std.testing.expectEqual(20, pollEvent().?.drag_end.y);
    try std.testing.expect(pollEvent() == null);
    try show();
    try std.testing.expect(testShown());
    setState(.recording);
    try std.testing.expectEqual(types.State.recording, testLastState().?);
    move(.{ .x = 5, .y = 6 });
    try std.testing.expectEqual(5, testLastMove().?.x);
    const ds = try displayList(std.testing.allocator);
    defer std.testing.allocator.free(ds);
    try std.testing.expectEqual(@as(usize, 0), ds.len);
}
