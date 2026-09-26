const std = @import("std");

/// What to do with newlines at the end of a transcript.
///
/// Whisper output routinely ends in "\n" because the model was trained on text
/// that ends sentences. Emitting that as a real Return key submits the message
/// mid-dictation in chat applications, so stripping is the default. Interior
/// newlines are unaffected.
pub const TrailingNewline = enum {
    send,
    strip,
};

/// Setup-time injection policy. Captured once at setup so the injection path
/// allocates nothing and main.zig does not thread config through per utterance.
pub const InjectOptions = struct {
    trailing_newline: TrailingNewline = .strip,
    /// 0 means "platform default": 2ms on macOS, 0ms on Windows.
    type_delay_ms: u16 = 0,
};

/// What one codepoint means to a platform emitter.
pub const Action = union(enum) {
    /// Deliver via the platform's Unicode-carrying event path.
    char: u21,
    return_key,
    tab_key,
};

/// Number of trailing bytes to drop from `text` to satisfy `mode`.
///
/// Scanning byte-wise is safe on UTF-8 because \n (0x0A) and \r (0x0D) can
/// never appear inside a multi-byte sequence, which only uses 0xC0-0xFF.
pub fn trailingCut(text: []const u8, mode: TrailingNewline) usize {
    if (mode == .send) return 0;
    var n: usize = 0;
    while (n < text.len) : (n += 1) {
        const b = text[text.len - 1 - n];
        if (b != '\n' and b != '\r') break;
    }
    return n;
}

/// Map a codepoint to the action a platform emitter should perform, or null to
/// drop it.
///
/// Newline and tab get real keycodes because a Unicode \n is ignored by most
/// text fields; only a genuine Return inserts a line break. The remaining C0
/// controls are dropped rather than emitted because they are meaningless in a
/// dictated sentence and some text fields treat them as input-modifying.
pub fn classify(cp: u21) ?Action {
    if (cp == '\n' or cp == '\r') return Action.return_key;
    if (cp == '\t') return Action.tab_key;
    if (cp < 0x20) return null;
    return Action{ .char = cp };
}

test "trailingCut strips trailing newlines" {
    const t = @import("inject_types.zig");
    try std.testing.expectEqual(@as(usize, 0), t.trailingCut("", .strip));
    try std.testing.expectEqual(@as(usize, 0), t.trailingCut("hi", .strip));
    try std.testing.expectEqual(@as(usize, 1), t.trailingCut("hi\n", .strip));
    try std.testing.expectEqual(@as(usize, 2), t.trailingCut("hi\n\n", .strip));
    try std.testing.expectEqual(@as(usize, 2), t.trailingCut("hi\r\n", .strip));
    try std.testing.expectEqual(@as(usize, 3), t.trailingCut("\n\n\n", .strip));
    try std.testing.expectEqual(@as(usize, 1), t.trailingCut("hi\nthere\n", .strip));
}

test "trailingCut is a no-op in send mode" {
    const t = @import("inject_types.zig");
    try std.testing.expectEqual(@as(usize, 0), t.trailingCut("hi\n\n", .send));
}

test "classify maps control characters to real keys" {
    const t = @import("inject_types.zig");
    try std.testing.expectEqual(t.Action.return_key, t.classify('\n').?);
    try std.testing.expectEqual(t.Action.return_key, t.classify('\r').?);
    try std.testing.expectEqual(t.Action.tab_key, t.classify('\t').?);
}

test "classify drops other C0 controls and passes everything else through" {
    const t = @import("inject_types.zig");
    try std.testing.expect(t.classify(0x07) == null);
    try std.testing.expect(t.classify(0x00) == null);
    try std.testing.expect(t.classify(0x1F) == null);
    try std.testing.expectEqual(@as(u21, 'a'), t.classify('a').?.char);
    try std.testing.expectEqual(@as(u21, 0x4F60), t.classify(0x4F60).?.char);
    try std.testing.expectEqual(@as(u21, 0x1F600), t.classify(0x1F600).?.char);
}
