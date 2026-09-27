const std = @import("std");
const posix = std.posix;
const types = @import("hotkey_types.zig");

pub const KeyEvent = types.KeyEvent;
pub const Mode = types.Mode;
pub const HotkeyConfig = types.HotkeyConfig;

const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("linux/input.h");
    @cInclude("sys/ioctl.h");
});

var fd_evdev: posix.fd_t = -1;
var active_cfg: HotkeyConfig = .{ .key_code = 0 };

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
            log.info("using explicit evdev {s} (key={d}, cancel={d})", .{ path, config.key_code, config.cancel_key_code });
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
                log.info("name match '{s}' -> {s} (key={d}, cancel={d})", .{ want, path, config.key_code, config.cancel_key_code });
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
            log.info("auto-scan picked {s} (key={d}, cancel={d})", .{ path, config.key_code, config.cancel_key_code });
            return;
        }
    }
    return error.DeviceNotFound;
}

pub fn pollEvent() ?KeyEvent {
    if (fd_evdev < 0) return null;
    const log = std.log.scoped(.hotkey);
    // struct input_event layout {timeval time; u16 type; u16 code; s32 value}
    // and value meanings (0 = release, 1 = press, 2 = autorepeat) per:
    // https://www.kernel.org/doc/html/latest/input/input.html (section 1.5)
    var ev: c.struct_input_event = undefined;
    const bytes = std.mem.asBytes(&ev);
    while (true) {
        const n = std.os.linux.read(fd_evdev, bytes.ptr, bytes.len);
        if (n != bytes.len) return null; // EAGAIN on empty nonblocking fd
        if (ev.type != c.EV_KEY) continue;
        log.debug("ev code={d} value={d} (want talk={d} clipboard={d} cancel={d})", .{ ev.code, ev.value, active_cfg.key_code, active_cfg.clipboard_key_code, active_cfg.cancel_key_code });
        // Hotkey first so a misconfigured cancel == hotkey degrades to hotkey.
        if (ev.code == active_cfg.key_code) {
            if (ev.value == 1) return .hotkey_pressed;
            if (ev.value == 0) return .hotkey_released;
            continue; // value == 2 is auto-repeat: ignore.
        }
        if (active_cfg.clipboard_key_code != 0 and ev.code == active_cfg.clipboard_key_code) {
            if (ev.value == 1) return .clipboard_pressed;
            if (ev.value == 0) return .clipboard_released;
            continue; // value == 2 is auto-repeat: ignore.
        }
        if (active_cfg.cancel_key_code != 0 and ev.code == active_cfg.cancel_key_code) {
            if (ev.value == 1) return .cancel_pressed;
            continue; // cancel release + autorepeat swallowed.
        }
    }
}

pub fn destroy() void {
    if (fd_evdev < 0) return;
    closeFd(fd_evdev);
    fd_evdev = -1;
}

fn setFdForTest(fd: posix.fd_t, config: HotkeyConfig) void {
    if (fd_evdev >= 0) destroy();
    fd_evdev = fd;
    active_cfg = config;
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
    setFdForTest(fds[0], .{ .key_code = 30, .mode = .hold });
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
    setFdForTest(fds[0], .{ .key_code = 30, .mode = .hold, .cancel_key_code = 46 });
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
    setFdForTest(fds[0], .{ .key_code = 30, .mode = .hold, .cancel_key_code = 0 });
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
    setFdForTest(fds[0], .{ .key_code = 30, .mode = .hold, .clipboard_key_code = 87 });
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
    setFdForTest(fds[0], .{ .key_code = 30, .mode = .hold, .clipboard_key_code = 87 });
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
    setFdForTest(fds[0], .{ .key_code = 30, .mode = .hold, .clipboard_key_code = 0 });
    try writeTestEvent(fds[1], c.EV_KEY, 87, 1);
    try writeTestEvent(fds[1], c.EV_KEY, 87, 0);
    try std.testing.expect(pollEvent() == null);
}
