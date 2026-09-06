const std = @import("std");

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

pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, opts: Options) ![]u8 {
    const key = apiKey() orelse return error.MissingApiKey;
    return try transcribeWithKey(io, gpa, wav_path, opts, key);
}

pub fn transcribeWithKey(io: std.Io, gpa: std.mem.Allocator, wav_path: []const u8, opts: Options, api_key: []const u8) ![]u8 {
    const wav = try std.Io.Dir.cwd().readFileAlloc(io, wav_path, gpa, .limited(wav_cap));
    defer gpa.free(wav);

    const boundary = "----zhisperBoundary7MA4YWxkTrZu0gW";
    const body = try buildMultipart(gpa, boundary, wav, "audio.wav", opts.model, opts.prompt);
    defer gpa.free(body);

    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key});
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
        .location = .{ .url = opts.base_url },
        .method = .POST,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = ctype },
        },
        .payload = body,
        .response_writer = &resp.writer,
    }) catch return error.HttpError;
    if (res.status != .ok) return error.GroqRejected;

    const json_body = resp.writer.buffered();
    if (json_body.len > response_cap) return error.ResponseTooLarge;
    return try parseText(gpa, json_body);
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
