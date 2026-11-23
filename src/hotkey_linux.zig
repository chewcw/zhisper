const std = @import("std");
const posix = std.posix;
const types = @import("hotkey_types.zig");
const shortcut = @import("shortcut.zig");

pub const KeyEvent = types.KeyEvent;
pub const Mode = types.Mode;
pub const HotkeyConfig = types.HotkeyConfig;

const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("linux/input.h");
    @cInclude("sys/ioctl.h");
});

var fd_evdev: posix.fd_t = -1;
var active_cfg: HotkeyConfig = .{ .shortcut = .{ .raw_code = 0 }, .cancel = .{ .raw_code = 0 } };

// src/hotkey_linux.zig — KEY_A..KEY_Z are not contiguous, so the table is written out.
const letters = [26]u16{ 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44 };
const fkeys = [24]u16{ 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194 };
// KEY_1..KEY_9 ascend to KEY_0, which sits last at 11.
const digit_base = 2;
// Modifier codes the chord state machine has to follow.
const KEY_LEFTMETA_C = 125;
const KEY_RIGHTMETA_C = 126;
const KEY_LEFTSHIFT_C = 42;
const KEY_RIGHTSHIFT_C = 54;

const meta_bit: u16 = 1 << 0;
const shift_bit: u16 = 1 << 1;

var held: std.atomic.Value(u16) = .init(0);
const Latched = enum { shortcut, clipboard, search };

// WHY one latched slot instead of a slot per binding: pressing a second
// binding while one is held would otherwise report two presses with no
// matching release, and main.zig would think two recordings are live.
var latched: ?Latched = null;
var chord_key_down = [_]bool{ false, false, false };
// Cancel is press-only and has no release event, so it cannot share the
// Latched slot. Its own state re-arms on cancel-key release or on release
// of a required modifier while the cancel key is still held.
var cancel_key_down = false;
var cancel_emitted = false;
var pending_event: ?KeyEvent = null;

fn bindingForLatched(kind: Latched) shortcut.Binding {
    return switch (kind) {
        .shortcut => active_cfg.shortcut,
        .clipboard => active_cfg.clipboard orelse .{ .raw_code = 0 },
        .search => active_cfg.search orelse .{ .raw_code = 0 },
    };
}

fn pressedEvent(kind: Latched) KeyEvent {
    return switch (kind) {
        .shortcut => .hotkey_pressed,
        .clipboard => .clipboard_pressed,
        .search => .search_pressed,
    };
}

fn releasedEvent(kind: Latched) KeyEvent {
    return switch (kind) {
        .shortcut => .hotkey_released,
        .clipboard => .clipboard_released,
        .search => .search_released,
    };
}

fn chordOf(b: shortcut.Binding) ?shortcut.Shortcut {
    return switch (b) {
        .chord => |ch| ch,
        .raw_code => null,
    };
}

fn chordModifiersSatisfied(ch: shortcut.Shortcut) bool {
    const h = held.load(.acquire);
    if (ch.modifiers.meta and (h & meta_bit) == 0) return false;
    if (ch.modifiers.shift and (h & shift_bit) == 0) return false;
    return true;
}

fn isModifierCode(code: u16) bool {
    return code == KEY_LEFTMETA_C or code == KEY_RIGHTMETA_C or code == KEY_LEFTSHIFT_C or code == KEY_RIGHTSHIFT_C;
}

fn modifierBit(code: u16) ?u16 {
    if (code == KEY_LEFTMETA_C or code == KEY_RIGHTMETA_C) return meta_bit;
    if (code == KEY_LEFTSHIFT_C or code == KEY_RIGHTSHIFT_C) return shift_bit;
    return null;
}

fn chordRequiresModifier(ch: shortcut.Shortcut, bit: u16) bool {
    return (bit == meta_bit and ch.modifiers.meta) or (bit == shift_bit and ch.modifiers.shift);
}

