const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const KeyEvent = @import("hotkey_types.zig").KeyEvent;
const clipboard = @import("clipboard.zig");
const types = @import("inject_types.zig");
const log = @import("log.zig");

/// Setup-time policy, mirroring hotkey_linux.zig's active_cfg module var.
var opts: types.InjectOptions = .{};

/// Number of codepoints in a validated UTF-8 slice.
fn countCodepoints(s: []const u8) usize {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return 0).iterator();
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

fn closeFd(fd: posix.fd_t) void {
    _ = linux.close(fd);
}

const c = @cImport({
    @cInclude("linux/input-event-codes.h");
    @cInclude("linux/input.h");
    @cInclude("linux/uinput.h");
    @cInclude("sys/ioctl.h");
});

// Re-export the kernel structs so existing consumers keep working.
pub const InputId = c.struct_input_id;
pub const UinputSetup = c.struct_uinput_setup;

// Device IDs (ours, not from headers).
const vendor_id = 0x1234;
const product_id = 0x5678;

pub const device_name = "zhisper";
pub const expected_key_count: usize = 58;

// Hold/gap pacing between press and release so uinput consumers don't
// coalesce rapid pairs. ~10ms per char total.
const press_hold_us: u64 = 8000;
const release_gap_us: u64 = 2000;

var fd_uinput: posix.fd_t = -1;

/// Clipboard probe result cached at setup() time for typeText().
/// Defaults to unavailable until setup() probes.
var clipboard_state: clipboard.Clipboard = .{ .available = false, .tool = null };

/// True when text contains multi-byte UTF-8 (any byte > 0x7F).
/// Such text cannot go through the US-ASCII keyForChar path and
/// must use the clipboard paste path.
pub fn needsClipboard(text: []const u8) bool {
    for (text) |b| if (b > 0x7F) return true;
    return false;
}

pub fn buildUinputSetup() UinputSetup {
    var uisetup: UinputSetup = std.mem.zeroes(UinputSetup);
    uisetup.id.bustype = c.BUS_USB;
    uisetup.id.vendor = vendor_id;
    uisetup.id.product = product_id;
    @memcpy(uisetup.name[0..device_name.len], device_name);
    return uisetup;
}

pub fn allKeyCodes() [expected_key_count]u16 {
    var codes: [expected_key_count]u16 = undefined;
    var i: usize = 0;
    for (c.KEY_Q..c.KEY_P + 1) |code| {
        codes[i] = @intCast(code);
        i += 1;
    }
    for (c.KEY_A..c.KEY_L + 1) |code| {
        codes[i] = @intCast(code);
        i += 1;
    }
    for (c.KEY_Z..c.KEY_M + 1) |code| {
        codes[i] = @intCast(code);
        i += 1;
    }
    for (c.KEY_1..c.KEY_0 + 1) |code| {
        codes[i] = @intCast(code);
        i += 1;
    }
    inline for (.{ c.KEY_SPACE, c.KEY_MINUS, c.KEY_EQUAL, c.KEY_LEFTBRACE, c.KEY_RIGHTBRACE, c.KEY_SEMICOLON, c.KEY_APOSTROPHE, c.KEY_GRAVE, c.KEY_BACKSLASH, c.KEY_COMMA, c.KEY_DOT, c.KEY_SLASH, c.KEY_TAB, c.KEY_ENTER, c.KEY_BACKSPACE }) |code| {
        codes[i] = @intCast(code);
        i += 1;
    }
    inline for (.{ c.KEY_LEFTCTRL, c.KEY_RIGHTCTRL, c.KEY_LEFTALT, c.KEY_RIGHTALT, c.KEY_LEFTSHIFT, c.KEY_RIGHTSHIFT, c.KEY_LEFTMETA }) |code| {
        codes[i] = @intCast(code);
        i += 1;
    }
    std.debug.assert(i == expected_key_count);
    return codes;
}

