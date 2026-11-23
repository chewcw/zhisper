const std = @import("std");

const zhisper = @import("zhisper");

const cli = @import("cli.zig");
const build_options = @import("build_options");

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

/// Mirrors modeFromString: config.zig validates the string against
/// notify_types.level_values, and this turns the validated string into the
/// enum the daemon branches on.
fn notifyLevelFromString(s: []const u8) !zhisper.notify.Level {
    if (std.mem.eql(u8, s, "off")) return .off;
    if (std.mem.eql(u8, s, "errors")) return .errors;
    if (std.mem.eql(u8, s, "clipboard")) return .clipboard;
    if (std.mem.eql(u8, s, "errors,clipboard")) return .all;
    return error.InvalidNotifyLevel;
}

fn legacyHotkeyKeysInUse(hotkey: zhisper.config.HotkeyCfg) [4]bool {
    return .{
        hotkey.shortcut.len == 0 and hotkey.key_code != null,
        hotkey.cancel.len == 0 and hotkey.cancel_key_code != null,
        hotkey.clipboard.len == 0 and hotkey.clipboard_key_code != null,
        hotkey.search.len == 0 and hotkey.search_key_code != null,
    };
}

fn clipboardBound(hotkeys: zhisper.config.Hotkeys) bool {
    const b = hotkeys.clipboard orelse return false;
    return switch (b) {
        .chord => true,
        .raw_code => |code| code != 0,
    };
}

fn findShortcutCollision(hotkey: zhisper.config.HotkeyCfg) ?struct { a: []const u8, b: []const u8 } {
    const hk = zhisper.config.resolveHotkeys(hotkey) catch return null;
    const pairs = [_]struct { name: []const u8, binding: ?zhisper.shortcut.Binding }{
        .{ .name = "shortcut", .binding = hk.shortcut },
        .{ .name = "cancel", .binding = hk.cancel },
        .{ .name = "clipboard", .binding = hk.clipboard },
        .{ .name = "search", .binding = hk.search },
    };
    for (pairs, 0..) |pa, i| {
        const ba = pa.binding orelse continue;
        for (pairs[i + 1 ..]) |pb| {
            const bb = pb.binding orelse continue;
            if (zhisper.shortcut.Binding.eql(ba, bb)) return .{ .a = pa.name, .b = pb.name };
        }
    }
    return null;
}

fn hotkeyStartupFailure(err: anyerror, hotkey: zhisper.config.HotkeyCfg) noreturn {
    switch (err) {
        error.InvalidShortcut => {
            if (zhisper.config.findShortcutProblem(hotkey)) |problem| {
                std.log.err(
                    "hotkey.{s} is not a valid shortcut ({s})",
                    .{ problem.field, @errorName(problem.err) },
                );
                std.log.err("{s}", .{shortcutHint()});
            } else {
                std.log.err("hotkey shortcut is invalid ({s})", .{@errorName(err)});
            }
        },
        error.ShortcutCollision => {
            if (findShortcutCollision(hotkey)) |pair| {
                std.log.err(
                    "hotkey.{s} and hotkey.{s} are the same binding",
                    .{ pair.a, pair.b },
                );
            } else {
                std.log.err("a bare function key and an old numeric key code may name the same key; give both actions shortcut strings", .{});
                std.log.err("hotkey bindings collide ({s})", .{@errorName(err)});
            }
        },
        else => std.log.err("hotkey setup failed: {s}", .{@errorName(err)}),
    }
    std.process.exit(1);
}

/// Printed when a shortcut string fails to parse. The parser's error name alone
/// ("MissingMetaModifier") does not tell the user that a function key may stand
/// alone, so the accepted shapes are spelled out here.
fn shortcutHint() []const u8 {
    return "a shortcut is a bare function key (f1-f24), or meta+key with optional shift, " ++
        "for example \"f9\" or \"meta+f9\"";
}

fn waitForModifiersReleased(io: std.Io, held: *const fn () bool, budget_ms: u64, step_ms: u64) bool {
    if (!held()) return true;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const budget_ns: i96 = @as(i96, @intCast(budget_ms)) * std.time.ns_per_ms;
    while (true) {
        io.sleep(.fromMilliseconds(@intCast(step_ms)), .awake) catch {};
        if (!held()) return true;
        const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
        if (elapsed.raw.nanoseconds >= budget_ns) return false;
    }
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

/// WHY the empty check: config.validate only requires base_url/model for
/// `custom`, because groq/openai/deepgram are meant to fall back to their
/// preset. Copying the raw values would send an empty request URL and model for
/// those three, so empty means "use the preset" here too - the same rule as
/// buildDeepgramConfig and transcribe.resolveConfig, which treat a null override
/// the same way.
fn buildTranscribeConfig(unified: zhisper.config.Config, api_key: []const u8) zhisper.transcribe.Config {
    const provider = zhisper.transcribe.providerFromName(unified.transcribe.provider);
    const preset = zhisper.transcribe.presetFor(provider);
    return .{
        .base_url = if (unified.transcribe.base_url.len == 0) preset.base_url else unified.transcribe.base_url,
        .model = if (unified.transcribe.model.len == 0) preset.model else unified.transcribe.model,
        .api_key = api_key,
        .prompt = unified.transcribe.prompt,
    };
}

fn buildDeepgramConfig(gpa: std.mem.Allocator, unified: zhisper.config.Config, api_key: []const u8) !zhisper.deepgram.Config {
    const model = if (unified.transcribe.model.len == 0)
        zhisper.deepgram.default_model
    else
        unified.transcribe.model;
    const rest_url = if (unified.transcribe.base_url.len == 0)
        zhisper.deepgram.default_rest_url
    else
        unified.transcribe.base_url;
    const stream_url = try zhisper.deepgram.streamUrlFor(gpa, rest_url);
    errdefer gpa.free(stream_url);
    const keyterms = try zhisper.deepgram.parseKeyterms(gpa, unified.transcribe.keyterm);
    return .{
        .rest_url = rest_url,
        .stream_url = stream_url,
        .model = model,
        .language = unified.transcribe.language,
        .keyterms = keyterms,
        .api_key = api_key,
    };
}

/// Built per recording, from the process-lifetime arena: the session keeps
/// these slices for as long as the stream lives.
fn startDeepgramSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: zhisper.config.Config) ?*zhisper.deepgram.Session {
    if (zhisper.transcribe.providerFromName(cfg.transcribe.provider) != .deepgram) return null;
    const key = resolveApiKey(.deepgram) orelse return null;
    const dc = buildDeepgramConfig(arena, cfg, key) catch |err| {
        std.log.scoped(.daemon).debug("deepgram config failed: {s}", .{@errorName(err)});
        return null;
    };
    return zhisper.deepgram.Session.start(io, gpa, dc) catch |err| {
        std.log.scoped(.daemon).debug("stream start failed: {s}", .{@errorName(err)});
        return null;
    };
}