fn latchedRequiresModifier(kind: Latched, bit: u16) bool {
    const ch = chordOf(bindingForLatched(kind)) orelse return false;
    return chordRequiresModifier(ch, bit);
}

fn cancelChord() ?shortcut.Shortcut {
    return chordOf(active_cfg.cancel);
}

fn cancelChordRequiresModifier(bit: u16) bool {
    const ch = cancelChord() orelse return false;
    return chordRequiresModifier(ch, bit);
}

fn nativeCode(name: shortcut.KeyName) ?u16 {
    const idx = @intFromEnum(name);
    const a_idx = @intFromEnum(shortcut.KeyName.a);
    const z_idx = @intFromEnum(shortcut.KeyName.z);
    if (idx >= a_idx and idx <= z_idx) {
        return letters[idx - a_idx];
    }
    const d0_idx = @intFromEnum(shortcut.KeyName.d0);
    const d9_idx = @intFromEnum(shortcut.KeyName.d9);
    if (idx >= d0_idx and idx <= d9_idx) {
        const n: u16 = @intCast(idx - d0_idx);
        if (n == 0) return 11;
        return digit_base + n - 1;
    }
    const f1_idx = @intFromEnum(shortcut.KeyName.f1);
    const f24_idx = @intFromEnum(shortcut.KeyName.f24);
    if (idx >= f1_idx and idx <= f24_idx) {
        return fkeys[idx - f1_idx];
    }
    return switch (name) {
        .space => 57,
        .enter => 28,
        .tab => 15,
        .esc => 1,
        .backspace => 14,
        .delete => 111,
        .insert => 110,
        .home => 102,
        .end => 107,
        .pageup => 104,
        .pagedown => 109,
        .left => 105,
        .right => 106,
        .up => 103,
        .down => 108,
        .minus => 12,
        .equal => 13,
        .comma => 51,
        .period => 52,
        .slash => 53,
        .backslash => 43,
        .semicolon => 39,
        .quote => 40,
        .bracketleft => 26,
        .bracketright => 27,
        .grave => 41,
        else => null,
    };
}

