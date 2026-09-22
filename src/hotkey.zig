const std = @import("std");
const builtin = @import("builtin");
const types = @import("hotkey_types.zig");

pub const KeyEvent = types.KeyEvent;
pub const Mode = types.Mode;
pub const HotkeyConfig = types.HotkeyConfig;

const impl = if (builtin.is_test)
    @import("hotkey_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("hotkey_linux.zig"),
    .windows => @import("hotkey_windows.zig"),
    .macos => @import("hotkey_macos.zig"),
    else => @compileError("hotkey: unsupported OS"),
};

pub fn setup(config: HotkeyConfig) !void {
    return impl.setup(config);
}

pub fn pollEvent() ?KeyEvent {
    return impl.pollEvent();
}

pub fn destroy() void {
    return impl.destroy();
}

test "facade replays stub events in order" {
    const stub = @import("hotkey_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(.{ .key_code = 30, .mode = .hold });
    stub.pushTestEvent(.hotkey_pressed);
    stub.pushTestEvent(.hotkey_released);
    stub.pushTestEvent(.cancel_pressed);
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    try std.testing.expectEqual(KeyEvent.hotkey_released, pollEvent().?);
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
    destroy();
}
