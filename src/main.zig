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

/// Builds the recording path inside `dir`. Split from resolveWavPath so the
/// path construction is testable without touching the real environment.
fn wavPathIn(gpa: std.mem.Allocator, dir: ?[]const u8) ![]u8 {
    const d = dir orelse return gpa.dupe(u8, "zhisper.wav");
    const trimmed = std.mem.trimEnd(u8, d, "/\\");
    if (trimmed.len == 0) return gpa.dupe(u8, "zhisper.wav");
    return std.fmt.allocPrint(gpa, "{s}" ++ std.fs.path.sep_str ++ "zhisper.wav", .{trimmed});
}

/// WHY: the config default used to be the literal "/tmp/zhisper.wav", a
/// hardcoded POSIX path in shared code. macOS survives that only because /tmp is
/// a symlink to /private/tmp; Windows cannot write there at all. An empty
/// config value now means "platform temp directory", resolved per OS the same
/// way resolveConfigPath branches.
fn resolveWavPath(gpa: std.mem.Allocator, configured: []const u8) ![]u8 {
    if (configured.len != 0) return gpa.dupe(u8, configured);
    const builtin = @import("builtin");
    // Sentinel-terminated because std.c.getenv takes [:0]const u8.
    const keys: []const [:0]const u8 = switch (builtin.os.tag) {
        .windows => &.{ "TMP", "TEMP" },
        else => &.{"TMPDIR"},
    };
    for (keys) |key| {
        if (std.c.getenv(key)) |raw| {
            const p = wavPathIn(gpa, std.mem.span(raw)) catch continue;
            return p;
        }
    }
    return wavPathIn(gpa, null);
}

fn buildTranscribeConfig(unified: zhisper.config.Config, api_key: []const u8) zhisper.transcribe.Config {
    return .{
        .base_url = unified.transcribe.base_url,
        .model = unified.transcribe.model,
        .api_key = api_key,
        .prompt = unified.transcribe.prompt,
    };
}