fn closeFd(fd: posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

fn pickEvdevPath(config_evdev: []const u8) ?[]const u8 {
    if (config_evdev.len > 0) return config_evdev;
    if (std.c.getenv("ZHISPER_EVDEV")) |raw| {
        const path = std.mem.span(raw);
        if (path.len > 0) return path;
    }
    return null;
}

fn pickEvdevName(config_name: []const u8) ?[]const u8 {
    if (config_name.len > 0) return config_name;
    if (std.c.getenv("ZHISPER_EVDEV_NAME")) |raw| {
        const name = std.mem.span(raw);
        if (name.len > 0) return name;
    }
    return null;
}

/// Reads /sys/class/input/eventN/device/name into out, trimmed.
/// Returns null when the device does not exist or cannot be read.
fn eventDeviceName(event_idx: u32, out: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const sys_path = std.fmt.bufPrint(&path_buf, "/sys/class/input/event{d}/device/name", .{event_idx}) catch return null;
    const fd = posix.openat(posix.AT.FDCWD, sys_path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer closeFd(fd);
    const n = std.os.linux.read(fd, out.ptr, out.len);
    if (n == 0 or n > out.len) return null;
    return std.mem.trim(u8, out[0..n], " \t\r\n\x00");
}

/// WHY this exists: /dev/input/event0, event1, ... are numbered randomly —
/// event0 might be your mouse, a power button, or a webcam. We cannot guess.
/// So we ask every candidate device "which keys can you press?" and only
/// keep the one that answers like a keyboard. That question IS this ioctl:
/// it fills buf with one bit per key code (bit N set = key N supported).
/// We ask for 96 bytes because key codes go up to 0x2ff, i.e. 768 bits.
///
/// WHY the number is computed: an ioctl request number packs four things
/// into one u32 — direction (_IOR = data flows from kernel to us), a magic
/// letter ('E', registered for linux/input.h), a sequence number
/// (0x20 + event type), and the buffer length. Computing it here instead of
/// hardcoding keeps it correct if the buffer size ever changes.
/// Registry and encoding documented at:
/// https://www.kernel.org/doc/html/latest/userspace-api/ioctl/ioctl-number.html
/// The same mask can also be read from sysfs at
/// class/input/event*/device/capabilities/; see:
/// https://www.kernel.org/doc/html/latest/input/event-codes.html
fn eviocgbit(fd: posix.fd_t, ev: u32, buf: []u8) !void {
    // WHY libc ioctl instead of std.os.linux.ioctl: the raw syscall returns
    // whatever the kernel returns (0 or a positive byte count on success),
    // while libc normalizes failure to exactly -1 with errno set — the same
    // pattern the existing ioctlInt/ioctlPtr/ioctlNoArg helpers in
    // src/linux.zig already use. Checking `rc != 0` on the raw return would
    // misread a positive success count as failure.
    const req: c_ulong = (@as(c_ulong, 2) << 30) | (@as(c_ulong, 0x45) << 8) | (0x20 + ev) | (@as(c_ulong, @intCast(buf.len)) << 16);
    if (c.ioctl(fd, req, buf.ptr) == -1) {
        const err: posix.E = @enumFromInt(std.c._errno().*);
        return posix.unexpectedErrno(err);
    }
}

fn hasKeyboardKeys(fd: posix.fd_t) bool {
    var bits: [96]u8 = [_]u8{0} ** 96;
    eviocgbit(fd, c.EV_KEY, &bits) catch return false;
    // WHY only four keys: checking every key would work too, but any real
    // keyboard has A, Q, SPACE and ENTER, while mice/power-buttons have none
    // of them. Four checks are enough to tell them apart, so we stop here.
    for ([_]u16{ c.KEY_A, c.KEY_Q, c.KEY_SPACE, c.KEY_ENTER }) |code| {
        const by: usize = @intCast(code / 8);
        const bi: u3 = @intCast(code % 8);
        // Parens are load-bearing: without them `&` vs `==` precedence could
        // misread this as masking with a boolean.
        if (by >= bits.len or (bits[by] & (@as(u8, 1) << bi)) == 0) return false;
    }
    return true;
}

fn openPath(path: []const u8) !?posix.fd_t {
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch |e| return switch (e) {
        error.FileNotFound, error.NoDevice, error.NotDir => null,
        else => e, // error.AccessDenied and the rest propagate to the caller
    };
    if (hasKeyboardKeys(fd)) return fd;
    closeFd(fd);
    return null;
}

pub fn setup(config: HotkeyConfig) !void {
    destroy();
    const log = std.log.scoped(.hotkey);
    // Priority 1: explicit event path (config evdev or ZHISPER_EVDEV).
    if (pickEvdevPath(config.evdev)) |path| {
        if (try openPath(path)) |fd| {
            fd_evdev = fd;
            active_cfg = config;
            var b_shortcut: [32]u8 = undefined;
            var b_cancel: [32]u8 = undefined;
            const key_label = config.shortcut.format(&b_shortcut) catch "?";
            const cancel_label = config.cancel.format(&b_cancel) catch "?";
            log.info("using explicit evdev {s} (key={s}, cancel={s})", .{ path, key_label, cancel_label });
            return;
        }
        return error.DeviceNotFound;
    }
    // Priority 2: logical device name (config evdev_name or
    // ZHISPER_EVDEV_NAME), e.g. "kanata". Event numbers move across
    // reboots; names don't. Fails loudly instead of silently listening
    // to the wrong keyboard.
    if (pickEvdevName(config.evdev_name)) |want| {
        var i: u32 = 0;
        var name_buf: [32]u8 = undefined;
        var devname_buf: [256]u8 = undefined;
        while (i < 32) : (i += 1) {
            const got = eventDeviceName(i, &devname_buf) orelse continue;
            if (!std.mem.eql(u8, got, want)) continue;
            const path = try std.fmt.bufPrint(&name_buf, "/dev/input/event{d}", .{i});
            if (try openPath(path)) |fd| {
                fd_evdev = fd;
                active_cfg = config;
                var b_shortcut: [32]u8 = undefined;
                var b_cancel: [32]u8 = undefined;
                const key_label = config.shortcut.format(&b_shortcut) catch "?";
                const cancel_label = config.cancel.format(&b_cancel) catch "?";
                log.info("name match '{s}' -> {s} (key={s}, cancel={s})", .{ want, path, key_label, cancel_label });
                return;
            }
        }
        log.err("no device named '{s}' found", .{want});
        return error.DeviceNotFound;
    }
    var i: u32 = 0;
    var name_buf: [32]u8 = undefined;
    // WHY scan event0..31: the kernel hands out these numbers in plug-in
    // order, so "the keyboard" is a different number on every machine and
    // can change between boots. Trying each one and keeping the first that
    // looks like a keyboard is the standard userspace approach (this is what
    // tools like evtest do when listing devices).
    while (i < 32) : (i += 1) {
        const path = try std.fmt.bufPrint(&name_buf, "/dev/input/event{d}", .{i});
        if (try openPath(path)) |fd| {
            fd_evdev = fd;
            active_cfg = config;
            var b_shortcut: [32]u8 = undefined;
            var b_cancel: [32]u8 = undefined;
            const key_label = config.shortcut.format(&b_shortcut) catch "?";
            const cancel_label = config.cancel.format(&b_cancel) catch "?";
            log.info("auto-scan picked {s} (key={s}, cancel={s})", .{ path, key_label, cancel_label });
            return;
        }
    }
    return error.DeviceNotFound;
}

pub fn pollEvent() ?KeyEvent {
    if (fd_evdev < 0) return null;
    // const log = std.log.scoped(.hotkey);
    // struct input_event layout {timeval time; u16 type; u16 code; s32 value}
    // and value meanings (0 = release, 1 = press, 2 = autorepeat) per:
    // https://www.kernel.org/doc/html/latest/input/input.html (section 1.5)
    var ev: c.struct_input_event = undefined;
    const bytes = std.mem.asBytes(&ev);
    outer: while (true) {
        if (pending_event) |pe| {
            pending_event = null;
            return pe;
        }
        const n = std.os.linux.read(fd_evdev, bytes.ptr, bytes.len);
        if (n != bytes.len) return null; // EAGAIN on empty nonblocking fd
        if (ev.type != c.EV_KEY) continue;
        // log.debug("ev code={d} value={d}", .{ ev.code, ev.value });

        // 1) Modifier bookkeeping: value 1 sets, 0 clears, 2 ignored.
        if (modifierBit(@intCast(ev.code))) |bit| {
            if (ev.value == 1) {
                _ = held.fetchOr(bit, .acq_rel);
                var cancel_fire = false;
                if (cancel_key_down) {
                    if (cancelChord()) |ch| {
                        if (!cancel_emitted and chordModifiersSatisfied(ch)) {
                            cancel_emitted = true;
                            cancel_fire = true;
                        }
                    }
                }
                var chord_fire: ?Latched = null;
                if (latched == null) {
                    const candidates = [_]Latched{ .shortcut, .clipboard, .search };
                    for (candidates) |kind| {
                        if (!chord_key_down[@intFromEnum(kind)]) continue;
                        const ch = chordOf(bindingForLatched(kind)) orelse continue;
                        if (!chordModifiersSatisfied(ch)) continue;
                        latched = kind;
                        chord_fire = kind;
                        break;
                    }
                }
                if (cancel_fire and chord_fire != null) {
                    pending_event = pressedEvent(chord_fire.?);
                    return .cancel_pressed;
                }
                if (cancel_fire) return .cancel_pressed;
                if (chord_fire) |kind| return pressedEvent(kind);
            } else if (ev.value == 0) {
                _ = held.fetchAnd(~bit, .acq_rel);
                if (cancel_key_down and cancelChordRequiresModifier(bit)) {
                    cancel_emitted = false;
                }
                // 2) Modifier up: release latched chord if it required this modifier.
                if (latched) |kind| {
                    if (latchedRequiresModifier(kind, bit)) {
                        latched = null;
                        return releasedEvent(kind);
                    }
                }
            }
            // Autorepeat on modifier: ignored.
            continue;
        }

        // Cancel chord: press-only, fires even while another binding is latched.
        if (cancelChord()) |ch| {
            if (nativeCode(ch.key)) |key_code| {
                if (ev.code == key_code) {
                    if (ev.value == 1) {
                        cancel_key_down = true;
                        if (!cancel_emitted and chordModifiersSatisfied(ch)) {
                            cancel_emitted = true;
                            return .cancel_pressed;
                        }
                        continue :outer;
                    }
                    if (ev.value == 0) {
                        cancel_key_down = false;
                        cancel_emitted = false;
                        continue :outer;
                    }
                    // autorepeat: swallow
                    continue :outer;
                }
            }
        }

        // 3) Chord bindings for record / clipboard / search.
        const candidates = [_]Latched{ .shortcut, .clipboard, .search };
        for (candidates) |kind| {
            const b = bindingForLatched(kind);
            const ch = chordOf(b) orelse continue;
            const key_code = nativeCode(ch.key) orelse continue;
            if (ev.code != key_code) continue;

            if (ev.value == 1) {
                chord_key_down[@intFromEnum(kind)] = true;
                if (latched != null) continue :outer; // another binding already latched
                if (!chordModifiersSatisfied(ch)) continue :outer;
                latched = kind;
                return pressedEvent(kind);
            }
            if (ev.value == 0) {
                chord_key_down[@intFromEnum(kind)] = false;
                if (latched == kind) {
                    latched = null;
                    return releasedEvent(kind);
                }
                continue :outer;
            }
            // autorepeat: swallow
            continue :outer;
        }

        // 5) Raw-code bindings keep today's behaviour exactly.
        // Hotkey first so a misconfigured cancel == hotkey degrades to hotkey.
        if (types.rawCode(active_cfg.shortcut)) |hk| {
            if (ev.code == hk) {
                if (ev.value == 1) return .hotkey_pressed;
                if (ev.value == 0) return .hotkey_released;
                continue; // value == 2 is auto-repeat: ignore.
            }
        }
        if (active_cfg.clipboard) |b| {
            if (types.rawCode(b)) |code| {
                if (ev.code == code) {
                    if (ev.value == 1) return .clipboard_pressed;
                    if (ev.value == 0) return .clipboard_released;
                    continue; // value == 2 is auto-repeat: ignore.
                }
            }
        }
        if (types.rawCode(active_cfg.cancel)) |code| {
            if (ev.code == code) {
                if (ev.value == 1) return .cancel_pressed;
                continue; // cancel release + autorepeat swallowed.
            }
        }
        if (active_cfg.search) |b| {
            if (types.rawCode(b)) |code| {
                if (ev.code == code) {
                    if (ev.value == 1) return .search_pressed;
                    if (ev.value == 0) return .search_released;
                    continue; // value == 2 is auto-repeat: ignore.
                }
            }
        }
    }
}

pub fn modifiersHeld() bool {
    return (held.load(.acquire) & (meta_bit | shift_bit)) != 0;
}

pub fn destroy() void {
    if (fd_evdev < 0) return;
    closeFd(fd_evdev);
    fd_evdev = -1;
    held.store(0, .release);
    latched = null;
    chord_key_down = [_]bool{ false, false, false };
    cancel_key_down = false;
    cancel_emitted = false;
    pending_event = null;
}

fn setFdForTest(fd: posix.fd_t, config: HotkeyConfig) void {
    // Do not close the previous fd here: tests own their pipe fds and may
    // have already closed them, so closing a stale fd number can hit a reused fd.
    fd_evdev = fd;
    active_cfg = config;
    held.store(0, .release);
    latched = null;
    chord_key_down = [_]bool{ false, false, false };
    cancel_key_down = false;
    cancel_emitted = false;
    pending_event = null;
}

fn writeTestEvent(fd: posix.fd_t, ev_type: u16, code: u16, value: i32) !void {
    // WHY raw os.linux.write in a loop: std.posix.write does not exist in
    // Zig 0.16; this mirrors the write loop style already used by emitKey.
    // Writes under PIPE_BUF are atomic, so one loop pass normally suffices.
    var ev: c.struct_input_event = std.mem.zeroes(c.struct_input_event);
    ev.type = ev_type;
    ev.code = code;
    ev.value = value;
    const bytes = std.mem.asBytes(&ev);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.os.linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (n != bytes.len - off) return error.ShortWrite;
        off += n;
    }
}

test "pollEvent decodes press, skips repeat, decodes release" {
    // WHY pipe2 + NONBLOCK: std.posix.pipe does not exist in Zig 0.16, and a
    // blocking pipe would hang the final null-check forever (no writer left).
    // Nonblocking read returns EAGAIN instead, exactly like an idle evdev fd.
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .mode = .hold });
    try writeTestEvent(fds[1], c.EV_KEY, 31, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 30, 2);
    try writeTestEvent(fds[1], c.EV_KEY, 30, 1);
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 30, 0);
    try std.testing.expectEqual(KeyEvent.hotkey_released, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
}

