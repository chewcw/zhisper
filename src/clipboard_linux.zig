const std = @import("std");
const clipboard = @import("clipboard.zig");

/// Linux clipboard backend: probes `xclip` then `wl-copy` via `which`,
/// pastes by spawning the tool with stdin piped. Pure Zig, no @cImport.

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
    if (probe(io, &.{ "which", "xclip" })) return .{ .available = true, .tool = "xclip" };
    if (probe(io, &.{ "which", "wl-copy" })) return .{ .available = true, .tool = "wl-copy" };
    return .{ .available = false, .tool = null };
}

pub fn paste(text: []const u8, io: std.Io, clipboard_state: clipboard.Clipboard) !void {
    if (!clipboard_state.available or clipboard_state.tool == null) return error.ClipboardNotAvailable;
    const tool = clipboard_state.tool.?;
    const argv: []const []const u8 = if (std.mem.eql(u8, tool, "xclip"))
        &.{ "xclip", "-selection", "clipboard", "-in" }
    else if (std.mem.eql(u8, tool, "wl-copy"))
        &.{ "wl-copy" }
    else
        return error.ClipboardNotAvailable;

    var child = std.process.spawn(io, .{
        .argv = argv,
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