fn buildNormalizeConfig(unified: zhisper.config.Config, api_key: []const u8) zhisper.normalize.ResolutionError!zhisper.normalize.Config {
    var cfg = try zhisper.normalize.resolveConfig(unified.normalize.model, unified.normalize.base_url, api_key);
    // resolveConfig only fills in the endpoint and model, so the three axis
    // values have to be copied across separately. Inlining this at the call
    // site is what let the endpoint override and the axes be silently
    // dropped, because nothing tested the wiring.
    cfg.styling = unified.normalize.styling;
    cfg.structure = unified.normalize.structure;
    cfg.context = unified.normalize.context;
    return cfg;
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

/// Where a finished transcript goes. Chosen when a recording starts, carried
/// with the job to the worker, and never changed mid-flight — a clipboard
/// recording can still be transcribing while a dictation recording is queued
/// behind it, so this is per-job state and never a global mode.
const Sink = enum { typing, clipboard };

const LoopState = struct {
    mode: zhisper.hotkey.Mode,
    recording: bool = false,
    press_count: u32 = 0,
    /// Output target of the current recording, and also its identity: only the
    /// key that started it can stop it.
    sink: Sink = .typing,
};

/// Which key an event came from. Key-based rather than press-based, because
/// the release arm reads this to confirm the releasing key owns the recording.
fn sinkFor(ev: zhisper.hotkey.KeyEvent) Sink {
    return switch (ev) {
        .clipboard_pressed, .clipboard_released => .clipboard,
        .hotkey_pressed, .hotkey_released, .cancel_pressed => .typing,
    };
}

fn handleHotkeyEvent(s: *LoopState, ev: zhisper.hotkey.KeyEvent) Action {
    if (ev == .cancel_pressed) {
        if (!s.recording) return .ignore;
        s.recording = false;
        return .cancel;
    }
    switch (s.mode) {
        .hold => switch (ev) {
            .hotkey_pressed, .clipboard_pressed => {
                if (s.recording) return .ignore;
                s.recording = true;
                s.sink = sinkFor(ev);
                return .start;
            },
            .hotkey_released, .clipboard_released => {
                if (!s.recording) return .ignore;
                // Only the key that started the recording ends it. Otherwise a
                // tap of the other key mid-dictation truncates the sentence.
                if (sinkFor(ev) != s.sink) return .ignore;
                s.recording = false;
                return .stop;
            },
            .cancel_pressed => unreachable, // handled above
        },
        .toggle => switch (ev) {
            .hotkey_released, .clipboard_released => return .ignore,
            .hotkey_pressed, .clipboard_pressed => {
                s.press_count += 1;
                if (!s.recording) {
                    s.recording = true;
                    s.sink = sinkFor(ev);
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

fn trayStateFor(recording: bool, active: bool, has_pending: bool) zhisper.tray.State {
    if (recording) return .recording;
    if (active or has_pending) return .working;
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
    // True from dequeue through transcription and injection completion.
    active: bool = false,
    // Fixed buffer for the waiting clip's path. 512 covers OS config-dir
    // paths plus the per-recording counter suffix from uniqueWavPath.
    pending_path: [512]u8 = undefined,
    // Valid bytes in pending_path (paths are not NUL-terminated here).
    pending_len: usize = 0,
    // Output target of the waiting clip, written with pending_path under the
    // same lock so the worker can never see a path and the wrong sink.
    pending_sink: Sink = .typing,
    // Set once by main on SIGINT/SIGTERM. Worker drains at most the active
    // plus one waiting job ("finish the sentence"), then exits.
    shutdown: bool = false,
};

fn workerMain(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: zhisper.config.Config,
    api_key: []const u8,
    q: *WorkQueue,
    normalize_flag: *std.atomic.Value(bool),
    clipboard_state: zhisper.clipboard.Clipboard,
    trailing_newline: zhisper.inject.TrailingNewline,
) void {
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
        // Copied under the lock, alongside the path it belongs to.
        const sink = q.pending_sink;
        q.has_pending = false;
        q.active = true;
        q.mutex.unlock(io);
        defer {
            q.mutex.lockUncancelable(io);
            q.active = false;
            q.mutex.unlock(io);
        }
        const wav_path = path_buf[0..len];
        const t_cfg = buildTranscribeConfig(cfg, api_key);
        const transcribe_log = std.log.scoped(.transcribe);
        const text = zhisper.transcribe.transcribeWithConfig(io, gpa, wav_path, t_cfg) catch |err| {
            transcribe_log.debug("transcribe failed: {s}", .{@errorName(err)});
            if (!cfg.daemon.keep_wav_on_error) std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
            continue;
        };
        defer gpa.free(text);
        // Normalization is best-effort and never blocks the dictation: every
        // failure path keeps the raw transcript. An empty raw transcript is
        // skipped entirely so silence does not cost a network round trip.
        var final_text = text;
        if (normalize_flag.load(.monotonic) and text.len > 0) {
            const normalize_log = std.log.scoped(.normalize);
            if (buildNormalizeConfig(cfg, api_key)) |n_cfg| {
                if (zhisper.normalize.normalizeWithConfig(io, gpa, text, n_cfg)) |clean| {
                    final_text = clean;
                } else |err| {
                    normalize_log.warn("normalize failed, using raw transcript: {s}", .{@errorName(err)});
                }
            } else |err| {
                normalize_log.warn("normalize config invalid, using raw transcript: {s}", .{@errorName(err)});
            }
        }
        const inject_log = std.log.scoped(.inject);
        switch (sink) {
            .typing => {
                const n = zhisper.inject.typeText(final_text, io) catch |err| {
                    inject_log.debug("inject failed: {s}", .{@errorName(err)});
                    continue;
                };
                inject_log.debug("typed {d} keystrokes", .{n});
            },
            .clipboard => {
                // Reuse the injection newline rule rather than a second one:
                // trailingCut is the same pure helper every platform emitter
                // uses, so daemon.trailing_newline means the same thing here.
                const cut = zhisper.inject.trailingCut(final_text, trailing_newline);
                const payload = final_text[0 .. final_text.len - cut];
                if (payload.len == 0) {
                    // Deliberately not `continue`: that would skip the WAV
                    // delete below and leak a file per misfire. An empty
                    // transcript must never clobber what the user has copied.
                    inject_log.debug("empty transcript, clipboard left untouched", .{});
                } else {
                    zhisper.clipboard.paste(payload, io, clipboard_state) catch |err| {
                        inject_log.debug("clipboard write failed: {s}", .{@errorName(err)});
                    };
                    inject_log.debug("clipboard filled with {d} bytes", .{payload.len});
                }
            },
        }

        std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    // Thread-safe and leak-checked in Debug. Used by the config-reload path,
    // which runs repeatedly and must not accumulate on the arena.
    const gpa = init.gpa;
    zhisper.log.init();
    // CLI/config --verbose also enables stdout logs (env already checked in init).

    const argv = try init.minimal.args.toSlice(arena);
    const overrides = try cli.parseCli(arena, io, argv);

    const cfg_path = try resolveConfigPath(arena);
    const cfg = zhisper.config.load(arena, io, cfg_path, overrides) catch |err| {
        var errbuf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &errbuf);
        w.interface.print("zhisper: config error: {s}\n", .{@errorName(err)}) catch {};
        // WHY an explicit flush and not a defer: print only fills errbuf, and
        // std.process.exit terminates immediately without unwinding, so the
        // diagnostic would be silently dropped and a config typo would look
        // like a crash with no message.
        w.interface.flush() catch {};
        std.process.exit(1);
    };
    defer zhisper.config.freeConfig(arena, cfg);
    if (cfg.daemon.verbose) zhisper.log.setEnabled(true);
    try zhisper.config.validate(cfg);
    const wav_base = try resolveWavPath(arena, cfg.daemon.wav_path);

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
    const trailing_newline: zhisper.inject.TrailingNewline =
        if (std.mem.eql(u8, cfg.daemon.trailing_newline, "send")) .send else .strip;
    zhisper.inject.setup(io, .{
        .trailing_newline = trailing_newline,
        .type_delay_ms = cfg.daemon.type_delay_ms,
    }) catch |err| {
        std.log.err("inject setup failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zhisper.inject.destroy();
    const hotkey_code = zhisper.config.keyCodeOf(cfg.hotkey.key_code) orelse {
        std.log.err("hotkey.key_code must be set to a real key code (use -1 to disable the cancel key, not the hotkey)", .{});
        std.process.exit(1);
    };
    // Clipboard capture gate. A zero code means "off", so the gate and the OS
    // seam agree on one value: when no clipboard tool exists we never hand the
    // key to the seam at all, so it can never emit an event we cannot honour.
    // The probe is skipped entirely when the key is unconfigured, so a daemon
    // that does not use this feature never spawns a `which` subprocess.
    var clipboard_state: zhisper.clipboard.Clipboard = .{ .available = false, .tool = null };
    const clipboard_code: u16 = if (zhisper.config.keyCodeOf(cfg.hotkey.clipboard_key_code)) |code| blk: {
        clipboard_state = zhisper.clipboard.check(io);
        if (!clipboard_state.available) {
            // .err, not .warn and not log.warn(): only .err bypasses the
            // ZHISPER_DEBUG gate, and a hotkey that silently never fires reads
            // to the user as a broken daemon or a broken keyboard. inject_linux
            // uses the silent helper for its own clipboard degradation, which
            // is a different failure — that one announces itself in the text.
            daemon_log.err("clipboard_key_code={d} set but no clipboard tool found — clipboard capture disabled, use key_code instead", .{code});
            break :blk 0;
        }
        break :blk code;
    } else 0;
    zhisper.hotkey.setup(.{
        .key_code = hotkey_code,
        .mode = mode,
        .evdev = cfg.hotkey.evdev,
        .evdev_name = cfg.hotkey.evdev_name,
        .cancel_key_code = zhisper.config.keyCodeOf(cfg.hotkey.cancel_key_code) orelse 0,
        .clipboard_key_code = clipboard_code,
    }) catch |err| {
        std.log.err("hotkey setup failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zhisper.hotkey.destroy();

    // Overlay is best-effort: any failure degrades to hotkey-only. With
    // daemon.overlay = false the subsystem is never started, so there is
    // no SDL window, no display enumeration, and no overlay.pos read.
    var overlay_live = false;
    if (cfg.daemon.overlay) {
        if (zhisper.overlay.setup(.{})) |_| {
            overlay_live = true;
        } else |err| {
            daemon_log.debug("overlay setup failed (headless): {s}", .{@errorName(err)});
        }
    } else {
        daemon_log.debug("overlay disabled by config", .{});
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

    var tray_live = false;
    if (cfg.daemon.tray) {
        if (zhisper.tray.setup(io)) |_| {
            tray_live = true;
        } else |err| {
            daemon_log.warn("tray setup failed (continuing without tray): {s}", .{@errorName(err)});
        }
    }
    defer if (tray_live) {
        zhisper.tray.destroy(io);
    };
    var tray_state: zhisper.tray.State = .idle;
    if (tray_live) {
        zhisper.tray.setState(io, .idle) catch |err| {
            daemon_log.debug("tray idle update failed (disabling tray): {s}", .{@errorName(err)});
            zhisper.tray.destroy(io);
            tray_live = false;
        };
    }

    var queue = WorkQueue{};
    // Seeded from the config file's value at startup; the poll loop below
    // keeps it in sync.
    var normalize_flag = std.atomic.Value(bool).init(cfg.normalize.enabled);
    const worker = try std.Thread.spawn(.{}, workerMain, .{ io, arena, cfg, api_key, &queue, &normalize_flag, clipboard_state, trailing_newline });

    // WHY: the config is loaded once, but `normalize.enabled` is the escape
    // hatch a user reaches for the moment normalization mangles their text.
    // It must be flippable without a restart. Only that one key is re-read —
    // see config.loadNormalizeEnabled for why a full reload would mislead.
    var cfg_signature: ?std.Io.File.Stat = zhisper.config.fileSignature(io, cfg_path);
    var cfg_checked_at = std.Io.Timestamp.now(io, .awake);
    const cfg_poll_interval_ns: i96 = 1_000_000_000; // once a second

    var loop_state = LoopState{ .mode = mode };
    var start_ts: std.Io.Clock.Timestamp = undefined;
    var have_start = false;
    var wav_counter: u32 = 0;
    const clipboard_label: []const u8 = if (clipboard_code == 0) "off" else "on";
    daemon_log.info("listening (mode={s}, key={d}, cancel={d}, clipboard={s})", .{ cfg.hotkey.mode, hotkey_code, zhisper.config.keyCodeOf(cfg.hotkey.cancel_key_code) orelse 0, clipboard_label });

    while (!stop_requested.load(.monotonic)) {
        const cfg_now = std.Io.Timestamp.now(io, .awake);
        const since_check = cfg_checked_at.durationTo(cfg_now).nanoseconds;
        if (since_check >= cfg_poll_interval_ns) {
            daemon_log.debug("checking the config file stats", .{});
            cfg_checked_at = cfg_now;
            const signature = zhisper.config.fileSignature(io, cfg_path);
            const changed = blk: {
                const old = cfg_signature;
                if (old == null and signature == null) break :blk false;
                if (old == null or signature == null) break :blk true;
                break :blk old.?.mtime.nanoseconds != signature.?.mtime.nanoseconds or
                    old.?.size != signature.?.size;
            };
            if (changed) {
                cfg_signature = signature;
                // Uses init.gpa, not the arena: this runs repeatedly, and a
                // typo in the config must not grow the arena or kill the daemon.
                if (zhisper.config.loadNormalizeEnabled(gpa, io, cfg_path)) |enabled| {
                    normalize_flag.store(enabled, .monotonic);
                    daemon_log.info("normalize.enabled = {}", .{enabled});
                } else |err| {
                    daemon_log.warn("config reload failed, keeping normalize.enabled: {s}", .{@errorName(err)});
                }
            }
        }
        if (tray_live) zhisper.tray.poll(io);
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
                    const wav_path = try uniqueWavPath(arena, wav_base, wav_counter);
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
                    queue.pending_sink = loop_state.sink;
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
        if (tray_live) {
            queue.mutex.lockUncancelable(io);
            const active = queue.active;
            const has_pending = queue.has_pending;
            queue.mutex.unlock(io);

            const cur_tray = trayStateFor(loop_state.recording, active, has_pending);
            if (cur_tray != tray_state) {
                tray_state = cur_tray;
                zhisper.tray.setState(io, cur_tray) catch |err| {
                    daemon_log.debug("tray state update failed (disabling tray): {s}", .{@errorName(err)});
                    zhisper.tray.destroy(io);
                    tray_live = false;
                };
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

test "wavPathIn builds the recording name in the given directory" {
    const gpa = std.testing.allocator;
    const p = try wavPathIn(gpa, "/tmp");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/tmp" ++ std.fs.path.sep_str ++ "zhisper.wav", p);
}

test "wavPathIn trims trailing separators from the directory" {
    const gpa = std.testing.allocator;
    const p = try wavPathIn(gpa, "/tmp/");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("/tmp" ++ std.fs.path.sep_str ++ "zhisper.wav", p);
}

test "wavPathIn falls back to the cwd when no directory is known" {
    const gpa = std.testing.allocator;
    const none = try wavPathIn(gpa, null);
    defer gpa.free(none);
    try std.testing.expectEqualStrings("zhisper.wav", none);

    const blank = try wavPathIn(gpa, "///");
    defer gpa.free(blank);
    try std.testing.expectEqualStrings("zhisper.wav", blank);
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

test "buildNormalizeConfig carries the endpoint override and all three axes" {
    const unified = zhisper.config.Config{
        .normalize = .{
            .enabled = true,
            .model = "some-model",
            .base_url = "http://127.0.0.1:11434/v1/chat/completions",
            .styling = "formal",
            .structure = "lists",
            .context = "email",
        },
    };
    const n = try buildNormalizeConfig(unified, "k123");
    try std.testing.expectEqualStrings("some-model", n.model);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1/chat/completions", n.base_url);
    try std.testing.expectEqualStrings("k123", n.api_key);
    try std.testing.expectEqualStrings("formal", n.styling);
    try std.testing.expectEqualStrings("lists", n.structure);
    try std.testing.expectEqualStrings("email", n.context);
}

test "buildNormalizeConfig falls back to the preset endpoint and model" {
    const unified = zhisper.config.Config{ .normalize = .{} };
    const n = try buildNormalizeConfig(unified, "k123");
    try std.testing.expectEqualStrings(zhisper.normalize.default_base_url, n.base_url);
    try std.testing.expectEqualStrings(zhisper.normalize.default_model, n.model);
    try std.testing.expectEqualStrings("semi-formal", n.styling);
    try std.testing.expectEqualStrings("prose", n.structure);
    try std.testing.expectEqualStrings("general", n.context);
}

test "buildNormalizeConfig rejects an empty key" {
    const unified = zhisper.config.Config{ .normalize = .{} };
    try std.testing.expectError(error.MissingApiKey, buildNormalizeConfig(unified, ""));
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

test "tray state covers recording, active work, pending work, and idle" {
    try std.testing.expectEqual(zhisper.tray.State.recording, trayStateFor(true, false, false));
    try std.testing.expectEqual(zhisper.tray.State.recording, trayStateFor(true, true, true));
    try std.testing.expectEqual(zhisper.tray.State.working, trayStateFor(false, true, false));
    try std.testing.expectEqual(zhisper.tray.State.working, trayStateFor(false, false, true));
    try std.testing.expectEqual(zhisper.tray.State.idle, trayStateFor(false, false, false));
}

test "overlay state derives from recording then pending" {
    try std.testing.expectEqual(zhisper.overlay.State.recording, overlayStateFor(true, false));
    try std.testing.expectEqual(zhisper.overlay.State.recording, overlayStateFor(true, true));
    try std.testing.expectEqual(zhisper.overlay.State.working, overlayStateFor(false, true));
    try std.testing.expectEqual(zhisper.overlay.State.idle, overlayStateFor(false, false));
}

test "clipboard press starts a clipboard recording and release stops it" {
    var s = LoopState{ .mode = .hold };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .clipboard_pressed));
    try std.testing.expectEqual(Sink.clipboard, s.sink);
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .clipboard_released));
}

test "the clipboard key mirrors the dictation key in toggle mode" {
    var s = LoopState{ .mode = .toggle };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .clipboard_pressed));
    try std.testing.expectEqual(Sink.clipboard, s.sink);
    // Toggle ignores every release, same as the dictation key.
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .clipboard_released));
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .clipboard_pressed));
    try std.testing.expectEqual(@as(u32, 2), s.press_count);
}

test "a clipboard press while dictating is ignored and does not change the sink" {
    var s = LoopState{ .mode = .hold };
    try std.testing.expectEqual(Action.start, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .clipboard_pressed));
    try std.testing.expectEqual(Sink.typing, s.sink);
}

test "a dictation press while clipboard recording is ignored" {
    var s = LoopState{ .mode = .hold };
    _ = handleHotkeyEvent(&s, .clipboard_pressed);
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_pressed));
    try std.testing.expectEqual(Sink.clipboard, s.sink);
    try std.testing.expect(s.recording);
}

test "the clipboard release does not stop a recording the dictation key started" {
    // Without the owner check, a user who holds the dictation key and taps the
    // clipboard key would have the tap end their dictation mid-sentence.
    var s = LoopState{ .mode = .hold };
    _ = handleHotkeyEvent(&s, .hotkey_pressed);
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .clipboard_released));
    try std.testing.expect(s.recording);
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .hotkey_released));
}

