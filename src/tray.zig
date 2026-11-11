const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const types = @import("tray_types.zig");

pub const State = types.State;
pub const tooltip = types.tooltip;
pub const idle_png = types.idle_png;
pub const recording_png = types.recording_png;
pub const working_png = types.working_png;
pub const MenuHost = types.MenuHost;
pub const Action = types.Action;

const impl = if (builtin.is_test)
    @import("tray_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("tray_linux.zig"),
    .windows => @import("tray_windows.zig"),
    .macos => @import("tray_macos.zig"),
    else => @compileError("tray: unsupported OS"),
};

pub fn setup(io: std.Io, host: types.MenuHost) !void {
    return impl.setup(io, host);
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

const Recorder = struct {
    applied: ?Action = null,
    fn snapshotFn(_: *anyopaque) config.Config {
        return config.defaultConfig();
    }
    fn applyFn(ctx: *anyopaque, action: Action) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.applied = action;
    }
};

fn recorderHost(rec: *Recorder) MenuHost {
    return .{ .ctx = rec, .snapshotFn = Recorder.snapshotFn, .applyFn = Recorder.applyFn };
}

test "facade records state through the stub" {
    const stub = @import("tray_stub.zig");
    stub.reset();
    defer stub.reset();

    var recorder = Recorder{};
    try setup(std.testing.io, recorderHost(&recorder));
    try setState(std.testing.io, .working);
    poll(std.testing.io);
    try std.testing.expectEqual(State.working, stub.testLastState().?);
    try std.testing.expectEqual(@as(u32, 1), stub.testPollCount());
    destroy(std.testing.io);
    destroy(std.testing.io);
    try std.testing.expectEqual(@as(u32, 2), stub.testDestroyCount());
}

test "a picked action reaches the host through the facade" {
    const stub = @import("tray_stub.zig");
    stub.reset();
    defer stub.reset();

    var recorder = Recorder{};
    try setup(std.testing.io, recorderHost(&recorder));
    try std.testing.expectEqualStrings("groq", stub.testHost().?.snapshot().transcribe.provider);
    stub.testPick(.quit);
    try std.testing.expect(recorder.applied.? == .quit);
}
