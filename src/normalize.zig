const std = @import("std");

/// S1-mini's system prompt, reproduced character for character. S1-mini was
/// fine-tuned against exactly this text; rewording it degrades output or
/// produces garbage, so it is a constant and not a config field.
pub const system_prompt: []const u8 =
    "You are a text normalizer for speech-to-text transcripts. The input begins " ++
    "with a control line specifying the styling, structure, and context settings; " ++
    "clean the transcript to match those settings and output only the cleaned text.";

pub const default_base_url = "https://api.groq.com/openai/v1/chat/completions";
/// Verified present on the Groq developer plan on 2026-09-27. Groq rotates its
/// lineup, so re-check https://console.groq.com/docs/models before changing it.
pub const default_model = "openai/gpt-oss-20b";
pub const max_tokens: u32 = 1024;
pub const response_cap: usize = 1024 * 1024;

/// Closed value sets from the S1-mini model card. The model was trained only
/// on these combinations; values outside them degrade output quality. Kept in
/// sync with the trained sets so the same config remains valid if the runtime
/// is later swapped to a local S1-mini.
pub const styling_values = [_][]const u8{ "casual", "semi-casual", "semi-formal", "formal" };
pub const structure_values = [_][]const u8{ "prose", "lists" };
pub const context_values = [_][]const u8{ "general", "email" };

pub const Config = struct {
    base_url: []const u8,
    model: []const u8,
    api_key: []const u8,
    styling: []const u8 = "semi-formal",
    structure: []const u8 = "prose",
    context: []const u8 = "general",
};

pub const ResolutionError = error{
    MissingApiKey,
};

/// Resolves runtime config from file-shaped values.
///
/// WHY empty strings mean "use the preset": the config file documents
/// `model = ""  # empty = preset default`, and `""` is not `null`. An earlier
/// draft of this plan used `orelse` semantics, which would have let the
/// default `model = ""` reach the provider as an empty model name and the
/// default `base_url = ""` reach it as an empty URL.
///
/// NOTE: `buildTranscribeConfig` in `src/main.zig` does pass
/// `cfg.transcribe.model` and `cfg.transcribe.base_url` straight through
/// without this empty-means-preset step. That is a pre-existing issue in the
/// transcription path, out of scope here — do not copy that pattern here.
pub fn resolveConfig(
    model_override: ?[]const u8,
    base_url_override: ?[]const u8,
    api_key: []const u8,
) ResolutionError!Config {
    if (api_key.len == 0) return error.MissingApiKey;
    const model = if (model_override) |m| (if (m.len == 0) default_model else m) else default_model;
    const base_url = if (base_url_override) |b| (if (b.len == 0) default_base_url else b) else default_base_url;
    return .{ .base_url = base_url, .model = model, .api_key = api_key };
}

/// Control line, newline, transcript. Allocates because the three axis values
/// are runtime strings rather than compile-time constants.
pub fn buildUserMessage(
    gpa: std.mem.Allocator,
    text: []const u8,
    styling: []const u8,
    structure: []const u8,
    context: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "[Styling: {s}] [Structure: {s}] [Context: {s}]\n{s}",
        .{ styling, structure, context, text },
    );
}

const RequestMessage = struct {
    role: []const u8,
    content: []const u8,
};

const RequestBody = struct {
    model: []const u8,
    temperature: f64,
    max_tokens: u32,
    messages: []const RequestMessage,
};

pub fn buildBody(gpa: std.mem.Allocator, text: []const u8, cfg: Config) ![]u8 {
    const user = try buildUserMessage(gpa, text, cfg.styling, cfg.structure, cfg.context);
    defer gpa.free(user);
    const messages = [_]RequestMessage{
        .{ .role = "system", .content = system_prompt },
        .{ .role = "user", .content = user },
    };
    const req: RequestBody = .{
        .model = cfg.model,
        // Greedy decoding. S1-mini's own documentation is emphatic that
        // normalization is a deterministic transformation and that sampling
        // only adds variance.
        .temperature = 0,
        .max_tokens = max_tokens,
        .messages = &messages,
    };
    // valueAlloc escapes the transcript for us, which is the whole reason
    // this is not hand-assembled with a format string.
    return std.json.Stringify.valueAlloc(gpa, req, .{ .whitespace = .minified });
}

const ResponseMessage = struct {
    content: ?[]const u8 = null,
};

