const std = @import("std");
const log = @import("log.zig");
const transcribe = @import("transcribe.zig");
const wav = @import("wav.zig");

pub const default_model = "nova-3";
pub const default_rest_url = "https://api.deepgram.com/v1/listen";

/// Every field is borrowed and must outlive its use.
pub const Config = struct {
    rest_url: []const u8,
    stream_url: []const u8,
    model: []const u8,
    language: []const u8,
    keyterms: []const []const u8,
    api_key: []const u8,
};

/// Caller frees.
pub fn streamUrlFor(gpa: std.mem.Allocator, rest_url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, rest_url, "https://")) {
        return std.fmt.allocPrint(gpa, "wss://{s}", .{rest_url["https://".len..]});
    }
    if (std.mem.startsWith(u8, rest_url, "http://")) {
        return std.fmt.allocPrint(gpa, "ws://{s}", .{rest_url["http://".len..]});
    }
    return error.UnsupportedScheme;
}

/// Caller frees.
pub fn restUrlFor(gpa: std.mem.Allocator, stream_url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, stream_url, "wss://")) {
        return std.fmt.allocPrint(gpa, "https://{s}", .{stream_url["wss://".len..]});
    }
    if (std.mem.startsWith(u8, stream_url, "ws://")) {
        return std.fmt.allocPrint(gpa, "http://{s}", .{stream_url["ws://".len..]});
    }
    return error.UnsupportedScheme;
}

/// Caller frees.
pub fn percentEncode(gpa: std.mem.Allocator, term: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    for (term) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
    const out = try gpa.dupe(u8, aw.writer.buffered());
    aw.deinit();
    return out;
}

/// Caller frees the outer slice; the terms are slices of `raw`.
pub fn parseKeyterms(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len != 0) count += 1;
    }

    const out = try gpa.alloc([]const u8, count);
    errdefer gpa.free(out);
    var i: usize = 0;
    it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len == 0) continue;
        out[i] = trimmed;
        i += 1;
    }
    return out;
}

fn appendQueryBase(gpa: std.mem.Allocator, w: anytype, cfg: Config) !void {
    const language = if (cfg.language.len == 0) "multi" else cfg.language;
    try w.print(
        "model={s}&punctuate=true&smart_format=true&dictation=true&language={s}",
        .{ cfg.model, language },
    );
    _ = gpa;
}

fn appendKeyterms(gpa: std.mem.Allocator, w: anytype, keyterms: []const []const u8) !void {
    for (keyterms) |term| {
        const encoded = try percentEncode(gpa, term);
        defer gpa.free(encoded);
        try w.writeAll("&keyterm=");
        try w.writeAll(encoded);
    }
}

/// Caller frees.
pub fn buildStreamUrl(gpa: std.mem.Allocator, cfg: Config) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(cfg.stream_url);
    try w.writeByte('?');
    try appendQueryBase(gpa, w, cfg);
    try w.print(
        "&encoding=linear16&sample_rate={d}&channels={d}&endpointing=100",
        .{ wav.sample_rate, wav.channels },
    );
    try appendKeyterms(gpa, w, cfg.keyterms);
    const out = try gpa.dupe(u8, aw.writer.buffered());
    aw.deinit();
    return out;
}

/// Caller frees.
pub fn buildRestUrl(gpa: std.mem.Allocator, cfg: Config) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(cfg.rest_url);
    try w.writeByte('?');
    try appendQueryBase(gpa, w, cfg);
    try appendKeyterms(gpa, w, cfg.keyterms);
    const out = try gpa.dupe(u8, aw.writer.buffered());
    aw.deinit();
    return out;
}

