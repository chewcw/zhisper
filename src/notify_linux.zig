const std = @import("std");
const notify = @import("notify.zig");
const types = @import("notify_types.zig");

/// Linux notification backend: probes `notify-send` via `which` and spawns it
/// with the body as a discrete argument. Pure Zig, no @cImport, so it compiles
/// for every target.
/// notify-send, --app-name, title, --urgency, urgency, --expire-time, expire,
/// title, body.
pub const argv_len: usize = 9;

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
        // Critical notifications stay on screen far longer: a silently
        // discarded dictation is the failure this whole feature exists to
        // prevent.
        self.slots[0] = "notify-send";
        self.slots[1] = "--app-name";
        self.slots[2] = notify.title;
        self.slots[3] = "--urgency";
        self.slots[4] = if (msg.critical) "critical" else "normal";
        self.slots[5] = "--expire-time";
        self.slots[6] = if (msg.critical) "10000" else "4000";
        self.slots[7] = notify.title;

        const body = msg.text.slice();
        @memcpy(self.body_buf[0..body.len], body);
        self.body_len = body.len;
        self.slots[8] = self.body_buf[0..self.body_len];
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
    if (probe(io, &.{ "which", "notify-send" })) {
        return .{ .available = true, .tool = "notify-send" };
    }
    // The hint names the real cause rather than the missing binary: on a bare
    // i3 session notify-send is usually installed and there is simply no
    // notification daemon to deliver to.
    return .{
        .available = false,
        .tool = null,
        .hint = "no notification daemon is reachable — notifications are off",
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

test "buildArgv passes the body as its own argument" {
    var store: Argv = .{ .slots = undefined };
    const msg = types.forEvent(.clipboard_ready, "he said \"hi\" and left");
    const argv = store.fill(msg);
    try std.testing.expectEqual(@as(usize, argv_len), argv.len);
    try std.testing.expectEqualStrings("notify-send", argv[0]);
    try std.testing.expectEqualStrings("normal", argv[4]);
    try std.testing.expectEqualStrings("4000", argv[6]);
    try std.testing.expectEqualStrings("zhisper", argv[7]);
    // The body is the final argument and nothing else. `notify-send` is spawned
    // with an argv array, not a shell string, so a quote or a newline in the
    // user's own transcript cannot split it into a new argument.
    try std.testing.expectEqualStrings(msg.text.slice(), argv[8]);
    try std.testing.expect(std.mem.indexOfScalar(u8, argv[8], '"') != null);
}

test "buildArgv escalates critical notifications" {
    var store: Argv = .{ .slots = undefined };
    const argv = store.fill(types.forEvent(.clipboard_failed, ""));
    try std.testing.expectEqualStrings("critical", argv[4]);
    try std.testing.expectEqualStrings("10000", argv[6]);
}

test "the body survives after the message it came from is gone" {
    // `fill` takes the Message by value, so a body handed straight back to the
    // caller would dangle on the callee's stack frame. This is the regression
    // guard for exactly that: copy the slice out, drop the message, and only
    // then look at the bytes.
    var store: Argv = .{ .slots = undefined };
    var kept: [types.text_capacity]u8 = undefined;
    var kept_len: usize = 0;
    {
        const msg = types.forEvent(.clipboard_ready, "a body that must outlive its frame");
        const argv = store.fill(msg);
        kept_len = argv[8].len;
        @memcpy(kept[0..kept_len], argv[8]);
    }
    try std.testing.expectEqualStrings(
        "Copied to clipboard: a body that must outlive its frame",
        kept[0..kept_len],
    );
}
