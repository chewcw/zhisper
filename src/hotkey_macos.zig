const types = @import("hotkey_types.zig");

pub fn setup(_: types.HotkeyConfig) !void {
    return error.UnsupportedOs;
}

pub fn pollEvent() ?types.KeyEvent {
    return null;
}

pub fn modifiersHeld() bool {
    return false;
}

pub fn destroy() void {}

test "setup reports UnsupportedOs until the native hook lands" {
    const std = @import("std");
    try std.testing.expectError(error.UnsupportedOs, setup(.{ .shortcut = .{ .raw_code = 0 }, .cancel = .{ .raw_code = 0 } }));
}
