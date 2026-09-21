const std = @import("std");
const wav = @import("wav.zig");

pub const Backend = struct {
    open: *const fn () anyerror!void,
    close: *const fn () anyerror!void,
};

var io_store: std.Io = undefined;
var gpa_store: std.mem.Allocator = undefined;
var capturing: std.atomic.Value(bool) = .init(false);
var samples: std.ArrayList(i16) = .empty;
/// Spinlock (not Io.Mutex): the miniaudio data callback runs on a foreign
/// audio thread with no Zig Io available, so it must never block on Io.
var spin: std.atomic.Mutex = .unlocked;
var backend: Backend = .{ .open = maOpen, .close = maClose };

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn findMatchIndex(names: []const []const u8, filter: []const u8) ?usize {
    if (filter.len == 0) return null;
    for (names, 0..) |n, idx| {
        if (containsCaseInsensitive(n, filter)) return idx;
    }
    return null;
}

const ma = @cImport(@cInclude("miniaudio.h"));

var device: ma.ma_device = undefined;
var device_live: bool = false;
var selected_id: ma.ma_device_id = undefined;
var has_selected: bool = false;

fn dataCallback(p_device: ?*ma.ma_device, p_output: ?*anyopaque, p_input: ?*const anyopaque, frame_count: ma.ma_uint32) callconv(.c) void {
    _ = p_device;
    _ = p_output;
    const input = p_input orelse return;
    // Warm-device gate: the device streams continuously once opened; frames
    // are kept only while a recording is active.
    if (!capturing.load(.acquire)) return;
    const frames: [*]const i16 = @ptrCast(@alignCast(input));
    lockSpin();
    defer spin.unlock();
    samples.appendSlice(gpa_store, frames[0..frame_count]) catch {};
}

fn maOpen() anyerror!void {
    var config = ma.ma_device_config_init(ma.ma_device_type_capture);
    config.capture.format = ma.ma_format_s16;
    config.capture.channels = 1;
    config.sampleRate = 16000;
    config.dataCallback = dataCallback;
    config.pUserData = null;
    if (has_selected) config.capture.pDeviceID = &selected_id;
    const r = ma.ma_device_init(null, &config, &device);
    if (r != ma.MA_SUCCESS) return error.DeviceInitFailed;
    errdefer ma.ma_device_uninit(&device);
    if (ma.ma_device_start(&device) != ma.MA_SUCCESS) return error.DeviceInitFailed;
    device_live = true;
}

fn maClose() anyerror!void {
    if (!device_live) return;
    _ = ma.ma_device_stop(&device);
    ma.ma_device_uninit(&device);
    device_live = false;
}

fn stubOpen() anyerror!void {}
fn stubClose() anyerror!void {}

/// Call once before setRecording. Empty filter = default mic.
/// Non-empty filter enumerates capture devices once via a throwaway
/// ma_context, picks the first case-insensitive substring match, copies
/// the ma_device_id struct (device init copies it internally, so the
/// temp context can be torn down immediately). No match -> error.DeviceNotFound.
pub fn init(io: std.Io, gpa: std.mem.Allocator, device_filter: []const u8) !void {
    io_store = io;
    gpa_store = gpa;
    has_selected = false;
    if (device_filter.len == 0) return;
    var ctx: ma.ma_context = undefined;
    if (ma.ma_context_init(null, 0, null, &ctx) != ma.MA_SUCCESS) return error.DeviceInitFailed;
    defer _ = ma.ma_context_uninit(&ctx);
    var p_playback: [*c]ma.ma_device_info = null;
    var playback_count: ma.ma_uint32 = 0;
    var p_capture: [*c]ma.ma_device_info = null;
    var capture_count: ma.ma_uint32 = 0;
    if (ma.ma_context_get_devices(&ctx, &p_playback, &playback_count, &p_capture, &capture_count) != ma.MA_SUCCESS) return error.DeviceInitFailed;
    const n: usize = @intCast(capture_count);
    const infos = if (p_capture) |p| p[0..n] else &[_]ma.ma_device_info{};
    var idx: ?usize = null;
    for (infos, 0..) |info, i| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
        if (containsCaseInsensitive(name, device_filter)) {
            idx = i;
            break;
        }
    }
    const hit = idx orelse return error.DeviceNotFound;
    selected_id = infos[hit].id;
    has_selected = true;
    const picked = std.mem.span(@as([*:0]const u8, @ptrCast(&infos[hit].name)));
    std.log.scoped(.daemon).info("using mic \"{s}\" for \"{s}\"", .{ picked, device_filter });
}

