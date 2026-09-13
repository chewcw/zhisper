const std = @import("std");

/// Single vocabulary for both directions: the hotkey listener reports a
/// KeyEvent, the typer consumes one. Pure Zig, no OS headers — safe on all
/// targets, including test builds.
pub const KeyEvent = enum { pressed, released };
pub const Mode = enum { hold, toggle };
pub const HotkeyConfig = struct { key_code: u16, mode: Mode = .hold };

test "default mode is hold" {
    const cfg = HotkeyConfig{ .key_code = 16 };
    try std.testing.expectEqual(Mode.hold, cfg.mode);
}