pub fn destroy() void {
    if (fd_uinput < 0) return;
    ioctlNoArg(fd_uinput, c.UI_DEV_DESTROY) catch {};
    closeFd(fd_uinput);
    fd_uinput = -1;
}

pub fn setup(io: std.Io, o: types.InjectOptions) !void {
    opts = o;
    fd_uinput = try posix.openat(posix.AT.FDCWD, "/dev/uinput", .{
        .ACCMODE = .WRONLY,
        .NONBLOCK = true,
    }, 0);
    errdefer {
        closeFd(fd_uinput);
        fd_uinput = -1;
    }

    try ioctlInt(fd_uinput, c.UI_SET_EVBIT, c.EV_KEY);

    const codes = allKeyCodes();
    for (codes) |code| try setKeyBit(code);

    var uisetup = buildUinputSetup();

    try ioctlPtr(fd_uinput, c.UI_DEV_SETUP, &uisetup);
    try ioctlNoArg(fd_uinput, c.UI_DEV_CREATE);

    // Give libinput/udev a moment to pick up the new device.
    try io.sleep(.fromMilliseconds(100), .awake);

    // Skip the clipboard probe warning during tests: clipboard.zig uses a
    // stub (always unavailable) under is_test, so warning here would just
    // pollute test stderr and make `zig build test` echo the test command.
    if (!builtin.is_test) {
        clipboard_state = clipboard.check(io);
        if (!clipboard_state.available) {
            log.warn("Clipboard unavailable — non-ASCII injection disabled");
        }
    }
}

fn setKeyBit(code: usize) !void {
    return ioctlInt(fd_uinput, c.UI_SET_KEYBIT, @intCast(code));
}

fn ioctlError() !void {
    const err: posix.E = @enumFromInt(std.c._errno().*);
    return switch (err) {
        .BADF => error.BadFileDescriptor,
        else => posix.unexpectedErrno(err),
    };
}

fn ioctlInt(fd: posix.fd_t, request: c_ulong, arg: c_int) !void {
    if (c.ioctl(fd, request, arg) == -1) return ioctlError();
}

fn ioctlPtr(fd: posix.fd_t, request: c_ulong, ptr: *UinputSetup) !void {
    if (c.ioctl(fd, request, ptr) == -1) return ioctlError();
}

fn ioctlNoArg(fd: posix.fd_t, request: c_ulong) !void {
    if (c.ioctl(fd, request) == -1) return ioctlError();
}

/// Writes one key event plus the closing SYN report to the uinput device.
/// Protocol (key press, report, key release, report) and the ioctls used in
/// setup (UI_SET_EVBIT / UI_SET_KEYBIT / UI_DEV_SETUP / UI_DEV_CREATE)
/// follow the kernel uinput docs:
/// https://www.kernel.org/doc/html/latest/input/uinput.html
/// Timestamps are left zeroed — the kernel ignores them for uinput writes.
pub fn emitKey(code: u16, action: KeyEvent) !void {
    if (fd_uinput < 0) return error.NotSetup;
    const value: u32 = if (action == .hotkey_pressed) 1 else 0;
    const ev_key = c.struct_input_event{
        .type = c.EV_KEY,
        .code = @intCast(code),
        .value = @intCast(value),
    };
    const ev_syn = c.struct_input_event{
        .type = c.EV_SYN,
        .code = c.SYN_REPORT,
        .value = 0,
    };
    const ev_key_bytes = std.mem.asBytes(&ev_key);
    const ev_syn_bytes = std.mem.asBytes(&ev_syn);
    const written_key = std.os.linux.write(fd_uinput, ev_key_bytes.ptr, ev_key_bytes.len);
    if (written_key != ev_key_bytes.len) return error.ShortWrite;
    const written_syn = std.os.linux.write(fd_uinput, ev_syn_bytes.ptr, ev_syn_bytes.len);
    if (written_syn != ev_syn_bytes.len) return error.ShortWrite;
}

pub fn tapKey(code: u16) !void {
    try emitKey(code, .hotkey_pressed);
    try emitKey(code, .hotkey_released);
}

