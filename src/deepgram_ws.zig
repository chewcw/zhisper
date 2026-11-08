const std = @import("std");
const builtin = @import("builtin");
const ws = @import("websocket");

pub const poll_ms: u32 = 50;
pub const stop_wait_ms: u32 = 500;

pub const Target = struct {
    tls: bool,
    port: u16,
    host: []const u8,
    path_and_query: []const u8,
};

pub fn parseUrl(url: []const u8) error{MalformedUrl}!Target {
    if (url.len == 0) return error.MalformedUrl;

    var rest = url;
    var tls = false;
    var default_port: u16 = 80;
    if (std.mem.startsWith(u8, rest, "wss://")) {
        tls = true;
        default_port = 443;
        rest = rest["wss://".len..];
    } else if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest["ws://".len..];
    } else {
        return error.MalformedUrl;
    }

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |i| rest[0..i] else rest;
    const path_and_query: []const u8 = if (slash) |i| rest[i..] else "/";
    if (authority.len == 0) return error.MalformedUrl;

    // IPv6 bracketed hosts are not supported.
    if (std.mem.indexOfScalar(u8, authority, '[') != null) return error.MalformedUrl;

    var host = authority;
    var port = default_port;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        // Only treat as host:port when the suffix is a decimal port.
        const port_str = authority[colon + 1 ..];
        if (port_str.len != 0) {
            const parsed = std.fmt.parseInt(u16, port_str, 10) catch return error.MalformedUrl;
            host = authority[0..colon];
            port = parsed;
        } else {
            return error.MalformedUrl;
        }
    }
    if (host.len == 0) return error.MalformedUrl;

    return .{
        .tls = tls,
        .port = port,
        .host = host,
        .path_and_query = path_and_query,
    };
}

pub const EndState = enum { open, finished, failed };

