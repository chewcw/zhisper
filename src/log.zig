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

/// Single warning outlet for clipboard-unavailable and similar
/// non-fatal setup issues. Routes through scoped `.inject` warn log
/// so it respects the existing `logFn` gating (visible with verbose).
pub fn warn(msg: []const u8) void {
    std.log.scoped(.inject).warn("{s}", .{msg});
}

/// Cap for the upstream error body echoed on a non-2xx. WHY 512: `logFn`
/// formats through a 4 KB stack buffer and silently drops anything larger,
/// and the diagnostic we actually need ("Invalid API Key", "audio file too
/// long") is well under 100 bytes. Anything past 512 is a provider stack
/// trace we would only truncate mid-word.
pub const upstream_cap: usize = 512;

/// Writes `s` into `buf`, truncated to `buf.len` with `mark` as the tail
/// marker when `s` does not fit, and returns the region of `buf` holding the
/// result. Never allocates — `buf` is caller-owned scratch, normally a stack
/// array. A `buf` too small to hold `mark` gets a plain prefix: `buf.len` is
/// a hard ceiling, not a target.
///
/// WHY not `return s[0..n] ++ mark`: Zig requires the concatenated length to
/// be comptime-known, so a runtime-bounded trim cannot build the result in
/// place. The caller has to own the buffer either way.
pub fn truncateInto(buf: []u8, s: []const u8, mark: []const u8) []const u8 {
    if (s.len <= buf.len) {
        @memcpy(buf[0..s.len], s);
        return buf[0..s.len];
    }
    if (buf.len <= mark.len) {
        @memcpy(buf[0..buf.len], s[0..buf.len]);
        return buf[0..buf.len];
    }
    const keep = buf.len - mark.len;
    @memcpy(buf[0..keep], s[0..keep]);
    @memcpy(buf[keep..], mark);
    return buf[0..buf.len];
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
    w.interface.print("\n", .{}) catch return;
}

test "truncateInto returns short input unchanged" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("short", truncateInto(&buf, "short", "..."));
    // Exact-fit input is not marked.
    try std.testing.expectEqualStrings("12345678", truncateInto(buf[0..8], "12345678", "..."));
}

test "truncateInto caps long input and appends the mark" {
    var buf: [8]u8 = undefined;
    const got = truncateInto(&buf, "abcdefghij", "...");
    try std.testing.expectEqualStrings("abcde...", got);
    try std.testing.expectEqual(@as(usize, 8), got.len);
}

test "truncateInto never exceeds buf even when the mark does not fit" {
    var buf: [2]u8 = undefined;
    const got = truncateInto(&buf, "abcdefghij", "...");
    try std.testing.expectEqualStrings("ab", got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
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