/// Caller frees.
pub fn parseRestTranscript(gpa: std.mem.Allocator, json_body: []const u8) ![]u8 {
    const Alt = struct { transcript: ?[]const u8 = null };
    const Channel = struct { alternatives: ?[]const Alt = null };
    const Results = struct { channels: ?[]const Channel = null };
    const T = struct { results: ?Results = null };

    const parsed = std.json.parseFromSlice(T, gpa, json_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.BadJson;
    defer parsed.deinit();

    const results = parsed.value.results orelse return error.MissingText;
    const channels = results.channels orelse return error.MissingText;
    if (channels.len == 0) return error.MissingText;
    const alternatives = channels[0].alternatives orelse return error.MissingText;
    if (alternatives.len == 0) return error.MissingText;
    const raw = alternatives[0].transcript orelse return error.MissingText;
    return try gpa.dupe(u8, std.mem.trimStart(u8, raw, " "));
}

/// Caller owns all fields and must call `deinit`.
pub const RestRequest = struct {
    /// Full Deepgram REST URL including query parameters. Allocated by `gpa`.
    url: []u8,
    /// `Authorization` value (`Token <api_key>`). Allocated by `gpa`; zeroed on `deinit`.
    auth: []u8,
    /// WAV bytes read from disk. Allocated by `gpa`.
    body: []u8,

    /// Frees `url`, `auth`, and `body`; zeros `auth` before freeing.
    pub fn deinit(self: *RestRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        @memset(self.auth, 0);
        gpa.free(self.auth);
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// Builds the REST request so callers never post to the bare endpoint.
/// Caller must call `req.deinit(gpa)`.
pub fn prepareRestRequest(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, cfg: Config) !RestRequest {
    const wav_bytes = try std.Io.Dir.cwd().readFileAlloc(io, wav_path, gpa, .limited(transcribe.wav_cap));
    errdefer gpa.free(wav_bytes);

    const url = try buildRestUrl(gpa, cfg);
    errdefer gpa.free(url);

    const auth = try std.fmt.allocPrint(gpa, "Token {s}", .{cfg.api_key});
    errdefer {
        @memset(auth, 0);
        gpa.free(auth);
    }

    return .{ .url = url, .auth = auth, .body = wav_bytes };
}

/// Caller frees.
pub fn transcribeRest(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, cfg: Config) ![]u8 {
    var req = try prepareRestRequest(io, gpa, wav_path, cfg);
    defer req.deinit(gpa);

    var detail_buf: [160]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "model=\"{s}\" wav={d}B", .{ cfg.model, req.body.len }) catch "detail unavailable";
    // Keep trace URL free of query/key material.
    const trace = log.ApiTrace.begin(io, "transcribe", cfg.rest_url, detail);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var resp: std.Io.Writer.Allocating = .init(gpa);
    defer resp.deinit();

    const res = client.fetch(.{
        .location = .{ .url = req.url },
        .method = .POST,
        .headers = .{
            .authorization = .{ .override = req.auth },
            .content_type = .{ .override = "audio/wav" },
        },
        .payload = req.body,
        .response_writer = &resp.writer,
    }) catch |err| {
        trace.failed(err);
        return error.HttpError;
    };
    if (res.status != .ok) {
        trace.rejected(@intFromEnum(res.status), resp.writer.buffered());
        return error.UpstreamRejected;
    }

    const json_body = resp.writer.buffered();
    if (json_body.len > transcribe.response_cap) {
        trace.tooLarge(@intFromEnum(res.status), json_body.len);
        return error.ResponseTooLarge;
    }
    trace.ok(@intFromEnum(res.status), json_body.len);
    return try parseRestTranscript(gpa, json_body);
}

const audio = @import("audio.zig");
const deepgram_ws = @import("deepgram_ws.zig");

pub const SessionState = enum { idle, connecting, streaming, finalizing, done, failed };

pub const keepalive_ms: u32 = 3000;
pub const finish_timeout_ms: u32 = 5000;
pub const poll_ms: u32 = 50;
pub const stop_wait_ms: u32 = 500;

const pump_samples: usize = 800;

pub const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: Config,
    fake: ?[]u8 = null,
    fake_error: ?anyerror = null,
    state: SessionState = .idle,
    err: ?anyerror = null,
    transcript: []u8 = "",
    finish_requested: bool = false,
    abort_requested: bool = false,
    /// Set by deinit when the thread is still inside a blocking call and cannot be
    /// joined. The thread frees the session and its owned memory on exit instead.
    abandoned: bool = false,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,

    pub fn start(io: std.Io, gpa: std.mem.Allocator, cfg: Config) !*Session {
        const self = try gpa.create(Session);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .cfg = cfg,
            .state = .connecting,
        };
        self.thread = std.Thread.spawn(.{}, Session.run, .{self}) catch |e| {
            gpa.destroy(self);
            return e;
        };
        return self;
    }

    pub fn startFake(gpa: std.mem.Allocator, transcript: []const u8) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        const owned = try gpa.dupe(u8, transcript);
        self.* = .{
            .io = std.testing.io,
            .gpa = gpa,
            .cfg = .{
                .rest_url = "",
                .stream_url = "",
                .model = "",
                .language = "",
                .keyterms = &.{},
                .api_key = "",
            },
            .fake = owned,
            .state = .connecting,
        };
        self.thread = std.Thread.spawn(.{}, Session.run, .{self}) catch |e| {
            gpa.free(owned);
            gpa.destroy(self);
            return e;
        };
        return self;
    }

    pub fn startFakeFailing(gpa: std.mem.Allocator, cause: anyerror) !*Session {
        const self = try gpa.create(Session);
        self.* = .{
            .io = std.testing.io,
            .gpa = gpa,
            .cfg = .{
                .rest_url = "",
                .stream_url = "",
                .model = "",
                .language = "",
                .keyterms = &.{},
                .api_key = "",
            },
            .fake_error = cause,
            .state = .connecting,
        };
        self.thread = std.Thread.spawn(.{}, Session.run, .{self}) catch |e| {
            gpa.destroy(self);
            return e;
        };
        return self;
    }

    pub fn requestFinish(self: *Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.finish_requested = true;
    }

    pub fn abort(self: *Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.abort_requested = true;
    }

    pub fn awaitTranscript(self: *Session, io: std.Io) ![]const u8 {
        const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(finish_timeout_ms + 1000));
        while (true) {
            self.mutex.lockUncancelable(io);
            const st = self.state;
            const owned_err = self.err;
            const transcript = self.transcript;
            self.mutex.unlock(io);
            switch (st) {
                .done => return transcript,
                .failed => return owned_err orelse error.StreamClosed,
                else => {},
            }
            if (deadline.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds > 0) return error.StreamTimeout;
            try io.sleep(.fromMilliseconds(poll_ms), .awake);
        }
    }

    /// `gpa` must be the allocator passed to `start`/`startFake`/`startFakeFailing`.
    /// Waits briefly for a terminal state, then joins. A Zig join cannot be
    /// interrupted, so if the thread is still inside a connect or stalled write the
    /// session is marked abandoned, the thread is detached, and the thread frees the
    /// session and its owned memory on exit.
    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.abort();
        var waited: u32 = 0;
        while (!self.settled() and waited < stop_wait_ms) : (waited += poll_ms) {
            self.io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
        }
        if (self.settled()) {
            if (self.thread) |t| t.join();
            self.freeOwned(gpa);
            gpa.destroy(self);
            return;
        }
        // Still running: the join cannot be interrupted, so hand ownership to the
        // thread instead of blocking the caller on a connect or a stalled write.
        self.mutex.lockUncancelable(self.io);
        self.abandoned = true;
        self.mutex.unlock(self.io);
        if (self.thread) |t| t.detach();
    }

    fn settled(self: *Session) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state == .done or self.state == .failed;
    }

    fn freeOwned(self: *Session, gpa: std.mem.Allocator) void {
        if (self.transcript.len != 0) gpa.free(self.transcript);
        if (self.fake) |f| gpa.free(f);
    }

    fn settle(self: *Session, state: SessionState, err: ?anyerror, transcript: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = state;
        self.err = err;
        self.transcript = transcript;
    }

    /// If deinit detached this session, the thread must free it and touch nothing after.
    fn maybeAbandonExit(self: *Session) bool {
        self.mutex.lockUncancelable(self.io);
        const abandoned = self.abandoned;
        self.mutex.unlock(self.io);
        if (!abandoned) return false;
        const gpa = self.gpa;
        self.freeOwned(gpa);
        gpa.destroy(self);
        return true;
    }

    fn flags(self: *Session) struct { finish: bool, abort_req: bool } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .finish = self.finish_requested, .abort_req = self.abort_requested };
    }

    fn setState(self: *Session, state: SessionState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = state;
    }

    fn run(self: *Session) void {
        if (self.fake != null or self.fake_error != null) return self.runFake();

        const query_url = buildStreamUrl(self.gpa, self.cfg) catch |e| {
            self.settle(.failed, e, "");
            _ = self.maybeAbandonExit();
            return;
        };
        defer self.gpa.free(query_url);

        var trace = log.StreamTrace.begin(self.io, self.cfg.stream_url);
        var conn: deepgram_ws.Connection = .{ .io = self.io, .gpa = self.gpa };
        conn.open(query_url, self.cfg.api_key) catch {
            trace.failed(error.StreamClosed);
            self.settle(.failed, error.StreamClosed, "");
            _ = self.maybeAbandonExit();
            return;
        };
        defer conn.deinit();
        self.setState(.streaming);

        var cursor: usize = 0;
        var audio_bytes: usize = 0;
        var frame: [pump_samples]i16 = undefined;
        var finish_sent = false;
        var deadline: std.Io.Timestamp = undefined;
        var last_keepalive = std.Io.Timestamp.now(self.io, .awake);

        while (true) {
            // 1. Copy with copySamplesFrom; pump if n > 0.
            const n = audio.copySamplesFrom(cursor, &frame);
            if (n > 0) {
                const bytes: []u8 = @constCast(std.mem.sliceAsBytes(frame[0..n]));
                conn.pump(bytes) catch {
                    trace.failed(error.StreamClosed);
                    self.settle(.failed, error.StreamClosed, "");
                    if (self.maybeAbandonExit()) return;
                    return;
                };
                cursor += n;
                audio_bytes += n * 2;
            }

            // Take flags out of the mutex once per iteration.
            const f = self.flags();

            // 2. Finish requested and CloseStream not yet sent: drain, send CloseStream,
            // then markFinishing only after a successful write.
            if (f.finish and !finish_sent) {
                while (true) {
                    const n2 = audio.copySamplesFrom(cursor, &frame);
                    if (n2 == 0) break;
                    const bytes2: []u8 = @constCast(std.mem.sliceAsBytes(frame[0..n2]));
                    conn.pump(bytes2) catch {
                        trace.failed(error.StreamClosed);
                        self.settle(.failed, error.StreamClosed, "");
                        if (self.maybeAbandonExit()) return;
                        return;
                    };
                    cursor += n2;
                    audio_bytes += n2 * 2;
                }
                var close_msg = "{\"type\": \"CloseStream\"}".*;
                conn.sendText(&close_msg) catch {
                    trace.failed(error.StreamClosed);
                    self.settle(.failed, error.StreamClosed, "");
                    if (self.maybeAbandonExit()) return;
                    return;
                };
                conn.markFinishing();
                finish_sent = true;
                self.setState(.finalizing);
                deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(.fromMilliseconds(finish_timeout_ms));
            }

            // 3. Finish requested and conn finished: take transcript, emit ok, settle done.
            // A failed takeTranscript must not look like success.
            if (f.finish and finish_sent and conn.state() == .finished) {
                const segments = conn.segmentCount();
                const transcript = conn.takeTranscript(self.gpa) catch |e| {
                    trace.failed(e);
                    self.settle(.failed, e, "");
                    if (self.maybeAbandonExit()) return;
                    return;
                };
                trace.ok(self.cfg.model, segments, audio_bytes);
                self.settle(.done, null, transcript);
                _ = self.maybeAbandonExit();
                return;
            }

            // 4. Finish requested and deadline passed: settle failed with StreamTimeout.
            if (f.finish and finish_sent and deadline.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds > 0) {
                trace.failed(error.StreamTimeout);
                self.settle(.failed, error.StreamTimeout, "");
                _ = self.maybeAbandonExit();
                return;
            }

            // 5. Abort flag: shutdown and settle failed with Aborted (defer deinit joins/closes).
            if (f.abort_req) {
                conn.shutdown();
                trace.failed(error.Aborted);
                self.settle(.failed, error.Aborted, "");
                _ = self.maybeAbandonExit();
                return;
            }

            // 6. Connection failed: settle failed with StreamClosed.
            if (conn.state() == .failed) {
                trace.failed(error.StreamClosed);
                self.settle(.failed, error.StreamClosed, "");
                _ = self.maybeAbandonExit();
                return;
            }

            // 7. Keepalive every keepalive_ms while not finishing.
            if (!finish_sent) {
                const now = std.Io.Timestamp.now(self.io, .awake);
                const elapsed_ms = @max(0, last_keepalive.durationTo(now).toMilliseconds());
                if (elapsed_ms >= keepalive_ms) {
                    var ka = "{\"type\": \"KeepAlive\"}".*;
                    conn.sendText(&ka) catch {
                        trace.failed(error.StreamClosed);
                        self.settle(.failed, error.StreamClosed, "");
                        if (self.maybeAbandonExit()) return;
                        return;
                    };
                    last_keepalive = now;
                }
            }

            // 8. Sleep.
            self.io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
        }
    }

    fn runFake(self: *Session) void {
        while (true) {
            const f = self.flags();
            if (f.abort_req) {
                self.settle(.failed, error.Aborted, "");
                _ = self.maybeAbandonExit();
                return;
            }
            if (f.finish) {
                if (self.fake_error) |e| {
                    self.settle(.failed, e, "");
                    _ = self.maybeAbandonExit();
                    return;
                }
                const src = self.fake orelse "";
                const owned = self.gpa.dupe(u8, src) catch {
                    self.settle(.failed, error.OutOfMemory, "");
                    _ = self.maybeAbandonExit();
                    return;
                };
                self.settle(.done, null, owned);
                _ = self.maybeAbandonExit();
                return;
            }
            self.io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
        }
    }
};