pub const Connection = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    client: ws.Client = undefined,
    reader: ?std.Thread = null,
    /// Guards everything below: the reader thread writes, the session
    /// thread reads.
    mutex: std.Io.Mutex = .init,
    segments: std.ArrayList([]u8) = .empty,
    /// Set by shutdown. The reader checks it between reads.
    stop: bool = false,
    ended: bool = false,
    finishing: bool = false,
    client_ready: bool = false,

    pub fn open(self: *Connection, url: []const u8, api_key: []const u8) !void {
        const target = try parseUrl(url);

        // Build the auth header in a caller-owned stack buffer and zero it
        // after use. WHY: the key must never be logged or retained.
        var auth_buf: [512]u8 = undefined;
        const auth = try std.fmt.bufPrint(&auth_buf, "Authorization: Token {s}\r\n", .{api_key});
        defer @memset(auth, 0);

        self.client = try ws.Client.init(self.io, self.gpa, .{
            .host = target.host,
            .port = target.port,
            .tls = target.tls,
        });
        self.client_ready = true;
        errdefer {
            self.client.deinit();
            self.client_ready = false;
        }

        try self.client.handshake(target.path_and_query, .{
            .timeout_ms = 5000,
            .headers = auth,
        });

        self.reader = try std.Thread.spawn(.{}, runReader, .{self});
    }

    fn stopped(self: *Connection) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stop;
    }

    fn isEnded(self: *Connection) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.ended;
    }

    fn waitForEnd(self: *Connection, timeout_ms: u32) void {
        const deadline_step_ms: u32 = 10;
        var waited: u32 = 0;
        while (waited < timeout_ms) {
            if (self.isEnded()) return;
            self.io.sleep(.fromMilliseconds(deadline_step_ms), .awake) catch {};
            waited += deadline_step_ms;
        }
    }

    // The reader owns socket/TLS teardown. websocket.zig frees the TLS client
    // and its buffers inside Client.close()/Stream.close() (the TLS arena), so
    // closing the client from another thread while a read is in flight lets the
    // reader return into freed TLS state. runReader therefore exits on its own
    // (timed read sees the stop flag) and deinit tears the client down only
    // after the reader thread has ended.
    fn runReader(self: *Connection) void {
        // A timed read returns null instead of blocking, so the loop can see
        // `stop`. On Windows the library ignores this timeout.
        self.client.readTimeout(poll_ms) catch {};
        while (!self.stopped()) {
            const msg = self.client.read() catch break orelse continue;
            defer self.client.done(msg);
            switch (msg.type) {
                .text, .binary => self.onMessage(msg.data),
                .ping => self.client.writePong(msg.data) catch {},
                .pong => {},
                .close => break,
            }
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.ended = true;
    }

    fn onMessage(self: *Connection, data: []u8) void {
        const text = parseStreamMessage(self.gpa, data) orelse return;
        defer self.gpa.free(text);

        const owned = self.gpa.dupe(u8, text) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.segments.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
    }

    pub fn pump(self: *Connection, pcm: []u8) !void {
        try self.client.writeBin(pcm);
    }

    pub fn sendText(self: *Connection, text: []u8) !void {
        try self.client.writeText(text);
    }

    pub fn markFinishing(self: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.finishing = true;
    }

    pub fn state(self: *Connection) EndState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.ended) return .open;
        return if (self.finishing) .finished else .failed;
    }

    pub fn takeTranscript(self: *Connection, gpa: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return try joinSegments(gpa, self.segments.items);
    }

    pub fn segmentCount(self: *Connection) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.segments.items.len;
    }

    pub fn shutdown(self: *Connection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.stop = true;
        self.finishing = true;
    }

    // The reader owns socket/TLS teardown (see runReader). deinit requests a
    // stop, waits for the reader to exit, and only then destroys the client.
    // websocket.zig frees the TLS arena in Client.close(), so client.deinit()
    // must not run while a read is in flight. On Windows a blocked read ignores
    // readTimeout, so if the reader is still running after the wait we force
    // Client.close() to unblock it and wait again before joining; Client.deinit()
    // after Client.close() is safe because closeStream skips a second close once
    // the stream is already closed.
    pub fn deinit(self: *Connection) void {
        self.shutdown();
        if (self.reader != null) {
            self.waitForEnd(stop_wait_ms);
            if (builtin.os.tag == .windows and !self.isEnded() and self.client_ready) {
                self.client.close(.{}) catch {};
                self.waitForEnd(stop_wait_ms);
            }
            if (self.reader) |t| {
                t.join();
                self.reader = null;
            }
        }
        if (self.client_ready) {
            self.client.deinit();
            self.client_ready = false;
        }
        for (self.segments.items) |seg| self.gpa.free(seg);
        self.segments.deinit(self.gpa);
        self.segments = .empty;
    }
};

/// Returns the raw transcript of a Results message when is_final is true.
/// Caller frees the result. Returns null for non-final/other types/malformed.
pub fn parseStreamMessage(gpa: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;

    const type_val = root.object.get("type") orelse return null;
    if (type_val != .string) return null;
    if (!std.mem.eql(u8, type_val.string, "Results")) return null;

    const is_final_val = root.object.get("is_final") orelse return null;
    switch (is_final_val) {
        .bool => |b| if (!b) return null,
        else => return null,
    }

    const channel_val = root.object.get("channel") orelse return null;
    if (channel_val != .object) return null;

    const alts_val = channel_val.object.get("alternatives") orelse return null;
    if (alts_val != .array) return null;
    if (alts_val.array.items.len == 0) return null;

    const alt0 = alts_val.array.items[0];
    if (alt0 != .object) return null;

    const transcript_val = alt0.object.get("transcript") orelse return null;
    if (transcript_val != .string) return null;

    return gpa.dupe(u8, transcript_val.string) catch null;
}