test "pollEvent decodes cancel press, swallows cancel release and repeat" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .mode = .hold });
    // unrelated code skipped
    try writeTestEvent(fds[1], c.EV_KEY, 31, 1);
    // cancel autorepeat swallowed
    try writeTestEvent(fds[1], c.EV_KEY, 46, 2);
    // cancel press decodes
    try writeTestEvent(fds[1], c.EV_KEY, 46, 1);
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
    // cancel release swallowed -> null (nonblocking empty pipe)
    try writeTestEvent(fds[1], c.EV_KEY, 46, 0);
    try std.testing.expect(pollEvent() == null);
}

test "cancel disabled with 0 never fires" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 0 }, .mode = .hold });
    try writeTestEvent(fds[1], c.EV_KEY, 46, 1);
    try std.testing.expect(pollEvent() == null);
}

test "pollEvent without setup returns null" {
    const saved_fd = fd_evdev;
    fd_evdev = -1;
    defer fd_evdev = saved_fd;
    try std.testing.expect(pollEvent() == null);
}

test "setup prefers config evdev over auto-scan" {
    // Config-provided path wins when set; tested via the pure picker below.
    // Full device open needs /dev/input permissions, so this test only
    // checks the picker, never touches hardware.
    try std.testing.expectEqualStrings("/dev/input/event5", pickEvdevPath("/dev/input/event5").?);
    try std.testing.expect(pickEvdevPath("") == null);
}

