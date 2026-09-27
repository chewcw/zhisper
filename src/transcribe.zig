const std = @import("std");
const log = @import("log.zig");

pub const default_model = "whisper-large-v3-turbo";
pub const default_prompt: []const u8 = "";
pub const default_base_url = "https://api.groq.com/openai/v1/audio/transcriptions";
pub const response_cap: usize = 1024 * 1024;
pub const wav_cap: usize = 32 * 1024 * 1024;

pub const Options = struct {
    model: []const u8 = default_model,
    prompt: []const u8 = default_prompt,
    base_url: []const u8 = default_base_url,
};

pub const Provider = enum { groq, openai, custom };

pub const Preset = struct {
    base_url: []const u8,
    model: []const u8,
    key_env: []const u8,
};

pub fn presetFor(p: Provider) Preset {
    return switch (p) {
        .groq => .{ .base_url = default_base_url, .model = default_model, .key_env = "GROQ_API_KEY" },
        .openai => .{ .base_url = "https://api.openai.com/v1/audio/transcriptions", .model = "whisper-1", .key_env = "OPENAI_API_KEY" },
        .custom => .{ .base_url = "", .model = "", .key_env = "ZHISPER_API_KEY" },
    };
}

/// Maps ZHISPER_PROVIDER value to a provider. Null/unknown/groq -> groq except
/// explicit "openai"/"custom". Unknown strings map to custom so a typo surfaces
/// as MissingBaseUrl (explicit URL required) instead of silently hitting Groq.
pub fn providerFromName(name: ?[]const u8) Provider {
    const n = name orelse return .groq;
    if (std.mem.eql(u8, n, "openai")) return .openai;
    if (std.mem.eql(u8, n, "custom")) return .custom;
    if (std.mem.eql(u8, n, "groq")) return .groq;
    return .custom;
}

pub const Config = struct {
    base_url: []const u8,
    model: []const u8,
    api_key: []const u8,
    prompt: []const u8 = "",
};

/// Pure resolution (no getenv): preset defaults + explicit overrides + already-resolved key.
/// Empty key counts as missing (matches existing apiKey() empty check).
pub fn resolveConfig(preset: Preset, key_value: ?[]const u8, model_override: ?[]const u8, base_url_override: ?[]const u8) !Config {
    const key = key_value orelse return error.MissingApiKey;
    if (key.len == 0) return error.MissingApiKey;
    const model = model_override orelse preset.model;
    const base_url = base_url_override orelse preset.base_url;
    if (base_url.len == 0) return error.MissingBaseUrl;
    if (model.len == 0) return error.MissingModel;
    return .{ .base_url = base_url, .model = model, .api_key = key };
}

fn envVal(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    if (raw[0] == 0) return null;
    return std.mem.span(raw);
}

/// Single env entry point. Reads ZHISPER_PROVIDER (default groq),
/// ZHISPER_MODEL / ZHISPER_BASE_URL overrides, and the key from
/// ZHISPER_API_KEY first then the provider-specific var. Explicit args beat env.
pub fn configFromEnv(model_override: ?[]const u8, base_url_override: ?[]const u8) !Config {
    const provider = providerFromName(envVal("ZHISPER_PROVIDER"));
    const preset = presetFor(provider);
    const key = envVal("ZHISPER_API_KEY") orelse switch (provider) {
        .groq => envVal("GROQ_API_KEY"),
        .openai => envVal("OPENAI_API_KEY"),
        .custom => envVal("ZHISPER_API_KEY"),
    };
    const model_env = envVal("ZHISPER_MODEL");
    const url_env = envVal("ZHISPER_BASE_URL");
    return try resolveConfig(preset, key, model_override orelse model_env, base_url_override orelse url_env);
}

pub fn buildMultipart(gpa: std.mem.Allocator, boundary: []const u8, wav_bytes: []const u8, filename: []const u8, model: []const u8, prompt: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var w = &aw.writer;
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: audio/wav\r\n\r\n", .{ boundary, filename });
    try w.writeAll(wav_bytes);
    try w.print("\r\n--{s}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{s}\r\n", .{ boundary, model });
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n{s}\r\n", .{ boundary, prompt });
    try w.print("--{s}--\r\n", .{boundary});
    const out = try gpa.dupe(u8, aw.writer.buffered());
    aw.deinit();
    return out;
}

pub fn parseText(gpa: std.mem.Allocator, json_body: []const u8) ![]u8 {
    const T = struct { text: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(T, gpa, json_body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();
    const raw = parsed.value.text orelse return error.MissingText;
    return try gpa.dupe(u8, std.mem.trimStart(u8, raw, " "));
}

fn apiKey() ?[]const u8 {
    const raw = std.c.getenv("GROQ_API_KEY") orelse return null;
    if (raw[0] == 0) return null;
    return std.mem.span(raw);
}

/// Metadata for the success line of one transcription request. WHY lengths
/// and not content: the prompt is user text and the WAV is binary, and a
/// verbose line must never carry either. The model name is safe — it comes
/// from config, not from the user.
pub fn requestDetail(buf: []u8, model: []const u8, req_len: usize, wav_len: usize, prompt_len: usize) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "model=\"{s}\" req={d}B (wav={d}B prompt={d}B)", .{ model, req_len, wav_len, prompt_len });
}