test "buildStreamUrl default config equals exact Deepgram URL" {
    const gpa = std.testing.allocator;
    const cfg: Config = .{
        .rest_url = default_rest_url,
        .stream_url = "wss://api.deepgram.com/v1/listen",
        .model = default_model,
        .language = "",
        .keyterms = &.{},
        .api_key = "unused",
    };
    const got = try buildStreamUrl(gpa, cfg);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "wss://api.deepgram.com/v1/listen?model=nova-3&punctuate=true&smart_format=true&dictation=true&language=multi&encoding=linear16&sample_rate=16000&channels=1&endpointing=100",
        got,
    );
}

test "buildRestUrl omits stream-only params and equals exact URL" {
    const gpa = std.testing.allocator;
    const cfg: Config = .{
        .rest_url = default_rest_url,
        .stream_url = "wss://api.deepgram.com/v1/listen",
        .model = default_model,
        .language = "",
        .keyterms = &.{},
        .api_key = "unused",
    };
    const got = try buildRestUrl(gpa, cfg);
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "encoding=") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "sample_rate=") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "channels=") == null);
    try std.testing.expectEqualStrings(
        "https://api.deepgram.com/v1/listen?model=nova-3&punctuate=true&smart_format=true&dictation=true&language=multi",
        got,
    );
}

