const std = @import("std");

var buf: [4096]u8 = undefined;
var len: usize = 0;

pub fn reset() void {
    len = 0;
}

pub fn setup(_: std.Io) !void {
    reset();
}

pub fn typeText(text: []const u8, _: std.Io) !usize {
    if (len + text.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[len .. len + text.len], text);
    len += text.len;
    return text.len;
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
    const n = try typeText("héllo", std.testing.io);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("héllo", takeText());
}
