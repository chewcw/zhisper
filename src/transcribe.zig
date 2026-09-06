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