test "language zh replaces multi in both URLs" {
    const gpa = std.testing.allocator;
    const cfg: Config = .{
        .rest_url = default_rest_url,
        .stream_url = "wss://api.deepgram.com/v1/listen",
        .model = default_model,
        .language = "zh",
        .keyterms = &.{},
        .api_key = "unused",
    };
    const stream = try buildStreamUrl(gpa, cfg);
    defer gpa.free(stream);
    const rest = try buildRestUrl(gpa, cfg);
    defer gpa.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, stream, "language=zh") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "language=multi") == null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "language=zh") != null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "language=multi") == null);
}

test "keyterms appended percent-encoded at end of both URLs" {
    const gpa = std.testing.allocator;
    const terms = [_][]const u8{ "zhisper", "hot dog" };
    const cfg: Config = .{
        .rest_url = default_rest_url,
        .stream_url = "wss://api.deepgram.com/v1/listen",
        .model = default_model,
        .language = "",
        .keyterms = &terms,
        .api_key = "unused",
    };
    const stream = try buildStreamUrl(gpa, cfg);
    defer gpa.free(stream);
    const rest = try buildRestUrl(gpa, cfg);
    defer gpa.free(rest);
    const suffix = "&keyterm=zhisper&keyterm=hot%20dog";
    try std.testing.expect(std.mem.endsWith(u8, stream, suffix));
    try std.testing.expect(std.mem.endsWith(u8, rest, suffix));
}

