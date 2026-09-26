const std = @import("std");
const toml = @import("toml");

pub const TranscribeCfg = struct {
    provider: []const u8 = "groq",
    model: []const u8 = "",
    base_url: []const u8 = "",
    prompt: []const u8 = "",
};

pub const HotkeyCfg = struct {
    /// OS-native key code; null and -1 both mean "disabled". 0 is a real key
    /// (macOS kVK_ANSI_A is 0).
    ///
    /// WHY i16 and not u16: the vendored toml parser assigns integers with a
    /// safety-checked @intCast, so a negative value aimed at an unsigned field
    /// panics at startup instead of erroring. The field default is null because
    /// the parser forces an *absent* optional to null before it consults
    /// default_value_ptr; the real defaults are applied in parseFileConfig.
    key_code: ?i16 = null,
    mode: []const u8 = "hold",
    evdev: []const u8 = "",
    evdev_name: []const u8 = "",
    cancel_key_code: ?i16 = null,
};

/// Default hotkey: KEY_F9 on Linux.
pub const default_key_code: i16 = 67;
/// Default cancel key: KEY_C on Linux.
pub const default_cancel_key_code: i16 = 46;

/// Single place that knows the disabled sentinel, so validate() and main.zig
/// cannot disagree about what -1 means. Any non-positive value means "off".
pub fn keyCodeOf(v: ?i16) ?u16 {
    const n = v orelse return null;
    if (n < 0) return null;
    return @intCast(n);
}

pub const AudioCfg = struct {
    device: []const u8 = "",
};

pub const DaemonCfg = struct {
    min_duration_ms: u32 = 500,
    wav_path: []const u8 = "/tmp/zhisper.wav",
    keep_wav_on_error: bool = true,
    overlay: bool = true,
    tray: bool = false,
    verbose: bool = false,
};

pub const Config = struct {
    transcribe: TranscribeCfg = .{},
    hotkey: HotkeyCfg = .{},
    audio: AudioCfg = .{},
    daemon: DaemonCfg = .{},
};

pub fn defaultConfig() Config {
    return .{
        .hotkey = .{
            .key_code = default_key_code,
            .cancel_key_code = default_cancel_key_code,
        },
    };
}

pub const CliOverrides = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    key_code: ?i16 = null,
    mode: ?[]const u8 = null,
    evdev: ?[]const u8 = null,
    evdev_name: ?[]const u8 = null,
    cancel_key_code: ?i16 = null,
    device: ?[]const u8 = null,
    min_duration_ms: ?u32 = null,
    wav_path: ?[]const u8 = null,
    keep_wav_on_error: ?bool = null,
    verbose: ?bool = null,
    list_devices: bool = false,
};

pub fn parseFileConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    // The vendored 0.16 toml parser silently drops unknown keys, so the
    // typo-catching strict mode is an allowlist over a Table parse. A key
    // named api_key is rejected as ApiKeyInFile (not UnknownField) so the
    // message tells the user keys belong in env, never in the file.
    try checkUnknownFields(gpa, io, path);
    var parser = toml.Parser(Config).init(gpa);
    defer parser.deinit();
    var result = try parser.parseFile(io, path);
    defer result.deinit();
    // result.value borrows the parse arena, which deinit frees — copy every
    // string into gpa so the returned Config outlives this call. Release
    // with freeConfig. (defaultConfig borrows literals and must NOT be freed.)
    var out = try dupeConfig(gpa, result.value);
    // An absent optional key parses to null (the toml parser forces null before
    // it consults the field default), and this function's result replaces the
    // default config wholesale rather than merging into it. So re-apply the
    // defaults here.
    if (out.hotkey.key_code == null) out.hotkey.key_code = default_key_code;
    if (out.hotkey.cancel_key_code == null) out.hotkey.cancel_key_code = default_cancel_key_code;
    return out;
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
    out.hotkey.evdev_name = try gpa.dupe(u8, cfg.hotkey.evdev_name);
    errdefer gpa.free(out.hotkey.evdev_name);
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
    gpa.free(cfg.hotkey.evdev_name);
    gpa.free(cfg.audio.device);
    gpa.free(cfg.daemon.wav_path);
}

pub const EnvValues = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    key_code: ?i16 = null,
    mode: ?[]const u8 = null,
    evdev: ?[]const u8 = null,
    evdev_name: ?[]const u8 = null,
    cancel_key_code: ?i16 = null,
    device: ?[]const u8 = null,
    min_duration_ms: ?u32 = null,
    wav_path: ?[]const u8 = null,
    keep_wav_on_error: ?bool = null,
    verbose: ?bool = null,
};