/// Trims " \t\r\n" from each segment, skips empty results, and joins the
/// rest with one space. An empty list returns an empty string. Caller frees.
pub fn joinSegments(gpa: std.mem.Allocator, segments: []const []u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var first = true;
    for (segments) |seg| {
        const trimmed = std.mem.trim(u8, seg, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!first) try aw.writer.writeByte(' ');
        try aw.writer.writeAll(trimmed);
        first = false;
    }
    const out = try gpa.dupe(u8, aw.writer.buffered());
    aw.deinit();
    return out;
}

test "parseUrl: wss default port and path" {
    const t = try parseUrl("wss://api.deepgram.com/v1/listen");
    try std.testing.expect(t.tls);
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("api.deepgram.com", t.host);
    try std.testing.expectEqualStrings("/v1/listen", t.path_and_query);
}

test "parseUrl: ws explicit port and query" {
    const t = try parseUrl("ws://127.0.0.1:8080/x?y=1");
    try std.testing.expect(!t.tls);
    try std.testing.expectEqual(@as(u16, 8080), t.port);
    try std.testing.expectEqualStrings("127.0.0.1", t.host);
    try std.testing.expectEqualStrings("/x?y=1", t.path_and_query);
}

test "parseUrl: missing path becomes /" {
    const t = try parseUrl("wss://h");
    try std.testing.expect(t.tls);
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("h", t.host);
    try std.testing.expectEqualStrings("/", t.path_and_query);
}

test "parseUrl: rejects non-ws schemes and empty" {
    try std.testing.expectError(error.MalformedUrl, parseUrl("http://h/x"));
    try std.testing.expectError(error.MalformedUrl, parseUrl(""));
}

test "parseStreamMessage: extracts final transcript" {
    const gpa = std.testing.allocator;
    const body =
        "{\"type\":\"Results\",\"is_final\":true,\"channel\":{\"alternatives\":[{\"transcript\":\"hello world\"}]}}";
    const got = parseStreamMessage(gpa, body).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "parseStreamMessage: non-final is null" {
    const gpa = std.testing.allocator;
    const body =
        "{\"type\":\"Results\",\"is_final\":false,\"channel\":{\"alternatives\":[{\"transcript\":\"hello world\"}]}}";
    try std.testing.expect(parseStreamMessage(gpa, body) == null);
}

test "parseStreamMessage: empty alternatives is null" {
    const gpa = std.testing.allocator;
    try std.testing.expect(parseStreamMessage(gpa, "{\"type\":\"Results\",\"channel\":{\"alternatives\":[]}}") == null);
}

test "parseStreamMessage: metadata and non-json are null" {
    const gpa = std.testing.allocator;
    try std.testing.expect(parseStreamMessage(gpa, "{\"type\":\"Metadata\"}") == null);
    try std.testing.expect(parseStreamMessage(gpa, "not json") == null);
}

test "joinSegments: trims and joins with single space" {
    const gpa = std.testing.allocator;
    var segs = [_][]u8{ @constCast("a "), @constCast(" b") };
    const got = try joinSegments(gpa, &segs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a b", got);
}

test "joinSegments: skips empty segments" {
    const gpa = std.testing.allocator;
    var segs = [_][]u8{ @constCast("a"), @constCast(""), @constCast("b") };
    const got = try joinSegments(gpa, &segs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a b", got);
}

test "joinSegments: empty list returns empty string" {
    const gpa = std.testing.allocator;
    var segs = [_][]u8{};
    const got = try joinSegments(gpa, &segs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("", got);
}

test "Connection: live Deepgram upgrade (opt-in)" {
    const live = std.c.getenv("DEEPGRAM_LIVE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(live), "1")) return error.SkipZigTest;
    const key = std.c.getenv("DEEPGRAM_API_KEY") orelse return error.SkipZigTest;
    const api_key = std.mem.span(key);
    if (api_key.len == 0) return error.SkipZigTest;

    var conn: Connection = .{ .io = std.testing.io, .gpa = std.testing.allocator };
    try conn.open("wss://api.deepgram.com/v1/listen?model=nova-3", api_key);
    conn.shutdown();
    conn.deinit();
}