test "parseKeyterms splits, trims, and drops empty pieces" {
    const gpa = std.testing.allocator;
    const got = try parseKeyterms(gpa, " a , ,b ");
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a", got[0]);
    try std.testing.expectEqualStrings("b", got[1]);

    const empty = try parseKeyterms(gpa, "");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "percentEncode encodes spaces and reserved query chars" {
    const gpa = std.testing.allocator;
    const got = try percentEncode(gpa, "a b&c");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a%20b%26c", got);
}

test "streamUrlFor and restUrlFor convert schemes and reject unsupported" {
    const gpa = std.testing.allocator;

    const wss = try streamUrlFor(gpa, "https://x/y");
    defer gpa.free(wss);
    try std.testing.expectEqualStrings("wss://x/y", wss);

    const ws = try streamUrlFor(gpa, "http://x");
    defer gpa.free(ws);
    try std.testing.expectEqualStrings("ws://x", ws);

    const https = try restUrlFor(gpa, "wss://x/y");
    defer gpa.free(https);
    try std.testing.expectEqualStrings("https://x/y", https);

    const http = try restUrlFor(gpa, "ws://x");
    defer gpa.free(http);
    try std.testing.expectEqualStrings("http://x", http);

    try std.testing.expectError(error.UnsupportedScheme, streamUrlFor(gpa, "ftp://x"));
    try std.testing.expectError(error.UnsupportedScheme, restUrlFor(gpa, "ftp://x"));
}

test "parseRestTranscript extracts trimmed transcript and maps failures" {
    const gpa = std.testing.allocator;

    const got = try parseRestTranscript(
        gpa,
        "{\"results\":{\"channels\":[{\"alternatives\":[{\"transcript\":\" hello world\"}]}]}}",
    );
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello world", got);

    try std.testing.expectError(
        error.MissingText,
        parseRestTranscript(gpa, "{\"results\":{\"channels\":[]}}"),
    );
    try std.testing.expectError(error.MissingText, parseRestTranscript(gpa, "{}"));
    try std.testing.expectError(error.BadJson, parseRestTranscript(gpa, "not json"));
}

test "prepareRestRequest builds full REST URL, auth, and body" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const wav_path = "task3-deepgram-prepare.wav";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wav_path, .data = "RIFF" });
    defer std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};

    const cfg: Config = .{
        .rest_url = default_rest_url,
        .stream_url = "wss://api.deepgram.com/v1/listen",
        .model = default_model,
        .language = "",
        .keyterms = &.{},
        .api_key = "k123",
    };

    var req = try prepareRestRequest(io, gpa, wav_path, cfg);
    defer req.deinit(gpa);

    const want_url = try buildRestUrl(gpa, cfg);
    defer gpa.free(want_url);
    try std.testing.expectEqualStrings(want_url, req.url);
    try std.testing.expect(std.mem.indexOf(u8, req.url, "model=nova-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.url, "language=multi") != null);
    try std.testing.expectEqualStrings("Token k123", req.auth);
    try std.testing.expectEqualStrings("RIFF", req.body);
}

test "transcribeRest against discard port fails without network" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "task3-deepgram-discard.wav", .data = "RIFF" });
    defer std.Io.Dir.cwd().deleteFile(io, "task3-deepgram-discard.wav") catch {};

    const cfg: Config = .{
        .rest_url = "http://127.0.0.1:9/v1/listen",
        .stream_url = "ws://127.0.0.1:9/v1/listen",
        .model = default_model,
        .language = "",
        .keyterms = &.{},
        .api_key = "dummy-key",
    };
    const err = transcribeRest(io, gpa, "task3-deepgram-discard.wav", cfg) catch |e| e;
    try std.testing.expect(err == error.HttpError);
}

