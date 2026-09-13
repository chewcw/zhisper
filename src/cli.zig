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
    \\.      --evdev=<str>         Linux evdev path (empty = auto-scan)
    \\.      --device=<str>        mic device (empty = default)
    \\.      --wav-path=<str>      wav output path
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
    if (parsed.evdev) |v| cli.evdev = v;
    if (parsed.device) |v| cli.device = v;
    if (parsed.@"wav-path") |v| cli.wav_path = v;
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
