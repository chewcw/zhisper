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

pub fn parseFileConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    // api_key must never appear in the file: scan raw bytes FIRST so the
    // error is always ApiKeyInFile (the unknown-key check below would
    // otherwise report UnknownField for the same line).
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(raw);
    if (std.mem.indexOf(u8, raw, "api_key") != null) return error.ApiKeyInFile;
    // The vendored 0.16 toml parser silently drops unknown keys, so the
    // typo-catching strict mode is an allowlist over a Table parse.
    try checkUnknownFields(gpa, io, path);
    var parser = toml.Parser(Config).init(gpa);
    defer parser.deinit();
    var result = try parser.parseFile(io, path);
    defer result.deinit();
    // result.value borrows the parse arena, which deinit frees — copy every
    // string into gpa so the returned Config outlives this call. Release
    // with freeConfig. (defaultConfig borrows literals and must NOT be freed.)
    return try dupeConfig(gpa, result.value);
}

/// Copies every string field out of `cfg` into gpa-owned memory.
pub fn dupeConfig(gpa: std.mem.Allocator, cfg: Config) !Config {
    var out = cfg;
    out.transcribe.provider = try gpa.dupe(u8, cfg.transcribe.provider);
    errdefer gpa.free(out.transcribe.provider);
    out.transcribe.model = try gpa.dupe(u8, cfg.transcribe.model);
    errdefer gpa.free(out.transcribe.model);
    out.transcribe.base_url = try gpa.dupe(u8, cfg.transcribe.base_url);
    errdefer gpa.free(out.transcribe.base_url);
    out.transcribe.prompt = try gpa.dupe(u8, cfg.transcribe.prompt);
    errdefer gpa.free(out.transcribe.prompt);
    out.hotkey.mode = try gpa.dupe(u8, cfg.hotkey.mode);
    errdefer gpa.free(out.hotkey.mode);
    out.hotkey.evdev = try gpa.dupe(u8, cfg.hotkey.evdev);
    errdefer gpa.free(out.hotkey.evdev);
    out.audio.device = try gpa.dupe(u8, cfg.audio.device);
    errdefer gpa.free(out.audio.device);
    out.daemon.wav_path = try gpa.dupe(u8, cfg.daemon.wav_path);
    return out;
}

/// Releases a Config returned by parseFileConfig, dupeConfig, or load.
/// Never call on defaultConfig (it borrows string literals).
pub fn freeConfig(gpa: std.mem.Allocator, cfg: Config) void {
    gpa.free(cfg.transcribe.provider);
    gpa.free(cfg.transcribe.model);
    gpa.free(cfg.transcribe.base_url);
    gpa.free(cfg.transcribe.prompt);
    gpa.free(cfg.hotkey.mode);
    gpa.free(cfg.hotkey.evdev);
    gpa.free(cfg.audio.device);
    gpa.free(cfg.daemon.wav_path);
}

// Every TOML key the file is allowed to contain. checkUnknownFields is the
// single owner of this list; the struct definitions above own the values.
const known_sections = [_]struct { name: []const u8, keys: []const []const u8 }{
    .{ .name = "transcribe", .keys = &.{ "provider", "model", "base_url", "prompt" } },
    .{ .name = "hotkey", .keys = &.{ "key_code", "mode", "evdev" } },
    .{ .name = "audio", .keys = &.{ "device" } },
    .{ .name = "daemon", .keys = &.{ "min_duration_ms", "wav_path", "keep_wav_on_error", "verbose" } },
};

fn checkUnknownFields(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var parser = toml.Parser(toml.Table).init(gpa);
    defer parser.deinit();
    var result = try parser.parseFile(io, path);
    defer result.deinit();
    var sec_it = result.value.iterator();
    while (sec_it.next()) |sec| {
        var keys: ?[]const []const u8 = null;
        for (known_sections) |s| if (std.mem.eql(u8, s.name, sec.key_ptr.*)) {
            keys = s.keys;
            break;
        };
        const want = keys orelse return error.UnknownField;
        const sub = switch (sec.value_ptr.*) {
            // A non-table section (e.g. `provider = "x"` at top level)
            // surfaces as InvalidValueType from the Config parse below.
            .table => |t| t,
            else => continue,
        };
        var key_it = sub.iterator();
        while (key_it.next()) |entry| {
            var ok = false;
            for (want) |k| if (std.mem.eql(u8, k, entry.key_ptr.*)) {
                ok = true;
                break;
            };
            if (!ok) return error.UnknownField;
        }
    }
}

test "defaultConfig matches spec defaults" {
    const cfg = defaultConfig();
    try std.testing.expectEqualStrings("groq", cfg.transcribe.provider);
    try std.testing.expectEqual(@as(u16, 67), cfg.hotkey.key_code);
    try std.testing.expectEqualStrings("hold", cfg.hotkey.mode);
    try std.testing.expectEqual(@as(u32, 500), cfg.daemon.min_duration_ms);
}

test "parseFileConfig reads example-shaped TOML" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const doc =
        \\[transcribe]
        \\provider = "openai"
        \\[hotkey]
        \\key_code = 70
        \\mode = "toggle"
        \\[daemon]
        \\min_duration_ms = 800
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-parse.toml", .data = doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-parse.toml") catch {};
    const cfg = try parseFileConfig(gpa, io, "cfg-parse.toml");
    defer freeConfig(gpa, cfg);
    try std.testing.expectEqualStrings("openai", cfg.transcribe.provider);
    try std.testing.expectEqual(@as(u16, 70), cfg.hotkey.key_code);
    try std.testing.expectEqualStrings("toggle", cfg.hotkey.mode);
    try std.testing.expectEqual(@as(u32, 800), cfg.daemon.min_duration_ms);
}

test "parseFileConfig rejects unknown fields" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-typo.toml", .data = "[hotkey]\nkey_cod = 67\n" });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-typo.toml") catch {};
    try std.testing.expectError(error.UnknownField, parseFileConfig(gpa, io, "cfg-typo.toml"));
}

test "parseFileConfig rejects api_key in file" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-key.toml", .data = "[transcribe]\napi_key = \"secret\"\n" });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-key.toml") catch {};
    try std.testing.expectError(error.ApiKeyInFile, parseFileConfig(gpa, io, "cfg-key.toml"));
}
