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

pub fn modifiersHeld() bool {
    return impl.modifiersHeld();
}

pub fn destroy() void {
    return impl.destroy();
}

test "facade replays stub events in order" {
    const stub = @import("hotkey_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(.{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .mode = .hold });
    stub.pushTestEvent(.hotkey_pressed);
    stub.pushTestEvent(.hotkey_released);
    stub.pushTestEvent(.cancel_pressed);
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    try std.testing.expectEqual(KeyEvent.hotkey_released, pollEvent().?);
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
    destroy();
}

test "facade replays stub search events in order" {
    const stub = @import("hotkey_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(.{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .search = .{ .raw_code = 65 }, .mode = .hold });
    stub.pushTestEvent(.search_pressed);
    stub.pushTestEvent(.search_released);
    try std.testing.expectEqual(KeyEvent.search_pressed, pollEvent().?);
    try std.testing.expectEqual(KeyEvent.search_released, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
    destroy();
}

test "facade reports the modifier state the stub holds" {
    const stub = @import("hotkey_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(.{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 } });
    stub.setModifiersHeldForTest(true);
    try std.testing.expect(modifiersHeld());
    stub.setModifiersHeldForTest(false);
    try std.testing.expect(!modifiersHeld());
    destroy();
}