const KeyPress = struct { code: u16, shift: bool };

/// US-layout byte → key mapping. KEY_* code values come from
/// include/uapi/linux/input-event-codes.h; press/release value semantics
/// (1 = press, 0 = release) per:
/// https://www.kernel.org/doc/html/latest/input/event-codes.html
fn keyForChar(ch: u8) ?KeyPress {
    return switch (ch) {
        'a' => .{ .code = c.KEY_A, .shift = false },
        'b' => .{ .code = c.KEY_B, .shift = false },
        'c' => .{ .code = c.KEY_C, .shift = false },
        'd' => .{ .code = c.KEY_D, .shift = false },
        'e' => .{ .code = c.KEY_E, .shift = false },
        'f' => .{ .code = c.KEY_F, .shift = false },
        'g' => .{ .code = c.KEY_G, .shift = false },
        'h' => .{ .code = c.KEY_H, .shift = false },
        'i' => .{ .code = c.KEY_I, .shift = false },
        'j' => .{ .code = c.KEY_J, .shift = false },
        'k' => .{ .code = c.KEY_K, .shift = false },
        'l' => .{ .code = c.KEY_L, .shift = false },
        'm' => .{ .code = c.KEY_M, .shift = false },
        'n' => .{ .code = c.KEY_N, .shift = false },
        'o' => .{ .code = c.KEY_O, .shift = false },
        'p' => .{ .code = c.KEY_P, .shift = false },
        'q' => .{ .code = c.KEY_Q, .shift = false },
        'r' => .{ .code = c.KEY_R, .shift = false },
        's' => .{ .code = c.KEY_S, .shift = false },
        't' => .{ .code = c.KEY_T, .shift = false },
        'u' => .{ .code = c.KEY_U, .shift = false },
        'v' => .{ .code = c.KEY_V, .shift = false },
        'w' => .{ .code = c.KEY_W, .shift = false },
        'x' => .{ .code = c.KEY_X, .shift = false },
        'y' => .{ .code = c.KEY_Y, .shift = false },
        'z' => .{ .code = c.KEY_Z, .shift = false },
        'A'...'Z' => .{ .code = @intCast(keyForChar(ch + 32).?.code), .shift = true },
        '0' => .{ .code = c.KEY_0, .shift = false },
        '1'...'9' => .{ .code = @intCast(@as(c_int, c.KEY_1) + (ch - '1')), .shift = false },
        ' ' => .{ .code = c.KEY_SPACE, .shift = false },
        '\n' => .{ .code = c.KEY_ENTER, .shift = false },
        '\t' => .{ .code = c.KEY_TAB, .shift = false },
        '.' => .{ .code = c.KEY_DOT, .shift = false },
        ',' => .{ .code = c.KEY_COMMA, .shift = false },
        '-' => .{ .code = c.KEY_MINUS, .shift = false },
        '=' => .{ .code = c.KEY_EQUAL, .shift = false },
        ';' => .{ .code = c.KEY_SEMICOLON, .shift = false },
        '\'' => .{ .code = c.KEY_APOSTROPHE, .shift = false },
        '/' => .{ .code = c.KEY_SLASH, .shift = false },
        '[' => .{ .code = c.KEY_LEFTBRACE, .shift = false },
        ']' => .{ .code = c.KEY_RIGHTBRACE, .shift = false },
        '`' => .{ .code = c.KEY_GRAVE, .shift = false },
        '\\' => .{ .code = c.KEY_BACKSLASH, .shift = false },
        '!' => .{ .code = c.KEY_1, .shift = true },
        '@' => .{ .code = c.KEY_2, .shift = true },
        '#' => .{ .code = c.KEY_3, .shift = true },
        '$' => .{ .code = c.KEY_4, .shift = true },
        '%' => .{ .code = c.KEY_5, .shift = true },
        '^' => .{ .code = c.KEY_6, .shift = true },
        '&' => .{ .code = c.KEY_7, .shift = true },
        '*' => .{ .code = c.KEY_8, .shift = true },
        '(' => .{ .code = c.KEY_9, .shift = true },
        ')' => .{ .code = c.KEY_0, .shift = true },
        '_' => .{ .code = c.KEY_MINUS, .shift = true },
        '+' => .{ .code = c.KEY_EQUAL, .shift = true },
        ':' => .{ .code = c.KEY_SEMICOLON, .shift = true },
        '"' => .{ .code = c.KEY_APOSTROPHE, .shift = true },
        '?' => .{ .code = c.KEY_SLASH, .shift = true },
        '<' => .{ .code = c.KEY_COMMA, .shift = true },
        '>' => .{ .code = c.KEY_DOT, .shift = true },
        else => null,
    };
}