test "name picker prefers config over env default" {
    // Pure picker, no hardware: config value wins when set.
    try std.testing.expectEqualStrings("kanata", pickEvdevName("kanata").?);
    // Empty config falls through to env or null; never touches hardware.
    // (When ZHISPER_EVDEV_NAME is unset this is null; when set, that value.)
    _ = pickEvdevName("");
}

test "eventDeviceName reads sysfs or skips without input subsystem" {
    var buf: [256]u8 = undefined;
    const got = eventDeviceName(0, &buf) orelse return error.SkipZigTest;
    try std.testing.expect(got.len > 0);
}

test "pollEvent decodes clipboard press and release" {
    // WHY pipe2 + NONBLOCK: std.posix.pipe does not exist in Zig 0.16, and a
    // blocking pipe would hang the final null-check forever (no writer left).
    // Nonblocking read returns EAGAIN instead, exactly like an idle evdev fd.
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .clipboard = .{ .raw_code = 87 }, .mode = .hold });
    try writeTestEvent(fds[1], c.EV_KEY, 87, 1);
    try std.testing.expectEqual(KeyEvent.clipboard_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 87, 0);
    try std.testing.expectEqual(KeyEvent.clipboard_released, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
}

test "pollEvent swallows clipboard autorepeat" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .clipboard = .{ .raw_code = 87 }, .mode = .hold });
    // value 2 is auto-repeat: a held key must not re-report presses.
    try writeTestEvent(fds[1], c.EV_KEY, 87, 2);
    try std.testing.expect(pollEvent() == null);
}

