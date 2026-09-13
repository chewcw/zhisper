const std = @import("std");
const types = @import("hotkey_types.zig");

var queue: [16]types.KeyEvent = undefined;
var queue_len: usize = 0;
var queue_pos: usize = 0;

pub fn pushTestEvent(ev: types.KeyEvent) void {
    std.debug.assert(queue_len < queue.len);
    queue[queue_len] = ev;
    queue_len += 1;
}

pub fn reset() void {
    queue_len = 0;
    queue_pos = 0;
}

pub fn setup(_: types.HotkeyConfig) !void {
    reset();
}

pub fn pollEvent() ?types.KeyEvent {
    if (queue_pos >= queue_len) return null;
    const ev = queue[queue_pos];
    queue_pos += 1;
    return ev;
}

pub fn destroy() void {
    reset();
}

test "stub replays queued press and release then null" {
    reset();
    defer reset();
    pushTestEvent(.pressed);
    pushTestEvent(.released);
    try std.testing.expectEqual(types.KeyEvent.pressed, pollEvent().?);
    try std.testing.expectEqual(types.KeyEvent.released, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
}