/// Prints capture device names for --list-devices and error paths.
pub fn listCaptureDevices() !void {
    const log = std.log.scoped(.daemon);
    var ctx: ma.ma_context = undefined;
    if (ma.ma_context_init(null, 0, null, &ctx) != ma.MA_SUCCESS) return error.DeviceInitFailed;
    defer _ = ma.ma_context_uninit(&ctx);
    var p_playback: [*c]ma.ma_device_info = null;
    var playback_count: ma.ma_uint32 = 0;
    var p_capture: [*c]ma.ma_device_info = null;
    var capture_count: ma.ma_uint32 = 0;
    if (ma.ma_context_get_devices(&ctx, &p_playback, &playback_count, &p_capture, &capture_count) != ma.MA_SUCCESS) return error.DeviceInitFailed;
    const n: usize = @intCast(capture_count);
    const infos = if (p_capture) |p| p[0..n] else &[_]ma.ma_device_info{};
    if (infos.len == 0) {
        log.info("no capture devices found", .{});
        return;
    }
    for (infos) |info| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
        log.info("capture: {s}", .{name});
    }
}

fn lockSpin() void {
    while (!spin.tryLock()) std.atomic.spinLoopHint();
}

fn ensureOpen() !void {
    if (device_live) return;
    try backend.open();
    device_live = true;
}

fn closeDevice() void {
    if (!device_live) return;
    backend.close() catch {};
    device_live = false;
}

/// Daemon exit path: stop capturing and release the warm device.
pub fn shutdown() void {
    capturing.store(false, .monotonic);
    closeDevice();
}

pub const RecordingMode = enum(u2) {
    silent = 0,
    start = 1,
    stop = 2,
    no_op = 3,
};

pub fn setRecording(mode: RecordingMode, path: []const u8) !void {
    switch (mode) {
        .silent, .no_op => return,
        .start => {
            if (capturing.load(.acquire)) return error.AlreadyRecording;
            try ensureOpen();
            lockSpin();
            samples.clearRetainingCapacity();
            spin.unlock();
            capturing.store(true, .release);
        },
        .stop => {
            if (!capturing.load(.acquire)) return error.NotRecording;
            capturing.store(false, .release);
            // Snapshot under the spinlock: the audio thread skips appends
            // once capturing is false, so the copy below cannot race.
            lockSpin();
            const snapshot = gpa_store.dupe(i16, samples.items) catch {
                spin.unlock();
                return error.OutOfMemory;
            };
            spin.unlock();
            defer gpa_store.free(snapshot);
            // Tmp + rename: Whisper never sees a half-file.
            var tmp_name_buf: [512]u8 = undefined;
            const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp", .{path});
            try wav.writeMono16(io_store, std.Io.Dir.cwd(), tmp_name, snapshot);
            errdefer std.Io.Dir.cwd().deleteFile(io_store, tmp_name) catch {};
            try std.Io.Dir.cwd().rename(tmp_name, std.Io.Dir.cwd(), path, io_store);
            lockSpin();
            samples.clearRetainingCapacity();
            spin.unlock();
        },
    }
}

fn appendStubSamplesForTest(data: []const i16) !void {
    lockSpin();
    defer spin.unlock();
    try samples.appendSlice(gpa_store, data);
}

test "mode 0 and 3 are silent no-ops" {
    try init(std.testing.io, std.testing.allocator, "");
    const prev_backend = backend;
    defer backend = prev_backend;
    backend = .{ .open = stubOpen, .close = stubClose };
    capturing.store(false, .monotonic);
    samples.clearRetainingCapacity();
    try setRecording(.silent, "should-never-exist.wav");
    try setRecording(.no_op, "should-never-exist.wav");
    try std.testing.expect(!capturing.load(.acquire));
}