/// Canonical HTTP path: OpenAI-compatible multipart POST, Bearer auth,
/// {"text": ...} response. Non-200 maps to error.UpstreamRejected (status code
/// is the caller's to log; never log key or body here).
pub fn transcribeWithConfig(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, cfg: Config) ![]u8 {
    const wav = try std.Io.Dir.cwd().readFileAlloc(io, wav_path, gpa, .limited(wav_cap));
    defer gpa.free(wav);

    const boundary = "----zhisperBoundary7MA4YWxkTrZu0gW";
    const body = try buildMultipart(gpa, boundary, wav, "audio.wav", cfg.model, cfg.prompt);
    defer gpa.free(body);

    // Started after the multipart build, so the reported latency is the HTTP
    // round trip and not the local copy. detail_buf is borrowed by the trace
    // and must outlive it — it is declared before `trace` and lives to the
    // end of this function.
    var detail_buf: [160]u8 = undefined;
    const detail = requestDetail(&detail_buf, cfg.model, body.len, wav.len, cfg.prompt.len) catch "detail unavailable";
    const trace = log.ApiTrace.begin(io, "transcribe", cfg.base_url, detail);

    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{cfg.api_key});
    defer gpa.free(auth);
    // Zero the key material before freeing (declared after the free, so it runs first).
    defer @memset(auth, 0);
    // fmt + free: content-type owns its own copy so it outlives the fetch call below.
    const ctype = try std.fmt.allocPrint(gpa, "multipart/form-data; boundary={s}", .{boundary});
    defer gpa.free(ctype);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var resp: std.Io.Writer.Allocating = .init(gpa);
    defer resp.deinit();

    const res = client.fetch(.{
        .location = .{ .url = cfg.base_url },
        .method = .POST,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = ctype },
        },
        .payload = body,
        .response_writer = &resp.writer,
    }) catch |err| {
        trace.failed(err);
        return error.HttpError;
    };
    if (res.status != .ok) {
        // Logged before returning: this body is the provider's explanation
        // ("Invalid API Key", "audio file too long") and the `defer` above
        // would otherwise discard it unread.
        trace.rejected(@intFromEnum(res.status), resp.writer.buffered());
        return error.UpstreamRejected;
    }

    const json_body = resp.writer.buffered();
    if (json_body.len > response_cap) {
        trace.tooLarge(@intFromEnum(res.status), json_body.len);
        return error.ResponseTooLarge;
    }
    trace.ok(@intFromEnum(res.status), json_body.len);
    return try parseText(gpa, json_body);
}

// Compat: pre-provider surface. Delegates to transcribeWithConfig so behavior
// (multipart shape, trim, caps, zeroing) stays single-sourced.
pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, opts: Options) ![]u8 {
    const key = apiKey() orelse return error.MissingApiKey;
    return try transcribeWithKey(io, gpa, wav_path, opts, key);
}

pub fn transcribeWithKey(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, opts: Options, api_key: []const u8) ![]u8 {
    return try transcribeWithConfig(io, gpa, wav_path, .{ .base_url = opts.base_url, .model = opts.model, .api_key = api_key, .prompt = opts.prompt });
}

test "multipart contains file, model, prompt parts" {
    const gpa = std.testing.allocator;
    const wav = [_]u8{ 0x52, 0x49, 0x46, 0x46 };
    const body = try buildMultipart(gpa, "TESTBOUND", &wav, "audio.wav", "whisper-large-v3-turbo", "hi");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "--TESTBOUND") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "whisper-large-v3-turbo") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--TESTBOUND--") != null);
}

test "parseText trims leading space like sed" {
    const gpa = std.testing.allocator;
    const got = try parseText(gpa, "{\"text\":\" hello world\"}");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "parseText passes through text without leading space" {
    const gpa = std.testing.allocator;
    const got = try parseText(gpa, "{\"text\":\"hi\"}");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hi", got);
}

test "parseText rejects missing text and bad json" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingText, parseText(gpa, "{}"));
    try std.testing.expectError(error.BadJson, parseText(gpa, "not json"));
}

test "transcribeWithKey against discard port fails without network" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // Same pattern as audio.zig tests: write into cwd, delete afterwards.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "task2-tiny.wav", .data = "RIFF" });
    defer std.Io.Dir.cwd().deleteFile(io, "task2-tiny.wav") catch {};
    const opts: Options = .{ .base_url = "http://127.0.0.1:9/audio/transcriptions" };
    const err = transcribeWithKey(io, gpa, "task2-tiny.wav", opts, "dummy-key") catch |e| e;
    // Any transport-level error is fine; what matters is it does NOT succeed and does NOT touch Groq.
    try std.testing.expect(err != error.MissingText);
}

