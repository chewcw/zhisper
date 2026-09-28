const std = @import("std");

/// What the user asked notifications to report. `all` is what the config
/// string "errors,clipboard" parses to.
pub const Level = enum { off, errors, clipboard, all };

/// Every outcome zhisper can report. Exactly one of these is a success; the
/// rest are the silent no-ops and failures that currently leave the user
/// guessing whether a dictation produced anything at all.
pub const Kind = enum {
    too_short,
    quiet_clip,
    dropped_oldest,
    transcribe_failed,
    empty_transcript,
    clipboard_failed,
    clipboard_ready,
};

/// The four accepted `[daemon] notify` strings. `config.zig` validates
/// against this list and `main.zig` parses through it, so the two can never
/// disagree about what is legal.
pub const level_values: []const []const u8 = &.{
    "off",
    "errors",
    "clipboard",
    "errors,clipboard",
};

/// Result of the one-shot backend probe at startup. `hint` is the actionable
/// half of a failure: without it a user who enabled notifications on Windows
/// with the tray off would only learn that "something" is unavailable.
pub const Availability = struct {
    available: bool,
    tool: ?[]const u8,
    hint: ?[]const u8 = null,
};

/// Every notification is titled "zhisper"; the backends read it from here so
/// the three platforms cannot drift apart.
pub const title: [:0]const u8 = "zhisper";

/// Bytes of payload shown in a clipboard_ready notification.
pub const preview_limit: usize = 60;

/// Fixed capacity for a notification body. The worst case is the
/// clipboard_ready body: a 21-byte prefix plus a 63-byte preview (60 of payload
/// and a 3-byte U+2026 ellipsis) comes to 84. The remaining 8 bytes are
/// headroom for longer future messages; a test asserts every body fits, so
/// exceeding them fails the build instead of silently truncating.
pub const text_capacity: usize = preview_limit + 32;

const ellipsis = "…";