fn firstKey(values: []const ?[]const u8) ?[]const u8 {
    for (values) |v| {
        const s = v orelse continue;
        if (s.len == 0) continue;
        return s;
    }
    return null;
}

/// Variables the normalizer tries, in order. A Deepgram or custom key must
/// never reach the normalizer, which posts to Groq or OpenAI.
const normalize_key_envs = [_][:0]const u8{ "GROQ_API_KEY", "OPENAI_API_KEY" };

fn resolveNormalizeKey() ?[]const u8 {
    var vals: [normalize_key_envs.len]?[]const u8 = undefined;
    for (normalize_key_envs, 0..) |name, i| {
        vals[i] = if (std.c.getenv(name.ptr)) |raw| blk: {
            const s = std.mem.span(raw);
            break :blk if (s.len == 0) null else s;
        } else null;
    }
    return firstKey(&vals);
}

fn transcribeBatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    wav_path: []const u8,
    t_cfg: zhisper.transcribe.Config,
    deepgram_cfg: ?zhisper.deepgram.Config,
) ![]u8 {
    if (deepgram_cfg) |d| return try zhisper.deepgram.transcribeRest(io, gpa, wav_path, d);
    return try zhisper.transcribe.transcribeWithConfig(io, gpa, wav_path, t_cfg);
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
    const raw = std.c.getenv(zhisper.transcribe.keyEnvName(provider).ptr) orelse return null;
    if (raw[0] == 0) return null;
    return std.mem.span(raw);
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
const Sink = enum { typing, clipboard, search };

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
        .search_pressed, .search_released => .search,
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
            .hotkey_pressed, .clipboard_pressed, .search_pressed => {
                if (s.recording) return .ignore;
                s.recording = true;
                s.sink = sinkFor(ev);
                return .start;
            },
            .hotkey_released, .clipboard_released, .search_released => {
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
            .hotkey_released, .clipboard_released, .search_released => return .ignore,
            .hotkey_pressed, .clipboard_pressed, .search_pressed => {
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

/// Owns every overlay side effect so the menu toggle and the startup path
/// cannot drift apart.
const OverlayCtl = struct {
    live: bool = false,
    pos_path: ?[]const u8 = null,
    displays: []zhisper.overlay_types.Display = &.{},
    state: zhisper.overlay.State = .idle,

    fn start(self: *OverlayCtl, io: std.Io, arena: std.mem.Allocator) void {
        if (self.live) return;
        zhisper.overlay.setup(.{}) catch |err| {
            std.log.scoped(.daemon).debug("overlay setup failed (headless): {s}", .{@errorName(err)});
            return;
        };
        zhisper.overlay.show() catch |err| {
            std.log.scoped(.daemon).debug("overlay show failed: {s}", .{@errorName(err)});
            zhisper.overlay.destroy();
            return;
        };
        self.live = true;
        self.pos_path = zhisper.overlay.overlayPosPath(arena) catch null;
        self.displays = zhisper.overlay.displayList(arena) catch &.{};
        if (self.pos_path) |pp| zhisper.overlay.move(zhisper.overlay.loadOverlayPos(io, arena, pp, self.displays));
    }

    fn stop(self: *OverlayCtl) void {
        if (!self.live) return;
        zhisper.overlay.destroy();
        self.live = false;
    }

    fn set(self: *OverlayCtl, io: std.Io, arena: std.mem.Allocator, enabled: bool) void {
        if (enabled) self.start(io, arena) else self.stop();
    }
};

const MenuCtx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg_path: []const u8,
    live: ?*zhisper.config_live.Live = null,
    loop_state: ?*LoopState = null,
    overlay: ?*OverlayCtl = null,
    cfg_signature: ?*?std.Io.File.Stat = null,
    notify_level: zhisper.notify.Level = .off,
    notify_live: bool = false,
};

fn menuSnapshot(ctx: *anyopaque) zhisper.config.Config {
    const self: *MenuCtx = @ptrCast(@alignCast(ctx));
    return self.live.?.get();
}

fn menuApply(ctx: *anyopaque, action: zhisper.tray.Action) void {
    const self: *MenuCtx = @ptrCast(@alignCast(ctx));
    applyMenuAction(self, action);
}

fn writeString(ctx: *MenuCtx, section: []const u8, key: []const u8, value: []const u8) bool {
    zhisper.config_edit.setKey(ctx.io, ctx.gpa, ctx.cfg_path, section, key, .{ .string = value }) catch |err| {
        reportConfigFailure(ctx, err);
        return false;
    };
    return true;
}

fn writeBool(ctx: *MenuCtx, section: []const u8, key: []const u8, value: bool) bool {
    zhisper.config_edit.setKey(ctx.io, ctx.gpa, ctx.cfg_path, section, key, .{ .boolean = value }) catch |err| {
        reportConfigFailure(ctx, err);
        return false;
    };
    return true;
}

fn reportConfigFailure(ctx: *MenuCtx, err: anyerror) void {
    std.log.scoped(.daemon).warn("config write failed: {s}", .{@errorName(err)});
    if (!ctx.notify_live) return;
    const kind = zhisper.notify.Kind.config_write_failed;
    if (!zhisper.notify.shouldNotify(ctx.notify_level, kind)) return;
    zhisper.notify.show(ctx.io, zhisper.notify_types.forEvent(kind, @errorName(err))) catch |e| {
        std.log.scoped(.daemon).debug("notification failed: {s}", .{@errorName(e)});
    };
}

fn refreshSignature(ctx: *MenuCtx) void {
    if (ctx.cfg_signature) |signature| signature.* = zhisper.config.fileSignature(ctx.io, ctx.cfg_path);
}

fn applyMenuAction(ctx: *MenuCtx, action: zhisper.tray.Action) void {
    const live = ctx.live orelse return;
    switch (action) {
        // Quit is not a setting: no file write is involved.
        .quit => {
            stop_requested.store(true, .monotonic);
            return;
        },
        .open_submenu, .back => return,
        .set_hotkey_mode => |mode| {
            const name = @tagName(mode);
            if (!writeString(ctx, "hotkey", "mode", name)) return;
            var next = live.get();
            next.hotkey.mode = name;
            live.replace(next) catch |err| return reportConfigFailure(ctx, err);
            if (ctx.loop_state) |ls| ls.mode = mode;
        },
        .set_normalize_enabled => |enabled| {
            if (!writeBool(ctx, "normalize", "enabled", enabled)) return;
            live.setNormalizeEnabled(enabled) catch |err| return reportConfigFailure(ctx, err);
        },
        .set_styling => |value| {
            if (!writeString(ctx, "normalize", "styling", value)) return;
            var next = live.get();
            next.normalize.styling = value;
            live.replace(next) catch |err| return reportConfigFailure(ctx, err);
        },
        .set_structure => |value| {
            if (!writeString(ctx, "normalize", "structure", value)) return;
            var next = live.get();
            next.normalize.structure = value;
            live.replace(next) catch |err| return reportConfigFailure(ctx, err);
        },
        .set_context => |value| {
            if (!writeString(ctx, "normalize", "context", value)) return;
            var next = live.get();
            next.normalize.context = value;
            live.replace(next) catch |err| return reportConfigFailure(ctx, err);
        },
        .set_provider => |name| {
            if (!writeString(ctx, "transcribe", "provider", name)) return;
            if (!writeString(ctx, "transcribe", "model", "")) return;
            if (!writeString(ctx, "transcribe", "base_url", "")) return;
            var next = live.get();
            next.transcribe.provider = name;
            next.transcribe.model = "";
            next.transcribe.base_url = "";
            live.replace(next) catch |err| return reportConfigFailure(ctx, err);
        },
        .set_overlay => |enabled| {
            if (!writeBool(ctx, "daemon", "overlay", enabled)) return;
            var next = live.get();
            next.daemon.overlay = enabled;
            live.replace(next) catch |err| return reportConfigFailure(ctx, err);
            if (ctx.overlay) |ovl| ovl.set(ctx.io, ctx.arena, enabled);
        },
    }
    refreshSignature(ctx);
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

/// The one place a notification is enqueued. `forEvent` is pure, so calling
/// this from either thread is safe; `show` is not, and lives in the loop only.
/// Never call this while holding `queue.mutex`, so lock order stays
/// one-directional.
fn report(
    io: std.Io,
    queue: *zhisper.notify.NotifyQueue,
    level: zhisper.notify.Level,
    kind: zhisper.notify.Kind,
    detail: []const u8,
) void {
    if (!zhisper.notify.shouldNotify(level, kind)) return;
    queue.push(io, zhisper.notify_types.forEvent(kind, detail));
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
    // Streaming session for the waiting clip, owned by the queue once enqueued.
    pending_session: ?*zhisper.deepgram.Session = null,
    // Set once by main on SIGINT/SIGTERM. Worker drains at most the active
    // plus one waiting job ("finish the sentence"), then exits.
    shutdown: bool = false,
};

fn workerMain(
    io: std.Io,
    gpa: std.mem.Allocator,
    session_gpa: std.mem.Allocator,
    live: *zhisper.config_live.Live,
    q: *WorkQueue,
    clipboard_state: zhisper.clipboard.Clipboard,
    trailing_newline: zhisper.inject.TrailingNewline,
    notify_queue: *zhisper.notify.NotifyQueue,
    notify_level: zhisper.notify.Level,
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
        const session = q.pending_session;
        q.pending_session = null;
        q.has_pending = false;
        q.active = true;
        q.mutex.unlock(io);
        defer {
            q.mutex.lockUncancelable(io);
            q.active = false;
            q.mutex.unlock(io);
        }
        const wav_path = path_buf[0..len];
        const cfg = live.get();
        const provider = zhisper.transcribe.providerFromName(cfg.transcribe.provider);
        const api_key = resolveApiKey(provider) orelse {
            report(io, notify_queue, notify_level, .transcribe_failed, "missing API key");
            if (session) |s| s.deinit(session_gpa);
            continue;
        };
        // A batch request is synchronous, so its config can live in an arena
        // that ends with the job.
        var job_arena = std.heap.ArenaAllocator.init(gpa);
        defer job_arena.deinit();
        var deepgram_cfg: ?zhisper.deepgram.Config = null;
        if (provider == .deepgram) {
            deepgram_cfg = buildDeepgramConfig(job_arena.allocator(), cfg, api_key) catch |err| {
                report(io, notify_queue, notify_level, .transcribe_failed, @errorName(err));
                if (session) |s| s.deinit(session_gpa);
                continue;
            };
        }
        const t_cfg = buildTranscribeConfig(cfg, api_key);
        const transcribe_log = std.log.scoped(.transcribe);
        // WHY two owners: a session transcript is freed by Session.deinit, while a
        // batch transcript is freed here. Freeing both would double-free the first.
        var from_session = false;
        var text: []const u8 = undefined;
        if (session) |s| {
            if (s.awaitTranscript(io)) |t| {
                text = t;
                from_session = true;
            } else |err| {
                transcribe_log.debug("stream failed ({s}), using batch endpoint", .{@errorName(err)});
            }
        }
        if (!from_session) {
            text = transcribeBatch(io, gpa, wav_path, t_cfg, deepgram_cfg) catch |err| {
                transcribe_log.debug("transcribe failed: {s}", .{@errorName(err)});
                report(io, notify_queue, notify_level, .transcribe_failed, @errorName(err));
                if (!cfg.daemon.keep_wav_on_error) std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
                if (session) |s| s.deinit(session_gpa);
                continue;
            };
        }
        defer if (!from_session) gpa.free(text);
        defer if (session) |s| s.deinit(session_gpa);
        // Normalization is best-effort and never blocks the dictation: every
        // failure path keeps the raw transcript. An empty raw transcript is
        // skipped entirely so silence does not cost a network round trip.
        var final_text = text;
        if (cfg.normalize.enabled and text.len > 0) {
            const normalize_log = std.log.scoped(.normalize);
            if (resolveNormalizeKey()) |n_key| {
                if (buildNormalizeConfig(cfg, n_key)) |n_cfg| {
                    if (zhisper.normalize.normalizeWithConfig(io, gpa, text, n_cfg)) |clean| {
                        final_text = clean;
                    } else |err| {
                        normalize_log.warn("normalize failed, using raw transcript: {s}", .{@errorName(err)});
                    }
                } else |err| {
                    normalize_log.warn("normalize config invalid, using raw transcript: {s}", .{@errorName(err)});
                }
            } else {
                normalize_log.warn("normalize config invalid, using raw transcript: {s}", .{@errorName(error.MissingApiKey)});
            }
        }
        const inject_log = std.log.scoped(.inject);
        // WHY: a held meta or shift turns the injected transcript into shell
        // shortcuts or uppercase text. Waiting is cheap; a corrupted sentence is not.
        // When the user keeps holding the chord, give up rather than drop the text.
        if (!waitForModifiersReleased(io, &zhisper.hotkey.modifiersHeld, 1500, 10)) {
            inject_log.debug("chord still held after 1500 ms, typing anyway", .{});
        }
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
                    report(io, notify_queue, notify_level, .empty_transcript, "");
                } else {
                    zhisper.clipboard.paste(payload, io, clipboard_state) catch |err| {
                        inject_log.debug("clipboard write failed: {s}", .{@errorName(err)});
                        report(io, notify_queue, notify_level, .clipboard_failed, "");
                    };
                    inject_log.debug("clipboard filled with {d} bytes", .{payload.len});
                    // Reported outside the catch arm: the catch does not
                    // return, so a success toast would otherwise land on top
                    // of the failure one.
                    report(io, notify_queue, notify_level, .clipboard_ready, payload);
                }
            },
            .search => {
                // Open the default browser on a web search for the transcript
                const query = std.mem.trim(u8, final_text, " \t\r\n");
                if (query.len == 0) {
                    inject_log.debug("empty transcript, no search launched", .{});
                    continue;
                }
                if (zhisper.browser.buildSearchUrl(gpa, cfg.search.base_url, query)) |url| {
                    defer gpa.free(url);
                    // Browser first: the visible result must not wait for a
                    // clipboard tool that may be slow or missing.
                    zhisper.browser.openUrl(io, gpa, url) catch |err| {
                        inject_log.debug("browser launch failed: {s}", .{@errorName(err)});
                        report(io, notify_queue, notify_level, .search_failed, @errorName(err));
                    };
                    // Best-effort, and deliberately outside the catch above:
                    // a failed launch still leaves the query available to
                    // paste by hand, and a failed copy must not hide that.
                    zhisper.clipboard.paste(query, io, clipboard_state) catch |err| {
                        inject_log.debug("clipboard write failed: {s}", .{@errorName(err)});
                    };
                } else |err| {
                    inject_log.debug("search url build failed: {s}", .{@errorName(err)});
                    report(io, notify_queue, notify_level, .search_failed, @errorName(err));
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

    if (overrides.version) {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        _ = w.interface.print("{s}\n", .{build_options.version}) catch {};
        _ = w.interface.flush() catch {};
        std.process.exit(0);
    }

    const cfg_path = if (overrides.config_path) |p| p else try resolveConfigPath(arena);
    const cfg = zhisper.config.load(arena, io, cfg_path, overrides) catch |err| {
        if (err == error.InvalidShortcut or err == error.ShortcutCollision) {
            var bad = zhisper.config.defaultConfig();
            if (zhisper.config.parseFileConfig(arena, io, cfg_path) catch null) |fc| bad = fc;
            bad = zhisper.config.applyEnv(bad, zhisper.config.readEnvValues());
            bad = zhisper.config.applyCli(bad, overrides);
            hotkeyStartupFailure(err, bad.hotkey);
        }
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
    zhisper.config.validate(cfg) catch |err| switch (err) {
        error.InvalidShortcut, error.ShortcutCollision => hotkeyStartupFailure(err, cfg.hotkey),
        else => {
            var errbuf: [256]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &errbuf);
            w.interface.print("zhisper: config error: {s}\n", .{@errorName(err)}) catch {};
            w.interface.flush() catch {};
            std.process.exit(1);
        },
    };
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
    var hotkeys = zhisper.config.resolveHotkeys(cfg.hotkey) catch |err| hotkeyStartupFailure(err, cfg.hotkey);

    const legacy = legacyHotkeyKeysInUse(cfg.hotkey);
    if (legacy[0]) daemon_log.warn("hotkey.key_code is deprecated, use hotkey.shortcut = \"f9\"", .{});
    if (legacy[1]) daemon_log.warn("hotkey.cancel_key_code is deprecated, use hotkey.cancel = \"meta+f8\"", .{});
    if (legacy[2]) daemon_log.warn("hotkey.clipboard_key_code is deprecated, use hotkey.clipboard = \"meta+f10\"", .{});
    if (legacy[3]) daemon_log.warn("hotkey.search_key_code is deprecated, use hotkey.search = \"off\"", .{});

    var clipboard_state: zhisper.clipboard.Clipboard = .{ .available = false, .tool = null };
    if (clipboardBound(hotkeys)) {
        clipboard_state = zhisper.clipboard.check(io);
        if (!clipboard_state.available) {
            const user_configured = !std.mem.eql(u8, cfg.hotkey.clipboard, zhisper.config.default_clipboard);
            const msg = "hotkey.clipboard is set but no clipboard tool found — clipboard capture disabled; set hotkey.clipboard = \"off\" to silence this";
            if (user_configured) daemon_log.err("{s}", .{msg}) else daemon_log.warn("{s}", .{msg});
            hotkeys.clipboard = null;
        }
    }

    zhisper.hotkey.setup(.{
        .shortcut = hotkeys.shortcut,
        .cancel = hotkeys.cancel,
        .clipboard = hotkeys.clipboard,
        .search = hotkeys.search,
        .mode = mode,
        .evdev = cfg.hotkey.evdev,
        .evdev_name = cfg.hotkey.evdev_name,
    }) catch |err| {
        if (err == error.ShortcutCollision or err == error.InvalidShortcut) {
            hotkeyStartupFailure(err, cfg.hotkey);
        }
        std.log.err("hotkey setup failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer zhisper.hotkey.destroy();

    // Overlay is best-effort: any failure degrades to hotkey-only. With
    // daemon.overlay = false the subsystem is never started, so there is
    // no SDL window, no display enumeration, and no overlay.pos read.
    var ovl = OverlayCtl{};
    if (cfg.daemon.overlay) ovl.start(io, arena) else daemon_log.debug("overlay disabled by config", .{});
    defer ovl.stop();
    // Animation clock base: pill frames use millis since daemon start
    // (monotonic .awake clock, same source as the recording timer below).
    const overlay_t0: std.Io.Clock.Timestamp = std.Io.Clock.Timestamp.now(io, .awake);

    const provider = zhisper.transcribe.providerFromName(cfg.transcribe.provider);
    if (resolveApiKey(provider) == null) {
        std.log.err("missing API key: set {s} (provider = {s})", .{
            zhisper.transcribe.keyEnvName(provider),
            cfg.transcribe.provider,
        });
        std.process.exit(1);
    }
    var live = try zhisper.config_live.Live.init(gpa, cfg);
    defer live.deinit();

    var tray_live = false;
    // These two callbacks run only from tray.poll inside the loop, by which
    // time live, loop_state, ovl and cfg_signature are all bound.
    var menu_ctx = MenuCtx{ .io = io, .gpa = gpa, .arena = arena, .cfg_path = cfg_path };
    const menu_host = zhisper.tray.MenuHost{ .ctx = &menu_ctx, .snapshotFn = menuSnapshot, .applyFn = menuApply };
    if (cfg.daemon.tray) {
        if (zhisper.tray.setup(io, menu_host)) |_| {
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

    // Probed after the tray so the Windows hint can talk about a tray that has
    // already been set up or reported failed: a Windows balloon hangs off the
    // tray icon, so `notify` is unavailable when `tray` is off.
    const notify_level = try notifyLevelFromString(cfg.daemon.notify);
    var notify_live = false;
    var notify_hint: ?[]const u8 = null;
    if (notify_level != .off) {
        const availability = zhisper.notify.check(io);
        notify_live = availability.available;
        notify_hint = availability.hint;
    }
    // One line, at startup, with the reason. A notification that silently never
    // arrives is the exact failure this feature exists to end.
    if (notify_level != .off and !notify_live) {
        daemon_log.warn("notify = {s} is set but {s}", .{
            cfg.daemon.notify,
            notify_hint orelse "no notification backend was found",
        });
    }

    // Shared by the worker thread and the poll loop. Both enqueue; only the
    // loop calls show.
    var notify_queue = zhisper.notify.NotifyQueue{};

    var queue = WorkQueue{};
    const worker = try std.Thread.spawn(.{}, workerMain, .{ io, arena, gpa, &live, &queue, clipboard_state, trailing_newline, &notify_queue, notify_level });

    // WHY: the config is loaded once, but `normalize.enabled` is the escape
    // hatch a user reaches for the moment normalization mangles their text.
    // It must be flippable without a restart. Only that one key is re-read —
    // see config.loadNormalizeEnabled for why a full reload would mislead.
    var cfg_signature: ?std.Io.File.Stat = zhisper.config.fileSignature(io, cfg_path);
    var cfg_checked_at = std.Io.Timestamp.now(io, .awake);
    const cfg_poll_interval_ns: i96 = 1_000_000_000; // once a second

    var loop_state = LoopState{ .mode = mode };
    menu_ctx.live = &live;
    menu_ctx.loop_state = &loop_state;
    menu_ctx.overlay = &ovl;
    menu_ctx.cfg_signature = &cfg_signature;
    menu_ctx.notify_level = notify_level;
    menu_ctx.notify_live = notify_live;
    var start_ts: std.Io.Clock.Timestamp = undefined;
    var have_start = false;
    var active_session: ?*zhisper.deepgram.Session = null;
    var wav_counter: u32 = 0;
    var b_shortcut: [32]u8 = undefined;
    var b_cancel: [32]u8 = undefined;
    var b_clipboard: [32]u8 = undefined;
    var b_search: [32]u8 = undefined;
    const shortcut_label = hotkeys.shortcut.format(&b_shortcut) catch "?";
    const cancel_label = hotkeys.cancel.format(&b_cancel) catch "?";
    const clipboard_label: []const u8 = if (hotkeys.clipboard) |b|
        (b.format(&b_clipboard) catch "?")
    else
        "off";
    const search_label: []const u8 = if (hotkeys.search) |b|
        (b.format(&b_search) catch "?")
    else
        "off";
    daemon_log.info("listening (mode={s}, key={s}, cancel={s}, search={s}, clipboard={s}, notify={s}{s})", .{
        cfg.hotkey.mode,
        shortcut_label,
        cancel_label,
        search_label,
        clipboard_label,
        cfg.daemon.notify,
        // `!` means "you asked for this and it is not available", so it must
        // not appear for `off` — that is a choice, not a failure.
        if (notify_level == .off or notify_live) "" else "!",
    });

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
                    live.setNormalizeEnabled(enabled) catch |err| {
                        daemon_log.warn("normalize snapshot update failed: {s}", .{@errorName(err)});
                    };
                    daemon_log.info("normalize.enabled = {}", .{enabled});
                } else |err| {
                    daemon_log.warn("config reload failed, keeping normalize.enabled: {s}", .{@errorName(err)});
                }
            }
        }
        if (tray_live) zhisper.tray.poll(io);
        if (notify_live) {
            var pending: [zhisper.notify.queue_capacity]zhisper.notify.Message = undefined;
            var pending_count: usize = 0;
            notify_queue.drain(io, &pending, &pending_count);
            for (pending[0..pending_count]) |msg| {
                // Best-effort: unlike the tray, a failed notification is not
                // worth degrading the daemon over.
                zhisper.notify.show(io, msg) catch |err| {
                    daemon_log.debug("notification failed: {s}", .{@errorName(err)});
                };
            }
        }
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
                    active_session = startDeepgramSession(io, gpa, arena, live.get());
                    zhisper.audio.setRecording(.start, "") catch |err| {
                        daemon_log.debug("record start failed: {s}", .{@errorName(err)});
                        if (active_session) |s| {
                            s.deinitNoWait(gpa);
                            active_session = null;
                        }
                        loop_state.recording = false;
                        have_start = false;
                    };
                },
                .cancel => {
                    daemon_log.info("cancelled recording", .{});
                    have_start = false;
                    if (active_session) |s| {
                        s.deinitNoWait(gpa);
                        active_session = null;
                    }
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
                        if (active_session) |s| {
                            s.deinitNoWait(gpa);
                            active_session = null;
                        }
                        continue;
                    };
                    if (active_session) |s| s.requestFinish();
                    const now_ts = std.Io.Clock.Timestamp.now(io, .awake);
                    const elapsed_ns: u64 = if (have_start) @intCast(start_ts.durationTo(now_ts).raw.nanoseconds) else 0;
                    have_start = false;
                    if (elapsed_ns < @as(u64, cfg.daemon.min_duration_ms) * 1_000_000) {
                        daemon_log.debug("discarded short press ({d}ns)", .{elapsed_ns});
                        report(io, &notify_queue, notify_level, .too_short, "");
                        if (active_session) |s| {
                            s.deinitNoWait(gpa);
                            active_session = null;
                        }
                        std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
                        continue;
                    }
                    const stat = std.Io.Dir.cwd().statFile(io, wav_path, .{}) catch {
                        if (active_session) |s| {
                            s.deinitNoWait(gpa);
                            active_session = null;
                        }
                        continue;
                    };
                    if (stat.size < 44 + minWavPayloadBytes(cfg.daemon.min_duration_ms)) {
                        daemon_log.debug("discarded quiet clip ({d} bytes)", .{stat.size});
                        report(io, &notify_queue, notify_level, .quiet_clip, "");
                        if (active_session) |s| {
                            s.deinitNoWait(gpa);
                            active_session = null;
                        }
                        std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
                        continue;
                    }
                    queue.mutex.lockUncancelable(io);
                    var old_session: ?*zhisper.deepgram.Session = null;
                    var old_len: usize = 0;
                    var old_buf: [512]u8 = undefined;
                    if (queue.has_pending) {
                        old_session = queue.pending_session;
                        queue.pending_session = null;
                        old_len = queue.pending_len;
                        @memcpy(old_buf[0..old_len], queue.pending_path[0..old_len]);
                        queue.has_pending = false;
                        queue.pending_len = 0;
                    }
                    queue.mutex.unlock(io);
                    if (old_len != 0) {
                        std.Io.Dir.cwd().deleteFile(io, old_buf[0..old_len]) catch {};
                        if (old_session) |s| s.deinitNoWait(gpa);
                        daemon_log.debug("worker busy, dropped oldest clip", .{});
                        report(io, &notify_queue, notify_level, .dropped_oldest, "");
                    }
                    queue.mutex.lockUncancelable(io);
                    const copy_len = @min(wav_path.len, queue.pending_path.len);
                    @memcpy(queue.pending_path[0..copy_len], wav_path[0..copy_len]);
                    queue.pending_len = copy_len;
                    queue.pending_sink = loop_state.sink;
                    queue.pending_session = active_session;
                    active_session = null;
                    queue.has_pending = true;
                    queue.mutex.unlock(io);
                },
            }
        } else {
            if (ovl.live) {
                if (zhisper.overlay.pollEvent()) |oev| {
                    switch (oev) {
                        .drag_start, .drag_moved => {},
                        .drag_end => |p| {
                            if (ovl.pos_path) |pp| {
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
        if (ovl.live) {
            // Pill animation frame (the backend throttles to 30fps and
            // guards clock jumps; negative deltas clamp to 0).
            const now_uptime = std.Io.Clock.Timestamp.now(io, .awake);
            const uptime_ns: u64 = @intCast(@max(0, overlay_t0.durationTo(now_uptime).raw.nanoseconds));
            zhisper.overlay.tick(uptime_ns / 1_000_000);
            queue.mutex.lockUncancelable(io);
            const pending = queue.has_pending;
            queue.mutex.unlock(io);
            const cur = overlayStateFor(loop_state.recording, pending);
            if (cur != ovl.state) {
                ovl.state = cur;
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
    if (active_session) |s| {
        s.deinitNoWait(gpa);
        active_session = null;
    }
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

test "buildTranscribeConfig falls back to the provider preset for empty url and model" {
    // The shipped config.example.toml leaves both empty, so this is the path
    // every groq/openai user takes.
    const groq = buildTranscribeConfig(.{
        .transcribe = .{ .provider = "groq", .model = "", .base_url = "" },
    }, "k123");
    try std.testing.expectEqualStrings(zhisper.transcribe.default_base_url, groq.base_url);
    try std.testing.expectEqualStrings("whisper-large-v3-turbo", groq.model);

    const openai = buildTranscribeConfig(.{
        .transcribe = .{ .provider = "openai", .model = "", .base_url = "" },
    }, "k123");
    try std.testing.expectEqualStrings("https://api.openai.com/v1/audio/transcriptions", openai.base_url);
    try std.testing.expectEqualStrings("whisper-1", openai.model);
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
    // exe root declares std_options with debug max level and that the gated
    // module is wired.
    // WHY our own decl and not `std.options.log_level`: that one falls back to
    // std's per-optimize-mode default when the test binary's root is not this
    // file, so it reads `.debug` only because Debug's default happens to be
    // `.debug` and turns `.info` under ReleaseSafe.
    try std.testing.expect(@hasDecl(@This(), "std_options"));
    try std.testing.expectEqual(std.log.Level.debug, std_options.log_level);
    @import("zhisper").log.setEnabled(false);
    try std.testing.expect(@import("zhisper").log.shouldLog(.err));
    try std.testing.expect(!@import("zhisper").log.shouldLog(.debug));
}

test "buildDeepgramConfig uses defaults for empty transcribe settings" {
    const gpa = std.testing.allocator;
    const cfg = try buildDeepgramConfig(gpa, .{ .transcribe = .{} }, "k");
    defer gpa.free(cfg.stream_url);
    defer gpa.free(cfg.keyterms);
    try std.testing.expectEqualStrings("https://api.deepgram.com/v1/listen", cfg.rest_url);
    try std.testing.expectEqualStrings("wss://api.deepgram.com/v1/listen", cfg.stream_url);
    try std.testing.expectEqualStrings("nova-3", cfg.model);
    try std.testing.expectEqualStrings("", cfg.language);
    try std.testing.expectEqual(@as(usize, 0), cfg.keyterms.len);
}

test "buildDeepgramConfig copies explicit values and derives stream URL" {
    const gpa = std.testing.allocator;
    const cfg = try buildDeepgramConfig(gpa, .{
        .transcribe = .{
            .model = "nova-3-general",
            .base_url = "https://eu.api.deepgram.com/v1/listen",
            .language = "zh",
            .keyterm = "a, b",
        },
    }, "k");
    defer gpa.free(cfg.stream_url);
    defer gpa.free(cfg.keyterms);
    try std.testing.expectEqualStrings("nova-3-general", cfg.model);
    try std.testing.expectEqualStrings("https://eu.api.deepgram.com/v1/listen", cfg.rest_url);
    try std.testing.expectEqualStrings("zh", cfg.language);
    try std.testing.expectEqualStrings("wss://eu.api.deepgram.com/v1/listen", cfg.stream_url);
    try std.testing.expectEqual(@as(usize, 2), cfg.keyterms.len);
    try std.testing.expectEqualStrings("a", cfg.keyterms[0]);
    try std.testing.expectEqualStrings("b", cfg.keyterms[1]);
}

test "firstKey returns first non-null non-empty value" {
    const values = [_]?[]const u8{ null, "", "k2", "k3" };
    try std.testing.expectEqualStrings("k2", firstKey(&values).?);
    const none = [_]?[]const u8{ null, "" };
    try std.testing.expect(firstKey(&none) == null);
}

test "normalizer key order is groq then openai" {
    try std.testing.expectEqual(@as(usize, 2), normalize_key_envs.len);
    try std.testing.expectEqualStrings("GROQ_API_KEY", normalize_key_envs[0]);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", normalize_key_envs[1]);
}

test "notifyLevelFromString maps every config value" {
    try std.testing.expectEqual(zhisper.notify.Level.off, try notifyLevelFromString("off"));
    try std.testing.expectEqual(zhisper.notify.Level.errors, try notifyLevelFromString("errors"));
    try std.testing.expectEqual(zhisper.notify.Level.clipboard, try notifyLevelFromString("clipboard"));
    try std.testing.expectEqual(zhisper.notify.Level.all, try notifyLevelFromString("errors,clipboard"));
    try std.testing.expectError(error.InvalidNotifyLevel, notifyLevelFromString("sometimes"));
}

test "every reported outcome passes the gate at the default level" {
    const level = zhisper.notify.Level.all;
    for (std.enums.values(zhisper.notify.Kind)) |kind| {
        try std.testing.expect(zhisper.notify.shouldNotify(level, kind));
    }
}

test "the errors level reports every failure but not the success" {
    for (std.enums.values(zhisper.notify.Kind)) |kind| {
        const expected = kind != zhisper.notify.Kind.clipboard_ready;
        try std.testing.expectEqual(expected, zhisper.notify.shouldNotify(.errors, kind));
    }
}

test "a live provider change reaches the per-job transcribe config" {
    const gpa = std.testing.allocator;
    var live = try zhisper.config_live.Live.init(gpa, zhisper.config.defaultConfig());
    defer live.deinit();
    var next = live.get();
    next.transcribe.provider = "openai";
    try live.replace(next);

    const t = buildTranscribeConfig(live.get(), "k");
    try std.testing.expectEqualStrings("https://api.openai.com/v1/audio/transcriptions", t.base_url);
    try std.testing.expectEqualStrings("whisper-1", t.model);
    try std.testing.expectEqualStrings("k", t.api_key);
}

test "legacy keys count as in use only when no string replaced them" {
    const cfg = zhisper.config.HotkeyCfg{ .shortcut = "", .key_code = 67, .cancel = "meta+c", .cancel_key_code = 46 };
    try std.testing.expectEqual([4]bool{ true, false, false, false }, legacyHotkeyKeysInUse(cfg));
}

test "legacy keys are not flagged for an empty config" {
    try std.testing.expectEqual([4]bool{ false, false, false, false }, legacyHotkeyKeysInUse(zhisper.config.HotkeyCfg{}));
}

test "clipboard capture is gated on the binding, not on a code" {
    // The gate must follow the binding: with a string binding there is no
    // integer to compare against zero, and a missed gate means the daemon
    // silently swallows a key bound to a clipboard tool that is not installed.
    var hotkeys = zhisper.config.Hotkeys{ .shortcut = .{ .raw_code = 67 }, .cancel = .{ .raw_code = 46 } };
    try std.testing.expect(!clipboardBound(hotkeys));
    hotkeys.clipboard = .{ .raw_code = 87 };
    try std.testing.expect(clipboardBound(hotkeys));
}

const HeldProbe = struct {
    var calls: usize = 0;
    var release_after: usize = 0;

    fn held() bool {
        calls += 1;
        return calls <= release_after;
    }
};

test "the wait returns as soon as the modifiers are up" {
    HeldProbe.calls = 0;
    HeldProbe.release_after = 2;
    try std.testing.expect(waitForModifiersReleased(std.testing.io, &HeldProbe.held, 1000, 1));
    try std.testing.expectEqual(@as(usize, 3), HeldProbe.calls);
}

test "the wait returns false when the budget runs out" {
    HeldProbe.calls = 0;
    HeldProbe.release_after = std.math.maxInt(usize);
    try std.testing.expect(!waitForModifiersReleased(std.testing.io, &HeldProbe.held, 20, 5));
}

test "the wait returns at once when nothing is held" {
    HeldProbe.calls = 0;
    HeldProbe.release_after = 0;
    try std.testing.expect(waitForModifiersReleased(std.testing.io, &HeldProbe.held, 1000, 5));
    try std.testing.expectEqual(@as(usize, 1), HeldProbe.calls);
}

test "the shortcut hint names a bare function key and a meta chord" {
    const hint = shortcutHint();
    try std.testing.expect(std.mem.indexOf(u8, hint, "f1-f24") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "\"f9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "\"meta+f9\"") != null);
    // The old wording said meta was required, which a bare f9 now contradicts.
    try std.testing.expect(std.mem.indexOf(u8, hint, "meta is required") == null);
}
