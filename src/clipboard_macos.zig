const std = @import("std");
const clipboard = @import("clipboard.zig");

/// macOS clipboard backend: probes `pbcopy`, pastes via `pbcopy` stdin.
/// Pure Zig so it parses on all targets.

fn probe(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    defer child.kill(io);
    const term = child.wait(io) catch return false;
    if (term != .exited) return false;
    return term.exited == 0;
}

pub fn check(gpa: std.mem.Allocator, io: std.Io) clipboard.Clipboard {
    _ = gpa;
    if (probe(io, &.{ "which", "pbcopy" })) return .{ .available = true, .tool = "pbcopy" };
    return .{ .available = false, .tool = null };
}

pub fn paste(text: []const u8, io: std.Io, clipboard_state: clipboard.Clipboard) !void {
    if (!clipboard_state.available or clipboard_state.tool == null) return error.ClipboardNotAvailable;
    if (!std.mem.eql(u8, clipboard_state.tool.?, "pbcopy")) return error.ClipboardNotAvailable;

    var child = std.process.spawn(io, .{
        .argv = &.{ "pbcopy" },
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
