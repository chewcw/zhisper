const std = @import("std");
const notify = @import("notify.zig");
const tray = @import("tray_windows.zig");

/// Windows notification backend: a Shell balloon on the tray icon. There is no
/// separate notification service to talk to, and WinRT toasts would mean
/// writing a Start Menu shortcut and registry entries at runtime.
pub fn check(_: std.Io) notify.Availability {
    if (tray.notifyLive()) {
        return .{ .available = true, .tool = "Shell_NotifyIconW" };
    }
    // The whole reason this backend can be unavailable: a balloon must hang off
    // an icon that is already in the tray.
    return .{
        .available = false,
        .tool = null,
        .hint = "Windows shows notifications through the tray icon — set daemon.tray = true",
    };
}

pub fn show(io: std.Io, msg: notify.Message) !void {
    _ = io;
    return tray.notify(msg);
}

test "check blames the tray when no icon exists" {
    // A test build never calls tray.setup(), so notifyLive() is false — which
    // is exactly the case a Windows user hits with daemon.tray = false. The
    // hint is the only thing standing between them and a silent no-op, so it
    // has to name the fix.
    const avail = check(std.testing.io);
    try std.testing.expect(!avail.available);
    try std.testing.expect(std.mem.indexOf(u8, avail.hint.?, "daemon.tray = true") != null);
}
