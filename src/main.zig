const std = @import("std");

const zhisper = @import("zhisper");

const cli = @import("cli.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = zhisper.log.logFn,
};

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

const Action = enum { start, stop, ignore, cancel };

const LoopState = struct {
    mode: zhisper.hotkey.Mode,
    recording: bool = false,
    press_count: u32 = 0,
};

fn handleHotkeyEvent(s: *LoopState, ev: zhisper.hotkey.KeyEvent) Action {
    if (ev == .cancel_pressed) {
        if (!s.recording) return .ignore;
        s.recording = false;
        return .cancel;
    }
    switch (s.mode) {
        .hold => switch (ev) {
            .hotkey_pressed => {
                if (s.recording) return .ignore;
                s.recording = true;
                return .start;
            },
            .hotkey_released => {
                if (!s.recording) return .ignore;
                s.recording = false;
                return .stop;
            },
            .cancel_pressed => unreachable, // handled above
        },
        .toggle => switch (ev) {
            .hotkey_released => return .ignore,
            .hotkey_pressed => {
                s.press_count += 1;
                if (!s.recording) {
                    s.recording = true;
                    return .start;
                }
                s.recording = false;
                return .stop;
            },
            .cancel_pressed => unreachable, // handled above
        },
    }
}

/// Overlay tint derivation (main thread only). Recording wins over a
/// queued clip; the worker thread never touches the overlay.
fn overlayStateFor(recording: bool, has_pending: bool) zhisper.overlay.State {
    if (recording) return .recording;
    if (has_pending) return .working;
    return .idle;
}

var stop_requested: std.atomic.Value(bool) = .init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .monotonic);
}

const WorkQueue = struct {
    // Single-slot handoff between the poll loop (producer) and the one
    // worker thread (consumer). Capacity is 1 active job + 1 waiting job;
    // when full, the loop deletes the waiting WAV and enqueues the newest
    // clip ("drop oldest"), so memory stays bounded no matter how fast
    // the user presses the key. Every field below is guarded by mutex.
    mutex: std.Io.Mutex = .init,
    // True when pending_path holds a clip the worker has not picked up yet.
    has_pending: bool = false,
    // Fixed buffer for the waiting clip's path. 512 covers OS config-dir
    // paths plus the per-recording counter suffix from uniqueWavPath.
    pending_path: [512]u8 = undefined,
    // Valid bytes in pending_path (paths are not NUL-terminated here).
    pending_len: usize = 0,
    // Set once by main on SIGINT/SIGTERM. Worker drains at most the active
    // plus one waiting job ("finish the sentence"), then exits.
    shutdown: bool = false,
};

