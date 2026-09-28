const std = @import("std");
const types = @import("tray_types.zig");
const notify_types = @import("notify_types.zig");

const Bridge = opaque {};
extern fn zhisper_tray_create(idle: [*]const u8, idle_len: usize, recording: [*]const u8, recording_len: usize, working: [*]const u8, working_len: usize) ?*Bridge;
extern fn zhisper_tray_set_state(tray: *Bridge, state: c_int) c_int;
extern fn zhisper_tray_poll(tray: *Bridge) void;
extern fn zhisper_tray_destroy(tray: *Bridge) void;
extern fn zhisper_tray_notify(tray: *Bridge, title: [*:0]const u8, body: [*:0]const u8, critical: c_int) c_int;

var handle: ?*Bridge = null;

/// notify_windows.zig needs to know whether a balloon has an icon to hang
/// off. The tray seam itself never exposes the handle, and duplicating it
/// here would leave two sources of truth for "is the icon alive".
pub fn notifyLive() bool {
    return handle != null;
}

pub fn notify(msg: notify_types.Message) !void {
    const tray = handle orelse return error.NotSetUp;
    // The C side takes a NUL-terminated char*, so the buffer carries its own
    // terminator. The C helper bounds-checks the copy anyway.
    var body_buf: [notify_types.text_capacity + 1]u8 = undefined;
    const body = msg.text.slice();
    @memcpy(body_buf[0..body.len], body);
    body_buf[body.len] = 0;
    if (zhisper_tray_notify(tray, notify_types.title.ptr, @ptrCast(&body_buf), @intFromBool(msg.critical)) == 0) {
        return error.NotifyFailed;
    }
}

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

test "a tray that was never created is not live" {
    // No setup() call: the handle must stay null so notify_windows.zig can
    // report the "tray is disabled" hint instead of calling into a null tray.
    try std.testing.expect(!notifyLive());
    try std.testing.expectError(error.NotSetUp, notify(notify_types.forEvent(.quiet_clip, "")));
}