pub fn applyEnv(cfg: Config, env: EnvValues) Config {
    var out = cfg;
    if (env.provider) |v| out.transcribe.provider = v;
    if (env.model) |v| out.transcribe.model = v;
    if (env.base_url) |v| out.transcribe.base_url = v;
    if (env.prompt) |v| out.transcribe.prompt = v;
    if (env.key_code) |v| out.hotkey.key_code = v;
    if (env.mode) |v| out.hotkey.mode = v;
    if (env.evdev) |v| out.hotkey.evdev = v;
    if (env.evdev_name) |v| out.hotkey.evdev_name = v;
    if (env.cancel_key_code) |v| out.hotkey.cancel_key_code = v;
    if (env.device) |v| out.audio.device = v;
    if (env.min_duration_ms) |v| out.daemon.min_duration_ms = v;
    if (env.wav_path) |v| out.daemon.wav_path = v;
    if (env.keep_wav_on_error) |v| out.daemon.keep_wav_on_error = v;
    if (env.verbose) |v| out.daemon.verbose = v;
    return out;
}

pub fn applyCli(cfg: Config, cli: CliOverrides) Config {
    return applyEnv(cfg, .{
        .provider = cli.provider,
        .model = cli.model,
        .base_url = cli.base_url,
        .prompt = cli.prompt,
        .key_code = cli.key_code,
        .mode = cli.mode,
        .evdev = cli.evdev,
        .evdev_name = cli.evdev_name,
        .cancel_key_code = cli.cancel_key_code,
        .device = cli.device,
        .min_duration_ms = cli.min_duration_ms,
        .wav_path = cli.wav_path,
        .keep_wav_on_error = cli.keep_wav_on_error,
        .verbose = cli.verbose,
    });
}

pub fn validate(cfg: Config) !void {
    const provider = cfg.transcribe.provider;
    const known = std.mem.eql(u8, provider, "groq") or
        std.mem.eql(u8, provider, "openai") or
        std.mem.eql(u8, provider, "custom");
    if (!known) return error.InvalidProvider;
    // groq/openai fall back to built-in presets, so empty model/base_url is
    // fine; custom has no preset, so both are required.
    if (std.mem.eql(u8, provider, "custom")) {
        if (cfg.transcribe.base_url.len == 0) return error.MissingBaseUrl;
        if (cfg.transcribe.model.len == 0) return error.MissingModel;
    }
    if (!std.mem.eql(u8, cfg.hotkey.mode, "hold") and !std.mem.eql(u8, cfg.hotkey.mode, "toggle")) return error.InvalidMode;
    const hotkey = keyCodeOf(cfg.hotkey.key_code) orelse return error.InvalidKeyCode;
    if (keyCodeOf(cfg.hotkey.cancel_key_code)) |cancel| {
        if (cancel == hotkey) return error.CancelEqualsHotkey;
    }
    if (cfg.daemon.min_duration_ms == 0) return error.InvalidDuration;
}

fn envStr(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    if (raw[0] == 0) return null;
    return std.mem.span(raw);
}

fn envI16(name: [*:0]const u8) ?i16 {
    const s = envStr(name) orelse return null;
    // i16, not u16, so ZHISPER_KEY_CODE=-1 is a real value rather than a parse
    // failure that silently falls back to the default.
    return std.fmt.parseInt(i16, s, 10) catch null;
}

fn envU16(name: [*:0]const u8) ?u16 {
    const s = envStr(name) orelse return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn envU32(name: [*:0]const u8) ?u32 {
    const s = envStr(name) orelse return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn envBool(name: [*:0]const u8) ?bool {
    const s = envStr(name) orelse return null;
    if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "false")) return false;
    return null;
}

pub fn readEnvValues() EnvValues {
    return .{
        .provider = envStr("ZHISPER_PROVIDER"),
        .model = envStr("ZHISPER_MODEL"),
        .base_url = envStr("ZHISPER_BASE_URL"),
        .prompt = envStr("ZHISPER_PROMPT"),
        .key_code = envI16("ZHISPER_KEY_CODE"),
        .mode = envStr("ZHISPER_MODE"),
        .evdev = envStr("ZHISPER_EVDEV"),
        .evdev_name = envStr("ZHISPER_EVDEV_NAME"),
        .cancel_key_code = envI16("ZHISPER_CANCEL_KEY_CODE"),
        .device = envStr("ZHISPER_DEVICE"),
        .min_duration_ms = envU32("ZHISPER_MIN_DURATION_MS"),
        .wav_path = envStr("ZHISPER_WAV_PATH"),
        .keep_wav_on_error = envBool("ZHISPER_KEEP_WAV"),
        .verbose = envBool("ZHISPER_VERBOSE"),
    };
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, cli: CliOverrides) !Config {
    var cfg = defaultConfig();
    const from_file = parseFileConfig(gpa, io, path) catch |e| switch (e) {
        error.FileNotFound, error.NoDevice, error.NotDir => null,
        else => return e,
    };
    if (from_file) |fc| cfg = fc;
    cfg = applyEnv(cfg, readEnvValues());
    cfg = applyCli(cfg, cli);
    validate(cfg) catch |e| {
        if (from_file != null) freeConfig(gpa, from_file.?);
        return e;
    };
    // The merged cfg borrows from the file parse (owned), env/argv
    // (borrowed), or literals — copy it whole so the result is always owned.
    const owned = try dupeConfig(gpa, cfg);
    if (from_file != null) freeConfig(gpa, from_file.?);
    return owned;
}