fn workerMain(io: std.Io, gpa: std.mem.Allocator, cfg: zhisper.config.Config, api_key: []const u8, q: *WorkQueue) void {
    var path_buf: [512]u8 = undefined;
    while (true) {
        q.mutex.lockUncancelable(io);
        while (!q.has_pending and !q.shutdown) {
            q.mutex.unlock(io);
            io.sleep(.fromMilliseconds(10), .awake) catch {};
            q.mutex.lockUncancelable(io);
        }
        if (!q.has_pending and q.shutdown) {
            q.mutex.unlock(io);
            break;
        }
        const len = q.pending_len;
        @memcpy(path_buf[0..len], q.pending_path[0..len]);
        q.has_pending = false;
        q.mutex.unlock(io);
        const wav_path = path_buf[0..len];
        const t_cfg = buildTranscribeConfig(cfg, api_key);
        const transcribe_log = std.log.scoped(.transcribe);
        const text = zhisper.transcribe.transcribeWithConfig(io, gpa, wav_path, t_cfg) catch |err| {
            transcribe_log.debug("transcribe failed: {s}", .{@errorName(err)});
            if (!cfg.daemon.keep_wav_on_error) std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
            continue;
        };
        defer gpa.free(text);
        const inject_log = std.log.scoped(.inject);
        const n = zhisper.inject.typeText(text, io) catch |err| {
            inject_log.debug("inject failed: {s}", .{@errorName(err)});
            continue;
        };
        inject_log.debug("typed {d} chars", .{n});

        std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    zhisper.log.init();
    // CLI/config --verbose also enables stdout logs (env already checked in init).

    const argv = try init.minimal.args.toSlice(arena);
    const overrides = try cli.parseCli(arena, io, argv);

    const cfg_path = try resolveConfigPath(arena);
    const cfg = zhisper.config.load(arena, io, cfg_path, overrides) catch |err| {
        var errbuf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &errbuf);
        w.interface.print("zhisper: config error: {s}\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer zhisper.config.freeConfig(arena, cfg);
    if (cfg.daemon.verbose) zhisper.log.setEnabled(true);
    try zhisper.config.validate(cfg);

    if (overrides.list_devices) {
        try zhisper.audio.listCaptureDevices(io);
        return;
    }

    const mode = try modeFromString(cfg.hotkey.mode);
    const daemon_log = std.log.scoped(.daemon);

    // POSIX signals only: on Windows std.posix.Sigaction is void, so this
    // block is pruned at comptime there (abrupt Ctrl-C instead of graceful).
    {
        const builtin = @import("builtin");
        if (comptime builtin.os.tag != .windows) {
            var act: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.INT, &act, null);
            std.posix.sigaction(.TERM, &act, null);
        }
    }

    zhisper.audio.init(io, arena, cfg.audio.device) catch |err| {
        if (err == error.DeviceNotFound) {
            daemon_log.err("no mic matches \"{s}\" — available mics:", .{cfg.audio.device});
            zhisper.audio.listCaptureDevices(io) catch {};
        } else {
            daemon_log.err("audio init failed: {s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    zhisper.inject.setup(io) catch |err| {
        std.log.err("inject setup failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zhisper.inject.destroy();
    zhisper.hotkey.setup(.{ .key_code = cfg.hotkey.key_code, .mode = mode, .evdev = cfg.hotkey.evdev, .evdev_name = cfg.hotkey.evdev_name, .cancel_key_code = cfg.hotkey.cancel_key_code }) catch |err| {
        std.log.err("hotkey setup failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zhisper.hotkey.destroy();

    // Overlay is best-effort: any failure degrades to hotkey-only.
    var overlay_live = false;
    if (zhisper.overlay.setup(.{})) |_| {
        overlay_live = true;
    } else |err| {
        daemon_log.debug("overlay setup failed (headless): {s}", .{@errorName(err)});
    }
    if (overlay_live) {
        zhisper.overlay.show() catch |err| {
            daemon_log.debug("overlay show failed: {s}", .{@errorName(err)});
            zhisper.overlay.destroy();
            overlay_live = false;
        };
    }
    defer if (overlay_live) {
        zhisper.overlay.destroy();
    };
    const overlay_pos_path = if (overlay_live) zhisper.overlay.overlayPosPath(arena) catch null else null;
    // Enumerate once at startup (primary first); unplugged-monitor saves
    // fall back to the default corner inside loadOverlayPos. The arena
    // owns the list for the life of the daemon.
    var overlay_no_displays: [0]zhisper.overlay_types.Display = .{};
    var overlay_displays: []zhisper.overlay_types.Display = overlay_no_displays[0..];
    if (overlay_live) {
        overlay_displays = zhisper.overlay.displayList(arena) catch overlay_no_displays[0..];
        if (overlay_pos_path) |pp| {
            zhisper.overlay.move(zhisper.overlay.loadOverlayPos(io, arena, pp, overlay_displays));
        }
    }
    var overlay_state: zhisper.overlay.State = .idle;
    // Animation clock base: pill frames use millis since daemon start
    // (monotonic .awake clock, same source as the recording timer below).
    const overlay_t0: std.Io.Clock.Timestamp = std.Io.Clock.Timestamp.now(io, .awake);

    const provider = zhisper.transcribe.providerFromName(cfg.transcribe.provider);
    const api_key = resolveApiKey(provider) orelse {
        std.log.err("missing API key (set ZHISPER_API_KEY or provider key)", .{});
        std.process.exit(1);
    };

    var queue = WorkQueue{};
    const worker = try std.Thread.spawn(.{}, workerMain, .{ io, arena, cfg, api_key, &queue });

    var loop_state = LoopState{ .mode = mode };
    var start_ts: std.Io.Clock.Timestamp = undefined;
    var have_start = false;
    var wav_counter: u32 = 0;
    daemon_log.info("listening (mode={s}, key={d}, cancel={d})", .{ cfg.hotkey.mode, cfg.hotkey.key_code, cfg.hotkey.cancel_key_code });

    while (!stop_requested.load(.monotonic)) {
        const ev = zhisper.hotkey.pollEvent();
        if (ev) |e| {
            daemon_log.debug("ev: {any}", .{e});
            const action = handleHotkeyEvent(&loop_state, e);
            switch (action) {
                .ignore => {},
                .start => {
                    daemon_log.info("start recording...", .{});
                    start_ts = std.Io.Clock.Timestamp.now(io, .awake);
                    have_start = true;
                    zhisper.audio.setRecording(.start, "") catch |err| {
                        daemon_log.debug("record start failed: {s}", .{@errorName(err)});
                        loop_state.recording = false;
                        have_start = false;
                    };
                },
                .cancel => {
                    daemon_log.info("cancelled recording", .{});
                    have_start = false;
                    zhisper.audio.setRecording(.cancel, "") catch |err| {
                        daemon_log.debug("record cancel failed: {s}", .{@errorName(err)});
                    };
                },
                .stop => {
                    daemon_log.info("stop recording", .{});
                    wav_counter += 1;
                    const wav_path = try uniqueWavPath(arena, cfg.daemon.wav_path, wav_counter);
                    defer arena.free(wav_path);
                    zhisper.audio.setRecording(.stop, wav_path) catch |err| {
                        daemon_log.debug("record stop failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    const now_ts = std.Io.Clock.Timestamp.now(io, .awake);
                    const elapsed_ns: u64 = if (have_start) @intCast(start_ts.durationTo(now_ts).raw.nanoseconds) else 0;
                    have_start = false;
                    if (elapsed_ns < @as(u64, cfg.daemon.min_duration_ms) * 1_000_000) {
                        daemon_log.debug("discarded short press ({d}ns)", .{elapsed_ns});
                        std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
                        continue;
                    }
                    const stat = std.Io.Dir.cwd().statFile(io, wav_path, .{}) catch continue;
                    if (stat.size < 44 + minWavPayloadBytes(cfg.daemon.min_duration_ms)) {
                        daemon_log.debug("discarded quiet clip ({d} bytes)", .{stat.size});
                        std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
                        continue;
                    }
                    queue.mutex.lockUncancelable(io);
                    if (queue.has_pending) {
                        var old: [512]u8 = undefined;
                        @memcpy(old[0..queue.pending_len], queue.pending_path[0..queue.pending_len]);
                        const old_path = old[0..queue.pending_len];
                        queue.mutex.unlock(io);
                        std.Io.Dir.cwd().deleteFile(io, old_path) catch {};
                        daemon_log.debug("worker busy, dropped oldest clip", .{});
                        queue.mutex.lockUncancelable(io);
                    }
                    const copy_len = @min(wav_path.len, queue.pending_path.len);
                    @memcpy(queue.pending_path[0..copy_len], wav_path[0..copy_len]);
                    queue.pending_len = copy_len;
                    queue.has_pending = true;
                    queue.mutex.unlock(io);
                },
            }
        } else {
            if (overlay_live) {
                if (zhisper.overlay.pollEvent()) |oev| {
                    switch (oev) {
                        .drag_start, .drag_moved => {},
                        .drag_end => |p| {
                            if (overlay_pos_path) |pp| {
                                zhisper.overlay.saveOverlayPos(io, pp, p) catch |err| {
                                    daemon_log.debug("overlay pos save failed: {s}", .{@errorName(err)});
                                };
                            }
                        },
                    }
                } else {
                    try io.sleep(.fromMilliseconds(5), .awake);
                }
            } else {
                try io.sleep(.fromMilliseconds(5), .awake);
            }
        }
        // One-way state push on change only (never from the worker thread).
        if (overlay_live) {
            // Pill animation frame (the backend throttles to 30fps and
            // guards clock jumps; negative deltas clamp to 0).
            const now_uptime = std.Io.Clock.Timestamp.now(io, .awake);
            const uptime_ns: u64 = @intCast(@max(0, overlay_t0.durationTo(now_uptime).raw.nanoseconds));
            zhisper.overlay.tick(uptime_ns / 1_000_000);
            queue.mutex.lockUncancelable(io);
            const pending = queue.has_pending;
            queue.mutex.unlock(io);
            const cur = overlayStateFor(loop_state.recording, pending);
            if (cur != overlay_state) {
                overlay_state = cur;
                zhisper.overlay.setState(cur);
            }
        }
    }

    // Graceful shutdown: abandon an active recording (no WAV written),
    // let the worker finish at most current + one waiting job, then exit.
    if (loop_state.recording) zhisper.audio.shutdown();
    queue.mutex.lockUncancelable(io);
    queue.shutdown = true;
    queue.mutex.unlock(io);
    worker.join();
    zhisper.audio.shutdown();
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
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .hotkey_released));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_released));
}

test "toggle alternates on press and ignores release" {
    var s = LoopState{ .mode = .toggle };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_released));
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_released));
}

test "cancel while recording returns cancel and resets" {
    var s = LoopState{ .mode = .toggle };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.cancel, handleHotkeyEvent(&s, .cancel_pressed));
    try std.testing.expect(!s.recording);
    // next press is a fresh start, not a stop
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .hotkey_pressed));
}

