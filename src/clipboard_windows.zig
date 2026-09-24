const std = @import("std");
const clipboard = @import("clipboard.zig");

/// Windows clipboard backend: `clip` ships with Windows, always available.
/// Paste via `clip` stdin. Pure Zig so it cross-compiles from Linux.

pub fn check(io: std.Io) clipboard.Clipboard {
    _ = io;
    return .{ .available = true, .tool = "clip" };
}

pub fn paste(text: []const u8, io: std.Io, clipboard_state: clipboard.Clipboard) !void {
    if (!clipboard_state.available or clipboard_state.tool == null) return error.ClipboardNotAvailable;
    if (!std.mem.eql(u8, clipboard_state.tool.?, "clip")) return error.ClipboardNotAvailable;

    var child = std.process.spawn(io, .{
        .argv = &.{ "clip" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.ClipboardPasteFailed;
    defer child.kill(io);

    const stdin = child.stdin orelse return error.ClipboardPasteFailed;
    stdin.writeStreamingAll(io, text) catch return error.ClipboardPasteFailed;
    stdin.close(io);
    child.stdin = null;

    const term = child.wait(io) catch return error.ClipboardPasteFailed;
    if (term != .exited or term.exited != 0) return error.ClipboardPasteFailed;
}
