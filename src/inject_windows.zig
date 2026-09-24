const std = @import("std");
const clipboard = @import("clipboard.zig");
const log = @import("log.zig");

/// Cached probe from setup() for the clipboard path.
var clipboard_state: clipboard.Clipboard = .{ .available = false, .tool = null };

/// True when text contains multi-byte UTF-8 (any byte > 0x7F).
pub fn needsClipboard(text: []const u8) bool {
    for (text) |b| if (b > 0x7F) return true;
    return false;
}

pub fn setup(io: std.Io) !void {
    clipboard_state = clipboard.check(std.heap.page_allocator, io);
    if (!clipboard_state.available) log.warn("Clipboard unavailable — non-ASCII injection disabled");
    return error.UnsupportedOs;
}

pub fn typeText(text: []const u8, io: std.Io) !usize {
    if (needsClipboard(text)) {
        try clipboard.paste(text, io, clipboard_state);
        return text.len;
    }
    return error.UnsupportedOs;
}

pub fn destroy() void {}

test "setup reports UnsupportedOs until the native typer lands" {
    try std.testing.expectError(error.UnsupportedOs, setup(std.testing.io));
}

test "needsClipboard detects multi-byte UTF-8" {
    try std.testing.expect(needsClipboard("你"));
    try std.testing.expect(!needsClipboard("hi"));
}