// Every TOML key the file is allowed to contain. checkUnknownFields is the
// single owner of this list; the struct definitions above own the values.
const known_sections = [_]struct { name: []const u8, keys: []const []const u8 }{
    .{ .name = "transcribe", .keys = &.{ "provider", "model", "base_url", "prompt" } },
    .{ .name = "hotkey", .keys = &.{ "key_code", "mode", "evdev", "evdev_name", "cancel_key_code" } },
    .{ .name = "audio", .keys = &.{"device"} },
    .{ .name = "daemon", .keys = &.{ "min_duration_ms", "wav_path", "keep_wav_on_error", "overlay", "tray", "verbose" } },
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
        const want = keys orelse {
            if (std.mem.eql(u8, "api_key", sec.key_ptr.*)) return error.ApiKeyInFile;
            return error.UnknownField;
        };
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
            // Range-check the key codes on the way through. WHY: the toml parser
            // assigns integers with a safety-checked @intCast, so a value like
            // 70000 in the file would panic the daemon at startup. This has to
            // run *before* the `ok` check below, which skips known keys.
            if (std.mem.eql(u8, "key_code", entry.key_ptr.*) or
                std.mem.eql(u8, "cancel_key_code", entry.key_ptr.*))
            {
                if (entry.value_ptr.* == .integer) {
                    const v = entry.value_ptr.integer;
                    if (v < -1 or v > 32767) return error.InvalidKeyCode;
                }
            }
            if (ok) continue;
            if (std.mem.eql(u8, "api_key", entry.key_ptr.*)) return error.ApiKeyInFile;
            return error.UnknownField;
        }
    }
}

test "defaultConfig matches spec defaults" {
    const cfg = defaultConfig();
    try std.testing.expectEqualStrings("groq", cfg.transcribe.provider);
    try std.testing.expectEqual(@as(?i16, 67), cfg.hotkey.key_code);
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
    try std.testing.expectEqual(@as(?i16, 70), cfg.hotkey.key_code);
    try std.testing.expectEqualStrings("toggle", cfg.hotkey.mode);
    try std.testing.expectEqual(@as(u32, 800), cfg.daemon.min_duration_ms);
}

test "daemon tray defaults off and parses opt-in" {
    try std.testing.expect(!defaultConfig().daemon.tray);

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const doc =
        \\[daemon]
        \\tray = true
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-tray.toml", .data = doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-tray.toml") catch {};

    const cfg = try parseFileConfig(gpa, io, "cfg-tray.toml");
    defer freeConfig(gpa, cfg);
    try std.testing.expect(cfg.daemon.tray);
}

test "daemon overlay defaults on and parses opt-out" {
    try std.testing.expect(defaultConfig().daemon.overlay);

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const off_doc =
        \\[daemon]
        \\overlay = false
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-overlay.toml", .data = off_doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-overlay.toml") catch {};

    const cfg = try parseFileConfig(gpa, io, "cfg-overlay.toml");
    defer freeConfig(gpa, cfg);
    try std.testing.expect(!cfg.daemon.overlay);

    const on_doc =
        \\[daemon]
        \\overlay = true
        \\
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-overlay-on.toml", .data = on_doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-overlay-on.toml") catch {};

    const on_cfg = try parseFileConfig(gpa, io, "cfg-overlay-on.toml");
    defer freeConfig(gpa, on_cfg);
    try std.testing.expect(on_cfg.daemon.overlay);
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

test "applyEnv overlays file values" {
    var cfg = defaultConfig();
    cfg.hotkey.key_code = 67;
    const out = applyEnv(cfg, .{ .provider = "openai", .model = "whisper-1", .evdev = "/dev/input/event5" });
    try std.testing.expectEqualStrings("openai", out.transcribe.provider);
    try std.testing.expectEqualStrings("whisper-1", out.transcribe.model);
    try std.testing.expectEqualStrings("/dev/input/event5", out.hotkey.evdev);
    // unset fields keep file values
    try std.testing.expectEqual(@as(?i16, 67), out.hotkey.key_code);
}

test "applyEnv overlays evdev_name" {
    const cfg = defaultConfig();
    const out = applyEnv(cfg, .{ .evdev_name = "kanata" });
    try std.testing.expectEqualStrings("kanata", out.hotkey.evdev_name);
    // unset fields keep file values
    try std.testing.expectEqualStrings("", cfg.hotkey.evdev_name);
}

