const std = @import("std");

pub fn openUrl(io: std.Io, gpa: std.mem.Allocator, url: []const u8) !void {
    _ = gpa;
    // The URL is one argv element, so no shell parses it. Ignored stdio keeps
    // the launcher's own messages out of the daemon's output.
    var child = std.process.spawn(io, .{
        .argv = &.{ "xdg-open", url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.LauncherFailed;
    defer child.kill(io);
    const term = child.wait(io) catch return error.LauncherFailed;
    if (term != .exited or term.exited != 0) return error.LauncherFailed;
}
