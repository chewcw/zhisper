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

/// Matches the stack buffer inside `logFn`. A trace line that does not fit
/// here would be silently dropped rather than reported, so every emitter
/// formats into a buffer of exactly this size.
pub const log_buf: usize = 4096;

pub const ApiOutcome = enum { ok, rejected, failed, too_large };

/// The exact text one outcome emits. Pure, so tests assert content without
/// capturing stdout. `detail` is placed per outcome: metadata on `ok`, the
/// (already capped) upstream body on `rejected`, the error name on `failed`,
/// and unused on `too_large` (the cap lives with each caller). `status` and
/// `resp_len` are ignored by `failed`, which never got a response.
pub fn formatApiLine(
    buf: []u8,
    tag: []const u8,
    url: []const u8,
    outcome: ApiOutcome,
    status: u16,
    resp_len: usize,
    detail: []const u8,
    ms: i64,
) std.fmt.BufPrintError![]const u8 {
    return switch (outcome) {
        .ok => std.fmt.bufPrint(buf, "{s} POST {s} -> {d} resp={d}B {d}ms {s}", .{ tag, url, status, resp_len, ms, detail }),
        .rejected => std.fmt.bufPrint(buf, "{s} POST {s} -> {d} resp={d}B {d}ms upstream={s}", .{ tag, url, status, resp_len, ms, detail }),
        .failed => std.fmt.bufPrint(buf, "{s} POST {s} -> {s} in {d}ms", .{ tag, url, detail, ms }),
        .too_large => std.fmt.bufPrint(buf, "{s} POST {s} -> {d} resp={d}B over cap in {d}ms", .{ tag, url, status, resp_len, ms }),
    };
}
/// Cap for the upstream error body echoed on a non-2xx. WHY 512: `logFn`
/// formats through a 4 KB stack buffer and silently drops anything larger,
/// and the diagnostic we actually need ("Invalid API Key", "audio file too
/// long") is well under 100 bytes. Anything past 512 is a provider stack
/// trace we would only truncate mid-word.
pub const upstream_cap: usize = 512;

/// One in-flight API call, logged as a single line when it finishes.
///
/// WHY metadata only: a verbose line goes to whatever stdout the daemon was
/// given — a terminal, or a journal that outlives the session. The
/// transcribe request body is up to 32 MB of raw WAV and a success body is
/// the user's speech, so neither is ever passed in. The only payload this
/// can log is the upstream error body on a non-2xx, and that is capped.
pub const ApiTrace = struct {
    io: std.Io,
    /// "transcribe" or "normalize" — a log scope is comptime, so the tag
    /// rides in the message instead of selecting the scope.
    tag: []const u8,
    /// Config `base_url` only. No query string, no credentials.
    url: []const u8,
    /// Caller-composed request metadata for the success line, e.g.
    /// `model="whisper-large-v3-turbo" req=123800B (wav=123456B prompt=120B)`.
    /// Borrows a caller-owned buffer, so build it before `begin` and keep it
    /// alive for the life of the trace.
    detail: []const u8,
    /// Monotonic: a wall clock can jump backwards mid-request and print a
    /// negative latency.
    start: std.Io.Timestamp,

    pub fn begin(io: std.Io, tag: []const u8, url: []const u8, detail: []const u8) ApiTrace {
        return .{ .io = io, .tag = tag, .url = url, .detail = detail, .start = .now(io, .awake) };
    }

    pub fn elapsedMs(self: ApiTrace) i64 {
        return self.start.durationTo(.now(self.io, .awake)).toMilliseconds();
    }

    /// Success. `.debug` because one per dictation is routine, not a problem.
    pub fn ok(self: ApiTrace, status: u16, resp_len: usize) void {
        if (!shouldLog(.debug)) return;
        var buf: [log_buf]u8 = undefined;
        const line = formatApiLine(&buf, self.tag, self.url, .ok, status, resp_len, self.detail, self.elapsedMs()) catch return;
        std.log.scoped(.api).debug("{s}", .{line});
    }

    /// Non-2xx. `.warn` because the status and the provider's own message
    /// are the difference between "it just failed" and a diagnosis, and they
    /// are currently discarded by the caller's `defer`.
    pub fn rejected(self: ApiTrace, status: u16, upstream: []const u8) void {
        if (!shouldLog(.warn)) return;
        var buf: [log_buf]u8 = undefined;
        var cap_buf: [upstream_cap]u8 = undefined;
        const capped = truncateInto(&cap_buf, upstream, "...");
        const line = formatApiLine(&buf, self.tag, self.url, .rejected, status, upstream.len, capped, self.elapsedMs()) catch return;
        std.log.scoped(.api).warn("{s}", .{line});
    }

    /// Transport failure — no status, no response body, so nothing to cap.
    pub fn failed(self: ApiTrace, err: anyerror) void {
        if (!shouldLog(.warn)) return;
        var buf: [log_buf]u8 = undefined;
        const line = formatApiLine(&buf, self.tag, self.url, .failed, 0, 0, @errorName(err), self.elapsedMs()) catch return;
        std.log.scoped(.api).warn("{s}", .{line});
    }

    /// A 2xx whose body exceeded the module's `response_cap`.
    pub fn tooLarge(self: ApiTrace, status: u16, resp_len: usize) void {
        if (!shouldLog(.warn)) return;
        var buf: [log_buf]u8 = undefined;
        const line = formatApiLine(&buf, self.tag, self.url, .too_large, status, resp_len, "", self.elapsedMs()) catch return;
        std.log.scoped(.api).warn("{s}", .{line});
    }
};

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

