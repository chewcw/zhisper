const std = @import("std");
const types = @import("overlay_types.zig");

// Temporary Task 4 placeholder: the real SDL3 backend arrives in Task 5.
// Every function fails safe (setup/show error, rest no-op) so non-test
// builds link while the headless-degrade paths stay exercised.
pub fn setup(_: types.OverlayConfig) !void {
    return error.OverlayNotImplemented;
}

pub fn destroy() void {}

pub fn show() !void {
    return error.OverlayNotImplemented;
}

pub fn hide() void {}

pub fn move(_: types.Position) void {}

pub fn setState(_: types.State) void {}

pub fn displayList(gpa: std.mem.Allocator) ![]types.Display {
    return try gpa.alloc(types.Display, 0);
}

pub fn pollEvent() ?types.Event {
    return null;
}
