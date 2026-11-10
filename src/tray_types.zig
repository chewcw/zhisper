const std = @import("std");
const config = @import("config.zig");
const hotkey_types = @import("hotkey_types.zig");

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

pub const Submenu = enum { hotkey_mode, normalize, styling, structure, context, provider, overlay };

pub const Action = union(enum) {
    set_hotkey_mode: hotkey_types.Mode,
    set_normalize_enabled: bool,
    set_styling: []const u8,
    set_structure: []const u8,
    set_context: []const u8,
    set_provider: []const u8,
    set_overlay: bool,
    open_submenu: Submenu,
    back,
    quit,
};

/// Which provider API keys the daemon environment carries. The menu greys out
/// a provider without a key, because selecting it would fail at transcription
/// time instead of at click time.
pub const ProviderKeys = struct { groq: bool = false, openai: bool = false, deepgram: bool = false };

/// Lets the Linux tray ask the daemon for the current config and report a
/// selection without importing main.zig.
pub const MenuHost = struct {
    ctx: *anyopaque,
    snapshotFn: *const fn (ctx: *anyopaque) config.Config,
    applyFn: *const fn (ctx: *anyopaque, action: Action) void,

    pub fn snapshot(self: MenuHost) config.Config {
        return self.snapshotFn(self.ctx);
    }

    pub fn apply(self: MenuHost, action: Action) void {
        self.applyFn(self.ctx, action);
    }
};

test "MenuHost forwards snapshot and apply to its context" {
    const Fake = struct {
        applied: ?Action = null,
        cfg: config.Config,

        fn snapshotFn(ctx: *anyopaque) config.Config {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.cfg;
        }

        fn applyFn(ctx: *anyopaque, action: Action) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.applied = action;
        }
    };

    var fake = Fake{ .cfg = config.defaultConfig() };
    const host = MenuHost{ .ctx = &fake, .snapshotFn = Fake.snapshotFn, .applyFn = Fake.applyFn };

    try std.testing.expectEqualStrings("groq", host.snapshot().transcribe.provider);
    host.apply(.quit);
    try std.testing.expect(fake.applied.? == .quit);
}