test "formatApiLine renders one shape per outcome" {
    var buf: [log_buf]u8 = undefined;

    const ok_line = try formatApiLine(&buf, "transcribe", "https://x/y", .ok, 200, 42, "model=\"m\"", 812);
    try std.testing.expectEqualStrings("transcribe POST https://x/y -> 200 resp=42B 812ms model=\"m\"", ok_line);

    const rej = try formatApiLine(&buf, "transcribe", "https://x/y", .rejected, 401, 58, "{\"error\":{\"message\":\"Invalid API Key\"}}", 30);
    try std.testing.expectEqualStrings("transcribe POST https://x/y -> 401 resp=58B 30ms upstream={\"error\":{\"message\":\"Invalid API Key\"}}", rej);

    const fail = try formatApiLine(&buf, "normalize", "https://x/y", .failed, 0, 0, "HttpError", 30);
    try std.testing.expectEqualStrings("normalize POST https://x/y -> HttpError in 30ms", fail);

    const big = try formatApiLine(&buf, "transcribe", "https://x/y", .too_large, 200, 2 * 1024 * 1024, "", 30);
    try std.testing.expectEqualStrings("transcribe POST https://x/y -> 200 resp=2097152B over cap in 30ms", big);
}

test "a one-megabyte upstream error body still fits the log buffer" {
    var buf: [log_buf]u8 = undefined;
    var cap_buf: [upstream_cap]u8 = undefined;
    const huge = "x" ** (1024 * 1024);
    const capped = truncateInto(&cap_buf, huge, "...");
    try std.testing.expectEqual(upstream_cap, capped.len);
    const line = try formatApiLine(&buf, "transcribe", "https://x/y", .rejected, 500, huge.len, capped, 5);
    try std.testing.expect(log_buf > line.len);
    try std.testing.expect(std.mem.endsWith(u8, line, "xxx..."));
}

test "trace emitters are no-ops while logging is disabled" {
    const io = std.testing.io;
    setEnabled(false);
    defer setEnabled(false);
    const t = ApiTrace.begin(io, "transcribe", "https://x/y", "model=\"m\"");
    try std.testing.expect(!shouldLog(.debug));
    try std.testing.expect(!shouldLog(.warn));
    t.ok(200, 42);
    t.rejected(401, "nope");
    t.failed(error.HttpError);
    t.tooLarge(200, 99);
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
