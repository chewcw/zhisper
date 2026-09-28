const std = @import("std");
const notify = @import("notify.zig");
const types = @import("notify_types.zig");

/// macOS notification backend: probes `osascript` and drives
/// `display notification`. Pure Zig, no @cImport.
/// WHY an `on run argv` handler and not string interpolation: the notification
/// body is a slice of the user's own transcript. Interpolated into AppleScript
/// source, a double quote, a backslash, or a newline in that text would
/// terminate the string literal early and hand `display notification`
/// attacker-shaped input. `argv` receives the bytes verbatim and never
/// evaluates them.
pub const script_lines = [_][]const u8{
    "on run argv",
    "display notification (item 2 of argv) with title (item 1 of argv)",
    "end run",
};

/// The three script lines, then the title, then the body.
pub const argv_len: usize = script_lines.len + 2;

/// Caller-allocated argv storage.
///
/// WHY this is a struct the caller owns rather than a function returning
/// `[]const []const u8`: `fill` takes `msg` *by value*, so `msg.text.slice()`
/// points into `fill`'s own stack frame and dangles the instant it returns.
/// The body is therefore copied into `body_buf` here, which lives as long as
/// the `Argv` value does.
pub const Argv = struct {
    slots: [argv_len][]const u8,
    body_buf: [types.text_capacity]u8 = undefined,
    body_len: usize = 0,

    pub fn fill(self: *Argv, msg: notify.Message) []const []const u8 {
        for (script_lines, 0..) |line, i| self.slots[i] = line;
        self.slots[script_lines.len] = notify.title;

        const body = msg.text.slice();
        @memcpy(self.body_buf[0..body.len], body);
        self.body_len = body.len;
        self.slots[argv_len - 1] = self.body_buf[0..self.body_len];
        return self.slots[0..];
    }
};

fn probe(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    defer child.kill(io);
    const term = child.wait(io) catch return false;
    if (term != .exited) return false;
    return term.exited == 0;
}

pub fn check(io: std.Io) notify.Availability {
    if (probe(io, &.{ "which", "osascript" })) {
        return .{ .available = true, .tool = "osascript" };
    }
    return .{
        .available = false,
        .tool = null,
        .hint = "osascript is missing — notifications are off",
    };
}

pub fn show(io: std.Io, msg: notify.Message) !void {
    var argv_store: Argv = .{ .slots = undefined };
    var child = std.process.spawn(io, .{
        .argv = argv_store.fill(msg),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.NotifyFailed;
    defer child.kill(io);
    const term = child.wait(io) catch return error.NotifyFailed;
    if (term != .exited or term.exited != 0) return error.NotifyFailed;
}

test "buildArgv keeps the body out of the AppleScript source" {
    var store: Argv = .{ .slots = undefined };
    const msg = types.forEvent(.clipboard_ready, "he said \"hi\"\nand left");
    const argv = store.fill(msg);
    try std.testing.expectEqual(@as(usize, argv_len), argv.len);
    try std.testing.expectEqualStrings("zhisper", argv[script_lines.len]);
    try std.testing.expectEqualStrings(msg.text.slice(), argv[argv.len - 1]);

    // The invariant that matters: no script line contains any part of the body.
    // This is what stops a quote or a newline in the transcript from
    // terminating an AppleScript string literal.
    const body = msg.text.slice();
    for (script_lines) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, body) == null);
    }
    try std.testing.expect(std.mem.indexOfScalar(u8, argv[argv.len - 1], '"') != null);
}

test "the body survives after the message it came from is gone" {
    // `fill` takes the Message by value, so a body handed straight back to the
    // caller would dangle on the callee's stack frame.
    var store: Argv = .{ .slots = undefined };
    var kept: [types.text_capacity]u8 = undefined;
    var kept_len: usize = 0;
    {
        const msg = types.forEvent(.clipboard_ready, "a body that must outlive its frame");
        const argv = store.fill(msg);
        kept_len = argv[argv.len - 1].len;
        @memcpy(kept[0..kept_len], argv[argv.len - 1]);
    }
    try std.testing.expectEqualStrings(
        "Copied to clipboard: a body that must outlive its frame",
        kept[0..kept_len],
    );
}

test "the AppleScript handler reads its arguments positionally" {
    try std.testing.expectEqual(@as(usize, 3), script_lines.len);
    try std.testing.expectEqualStrings("on run argv", script_lines[0]);
    try std.testing.expect(std.mem.indexOf(u8, script_lines[1], "item 1 of argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, script_lines[1], "item 2 of argv") != null);
    try std.testing.expectEqualStrings("end run", script_lines[2]);
}
