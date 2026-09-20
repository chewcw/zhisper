const std = @import("std");

var enabled: std.atomic.Value(bool) = .init(false);

pub fn init() void {
    enabled.store(checkEnv(), .monotonic);
}

pub fn setEnabled(v: bool) void {
    enabled.store(v, .monotonic);
}

pub fn isEnabled() bool {
    return enabled.load(.monotonic);
}

/// Errors always log (stderr). Everything else only when enabled.
pub fn shouldLog(level: std.log.Level) bool {
    if (level == .err) return true;
    return isEnabled();
}

fn checkEnv() bool {
    if (std.c.getenv("ZHISPER_DEBUG")) |raw| {
        if (raw[0] != 0) return true;
    }
    if (std.c.getenv("ZHISPER_VERBOSE")) |raw| {
        if (raw[0] != 0) return true;
    }
    return false;
}

/// Custom logFn: err -> stderr via defaultLog (locked); other levels ->
/// stdout via debug_io only when enabled. Never allocates, never fails.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!shouldLog(level)) return;
    if (level == .err) {
        std.log.defaultLog(level, scope, format, args);
        return;
    }
    const io = std.Options.debug_io;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    defer w.interface.flush() catch {};
    w.interface.print("{s}({s}): ", .{ level.asText(), @tagName(scope) }) catch return;
    w.interface.print(format, args) catch return;
}

test "disabled by default, err always logs" {
    setEnabled(false);
    try std.testing.expect(!isEnabled());
    try std.testing.expect(shouldLog(.err));
    try std.testing.expect(!shouldLog(.warn));
    try std.testing.expect(!shouldLog(.info));
    try std.testing.expect(!shouldLog(.debug));
}

test "enabled logs everything" {
    setEnabled(true);
    defer setEnabled(false);
    try std.testing.expect(shouldLog(.err));
    try std.testing.expect(shouldLog(.warn));
    try std.testing.expect(shouldLog(.info));
    try std.testing.expect(shouldLog(.debug));
}