fn tapCode(code: u16, shift: bool, io: std.Io) !void {
    if (shift) try emitKey(c.KEY_LEFTSHIFT, .hotkey_pressed);
    errdefer if (shift) emitKey(c.KEY_LEFTSHIFT, .hotkey_released) catch {};
    try emitKey(code, .hotkey_pressed);
    // Pacing for uinput consumers (libinput/compositors) that coalesce or
    // drop back-to-back press/release pairs without a small hold/gap.
    // Best-effort: sleep interruption must not abort typing mid-word.
    io.sleep(.fromMicroseconds(press_hold_us), .awake) catch {};
    try emitKey(code, .hotkey_released);
    io.sleep(.fromMicroseconds(release_gap_us), .awake) catch {};
    if (shift) try emitKey(c.KEY_LEFTSHIFT, .hotkey_released);
}

/// Types UTF-8 ASCII text via the uinput device. US layout. Returns the
/// number of keystrokes emitted; stops at the first unmapped byte.
/// Multi-byte UTF-8 (any byte > 0x7F) goes through the clipboard:
/// copy via clipboard.paste() then emit Ctrl+V.
/// Trailing newlines are stripped or kept per the setup-time policy.
pub fn typeText(text: []const u8, io: std.Io) !usize {
    if (fd_uinput < 0) return error.NotSetup;
    _ = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    const body = text[0 .. text.len - types.trailingCut(text, opts.trailing_newline)];
    if (needsClipboard(body)) {
        try clipboard.paste(body, io, clipboard_state);
        // Emit Ctrl+V to paste the clipboard contents.
        try emitKey(@intCast(c.KEY_LEFTCTRL), .hotkey_pressed);
        errdefer emitKey(@intCast(c.KEY_LEFTCTRL), .hotkey_released) catch {};
        try tapCode(@intCast(c.KEY_V), false, io);
        try emitKey(@intCast(c.KEY_LEFTCTRL), .hotkey_released);
        return countCodepoints(body);
    }
    var count: usize = 0;
    // Interior newlines need no special handling: keyForChar already maps
    // '\n' to KEY_ENTER.
    for (body) |ch| {
        const kp = keyForChar(ch) orelse return error.UnsupportedCharacter;
        try tapCode(kp.code, kp.shift, io);
        count += 1;
    }
    return count;
}

test {
    std.testing.refAllDecls(@This());
}

test "UinputSetup layout matches kernel" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(InputId));
    try std.testing.expectEqual(@as(usize, 92), @sizeOf(UinputSetup));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(UinputSetup, "id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(UinputSetup, "name"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(UinputSetup, "ff_effects_max"));
    const zero: UinputSetup = std.mem.zeroes(UinputSetup);
    try std.testing.expectEqual(@as(u16, 0), zero.id.bustype);
    try std.testing.expectEqual(@as(u8, 0), zero.name[0]);
}

