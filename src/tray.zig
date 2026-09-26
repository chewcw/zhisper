const std = @import("std");
const builtin = @import("builtin");
const types = @import("tray_types.zig");

pub const State = types.State;
pub const tooltip = types.tooltip;
pub const idle_png = types.idle_png;
pub const recording_png = types.recording_png;
pub const working_png = types.working_png;

const impl = if (builtin.is_test)
    @import("tray_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("tray_linux.zig"),
    .windows => @import("tray_windows.zig"),
    .macos => @import("tray_macos.zig"),
    else => @compileError("tray: unsupported OS"),
};

pub fn setup(io: std.Io) !void {
    return impl.setup(io);
}

pub fn setState(io: std.Io, state: State) !void {
    return impl.setState(io, state);
}

pub fn poll(io: std.Io) void {
    return impl.poll(io);
}

pub fn destroy(io: std.Io) void {
    return impl.destroy(io);
}

test "facade records state through the stub" {
    const stub = @import("tray_stub.zig");
    stub.reset();
    defer stub.reset();

    try setup(std.testing.io);
    try setState(std.testing.io, .working);
    poll(std.testing.io);
    try std.testing.expectEqual(State.working, stub.testLastState().?);
    try std.testing.expectEqual(@as(u32, 1), stub.testPollCount());
    destroy(std.testing.io);
    destroy(std.testing.io);
    try std.testing.expectEqual(@as(u32, 2), stub.testDestroyCount());
}