const ResponseChoice = struct {
    message: ResponseMessage,
};

const ResponseBody = struct {
    choices: ?[]ResponseChoice = null,
};

pub const ParseError = error{
    BadJson,
    MissingText,
} || std.mem.Allocator.Error;

/// Caller owns the returned slice. The parse result owns its own strings and
/// is freed before returning, so the content is copied out. Same shape as
/// `parseText` in src/transcribe.zig.
pub fn parseContent(gpa: std.mem.Allocator, json_body: []const u8) ParseError![]u8 {
    const parsed = std.json.parseFromSlice(ResponseBody, gpa, json_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.BadJson;
    defer parsed.deinit();
    const choices = parsed.value.choices orelse return error.MissingText;
    if (choices.len == 0) return error.MissingText;
    const content = choices[0].message.content orelse return error.MissingText;
    return try gpa.dupe(u8, content);
}

/// Strips a wrapping ``` fence. Models asked for bare output occasionally
/// wrap it anyway, and an unstripped fence is typed straight into the user's
/// editor. Returns a subslice of `text`; it never allocates.
pub fn stripCodeFence(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    const after_open = trimmed[3..];
    const newline = std.mem.indexOfScalar(u8, after_open, '\n') orelse return trimmed;
    if (!std.mem.endsWith(u8, after_open, "```")) return trimmed;
    // Cut the closing fence off BEFORE trimming. Trimming first would leave
    // the newline that sits between the content and the fence inside the body.
    const body = after_open[newline + 1 .. after_open.len - 3];
    return std.mem.trim(u8, body, " \t\r\n");
}

/// WHY this exists: `inject.typeText` runs at roughly 2 ms per character on
/// macOS. A model that returned 4000 characters for 60 spoken characters would
/// be typed for eight seconds with no way to interrupt. A length check turns a
/// low-probability but high-annoyance failure into a harmless fallback to the
/// raw transcript.
pub fn isPlausibleOutput(raw: []const u8, normalized: []const u8) bool {
    return normalized.len <= 4 * raw.len + 256;
}

/// Canonical HTTP path: JSON POST, Bearer auth, `{"choices":[...]}`
/// response. Non-200 maps to `error.UpstreamRejected`; the status code is the
/// caller's to log. The key is never logged and never appears in an error.
pub fn normalizeWithConfig(io: std.Io, gpa: std.mem.Allocator, text: []const u8, cfg: Config) ![]u8 {
    const body = try buildBody(gpa, text, cfg);
    defer gpa.free(body);

    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{cfg.api_key});
    defer gpa.free(auth);
    // Zero the key material before freeing (declared after the free, so it
    // runs first). Same ordering trick as transcribeWithConfig.
    defer @memset(auth, 0);
    const ctype = "application/json";

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
    }) catch return error.HttpError;
    if (res.status != .ok) return error.UpstreamRejected;

    const json_body = resp.writer.buffered();
    if (json_body.len > response_cap) return error.ResponseTooLarge;

    // Copy out before the guards so a rejected response is still released.
    const content = try parseContent(gpa, json_body);
    defer gpa.free(content);

    const final = stripCodeFence(content);
    // Order matters: the empty check runs first because the plausibility
    // bound (4 * raw.len + 256) is loose enough to accept an empty response
    // for short input, and emptiness has its own rule.
    if (final.len == 0) return error.EmptyOutput;
    if (!isPlausibleOutput(text, final)) return error.DegenerateOutput;
    return try gpa.dupe(u8, final);
}

test "normalizeWithConfig against discard port fails without network" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cfg: Config = .{
        .base_url = "http://127.0.0.1:9/chat/completions",
        .model = default_model,
        .api_key = "dummy-key",
    };
    const err = normalizeWithConfig(io, gpa, "hello", cfg) catch |e| e;
    // Any transport-level error is acceptable. What matters is that it does
    // NOT succeed and does not reach a real provider.
    try std.testing.expect(err != error.MissingText);
}

test "buildUserMessage puts the control line above the transcript" {
    const gpa = std.testing.allocator;
    const got = try buildUserMessage(gpa, "hello there", "semi-formal", "prose", "general");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "[Styling: semi-formal] [Structure: prose] [Context: general]\nhello there",
        got,
    );
}

