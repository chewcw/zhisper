const std = @import("std");
const types = @import("notify_types.zig");

var last: ?types.Message = null;
var show_count: u32 = 0;

pub fn reset() void {
    last = null;
    show_count = 0;
}

/// The stub claims to be available so the facade test can exercise `show`
/// without a real notification backend on the build machine.
pub fn check(_: std.Io) types.Availability {
    return .{ .available = true, .tool = "stub" };
}

pub fn show(_: std.Io, msg: types.Message) !void {
    show_count += 1;
    last = msg;
}

pub fn testLast() ?types.Message {
    return last;
}

pub fn testShowCount() u32 {
    return show_count;
}

test "the stub records the last message and a show count" {
    reset();
    defer reset();
    try show(std.testing.io, types.forEvent(.clipboard_ready, "hello"));
    try show(std.testing.io, types.forEvent(.quiet_clip, ""));
    try std.testing.expectEqual(@as(u32, 2), testShowCount());
    try std.testing.expectEqual(types.Kind.quiet_clip, testLast().?.kind);
    try std.testing.expectEqualStrings("Nothing audible in that recording", testLast().?.text.slice());
}

test "the stub reports itself available" {
    const avail = check(std.testing.io);
    try std.testing.expect(avail.available);
    try std.testing.expectEqualStrings("stub", avail.tool.?);
}