test "kernel constants sanity" {
    try std.testing.expectEqual(@as(c_int, 1), c.EV_KEY);
    try std.testing.expectEqual(@as(c_int, 3), c.BUS_USB);
    try std.testing.expectEqual(@as(c_int, 16), c.KEY_Q);
    try std.testing.expectEqual(@as(c_int, 25), c.KEY_P);
    try std.testing.expectEqual(@as(c_int, 30), c.KEY_A);
    try std.testing.expectEqual(@as(c_int, 38), c.KEY_L);
    try std.testing.expectEqual(@as(c_int, 44), c.KEY_Z);
    try std.testing.expectEqual(@as(c_int, 50), c.KEY_M);
    try std.testing.expectEqual(@as(c_int, 2), c.KEY_1);
    try std.testing.expectEqual(@as(c_int, 11), c.KEY_0);
    // Values come from _IOW('U',...) encoding; guard against header drift.
    try std.testing.expectEqual(@as(c_ulong, 0x40045564), c.UI_SET_EVBIT);
    try std.testing.expectEqual(@as(c_ulong, 0x40045565), c.UI_SET_KEYBIT);
    try std.testing.expectEqual(@as(c_ulong, 0x405C5503), c.UI_DEV_SETUP);
    try std.testing.expectEqual(@as(c_ulong, 0x5501), c.UI_DEV_CREATE);
}

