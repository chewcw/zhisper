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

pub const Value = union(enum) { string: []const u8, boolean: bool };

pub fn render(arena: std.mem.Allocator, value: Value) ![]u8 {
    switch (value) {
        .boolean => |b| return std.fmt.allocPrint(arena, "{s}", .{if (b) "true" else "false"}),
        .string => |s| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            try out.append(arena, '"');
            for (s) |ch| {
                if (ch == '"' or ch == '\\') try out.append(arena, '\\');
                try out.append(arena, ch);
            }
            try out.append(arena, '"');
            return out.toOwnedSlice(arena);
        },
    }
}

pub fn valueMatches(doc: []const u8, span: Span, value: Value) bool {
    const text = doc[span.start..span.end];
    return switch (value) {
        .boolean => |b| std.mem.eql(u8, text, if (b) "true" else "false"),
        .string => |s| text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"' and
            std.mem.eql(u8, text[1 .. text.len - 1], s),
    };
}

pub fn setKey(io: std.Io, gpa: std.mem.Allocator, path: []const u8, section: []const u8, key: []const u8, value: Value) !void {
    // Resolve first: the config path is a symlink in a dotfiles setup, and a
    // rename onto the link would replace the link with a regular file.
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.FileNotFound => try gpa.dupeZ(u8, path),
        else => return err,
    };
    defer gpa.free(resolved);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = std.Io.Dir.cwd().readFileAlloc(io, resolved, arena, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        error.StreamTooLong => return error.ConfigTooLarge,
        else => return err,
    };

    const rendered = try render(arena, value);
    const out = if (findValue(doc, section, key)) |span| blk: {
        if (valueMatches(doc, span, value)) return;
        break :blk try replaceValue(arena, doc, span, rendered);
    } else try insertKey(arena, doc, section, key, rendered);

    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.zhisper.tmp", .{resolved});
    const permissions: std.Io.File.Permissions = blk: {
        const st = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch break :blk .default_file;
        break :blk st.permissions;
    };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out, .flags = .{ .permissions = permissions } }) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), resolved, io);
}

test "render quotes strings, escapes, and leaves booleans bare" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("true", try render(arena, .{ .boolean = true }));
    try std.testing.expectEqualStrings("false", try render(arena, .{ .boolean = false }));
    try std.testing.expectEqualStrings("\"semi-formal\"", try render(arena, .{ .string = "semi-formal" }));
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", try render(arena, .{ .string = "a\"b\\c" }));
}

test "valueMatches compares without allocating" {
    const doc = "[daemon]\noverlay = true  # on | off\n";
    const span = findValue(doc, "daemon", "overlay").?;
    try std.testing.expect(valueMatches(doc, span, .{ .boolean = true }));
    try std.testing.expect(!valueMatches(doc, span, .{ .boolean = false }));
    try std.testing.expect(!valueMatches(doc, span, .{ .string = "true" }));
}

test "setKey replaces one value and leaves every other byte alone" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(io, "config.example.toml", gpa, .limited(max_config_bytes));
    defer gpa.free(src);
    const path = "cfg-edit-golden.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try setKey(io, gpa, path, "normalize", "styling", .{ .string = "formal" });

    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes));
    defer gpa.free(after);
    const restored = try std.mem.replaceOwned(u8, gpa, after, "styling = \"formal\"", "styling = \"semi-formal\"");
    defer gpa.free(restored);
    try std.testing.expectEqualStrings(src, restored);
}

test "setKey follows a symlink instead of replacing it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const target = "cfg-edit-target.toml";
    const link = "cfg-edit-link.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = "[daemon]\noverlay = true\n" });
    defer std.Io.Dir.cwd().deleteFile(io, target) catch {};
    std.Io.Dir.cwd().symLink(io, target, link, .{}) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteFile(io, link) catch {};

    try setKey(io, gpa, link, "daemon", "overlay", .{ .boolean = false });

    const link_stat = try std.Io.Dir.cwd().statFile(io, link, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(max_config_bytes));
    defer gpa.free(body);
    try std.testing.expectEqualStrings("[daemon]\noverlay = false\n", body);
}

test "setKey creates a missing file with only that section" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "cfg-edit-new.toml";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try setKey(io, gpa, path, "normalize", "enabled", .{ .boolean = true });

    const body = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes));
    defer gpa.free(body);
    try std.testing.expectEqualStrings("[normalize]\nenabled = true\n", body);
}

test "setKey does not write when the value already matches" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "cfg-edit-noop.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[daemon]\noverlay = true\n" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const before = try std.Io.Dir.cwd().statFile(io, path, .{});

    try setKey(io, gpa, path, "daemon", "overlay", .{ .boolean = true });

    const after = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

test "setKey keeps CRLF line endings" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "cfg-edit-crlf.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "[hotkey]\r\nmode = \"hold\"  # hold | toggle\r\n" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try setKey(io, gpa, path, "hotkey", "mode", .{ .string = "toggle" });

    const body = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes));
    defer gpa.free(body);
    try std.testing.expectEqualStrings("[hotkey]\r\nmode = \"toggle\"  # hold | toggle\r\n", body);
}

test "setKey fails without leaving a temp file when the directory is missing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.FileNotFound,
        setKey(io, gpa, "cfg-edit-nodir/config.toml", "daemon", "overlay", .{ .boolean = true }),
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(io, "cfg-edit-nodir/config.toml.zhisper.tmp", .{}),
    );
}

test "setKey rejects a file above the size cap" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = "cfg-edit-big.toml";
    const big = try gpa.alloc(u8, max_config_bytes + 1);
    defer gpa.free(big);
    @memset(big, 'a');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = big });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.testing.expectError(
        error.ConfigTooLarge,
        setKey(io, gpa, path, "daemon", "overlay", .{ .boolean = true }),
    );
}
