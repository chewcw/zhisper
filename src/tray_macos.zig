const std = @import("std");
const types = @import("tray_types.zig");

// Temporary seam placeholder: the native AppKit implementation replaces
// this in the macOS backend task. It keeps the shared tray tests buildable
// while the platform adapter is being implemented.
pub fn setup(_: std.Io) !void {
    return error.Unsupported;
}

pub fn setState(_: std.Io, _: types.State) !void {
    return error.Unsupported;
}

pub fn poll(_: std.Io) void {}

pub fn destroy(_: std.Io) void {}
