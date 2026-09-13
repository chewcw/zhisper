const std = @import("std");
const toml = @import("toml");

pub const TranscribeCfg = struct {
    provider: []const u8 = "groq",
    model: []const u8 = "",
    base_url: []const u8 = "",
    prompt: []const u8 = "",
};

pub const HotkeyCfg = struct {
    key_code: u16 = 67,
    mode: []const u8 = "hold",
    evdev: []const u8 = "",
};

pub const AudioCfg = struct {
    device: []const u8 = "",
};

pub const DaemonCfg = struct {
    min_duration_ms: u32 = 500,
    wav_path: []const u8 = "/tmp/zhisper.wav",
    keep_wav_on_error: bool = true,
    verbose: bool = false,
};

pub const Config = struct {
    transcribe: TranscribeCfg = .{},
    hotkey: HotkeyCfg = .{},
    audio: AudioCfg = .{},
    daemon: DaemonCfg = .{},
};

pub fn defaultConfig() Config {
    return .{};
}

pub const CliOverrides = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    key_code: ?u16 = null,
    mode: ?[]const u8 = null,
    evdev: ?[]const u8 = null,
    device: ?[]const u8 = null,
    min_duration_ms: ?u32 = null,
    wav_path: ?[]const u8 = null,
    keep_wav_on_error: ?bool = null,
    verbose: ?bool = null,
};

test "defaultConfig matches spec defaults" {
    const cfg = defaultConfig();
    try std.testing.expectEqualStrings("groq", cfg.transcribe.provider);
    try std.testing.expectEqual(@as(u16, 67), cfg.hotkey.key_code);
    try std.testing.expectEqualStrings("hold", cfg.hotkey.mode);
    try std.testing.expectEqual(@as(u32, 500), cfg.daemon.min_duration_ms);
}
