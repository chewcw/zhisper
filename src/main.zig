const std = @import("std");

const zhisper = @import("zhisper");

// Imported so its tests run under `zig build test`; main() does not call
// into it yet (daemon-loop wiring is out of scope for the config change).
const cli = @import("cli.zig");

test {
    std.testing.refAllDecls(@import("cli.zig"));
}

fn modeFromString(s: []const u8) !zhisper.hotkey.Mode {
    if (std.mem.eql(u8, s, "hold")) return .hold;
    if (std.mem.eql(u8, s, "toggle")) return .toggle;
    return error.InvalidMode;
}

/// 16kHz mono s16 = 32000 bytes/sec = 32 bytes/ms of payload (header excluded).
fn minWavPayloadBytes(min_duration_ms: u32) usize {
    return @as(usize, min_duration_ms) * 32;
}

fn uniqueWavPath(gpa: std.mem.Allocator, base: []const u8, counter: u32) ![]u8 {
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        return try std.fmt.allocPrint(gpa, "{s}-{d}{s}", .{ base[0..dot], counter, base[dot..] });
    }
    return try std.fmt.allocPrint(gpa, "{s}-{d}", .{ base, counter });
}

fn buildTranscribeConfig(unified: zhisper.config.Config, api_key: []const u8) zhisper.transcribe.Config {
    return .{
        .base_url = unified.transcribe.base_url,
        .model = unified.transcribe.model,
        .api_key = api_key,
        .prompt = unified.transcribe.prompt,
    };
}

fn resolveApiKey(provider: zhisper.transcribe.Provider) ?[]const u8 {
    if (std.c.getenv("ZHISPER_API_KEY")) |raw| {
        if (raw[0] != 0) return std.mem.span(raw);
    }
    const name: [*:0]const u8 = switch (provider) {
        .groq => "GROQ_API_KEY",
        .openai => "OPENAI_API_KEY",
        .custom => "ZHISPER_API_KEY",
    };
    if (std.c.getenv(name)) |raw| {
        if (raw[0] != 0) return std.mem.span(raw);
    }
    return null;
}

fn resolveConfigPath(gpa: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("APPDATA")) |raw| {
            const base = std.mem.span(raw);
            if (base.len > 0) return try std.fmt.allocPrint(gpa, "{s}\\zhisper\\config.toml", .{base});
        }
        return try gpa.dupe(u8, "config.toml");
    }
    const home = if (std.c.getenv("HOME")) |raw| std.mem.span(raw) else "";
    if (home.len == 0) return try gpa.dupe(u8, "config.toml");
    if (builtin.os.tag == .macos) {
        return try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/zhisper/config.toml", .{home});
    }
    return try std.fmt.allocPrint(gpa, "{s}/.config/zhisper/config.toml", .{home});
}

const Action = enum { start, stop, ignore };

const LoopState = struct {
    mode: zhisper.hotkey.Mode,
    recording: bool = false,
    press_count: u32 = 0,
};

fn handleHotkeyEvent(s: *LoopState, ev: zhisper.hotkey.KeyEvent) Action {
    switch (s.mode) {
        .hold => switch (ev) {
            .pressed => {
                if (s.recording) return .ignore;
                s.recording = true;
                return .start;
            },
            .released => {
                if (!s.recording) return .ignore;
                s.recording = false;
                return .stop;
            },
        },
        .toggle => switch (ev) {
            .released => return .ignore,
            .pressed => {
                s.press_count += 1;
                if (!s.recording) {
                    s.recording = true;
                    return .start;
                }
                s.recording = false;
                return .stop;
            },
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    zhisper.audio.init(io, gpa);

    const path = "/tmp/test.wav";
    try zhisper.audio.setRecording(.start, path);

    try io.sleep(.fromSeconds(2), .awake);

    try zhisper.audio.setRecording(.stop, path);
}

test "modeFromString maps hold and toggle" {
    try std.testing.expectEqual(zhisper.hotkey.Mode.hold, try modeFromString("hold"));
    try std.testing.expectEqual(zhisper.hotkey.Mode.toggle, try modeFromString("toggle"));
    try std.testing.expectError(error.InvalidMode, modeFromString("bogus"));
}

test "minWavPayloadBytes is 32 bytes per ms" {
    try std.testing.expectEqual(@as(usize, 16000), minWavPayloadBytes(500));
    try std.testing.expectEqual(@as(usize, 25600), minWavPayloadBytes(800));
}

test "uniqueWavPath inserts a counter before the extension" {
    const gpa = std.testing.allocator;
    const got = try uniqueWavPath(gpa, "/tmp/zhisper.wav", 7);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/tmp/zhisper-7.wav", got);
}

test "buildTranscribeConfig copies provider fields plus key" {
    const unified = zhisper.config.Config{
        .transcribe = .{ .provider = "groq", .model = "m", .base_url = "http://x", .prompt = "p" },
    };
    const t = buildTranscribeConfig(unified, "k123");
    try std.testing.expectEqualStrings("http://x", t.base_url);
    try std.testing.expectEqualStrings("m", t.model);
    try std.testing.expectEqualStrings("k123", t.api_key);
    try std.testing.expectEqualStrings("p", t.prompt);
}

test "hold press starts, release stops, extras ignored" {
    var s = LoopState{ .mode = .hold };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .pressed));
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .released));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .released));
}

test "toggle alternates on press and ignores release" {
    var s = LoopState{ .mode = .toggle };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .released));
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .released));
}