test "validate rejects custom without url and bad mode" {
    var cfg = defaultConfig();
    cfg.transcribe.provider = "custom";
    cfg.transcribe.base_url = "";
    try std.testing.expectError(error.MissingBaseUrl, validate(cfg));
    cfg.transcribe.base_url = "http://localhost:8080/x";
    cfg.transcribe.model = "";
    try std.testing.expectError(error.MissingModel, validate(cfg));
    cfg.transcribe.model = "m";
    cfg.hotkey.mode = "bogus";
    try std.testing.expectError(error.InvalidMode, validate(cfg));
}

test "example file parses clean" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const cfg = try parseFileConfig(gpa, io, "config.example.toml");
    defer freeConfig(gpa, cfg);
    try validate(cfg);
    try std.testing.expectEqualStrings("groq", cfg.transcribe.provider);
}

test "load with missing file yields defaults plus CLI" {
    const gpa = std.testing.allocator;
    const cfg = try load(gpa, std.testing.io, "/tmp/zhisper-missing-config.toml", .{ .key_code = 70 });
    defer freeConfig(gpa, cfg);
    try std.testing.expectEqual(@as(?i16, 70), cfg.hotkey.key_code);
    try std.testing.expectEqualStrings("groq", cfg.transcribe.provider);
}

test "cancel_key_code defaults to 46 and overlays via env struct" {
    const cfg = defaultConfig();
    try std.testing.expectEqual(@as(?i16, 46), cfg.hotkey.cancel_key_code);
    const out = applyEnv(cfg, .{ .cancel_key_code = 48 });
    try std.testing.expectEqual(@as(?i16, 48), out.hotkey.cancel_key_code);
}

test "validate accepts a disabled cancel key but rejects one equal to the hotkey" {
    var cfg = defaultConfig();
    cfg.hotkey.cancel_key_code = -1;
    try validate(cfg);
    cfg.hotkey.cancel_key_code = cfg.hotkey.key_code;
    try std.testing.expectError(error.CancelEqualsHotkey, validate(cfg));
}

test "keyCodeOf maps null and -1 to disabled" {
    try std.testing.expect(keyCodeOf(null) == null);
    try std.testing.expect(keyCodeOf(-1) == null);
}

test "keyCodeOf preserves 0 as a real key" {
    try std.testing.expectEqual(@as(?u16, 0), keyCodeOf(0));
    try std.testing.expectEqual(@as(?u16, 67), keyCodeOf(67));
    try std.testing.expectEqual(@as(?u16, 32767), keyCodeOf(32767));
}

test "validate rejects a disabled hotkey" {
    var cfg = defaultConfig();
    cfg.hotkey.key_code = -1;
    try std.testing.expectError(error.InvalidKeyCode, validate(cfg));
    cfg.hotkey.key_code = null;
    try std.testing.expectError(error.InvalidKeyCode, validate(cfg));
}

test "parseFileConfig defaults an omitted key code to KEY_F9" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const doc = "[daemon]\ntray = false\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-nokey.toml", .data = doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-nokey.toml") catch {};
    const cfg = try parseFileConfig(gpa, io, "cfg-nokey.toml");
    defer freeConfig(gpa, cfg);
    try std.testing.expectEqual(@as(?i16, 67), cfg.hotkey.key_code);
    try std.testing.expectEqual(@as(?i16, 46), cfg.hotkey.cancel_key_code);
}

test "parseFileConfig reads -1 as a disabled key code" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const doc = "[hotkey]\nkey_code = -1\ncancel_key_code = -1\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-off.toml", .data = doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-off.toml") catch {};
    const cfg = try parseFileConfig(gpa, io, "cfg-off.toml");
    defer freeConfig(gpa, cfg);
    try std.testing.expectEqual(@as(?i16, -1), cfg.hotkey.key_code);
    try std.testing.expectEqual(@as(?i16, -1), cfg.hotkey.cancel_key_code);
}

test "parseFileConfig rejects an out-of-range key code instead of panicking" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const doc = "[hotkey]\nkey_code = 70000\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-huge.toml", .data = doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-huge.toml") catch {};
    try std.testing.expectError(error.InvalidKeyCode, parseFileConfig(gpa, io, "cfg-huge.toml"));
}

test "parseFileConfig reads cancel_key_code" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const doc = "[hotkey]\ncancel_key_code = 48\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "cfg-cancel.toml", .data = doc });
    defer std.Io.Dir.cwd().deleteFile(io, "cfg-cancel.toml") catch {};
    const cfg = try parseFileConfig(gpa, io, "cfg-cancel.toml");
    defer freeConfig(gpa, cfg);
    try std.testing.expectEqual(@as(?i16, 48), cfg.hotkey.cancel_key_code);
}