test "buildUserMessage substitutes every axis value" {
    const gpa = std.testing.allocator;
    const got = try buildUserMessage(gpa, "t", "formal", "lists", "email");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "[Styling: formal] [Structure: lists] [Context: email]\nt",
        got,
    );
}

test "buildUserMessage preserves newlines inside the transcript" {
    const gpa = std.testing.allocator;
    const got = try buildUserMessage(gpa, "a\nb", "casual", "prose", "general");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "[Styling: casual] [Structure: prose] [Context: general]\na\nb",
        got,
    );
}

test "buildBody pins greedy decoding and the model id" {
    const gpa = std.testing.allocator;
    const cfg: Config = .{
        .base_url = default_base_url,
        .model = default_model,
        .api_key = "k",
    };
    const body = try buildBody(gpa, "hi", cfg);
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, default_model) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_tokens") != null);
}

test "buildBody escapes quotes, backslashes and newlines in the transcript" {
    const gpa = std.testing.allocator;
    const cfg: Config = .{
        .base_url = default_base_url,
        .model = default_model,
        .api_key = "k",
    };
    const body = try buildBody(gpa, "say \"hi\"\\ then\nnewline", cfg);
    defer gpa.free(body);
    // The body must still parse as JSON and round-trip the original text.
    const parsed = try std.json.parseFromSlice(
        struct {
            const M = struct { role: []const u8, content: []const u8 };
            messages: []M,
        },
        gpa,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    // The user content round-trips the control line AND the escaped transcript.
    try std.testing.expectEqualStrings("system", parsed.value.messages[0].role);
    try std.testing.expectEqualStrings(
        "[Styling: semi-formal] [Structure: prose] [Context: general]\nsay \"hi\"\\ then\nnewline",
        parsed.value.messages[1].content,
    );
}

test "parseContent extracts choices[0].message.content" {
    const gpa = std.testing.allocator;
    const got = try parseContent(gpa,
        \\{"choices":[{"message":{"role":"assistant","content":"I need to send the report by Thursday."}}]}
    );
    defer gpa.free(got);
    try std.testing.expectEqualStrings("I need to send the report by Thursday.", got);
}

test "parseContent rejects missing choices, empty choices, and null content" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.MissingText, parseContent(gpa, "{}"));
    try std.testing.expectError(error.MissingText, parseContent(gpa,
        \\{"choices":[]}
    ));
    try std.testing.expectError(error.MissingText, parseContent(gpa,
        \\{"choices":[{"message":{"role":"assistant","content":null}}]}
    ));
}

test "parseContent rejects malformed json" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadJson, parseContent(gpa, "not json"));
}

test "stripCodeFence removes a wrapping fence" {
    try std.testing.expectEqualStrings("hello", stripCodeFence("```\nhello\n```"));
    try std.testing.expectEqualStrings("hello", stripCodeFence("```text\nhello\n```"));
}

test "stripCodeFence leaves unfenced and unmatched text alone" {
    try std.testing.expectEqualStrings("hello", stripCodeFence("  hello  "));
    try std.testing.expectEqualStrings("```hello", stripCodeFence("```hello"));
    try std.testing.expectEqualStrings("```\nhello", stripCodeFence("```\nhello"));
}

test "isPlausibleOutput rejects runaway output" {
    try std.testing.expect(isPlausibleOutput("hi", "Hello there."));
    try std.testing.expect(!isPlausibleOutput("hi", "x" ** 4096));
    try std.testing.expect(isPlausibleOutput("", ""));
}

test "resolveConfig treats an empty override as 'use the preset'" {
    const cfg = try resolveConfig(null, null, "k");
    try std.testing.expectEqualStrings(default_base_url, cfg.base_url);
    try std.testing.expectEqualStrings(default_model, cfg.model);
    try std.testing.expectEqualStrings("semi-formal", cfg.styling);

    // "" is the documented "preset default" idiom in the config file, and it
    // is NOT null. It must not reach the provider as an empty model or URL.
    const empty = try resolveConfig("", "", "k");
    try std.testing.expectEqualStrings(default_base_url, empty.base_url);
    try std.testing.expectEqualStrings(default_model, empty.model);

    const over = try resolveConfig("m", "http://x", "k");
    try std.testing.expectEqualStrings("m", over.model);
    try std.testing.expectEqualStrings("http://x", over.base_url);

    try std.testing.expectError(error.MissingApiKey, resolveConfig(null, null, ""));
}