test "buildUinputSetup id and name" {
    const uisetup = buildUinputSetup();
    try std.testing.expectEqual(@as(u16, c.BUS_USB), uisetup.id.bustype);
    try std.testing.expectEqual(@as(u16, vendor_id), uisetup.id.vendor);
    try std.testing.expectEqual(@as(u16, product_id), uisetup.id.product);
    try std.testing.expectEqual(@as(u16, 0), uisetup.id.version);
    try std.testing.expectEqual(@as(u32, 0), uisetup.ff_effects_max);
    try std.testing.expect(device_name.len < uisetup.name.len);
    try std.testing.expectEqualStrings(device_name, uisetup.name[0..device_name.len]);
    // NUL-terminated and zero-padded.
    try std.testing.expectEqual(@as(u8, 0), uisetup.name[device_name.len]);
    for (uisetup.name[device_name.len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "allKeyCodes count, coverage, no duplicates" {
    const codes = allKeyCodes();
    try std.testing.expectEqual(expected_key_count, codes.len);

    // Spot-check representatives from each group.
    const wants = [_]u16{
        @intCast(c.KEY_Q),         @intCast(c.KEY_P),
        @intCast(c.KEY_A),         @intCast(c.KEY_L),
        @intCast(c.KEY_Z),         @intCast(c.KEY_M),
        @intCast(c.KEY_1),         @intCast(c.KEY_0),
        @intCast(c.KEY_SPACE),     @intCast(c.KEY_ENTER),
        @intCast(c.KEY_BACKSPACE), @intCast(c.KEY_TAB),
        @intCast(c.KEY_LEFTCTRL),  @intCast(c.KEY_RIGHTCTRL),
        @intCast(c.KEY_LEFTALT),   @intCast(c.KEY_RIGHTALT),
        @intCast(c.KEY_LEFTSHIFT), @intCast(c.KEY_RIGHTSHIFT),
        @intCast(c.KEY_LEFTMETA),
    };
    for (wants) |w| {
        var found = false;
        for (codes) |have| if (have == w) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }

    // No duplicates.
    for (codes, 0..) |a, idx| {
        for (codes[idx + 1 ..]) |b| try std.testing.expect(a != b);
    }

    // Letter/number ranges are fully covered.
    var q_count: usize = 0;
    var a_count: usize = 0;
    var z_count: usize = 0;
    var n_count: usize = 0;
    for (codes) |code| {
        if (code >= c.KEY_Q and code <= c.KEY_P) q_count += 1;
        if (code >= c.KEY_A and code <= c.KEY_L) a_count += 1;
        if (code >= c.KEY_Z and code <= c.KEY_M) z_count += 1;
        if (code >= c.KEY_1 and code <= c.KEY_0) n_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), q_count);
    try std.testing.expectEqual(@as(usize, 9), a_count);
    try std.testing.expectEqual(@as(usize, 7), z_count);
    try std.testing.expectEqual(@as(usize, 10), n_count);
}

test "ioctl helpers reject bad fd" {
    try std.testing.expectError(error.BadFileDescriptor, ioctlInt(-1, c.UI_DEV_CREATE, 0));
    try std.testing.expectError(error.BadFileDescriptor, ioctlNoArg(-1, c.UI_DEV_CREATE));
    var dummy: UinputSetup = std.mem.zeroes(UinputSetup);
    try std.testing.expectError(error.BadFileDescriptor, ioctlPtr(-1, c.UI_DEV_SETUP, &dummy));
}

test "destroy is safe when idle" {
    if (fd_uinput >= 0) destroy();
    try std.testing.expectEqual(@as(posix.fd_t, -1), fd_uinput);
    destroy();
    try std.testing.expectEqual(@as(posix.fd_t, -1), fd_uinput);
}

test "setup creates device" {
    // Needs /dev/uinput + permission (input group or root). Skip in CI.
    const probe = posix.openat(posix.AT.FDCWD, "/dev/uinput", .{ .ACCMODE = .WRONLY }, 0) catch
        return error.SkipZigTest;
    closeFd(probe);

    if (fd_uinput >= 0) destroy();
    defer destroy();

    const io = std.testing.io;
    try setup(io, .{});
    try std.testing.expect(fd_uinput >= 0);
}

test "emitKey without setup returns NotSetup" {
    const saved = fd_uinput;
    fd_uinput = -1;
    defer fd_uinput = saved;
    try std.testing.expectError(error.NotSetup, emitKey(c.KEY_ENTER, .hotkey_pressed));
    try std.testing.expectError(error.NotSetup, emitKey(c.KEY_ENTER, .hotkey_released));
}

test "tapKey without setup returns NotSetup" {
    const saved = fd_uinput;
    fd_uinput = -1;
    defer fd_uinput = saved;
    try std.testing.expectError(error.NotSetup, tapKey(c.KEY_A));
}

test "keyForChar maps letters, digits, punctuation and shift" {
    const A = keyForChar('a').?;
    try std.testing.expectEqual(@as(u16, @intCast(c.KEY_A)), A.code);
    try std.testing.expectEqual(false, A.shift);
    const CapA = keyForChar('A').?;
    try std.testing.expectEqual(@as(u16, @intCast(c.KEY_A)), CapA.code);
    try std.testing.expectEqual(true, CapA.shift);
    try std.testing.expectEqual(@as(u16, @intCast(c.KEY_1)), keyForChar('1').?.code);
    try std.testing.expectEqual(@as(u16, @intCast(c.KEY_SPACE)), keyForChar(' ').?.code);
    try std.testing.expectEqual(@as(u16, @intCast(c.KEY_ENTER)), keyForChar('\n').?.code);
    try std.testing.expectEqual(@as(u16, @intCast(c.KEY_DOT)), keyForChar('.').?.code);
    try std.testing.expect(keyForChar('!').?.shift);
    try std.testing.expect(keyForChar(0xC3) == null);
}

test "typeText without setup returns NotSetup" {
    const saved = fd_uinput;
    fd_uinput = -1;
    defer fd_uinput = saved;
    try std.testing.expectError(error.NotSetup, typeText("hi", std.testing.io));
}

test "typeText with multi-byte UTF-8 triggers clipboard path" {
    // Non-ASCII byte (Mandarin '你' = 0xE4 0xBD 0xA0) triggers clipboard branch.
    const text = "你";
    // Branch check: first byte > 0x7F means clipboard.
    try std.testing.expect(text[0] > 0x7F);
    try std.testing.expect(needsClipboard(text));
    try std.testing.expect(!needsClipboard("hi"));
    try std.testing.expect(needsClipboard("hi 你"));
    // Without setup, still NotSetup (clipboard branch is after the fd guard).
    const saved_fd = fd_uinput;
    fd_uinput = -1;
    defer fd_uinput = saved_fd;
    try std.testing.expectError(error.NotSetup, typeText(text, std.testing.io));
}