test "a clipboard key of 0 never fires" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .clipboard = null, .mode = .hold });
    try writeTestEvent(fds[1], c.EV_KEY, 87, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 87, 0);
    try std.testing.expect(pollEvent() == null);
}

test "pollEvent decodes search press and release" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .search = .{ .raw_code = 65 }, .mode = .hold });
    try writeTestEvent(fds[1], c.EV_KEY, 65, 1);
    try std.testing.expectEqual(KeyEvent.search_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 65, 2);
    try std.testing.expect(pollEvent() == null); // autorepeat swallowed
    try writeTestEvent(fds[1], c.EV_KEY, 65, 0);
    try std.testing.expectEqual(KeyEvent.search_released, pollEvent().?);
    try std.testing.expect(pollEvent() == null);
}

test "search key of 0 never fires" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    const saved_fd = fd_evdev;
    const saved_cfg = active_cfg;
    defer {
        fd_evdev = saved_fd;
        active_cfg = saved_cfg;
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 }, .search = null, .mode = .hold });
    try writeTestEvent(fds[1], c.EV_KEY, 65, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 65, 0);
    try std.testing.expect(pollEvent() == null);
}

test "nativeCode maps every portable key name to its evdev code" {
    try std.testing.expectEqual(@as(?u16, 30), nativeCode(.a));
    try std.testing.expectEqual(@as(?u16, 44), nativeCode(.z));
    try std.testing.expectEqual(@as(?u16, 11), nativeCode(.d0));
    try std.testing.expectEqual(@as(?u16, 2), nativeCode(.d1));
    try std.testing.expectEqual(@as(?u16, 59), nativeCode(.f1));
    try std.testing.expectEqual(@as(?u16, 68), nativeCode(.f10));
    try std.testing.expectEqual(@as(?u16, 87), nativeCode(.f11));
    try std.testing.expectEqual(@as(?u16, 88), nativeCode(.f12));
    try std.testing.expectEqual(@as(?u16, 183), nativeCode(.f13));
    try std.testing.expectEqual(@as(?u16, 194), nativeCode(.f24));
    try std.testing.expectEqual(@as(?u16, 57), nativeCode(.space));
    try std.testing.expectEqual(@as(?u16, 28), nativeCode(.enter));
    try std.testing.expectEqual(@as(?u16, 1), nativeCode(.esc));
    try std.testing.expectEqual(@as(?u16, 111), nativeCode(.delete));
    try std.testing.expectEqual(@as(?u16, 41), nativeCode(.grave));
}

