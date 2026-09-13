const std = @import("std");

pub fn setup(_: std.Io) !void {
    return error.UnsupportedOs;
}

pub fn typeText(_: []const u8) !usize {
    return error.UnsupportedOs;
}

pub fn destroy() void {}

test "setup reports UnsupportedOs until the native typer lands" {
    try std.testing.expectError(error.UnsupportedOs, setup(std.testing.io));
}
