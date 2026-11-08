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