test "the dictation release does not stop a recording the clipboard key started" {
    var s = LoopState{ .mode = .hold };
    _ = handleHotkeyEvent(&s, .clipboard_pressed);
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .hotkey_released));
    try std.testing.expectEqual(Action.stop, handleHotkeyEvent(&s, .clipboard_released));
}

test "cancel clears a clipboard recording" {
    var s = LoopState{ .mode = .hold };
    _ = handleHotkeyEvent(&s, .clipboard_pressed);
    try std.testing.expectEqual(Action.cancel, handleHotkeyEvent(&s, .cancel_pressed));
    try std.testing.expect(!s.recording);
    // The trailing release stays a no-op, exactly as for a dictation recording.
    try std.testing.expectEqual(Action.ignore, handleHotkeyEvent(&s, .clipboard_released));
}

test "a clipboard recording uses the same overlay and tray indicators" {
    var s = LoopState{ .mode = .hold };
    _ = handleHotkeyEvent(&s, .clipboard_pressed);
    try std.testing.expectEqual(zhisper.overlay.State.recording, overlayStateFor(s.recording, false));
    try std.testing.expectEqual(zhisper.tray.State.recording, trayStateFor(s.recording, false, false));
}

test "the inject facade re-exports trailingCut for the clipboard branch" {
    // The clipboard path reuses the injection newline rule instead of
    // inventing a second one, so the two sinks cannot disagree.
    try std.testing.expectEqual(@as(usize, 1), zhisper.inject.trailingCut("hi\n", .strip));
    try std.testing.expectEqual(@as(usize, 0), zhisper.inject.trailingCut("hi\n", .send));
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