test "cancel in hold mode makes trailing release a no-op" {
    var s = LoopState{ .mode = .hold };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.cancel, handleHotkeyEvent(&s, .cancel_pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_released));
}

test "cancel while idle is ignored" {
    var s = LoopState{ .mode = .hold };
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .cancel_pressed));
    var t = LoopState{ .mode = .toggle };
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&t, .cancel_pressed));
}

test "overlay state derives from recording then pending" {
    try std.testing.expectEqual(zhisper.overlay.State.recording, overlayStateFor(true, false));
    try std.testing.expectEqual(zhisper.overlay.State.recording, overlayStateFor(true, true));
    try std.testing.expectEqual(zhisper.overlay.State.working, overlayStateFor(false, true));
    try std.testing.expectEqual(zhisper.overlay.State.idle, overlayStateFor(false, false));
}

test "std_options routes through env-gated logFn" {
    // Generic logFn values don't compare reliably with ==, so verify the
    // exe root declares std_options with debug max level (proves our decl
    // wins over the default) and that the gated module is wired.
    try std.testing.expect(@hasDecl(@This(), "std_options"));
    try std.testing.expectEqual(std.log.Level.debug, std.options.log_level);
    @import("zhisper").log.setEnabled(false);
    try std.testing.expect(@import("zhisper").log.shouldLog(.err));
    try std.testing.expect(!@import("zhisper").log.shouldLog(.debug));
}
