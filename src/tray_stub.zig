const std = @import("std");
const config = @import("config.zig");
const types = @import("tray_types.zig");

var inited = false;
var last_state: ?types.State = null;
var poll_count: u32 = 0;
var destroy_count: u32 = 0;
var host: ?types.MenuHost = null;

pub fn reset() void {
    inited = false;
    last_state = null;
    poll_count = 0;
    destroy_count = 0;
    host = null;
}

pub fn setup(_: std.Io, h: types.MenuHost) !void {
    inited = true;
    host = h;
}

pub fn testHost() ?types.MenuHost {
    return host;
}

pub fn testPick(action: types.Action) void {
    if (host) |h| h.apply(action);
}

pub fn setState(_: std.Io, state: types.State) !void {
    if (!inited) return error.NotSetup;
    last_state = state;
}

pub fn poll(_: std.Io) void {
    poll_count += 1;
}

pub fn destroy(_: std.Io) void {
    inited = false;
    destroy_count += 1;
}

pub fn testLastState() ?types.State {
    return last_state;
}

pub fn testPollCount() u32 {
    return poll_count;
}

pub fn testDestroyCount() u32 {
    return destroy_count;
}

test "tray stub records setup, state, polling, and cleanup" {
    reset();
    defer reset();
    const Host = struct {
        fn snapshotFn(_: *anyopaque) config.Config {
            return config.defaultConfig();
        }
        fn applyFn(_: *anyopaque, _: types.Action) void {}
    };
    var ctx: u8 = 0;
    try setup(std.testing.io, .{ .ctx = &ctx, .snapshotFn = Host.snapshotFn, .applyFn = Host.applyFn });
    try setState(std.testing.io, .recording);
    poll(std.testing.io);
    try std.testing.expectEqual(types.State.recording, testLastState().?);
    try std.testing.expectEqual(@as(u32, 1), testPollCount());
    destroy(std.testing.io);
    destroy(std.testing.io);
    try std.testing.expectEqual(@as(u32, 2), testDestroyCount());
}
