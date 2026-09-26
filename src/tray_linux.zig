const std = @import("std");
const types = @import("tray_types.zig");

// Temporary seam placeholder: the native X11 implementation replaces this in
// the Linux backend task. It exists so Zig 0.16 can resolve every comptime
// facade import while the shared tray tests are being added.
pub fn setup(_: std.Io) !void {
    return error.Unsupported;
}

pub fn setState(_: std.Io, _: types.State) !void {
    return error.Unsupported;
}

pub fn poll(_: std.Io) void {}

pub fn destroy(_: std.Io) void {}
