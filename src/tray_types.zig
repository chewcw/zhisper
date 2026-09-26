const std = @import("std");

/// Single vocabulary for the tray indicator. Pure Zig so every target,
/// including test builds, can use it without OS headers.
pub const State = enum { idle, recording, working };

pub fn tooltip(state: State) []const u8 {
    return switch (state) {
        .idle => "zhisper: idle",
        .recording => "zhisper: recording",
        .working => "zhisper: processing",
    };
}

/// Embedded so the installed binary is independent of the current directory
/// and users do not need to install a separate icon directory.
pub const idle_png = @embedFile("assets/zhisper-tray-idle.png");
pub const recording_png = @embedFile("assets/zhisper-tray-recording.png");
pub const working_png = @embedFile("assets/zhisper-tray-working.png");

fn pngDimension(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

test "tray states and tooltips are stable" {
    try std.testing.expectEqualStrings("zhisper: idle", tooltip(.idle));
    try std.testing.expectEqualStrings("zhisper: recording", tooltip(.recording));
    try std.testing.expectEqualStrings("zhisper: processing", tooltip(.working));
}

test "embedded tray assets are 22x22 PNGs" {
    const png_signature = "\x89PNG\r\n\x1a\n";
    for ([_][]const u8{ idle_png, recording_png, working_png }) |png| {
        try std.testing.expect(png.len >= 24);
        try std.testing.expectEqualStrings(png_signature, png[0..8]);
        try std.testing.expectEqual(@as(u32, 22), pngDimension(png, 16));
        try std.testing.expectEqual(@as(u32, 22), pngDimension(png, 20));
    }
}