test "double start errors, stop-while-idle errors" {
    try init(std.testing.io, std.testing.allocator, "");
    const prev_backend = backend;
    defer backend = prev_backend;
    backend = .{ .open = stubOpen, .close = stubClose };
    defer samples.clearRetainingCapacity();
    capturing.store(false, .monotonic);
    samples.clearRetainingCapacity();
    try setRecording(.start, "ignored-on-start.wav");
    try std.testing.expect(capturing.load(.acquire));
    try std.testing.expectError(error.AlreadyRecording, setRecording(.start, "ignored.wav"));
    try setRecording(.stop, "task3-state.wav");
    try std.testing.expect(!capturing.load(.acquire));
    try std.testing.expectError(error.NotRecording, setRecording(.stop, "task3-state.wav"));
    std.Io.Dir.cwd().deleteFile(std.testing.io, "task3-state.wav") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, "task3-state.wav.tmp") catch {};
}

test "stop writes injected samples as parseable wav" {
    const io = std.testing.io;
    try init(io, std.testing.allocator, "");
    const prev_backend = backend;
    defer backend = prev_backend;
    backend = .{ .open = stubOpen, .close = stubClose };
    // clearRetainingCapacity keeps the backing buffer (by design, for reuse
    // across recordings), so free it here to satisfy the test allocator.
    defer {
        samples.deinit(std.testing.allocator);
        samples = .empty;
    }
    capturing.store(false, .monotonic);
    samples.clearRetainingCapacity();
    try setRecording(.start, "ignored.wav");
    try appendStubSamplesForTest(&[_]i16{ 0, 1000, -1000 });
    try setRecording(.stop, "task3-injected.wav");
    var f = try std.Io.Dir.cwd().openFile(io, "task3-injected.wav", .{});
    defer f.close(io);
    var rbuf: [128]u8 = undefined;
    var r = f.reader(io, &rbuf);
    var got: [44]u8 = undefined;
    try r.interface.readSliceAll(&got);
    var want: [44]u8 = undefined;
    wav.header(3, &want);
    try std.testing.expectEqualSlices(u8, &want, &got);
    std.Io.Dir.cwd().deleteFile(io, "task3-injected.wav") catch {};
}

test "live mic smoke test (opt-in)" {
    if (std.c.getenv("RECORD_LIVE") == null) return error.SkipZigTest;
    const io = std.testing.io;
    try init(io, std.testing.allocator, "");
    defer {
        samples.deinit(std.testing.allocator);
        samples = .empty;
    }
    capturing.store(false, .monotonic);
    device_live = false;
    backend = .{ .open = maOpen, .close = maClose };
    try setRecording(.start, "ignored-live.wav");
    try io.sleep(.fromMilliseconds(500), .awake);
    try setRecording(.stop, "live-smoke.wav");
    defer std.Io.Dir.cwd().deleteFile(io, "live-smoke.wav") catch {};
    var f = try std.Io.Dir.cwd().openFile(io, "live-smoke.wav", .{});
    defer f.close(io);
    var rbuf: [128]u8 = undefined;
    var r = f.reader(io, &rbuf);
    var got: [44]u8 = undefined;
    try r.interface.readSliceAll(&got);
    try std.testing.expectEqualSlices(u8, "RIFF", got[0..4]);
    try std.testing.expectEqualSlices(u8, "WAVE", got[8..12]);
}

test "findMatchIndex matches substring case-insensitively" {
    const names = [_][]const u8{ "Built-in Microphone", "USB Mic Pro" };
    try std.testing.expectEqual(@as(?usize, 1), findMatchIndex(&names, "usb"));
    try std.testing.expectEqual(@as(?usize, 1), findMatchIndex(&names, "USB"));
    try std.testing.expectEqual(@as(?usize, 0), findMatchIndex(&names, "built"));
    try std.testing.expectEqual(@as(?usize, null), findMatchIndex(&names, ""));
    try std.testing.expectEqual(@as(?usize, null), findMatchIndex(&names, "nope"));
}

test "empty filter keeps default device" {
    try init(std.testing.io, std.testing.allocator, "");
    try std.testing.expect(!has_selected);
}