/// A fixed-capacity inline string, the equivalent of a C
/// `struct { char bytes[N]; unsigned short len; }`. `len` is `u16` rather than
/// `u8` so raising `text_capacity` past 255 cannot silently wrap.
///
/// `from` and `appendSlice` are deliberately NOT pub. A `TextBuf` reaches the
/// `NotifyQueue` inside a `Message` and is immutable from the moment it is
/// published, so the only operation another file needs is `slice()`. Making the
/// mutators private turns "a published message is never mutated" from a
/// comment into something the compiler enforces — otherwise a backend holding a
/// `Message` by value could append to it, and the day a signature changes to
/// `*Message` that becomes an unsynchronised write racing the next push.
pub const TextBuf = struct {
    bytes: [text_capacity]u8 = undefined,
    len: u16 = 0,

    fn from(s: []const u8) TextBuf {
        var buf: TextBuf = .{};
        buf.appendSlice(s);
        return buf;
    }

    /// Truncates at capacity rather than failing. A notification body is
    /// display text: losing its tail is always better than losing the toast.
    fn appendSlice(self: *TextBuf, s: []const u8) void {
        const start: usize = self.len;
        const room = self.bytes.len - start;
        const n = @min(s.len, room);
        @memcpy(self.bytes[start..][0..n], s[0..n]);
        self.len = @intCast(start + n);
    }

    pub fn slice(self: *const TextBuf) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One rendered notification. Every field is a plain value, so a `Message` can
/// be memcpy'd into the cross-thread `NotifyQueue` with no allocator and no
/// documented owner. That property is the whole reason it is not a slice.
pub const Message = struct {
    kind: Kind,
    critical: bool,
    text: TextBuf,
};

/// Collapse to one line, then cut to `preview_limit` on a word boundary.
pub fn preview(s: []const u8) TextBuf {
    var flat: [text_capacity]u8 = undefined;
    var n: usize = 0;
    for (s) |ch| {
        if (n == flat.len) break;
        const out: u8 = switch (ch) {
            '\n', '\r', '\t' => ' ',
            else => ch,
        };
        // Collapse a run of separators into a single space. Whisper output
        // routinely ends in "\n" or "\n\n", and a double space in a toast
        // reads as a typo rather than as a paragraph break.
        if (out == ' ' and n > 0 and flat[n - 1] == ' ') continue;
        flat[n] = out;
        n += 1;
    }
    const line = flat[0..n];
    if (line.len <= preview_limit) return TextBuf.from(line);

    var buf = TextBuf.from(line[0..preview_limit]);
    // Cut back to the last space so words survive, but only when that space is
    // far enough in: honouring a space at byte 3 would gut the preview.
    if (std.mem.lastIndexOfScalar(u8, line[0..preview_limit], ' ')) |space| {
        if (space >= 40) buf = TextBuf.from(line[0..space]);
    }
    buf.appendSlice(ellipsis);
    return buf;
}

pub fn shouldNotify(level: Level, kind: Kind) bool {
    return switch (level) {
        .off => false,
        .errors => kind != .clipboard_ready,
        .clipboard => kind == .clipboard_ready,
        .all => true,
    };
}

/// Pure and idempotent: same arguments, same `Message`, every call, from any
/// thread. Only `show` has a side effect, and it is owned by the poll loop.
pub fn forEvent(kind: Kind, detail: []const u8) Message {
    return .{
        .kind = kind,
        .critical = kind != .clipboard_ready,
        .text = textFor(kind, detail),
    };
}

fn textFor(kind: Kind, detail: []const u8) TextBuf {
    var buf: TextBuf = .{};
    switch (kind) {
        .too_short => buf.appendSlice("Held too briefly — nothing recorded"),
        .quiet_clip => buf.appendSlice("Nothing audible in that recording"),
        .dropped_oldest => buf.appendSlice("Already transcribing — this clip replaced the last one"),
        .transcribe_failed => {
            buf.appendSlice("Transcription failed (");
            buf.appendSlice(detail);
            buf.appendSlice(")");
        },
        .empty_transcript => buf.appendSlice("No speech recognized — clipboard left untouched"),
        .clipboard_failed => buf.appendSlice("Transcribed, but the clipboard write failed"),
        .clipboard_ready => {
            // The prefix is the whole point: without it a finished dictation
            // and a stray line of text look identical on screen.
            buf.appendSlice("Copied to clipboard: ");
            buf.appendSlice(preview(detail).slice());
        },
    }
    return buf;
}

test "preview keeps short text whole" {
    try std.testing.expectEqualStrings("hello there", preview("hello there").slice());
}

test "preview collapses newlines into one line" {
    try std.testing.expectEqualStrings("one two three", preview("one\ntwo\r\tthree").slice());
}

test "preview cuts at the last space and marks the truncation" {
    const input = "the quick brown fox jumps over the lazy dog and keeps on running";
    // 60 bytes lands mid-word ("ru|nning"); cutting back to the last space
    // keeps whole words and stays above the 40-byte floor.
    try std.testing.expectEqualStrings("the quick brown fox jumps over the lazy dog and keeps on…", preview(input).slice());
}

test "preview hard-cuts text with no space past the floor" {
    var cjk: [80]u8 = undefined;
    @memset(&cjk, 0xE4);
    const out = preview(&cjk);
    try std.testing.expectEqual(@as(u16, preview_limit + 3), out.len);
    try std.testing.expectEqualStrings("…", out.slice()[out.len - 3 ..]);
}

test "preview leaves exactly preview_limit bytes unmarked" {
    const exact = "a" ** preview_limit;
    try std.testing.expectEqualStrings(exact, preview(exact).slice());
}

test "text_capacity covers the worst case clipboard_ready body" {
    // 21-byte prefix + 60 bytes of payload + a 3-byte U+2026 ellipsis.
    try std.testing.expect(text_capacity > 21 + preview_limit + 3);
}

test "every event body fits the fixed buffer" {
    for (std.enums.values(Kind)) |kind| {
        const msg = forEvent(kind, "the quick brown fox jumps over the lazy dog and keeps on running for a while");
        try std.testing.expect(msg.text.len <= text_capacity);
        try std.testing.expect(msg.text.len > 0);
    }
}

test "the worst case clipboard_ready body still fits" {
    // 61 space-free bytes, so preview truncates and appends its ellipsis:
    // 21 + 60 + 3 = 84 of 92. (At exactly preview_limit the text fits whole
    // and no ellipsis is added, which is why this is limit + 1.)
    const msg = forEvent(.clipboard_ready, "x" ** (preview_limit + 1));
    try std.testing.expectEqual(@as(u16, 21 + preview_limit + 3), msg.text.len);
    try std.testing.expect(msg.text.len <= text_capacity);
}

test "clipboard_ready is labelled so a finished dictation is unmistakable" {
    try std.testing.expectEqualStrings(
        "Copied to clipboard: hello",
        forEvent(.clipboard_ready, "hello").text.slice(),
    );
    try std.testing.expect(std.mem.startsWith(
        u8,
        forEvent(.clipboard_ready, "the quick brown fox jumps over").text.slice(),
        "Copied to clipboard: ",
    ));
}

test "shouldNotify maps every level onto every kind" {
    try std.testing.expect(!shouldNotify(.off, .too_short));
    try std.testing.expect(!shouldNotify(.off, .clipboard_ready));

    try std.testing.expect(shouldNotify(.errors, .too_short));
    try std.testing.expect(shouldNotify(.errors, .quiet_clip));
    try std.testing.expect(shouldNotify(.errors, .dropped_oldest));
    try std.testing.expect(shouldNotify(.errors, .transcribe_failed));
    try std.testing.expect(shouldNotify(.errors, .empty_transcript));
    try std.testing.expect(shouldNotify(.errors, .clipboard_failed));
    // The errors level deliberately excludes the one non-failure kind.
    try std.testing.expect(!shouldNotify(.errors, .clipboard_ready));

    try std.testing.expect(shouldNotify(.clipboard, .clipboard_ready));
    try std.testing.expect(!shouldNotify(.clipboard, .too_short));
    try std.testing.expect(!shouldNotify(.clipboard, .clipboard_failed));

    for (std.enums.values(Kind)) |kind| {
        try std.testing.expect(shouldNotify(.all, kind));
    }
}

test "only clipboard_ready is non-critical" {
    for (std.enums.values(Kind)) |kind| {
        try std.testing.expectEqual(kind != .clipboard_ready, forEvent(kind, "").critical);
    }
}

test "forEvent interpolates the error name and previews the payload" {
    try std.testing.expectEqualStrings(
        "Transcription failed (Timeout)",
        forEvent(.transcribe_failed, "Timeout").text.slice(),
    );
    // 30 bytes is under the 60-byte preview limit, so nothing truncates.
    try std.testing.expectEqualStrings(
        "Copied to clipboard: the quick brown fox jumps over",
        forEvent(.clipboard_ready, "the quick brown fox jumps over").text.slice(),
    );
}

test "forEvent is a pure function of its arguments" {
    const first = forEvent(.quiet_clip, "ignored");
    const second = forEvent(.quiet_clip, "ignored");
    try std.testing.expectEqualSlices(u8, first.text.slice(), second.text.slice());
    try std.testing.expectEqual(first.kind, second.kind);
    try std.testing.expectEqual(first.critical, second.critical);
}

test "the four config level strings are spelled out" {
    try std.testing.expectEqual(@as(usize, 4), level_values.len);
    try std.testing.expectEqualStrings("off", level_values[0]);
    try std.testing.expectEqualStrings("errors", level_values[1]);
    try std.testing.expectEqualStrings("clipboard", level_values[2]);
    try std.testing.expectEqualStrings("errors,clipboard", level_values[3]);
}