test "a meta chord fires only while meta is held" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .chord = try sc.parse("meta+8") },
        .cancel = .{ .raw_code = 46 },
    });
    // The key alone must stay silent: the modifier is part of the binding.
    try writeTestEvent(fds[1], c.EV_KEY, 9, 1);
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 9, 0);
    try std.testing.expect(pollEvent() == null);
    // meta down, then the key: this is the chord.
    try writeTestEvent(fds[1], c.EV_KEY, 125, 1);
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 9, 1);
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    // Releasing meta alone ends the chord, without waiting for the key.
    try writeTestEvent(fds[1], c.EV_KEY, 125, 0);
    try std.testing.expectEqual(KeyEvent.hotkey_released, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 9, 0);
    try std.testing.expect(pollEvent() == null);
}

test "a chord registers whichever key goes down first" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .chord = try sc.parse("meta+f2") },
        .cancel = .{ .raw_code = 46 },
    });
    try writeTestEvent(fds[1], c.EV_KEY, 60, 1); // key first
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 126, 1); // right meta second
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 60, 0); // key up first
    try std.testing.expectEqual(KeyEvent.hotkey_released, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 126, 0);
    try std.testing.expect(pollEvent() == null);
}

test "a meta+shift chord needs shift too, and swallows its autorepeat" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .chord = try sc.parse("meta+shift+z") },
        .cancel = .{ .raw_code = 46 },
    });
    try writeTestEvent(fds[1], c.EV_KEY, 125, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 44, 1); // z without shift: no chord
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 42, 1); // left shift: chord forms
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 44, 2); // key autorepeat: silent
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 42, 0); // shift up ends it
    try std.testing.expectEqual(KeyEvent.hotkey_released, pollEvent().?);
}

