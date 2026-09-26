const std = @import("std");
const types = @import("inject_types.zig");

var buf: [4096]u8 = undefined;
var len: usize = 0;
var opts: types.InjectOptions = .{};

pub fn reset() void {
    len = 0;
    opts = .{};
}

pub fn setup(_: std.Io, o: types.InjectOptions) !void {
    len = 0;
    opts = o;
}

/// Mirrors a real backend: validate, apply the trailing-newline policy, record
/// the body, and report how many codepoints were delivered. Returns a
/// keystroke count so facade tests assert the contract rather than a byte count.
pub fn typeText(text: []const u8, _: std.Io) !usize {
    _ = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    const body = text[0 .. text.len - types.trailingCut(text, opts.trailing_newline)];
    if (len + body.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[len .. len + body.len], body);
    len += body.len;
    var count: usize = 0;
    var it = (std.unicode.Utf8View.init(body) catch return error.InvalidUtf8).iterator();
    while (it.nextCodepoint()) |_| count += 1;
    return count;
}

pub fn destroy() void {
    reset();
}

pub fn takeText() []const u8 {
    return buf[0..len];
}

test "stub records typed text including multibyte" {
    reset();
    defer reset();
    try setup(std.testing.io, .{});
    // "héllo" is 6 UTF-8 bytes but 5 codepoints, and typeText now reports
    // keystrokes emitted rather than bytes delivered.
    const n = try typeText("héllo", std.testing.io);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("héllo", takeText());
}