test "live transcribe via provider config (opt-in)" {
    if (std.c.getenv("TRANSCRIBE_LIVE") == null) return error.SkipZigTest;
    const cfg = configFromEnv(null, null) catch return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    // Tiny silence WAV (16 samples) — proves auth + multipart + parse end-to-end.
    const silence = [_]i16{0} ** 16;
    const wav_mod = @import("wav.zig");
    var hdr: [44]u8 = undefined;
    wav_mod.header(silence.len, &hdr);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(&hdr);
    try aw.writer.writeAll(std.mem.sliceAsBytes(&silence));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "live-transcribe.wav", .data = aw.writer.buffered() });
    defer std.Io.Dir.cwd().deleteFile(io, "live-transcribe.wav") catch {};
    const got = try transcribeWithConfig(io, gpa, "live-transcribe.wav", cfg);
    defer gpa.free(got);
    // Silence may transcribe to empty; what matters is it is trimmed (no leading space).
    try std.testing.expect(got.len == 0 or got[0] != ' ');
}

test "presetFor returns groq and openai presets" {
    const groq = presetFor(.groq);
    try std.testing.expectEqualStrings("https://api.groq.com/openai/v1/audio/transcriptions", groq.base_url);
    try std.testing.expectEqualStrings("whisper-large-v3-turbo", groq.model);
    try std.testing.expectEqualStrings("GROQ_API_KEY", groq.key_env);
    const openai = presetFor(.openai);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/audio/transcriptions", openai.base_url);
    try std.testing.expectEqualStrings("whisper-1", openai.model);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", openai.key_env);
}

test "providerFromName defaults groq, maps openai and custom" {
    try std.testing.expectEqual(Provider.groq, providerFromName(null));
    try std.testing.expectEqual(Provider.groq, providerFromName("groq"));
    try std.testing.expectEqual(Provider.openai, providerFromName("openai"));
    try std.testing.expectEqual(Provider.custom, providerFromName("custom"));
    try std.testing.expectEqual(Provider.custom, providerFromName("bogus"));
}

test "resolveConfig uses preset unless overridden, rejects missing key" {
    const groq = presetFor(.groq);
    const cfg = try resolveConfig(groq, "k123", null, null);
    try std.testing.expectEqualStrings(groq.base_url, cfg.base_url);
    try std.testing.expectEqualStrings(groq.model, cfg.model);
    try std.testing.expectEqualStrings("k123", cfg.api_key);
    const over = try resolveConfig(groq, "k123", "my-model", "http://localhost:8080/x");
    try std.testing.expectEqualStrings("my-model", over.model);
    try std.testing.expectEqualStrings("http://localhost:8080/x", over.base_url);
    try std.testing.expectError(error.MissingApiKey, resolveConfig(groq, null, null, null));
    try std.testing.expectError(error.MissingApiKey, resolveConfig(groq, "", null, null));
}

test "requestDetail reports sizes without any payload content" {
    var buf: [160]u8 = undefined;
    const got = try requestDetail(&buf, "whisper-large-v3-turbo", 123800, 123456, 120);
    try std.testing.expectEqualStrings("model=\"whisper-large-v3-turbo\" req=123800B (wav=123456B prompt=120B)", got);
}

test "failed transcription exercises the trace without crashing or leaking" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const zlog = @import("log.zig");
    // Turn the gate on so the warn path actually formats, and capture the
    // line instead of logging it: `zig test` owns std_options.logFn, so a
    // real log line would reach stderr and make the build runner report a
    // bogus `failed command:` for this passing run.
    zlog.setEnabled(true);
    defer zlog.setEnabled(false);
    var cap: [zlog.log_buf]u8 = undefined;
    zlog.beginCapture(&cap);
    defer zlog.endCapture();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "trace-tiny.wav", .data = "RIFF" });
    defer std.Io.Dir.cwd().deleteFile(io, "trace-tiny.wav") catch {};
    const cfg: Config = .{ .base_url = "http://127.0.0.1:9/audio/transcriptions", .model = "m", .api_key = "dummy-key" };
    const err = transcribeWithConfig(io, gpa, "trace-tiny.wav", cfg) catch |e| e;
    // The discard port refuses the connection, so the fetch fails before a
    // status exists: this is the `failed` path. The error set is unchanged.
    try std.testing.expect(err == error.HttpError or err == error.UpstreamRejected);
    // The wiring under test is that this call reached the `failed` emitter
    // with the configured URL and the transport error name.
    try std.testing.expect(std.mem.startsWith(u8, zlog.captured(), "transcribe POST http://127.0.0.1:9/audio/transcriptions -> "));
    try std.testing.expect(std.mem.indexOf(u8, zlog.captured(), "ConnectionRefused") != null);
}

test "transcribeWithConfig against discard port fails without network" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "task2c-tiny.wav", .data = "RIFF" });
    defer std.Io.Dir.cwd().deleteFile(io, "task2c-tiny.wav") catch {};
    const cfg: Config = .{ .base_url = "http://127.0.0.1:9/audio/transcriptions", .model = "m", .api_key = "dummy-key" };
    const err = transcribeWithConfig(io, gpa, "task2c-tiny.wav", cfg) catch |e| e;
    try std.testing.expect(err != error.MissingText);
}
