const std = @import("std");
const wav = @import("wav.zig");

pub const Backend = struct {
    start: *const fn () anyerror!void,
    stop: *const fn () anyerror!void,
};

var io_store: std.Io = undefined;
var gpa_store: std.mem.Allocator = undefined;
var active: bool = false;
var samples: std.ArrayList(i16) = .empty;
/// Spinlock (not Io.Mutex): the miniaudio data callback runs on a foreign
/// audio thread with no Zig Io available, so it must never block on Io.
var spin: std.atomic.Mutex = .unlocked;
var backend: Backend = .{ .start = stubStart, .stop = stubStop };

fn stubStart() anyerror!void {}
fn stubStop() anyerror!void {}

/// Call once before setRecording (e.g. from main or tests).
pub fn init(io: std.Io, gpa: std.mem.Allocator) void {
    io_store = io;
    gpa_store = gpa;
}

fn lockSpin() void {
    while (!spin.tryLock()) std.atomic.spinLoopHint();
}

pub fn setRecording(mode: u2, path: []const u8) !void {
    switch (mode) {
        0, 3 => return,
        1 => {
            if (active) return error.AlreadyRecording;
            samples.clearRetainingCapacity();
            try backend.start();
            active = true;
        },
        2 => {
            if (!active) return error.NotRecording;
            try backend.stop();
            active = false;
            // Tmp + rename: Whisper never sees a half-file.
            var tmp_name_buf: [512]u8 = undefined;
            const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp", .{path});
            try wav.writeMono16(io_store, std.Io.Dir.cwd(), tmp_name, samples.items);
            errdefer std.Io.Dir.cwd().deleteFile(io_store, tmp_name) catch {};
            try std.Io.Dir.cwd().rename(tmp_name, std.Io.Dir.cwd(), path, io_store);
            samples.clearRetainingCapacity();
        },
    }
}

fn appendStubSamplesForTest(data: []const i16) !void {
    lockSpin();
    defer spin.unlock();
    try samples.appendSlice(gpa_store, data);
}

test "mode 0 and 3 are silent no-ops" {
    init(std.testing.io, std.testing.allocator);
    active = false;
    samples.clearRetainingCapacity();
    try setRecording(0, "should-never-exist.wav");
    try setRecording(3, "should-never-exist.wav");
    try std.testing.expect(!active);
}

test "double start errors, stop-while-idle errors" {
    init(std.testing.io, std.testing.allocator);
    defer samples.clearRetainingCapacity();
    active = false;
    samples.clearRetainingCapacity();
    try setRecording(1, "ignored-on-start.wav");
    try std.testing.expect(active);
    try std.testing.expectError(error.AlreadyRecording, setRecording(1, "ignored.wav"));
    try setRecording(2, "task3-state.wav");
    try std.testing.expect(!active);
    try std.testing.expectError(error.NotRecording, setRecording(2, "task3-state.wav"));
    std.Io.Dir.cwd().deleteFile(std.testing.io, "task3-state.wav") catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, "task3-state.wav.tmp") catch {};
}

test "stop writes injected samples as parseable wav" {
    const io = std.testing.io;
    init(io, std.testing.allocator);
    // clearRetainingCapacity keeps the backing buffer (by design, for reuse
    // across recordings), so free it here to satisfy the test allocator.
    defer {
        samples.deinit(std.testing.allocator);
        samples = .empty;
    }
    active = false;
    samples.clearRetainingCapacity();
    try setRecording(1, "ignored.wav");
    try appendStubSamplesForTest(&[_]i16{ 0, 1000, -1000 });
    try setRecording(2, "task3-injected.wav");
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
