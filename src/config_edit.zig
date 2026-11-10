const std = @import("std");

/// Byte range of one value token, quotes included for a string.
pub const Span = struct { start: usize, end: usize };

/// Declared here so the reader and the writer name the same limit.
pub const max_config_bytes: usize = 1024 * 1024;

const Range = struct { start: usize, end: usize };

/// Range of the section body: from its header line to the next header or EOF.
fn sectionRange(doc: []const u8, section: []const u8) ?Range {
    var start: ?usize = null;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, doc, '\n');
    while (it.next()) |line| {
        const line_start = offset;
        offset += line.len + 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] != '[') continue;
        const close = std.mem.indexOfScalar(u8, t, ']') orelse continue;
        if (start) |s| return .{ .start = s, .end = line_start };
        if (std.mem.eql(u8, t[1..close], section)) start = line_start;
    }
    if (start) |s| return .{ .start = s, .end = doc.len };
    return null;
}

pub fn findValue(doc: []const u8, section: []const u8, key: []const u8) ?Span {
    const range = sectionRange(doc, section) orelse return null;
    var offset = range.start;
    var it = std.mem.splitScalar(u8, doc[range.start..range.end], '\n');
    while (it.next()) |line| {
        const line_start = offset;
        offset += line.len + 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (!std.mem.startsWith(u8, t, key)) continue;
        var i = key.len;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len or t[i] != '=') continue;
        i += 1;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len) continue;
        const lead = @intFromPtr(t.ptr) - @intFromPtr(line.ptr);
        const start = line_start + lead + i;
        const end = if (t[i] == '"') quotedEnd(doc, start) orelse return null else bareEnd(doc, start);
        return .{ .start = start, .end = end };
    }
    return null;
}

fn quotedEnd(doc: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < doc.len) : (i += 1) {
        if (doc[i] == '\\') {
            i += 1;
            continue;
        }
        if (doc[i] == '"') return i + 1;
    }
    return null;
}

fn bareEnd(doc: []const u8, start: usize) usize {
    var i = start;
    while (i < doc.len) : (i += 1) switch (doc[i]) {
        ' ', '\t', '\r', '\n', '#' => break,
        else => {},
    };
    return i;
}

pub fn replaceValue(arena: std.mem.Allocator, doc: []const u8, span: Span, rendered: []const u8) ![]u8 {
    return std.mem.concat(arena, u8, &.{ doc[0..span.start], rendered, doc[span.end..] });
}

/// Appends `key = value` to the named section, or appends the section itself
/// when it is absent. Blank lines after the section body stay after the key.
pub fn insertKey(arena: std.mem.Allocator, doc: []const u8, section: []const u8, key: []const u8, rendered: []const u8) ![]u8 {
    const eol: []const u8 = if (std.mem.indexOf(u8, doc, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (sectionRange(doc, section)) |range| {
        var cut = range.end;
        while (cut > range.start and (doc[cut - 1] == '\n' or doc[cut - 1] == '\r')) cut -= 1;
        try out.appendSlice(arena, doc[0..cut]);
        try out.appendSlice(arena, eol);
        try out.appendSlice(arena, key);
        try out.appendSlice(arena, " = ");
        try out.appendSlice(arena, rendered);
        try out.appendSlice(arena, doc[cut..]);
        return out.toOwnedSlice(arena);
    }
    try out.appendSlice(arena, doc);
    if (doc.len != 0) {
        if (doc[doc.len - 1] != '\n') try out.appendSlice(arena, eol);
        try out.appendSlice(arena, eol);
    }
    try out.appendSlice(arena, "[");
    try out.appendSlice(arena, section);
    try out.appendSlice(arena, "]");
    try out.appendSlice(arena, eol);
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, " = ");
    try out.appendSlice(arena, rendered);
    try out.appendSlice(arena, eol);
    return out.toOwnedSlice(arena);
}

test "findValue returns the value token inside the named section only" {
    const doc =
        \\[transcribe]
        \\model = ""      # empty = preset default
        \\
        \\[normalize]
        \\model = "openai/gpt-oss-20b"        # empty = preset default
        \\enabled = false
        \\
    ;
    const n = findValue(doc, "normalize", "model").?;
    try std.testing.expectEqualStrings("\"openai/gpt-oss-20b\"", doc[n.start..n.end]);
    const t = findValue(doc, "transcribe", "model").?;
    try std.testing.expectEqualStrings("\"\"", doc[t.start..t.end]);
    try std.testing.expect(findValue(doc, "normalize", "model_missing") == null);
}

test "findValue ignores a key that appears only in a comment" {
    const doc = "[hotkey]\n# mode = \"toggle\"\nmode = \"hold\"     # hold | toggle\n";
    const span = findValue(doc, "hotkey", "mode").?;
    try std.testing.expectEqualStrings("\"hold\"", doc[span.start..span.end]);
}

test "replaceValue leaves the inline comment and spacing intact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = "[hotkey]\nmode = \"hold\"     # hold | toggle\nkey_code = 67\n";
    const span = findValue(doc, "hotkey", "mode").?;
    const out = try replaceValue(arena, doc, span, "\"toggle\"");
    try std.testing.expectEqualStrings("[hotkey]\nmode = \"toggle\"     # hold | toggle\nkey_code = 67\n", out);
}

test "insertKey appends at the end of an existing section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try insertKey(
        arena_state.allocator(),
        "[transcribe]\nprovider = \"groq\"\n\n[normalize]\nenabled = false\n",
        "transcribe",
        "model",
        "\"whisper-1\"",
    );
    try std.testing.expectEqualStrings(
        "[transcribe]\nprovider = \"groq\"\nmodel = \"whisper-1\"\n\n[normalize]\nenabled = false\n",
        out,
    );
}

test "insertKey appends a new section at end of file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try insertKey(arena_state.allocator(), "[hotkey]\nmode = \"hold\"\n", "daemon", "overlay", "false");
    try std.testing.expectEqualStrings("[hotkey]\nmode = \"hold\"\n\n[daemon]\noverlay = false\n", out);
}
