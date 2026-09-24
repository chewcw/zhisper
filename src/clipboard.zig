const std = @import("std");
const builtin = @import("builtin");

/// Clipboard availability probe result. `tool` is the binary name
/// (e.g. "xclip", "wl-copy", "pbcopy", "clip") or null when unavailable.
pub const Clipboard = struct {
    available: bool,
    tool: ?[]const u8,
};

const impl = if (builtin.is_test)
    struct {
        pub fn check(_: std.mem.Allocator, _: std.Io) Clipboard {
            return .{ .available = false, .tool = null };
        }
        pub fn paste(_: []const u8, _: std.Io, _: Clipboard) !void {
            return error.ClipboardNotImplemented;
        }
    }
else switch (builtin.os.tag) {
    .linux => @import("clipboard_linux.zig"),
    .macos => @import("clipboard_macos.zig"),
    .windows => @import("clipboard_windows.zig"),
    else => @compileError("clipboard: unsupported OS"),
};

pub fn check(gpa: std.mem.Allocator, io: std.Io) Clipboard {
    return impl.check(gpa, io);
}

pub fn paste(text: []const u8, io: std.Io, clipboard_state: Clipboard) !void {
    return impl.paste(text, io, clipboard_state);
}

test "clipboard stub detects missing tool" {
    const c = check(std.testing.allocator, std.testing.io);
    try std.testing.expect(!c.available);
    try std.testing.expect(c.tool == null);
}

test "paste stub returns not implemented" {
    const c = check(std.testing.allocator, std.testing.io);
    try std.testing.expectError(error.ClipboardNotImplemented, paste("hi", std.testing.io, c));
}