test "modifiersHeld tracks meta and shift and ignores repeats" {
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 } });
    try std.testing.expect(!modifiersHeld());
    try writeTestEvent(fds[1], c.EV_KEY, 54, 1); // right shift
    _ = pollEvent();
    try std.testing.expect(modifiersHeld());
    try writeTestEvent(fds[1], c.EV_KEY, 54, 2); // autorepeat must not double count
    _ = pollEvent();
    try writeTestEvent(fds[1], c.EV_KEY, 54, 0);
    _ = pollEvent();
    try std.testing.expect(!modifiersHeld());
}

test "a chord cancel fires after meta then key" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .raw_code = 30 },
        .cancel = .{ .chord = try sc.parse("meta+f8") },
    });
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 1);
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 1); // F8
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
}

test "a chord cancel fires after key then meta" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .raw_code = 30 },
        .cancel = .{ .chord = try sc.parse("meta+f8") },
    });
    try writeTestEvent(fds[1], c.EV_KEY, 66, 1); // F8 first
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 1); // meta second
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
}

test "a chord cancel does not re-fire on autorepeat, and fires again after release and re-press" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .raw_code = 30 },
        .cancel = .{ .chord = try sc.parse("meta+f8") },
    });
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 1);
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 2); // autorepeat
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 0); // release
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 1); // re-press
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
}

test "a chord cancel fires while a record chord is latched" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .chord = try sc.parse("meta+9") },
        .cancel = .{ .chord = try sc.parse("meta+f8") },
    });
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 1);
    _ = pollEvent();
    try writeTestEvent(fds[1], c.EV_KEY, 10, 1); // KEY_9
    try std.testing.expectEqual(KeyEvent.hotkey_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 1); // F8 cancels while record is latched
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
}

test "a chord cancel re-arms when a required modifier is released while key is held" {
    const sc = @import("shortcut.zig");
    var fds: [2]posix.fd_t = undefined;
    if (std.os.linux.pipe2(&fds, .{ .NONBLOCK = true }) != 0) return error.PipeFailed;
    defer {
        closeFd(fds[0]);
        closeFd(fds[1]);
    }
    setFdForTest(fds[0], .{
        .shortcut = .{ .raw_code = 30 },
        .cancel = .{ .chord = try sc.parse("meta+f8") },
    });
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 66, 1);
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 0); // re-arm
    try std.testing.expect(pollEvent() == null);
    try writeTestEvent(fds[1], c.EV_KEY, KEY_LEFTMETA_C, 1);
    try std.testing.expectEqual(KeyEvent.cancel_pressed, pollEvent().?);
}
