const std = @import("std");
const types = @import("tray_types.zig");

const Bridge = opaque {};
extern fn zhisper_tray_create(idle: [*]const u8, idle_len: usize, recording: [*]const u8, recording_len: usize, working: [*]const u8, working_len: usize) ?*Bridge;
extern fn zhisper_tray_set_state(tray: *Bridge, state: c_int) c_int;
extern fn zhisper_tray_poll(tray: *Bridge) void;
extern fn zhisper_tray_destroy(tray: *Bridge) void;

var handle: ?*Bridge = null;

fn stateCode(state: types.State) c_int {
    return switch (state) {
        .idle => 0,
        .recording => 1,
        .working => 2,
    };
}

pub fn setup(_: std.Io) !void {
    if (handle != null) return;
    handle = zhisper_tray_create(
        types.idle_png.ptr,
        types.idle_png.len,
        types.recording_png.ptr,
        types.recording_png.len,
        types.working_png.ptr,
        types.working_png.len,
    ) orelse return error.TraySetupFailed;
}

pub fn setState(_: std.Io, state: types.State) !void {
    const tray = handle orelse return error.NotSetup;
    if (zhisper_tray_set_state(tray, stateCode(state)) == 0) return error.TrayUpdateFailed;
}

pub fn poll(_: std.Io) void {
    if (handle) |tray| zhisper_tray_poll(tray);
}

pub fn destroy(_: std.Io) void {
    if (handle) |tray| {
        zhisper_tray_destroy(tray);
        handle = null;
    }
}