test "live Deepgram REST transcribe (opt-in)" {
    const live = std.c.getenv("DEEPGRAM_LIVE") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(live), "1")) return error.SkipZigTest;
    const key = std.c.getenv("DEEPGRAM_API_KEY") orelse return error.SkipZigTest;
    const api_key = std.mem.span(key);
    if (api_key.len == 0) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    // Tiny silence WAV (16 samples) — proves auth + post + parse end-to-end.
    const silence = [_]i16{0} ** 16;
    var hdr: [wav.header_len]u8 = undefined;
    wav.header(silence.len, &hdr);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(&hdr);
    try aw.writer.writeAll(std.mem.sliceAsBytes(&silence));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "task3-deepgram-live.wav", .data = aw.writer.buffered() });
    defer std.Io.Dir.cwd().deleteFile(io, "task3-deepgram-live.wav") catch {};

    const cfg: Config = .{
        .rest_url = default_rest_url,
        .stream_url = "wss://api.deepgram.com/v1/listen",
        .model = default_model,
        .language = "",
        .keyterms = &.{},
        .api_key = api_key,
    };
    const got = try transcribeRest(io, gpa, "task3-deepgram-live.wav", cfg);
    defer gpa.free(got);
    // Silence may transcribe to empty; what matters is it is trimmed (no leading space).
    try std.testing.expect(got.len == 0 or got[0] != ' ');
}

test "Session fake success returns transcript" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const s = try Session.startFake(gpa, "hello");
    defer s.deinit(gpa);
    s.requestFinish();
    const got = try s.awaitTranscript(io);
    try std.testing.expectEqualStrings("hello", got);
}

test "Session fake failure returns recorded error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const s = try Session.startFakeFailing(gpa, error.StreamClosed);
    defer s.deinit(gpa);
    s.requestFinish();
    try std.testing.expectError(error.StreamClosed, s.awaitTranscript(io));
}

test "Session abort settles failed with Aborted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const s = try Session.startFake(gpa, "hello");
    defer s.deinit(gpa);
    s.abort();
    try std.testing.expectError(error.Aborted, s.awaitTranscript(io));
}

test "Session deinit without finish does not hang or leak" {
    const gpa = std.testing.allocator;
    const s = try Session.startFake(gpa, "x");
    s.deinit(gpa);
}

test "Session fake empty transcript returns empty slice" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const s = try Session.startFake(gpa, "");
    defer s.deinit(gpa);
    s.requestFinish();
    const got = try s.awaitTranscript(io);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
