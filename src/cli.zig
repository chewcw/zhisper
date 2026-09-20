const std = @import("std");
const argz = @import("argz");
const config = @import("zhisper").config;

const help_text =
    \\usage zhisper [options...]
    \\
    \\options:
    \\.  -h, --help                print this help and exit
    \\.      --provider=<str>      groq | openai | custom
    \\.      --model=<str>         model override (empty = preset)
    \\.      --base-url=<str>      base URL override (required if provider=custom)
    \\.      --prompt=<str>        transcription prompt
    \\.      --key-code=<uint>     OS-native hotkey code (default 67=F9)
    \\.      --mode=<str>          hold | toggle
    \\.      --evdev=<str>         Linux evdev path or name:DEVICE (empty = auto-scan)
    \\.      --device=<str>        mic device (empty = default)
    \\.      --wav-path=<str>      wav output path
    \\.      --min-duration-ms=<uint>  discard recordings shorter than this (ms)
    \\.      --keep-wav            keep WAV on error (default keep)
    \\.      --no-keep-wav         do not keep WAV on error
    \\.  -v, --verbose             verbose logging
    \\
;

// Single argv-slice entry point: main passes its real args, tests pass fake
// args — no Init dependency, so no mock is needed. Values borrow argv/arena;
// the daemon copies them into Config via load(). --help prints usage and
// exits (argz behavior), so never pass --help in tests.
pub fn parseCli(arena: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !config.CliOverrides {
    const parsed = try argz.parseArgv(help_text, .{}, arena, io, argv);
    return fromParsed(parsed);
}

fn fromParsed(parsed: anytype) config.CliOverrides {
    var cli: config.CliOverrides = .{};
    if (parsed.provider) |v| cli.provider = v;
    if (parsed.model) |v| cli.model = v;
    if (parsed.@"base-url") |v| cli.base_url = v;
    if (parsed.prompt) |v| cli.prompt = v;
    if (parsed.@"key-code") |v| cli.key_code = std.math.cast(u16, v);
    if (parsed.mode) |v| cli.mode = v;
    // --evdev accepts either a path (/dev/input/event5) or a logical
    // device name (name:kanata) that survives reboot renumbering.
    if (parsed.evdev) |v| {
        if (std.mem.startsWith(u8, v, "name:")) {
            cli.evdev_name = v["name:".len..];
        } else {
            cli.evdev = v;
        }
    }
    if (parsed.device) |v| cli.device = v;
    if (parsed.@"wav-path") |v| cli.wav_path = v;
    if (parsed.@"min-duration-ms") |v| cli.min_duration_ms = std.math.cast(u32, v);
    if (parsed.@"keep-wav" > 0) cli.keep_wav_on_error = true;
    if (parsed.@"no-keep-wav" > 0) cli.keep_wav_on_error = false;
    if (parsed.verbose > 0) cli.verbose = true;
    return cli;
}

test "cli parses flags into overrides" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "zhisper", "--provider", "openai", "--key-code=70", "--verbose" };
    const cli = try parseCli(arena.allocator(), std.testing.io, &argv);
    try std.testing.expectEqualStrings("openai", cli.provider.?);
    try std.testing.expectEqual(@as(u16, 70), cli.key_code.?);
    try std.testing.expectEqual(true, cli.verbose.?);
}

test "cli defaults to no overrides" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = [_][:0]const u8{"zhisper"};
    const cli = try parseCli(arena.allocator(), std.testing.io, &argv);
    try std.testing.expect(cli.provider == null);
    try std.testing.expect(cli.key_code == null);
    try std.testing.expect(cli.verbose == null);
}

test "cli parses min-duration and keep-wav flags" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "zhisper", "--min-duration-ms=800", "--keep-wav" };
    const got = try parseCli(arena.allocator(), std.testing.io, &argv);
    try std.testing.expectEqual(@as(u32, 800), got.min_duration_ms.?);
    try std.testing.expectEqual(true, got.keep_wav_on_error.?);
}

test "cli parses evdev path and name: prefix" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "zhisper", "--evdev=name:kanata" };
    const got = try parseCli(arena.allocator(), std.testing.io, &argv);
    try std.testing.expectEqualStrings("kanata", got.evdev_name.?);
    try std.testing.expect(got.evdev == null);
    const argv2 = [_][:0]const u8{ "zhisper", "--evdev=/dev/input/event5" };
    const got2 = try parseCli(arena.allocator(), std.testing.io, &argv2);
    try std.testing.expectEqualStrings("/dev/input/event5", got2.evdev.?);
    try std.testing.expect(got2.evdev_name == null);
}

test "cli parses no-keep-wav as false" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "zhisper", "--no-keep-wav" };
    const got = try parseCli(arena.allocator(), std.testing.io, &argv);
    try std.testing.expectEqual(false, got.keep_wav_on_error.?);
}
