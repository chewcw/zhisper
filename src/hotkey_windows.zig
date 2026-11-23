const std = @import("std");
const types = @import("hotkey_types.zig");
const shortcut = @import("shortcut.zig");

const c = @cImport({
    @cInclude("windows.h");
});

const WH_KEYBOARD_LL: c_int = 13;

/// Set on keystrokes that were synthesized, i.e. our own injection. Without
/// this filter an injected VK_RETURN or VK_TAB re-enters the hook and cancels
/// our own recording the instant a sentence ends. Note that KEYEVENTF_UNICODE
/// text arrives as VK_PACKET, not as the 0 the caller sent, so vkCode is not a
/// usable discriminator; this flag is.
const LLKHF_INJECTED: u32 = 0x10;

const status_pending: u8 = 0;
const status_ok: u8 = 1;
const status_failed: u8 = 2;

// src/hotkey_windows.zig — letters, digits and function keys are contiguous.
const vk_letter_base: u16 = 0x41; // VK_A .. VK_Z
const vk_digit_base: u16 = 0x30; // VK_0 .. VK_9
const vk_fkey_base: u16 = 0x70; // VK_F1 .. VK_F24
const vk_lwin_c: u16 = 0x5B;
const vk_rwin_c: u16 = 0x5C;
const vk_shift_c: u16 = 0x10; // the generic one the hook sometimes reports
const vk_lshift_c: u16 = 0xA0;
const vk_rshift_c: u16 = 0xA1;

const meta_bit: u16 = 1 << 0;
const shift_bit: u16 = 1 << 1;

const KeyEvent = types.KeyEvent;
const Latched = enum { shortcut, clipboard, search };

var ring: types.EventRing = types.EventRing.init();
var cfg: types.HotkeyConfig = .{ .shortcut = .{ .raw_code = 0 }, .cancel = .{ .raw_code = 0 } };
/// Written only by the hook thread, which is also the only thread the hook
/// callback runs on, so plain bools are correct here.
var hotkey_down = false;
var cancel_down = false;
var clipboard_down = false;
var search_down = false;
var lmeta_down = false;
var rmeta_down = false;
var lshift_down = false;
var rshift_down = false;
var generic_shift_down = false;
var latched: ?Latched = null;
var chord_key_down = [_]bool{ false, false, false };
// Cancel is press-only and has no release event, so it cannot share the
// Latched slot. Its own state re-arms on cancel-key release or on release
// of a required modifier while the cancel key is still held.
var cancel_key_down = false;
var cancel_emitted = false;
var held: std.atomic.Value(u16) = .init(0);
var hook: c.HHOOK = null;
var thread: ?std.Thread = null;
var status: std.atomic.Value(u8) = .init(status_pending);
var thread_id: std.atomic.Value(c.DWORD) = .init(0);

fn nativeCode(name: shortcut.KeyName) ?u16 {
    const idx = @intFromEnum(name);
    const a_idx = @intFromEnum(shortcut.KeyName.a);
    const z_idx = @intFromEnum(shortcut.KeyName.z);
    if (idx >= a_idx and idx <= z_idx) return vk_letter_base + @as(u16, @intCast(idx - a_idx));
    const d0_idx = @intFromEnum(shortcut.KeyName.d0);
    const d9_idx = @intFromEnum(shortcut.KeyName.d9);
    if (idx >= d0_idx and idx <= d9_idx) return vk_digit_base + @as(u16, @intCast(idx - d0_idx));
    const f1_idx = @intFromEnum(shortcut.KeyName.f1);
    const f24_idx = @intFromEnum(shortcut.KeyName.f24);
    if (idx >= f1_idx and idx <= f24_idx) return vk_fkey_base + @as(u16, @intCast(idx - f1_idx));
    return switch (name) {
        .space => 0x20,
        .enter => 0x0D,
        .tab => 0x09,
        .esc => 0x1B,
        .backspace => 0x08,
        .delete => 0x2E,
        .insert => 0x2D,
        .home => 0x24,
        .end => 0x23,
        .pageup => 0x21,
        .pagedown => 0x22,
        .left => 0x25,
        .right => 0x27,
        .up => 0x26,
        .down => 0x28,
        .minus => 0xBD,
        .equal => 0xBB,
        .comma => 0xBC,
        .period => 0xBE,
        .slash => 0xBF,
        .backslash => 0xDC,
        .semicolon => 0xBA,
        .quote => 0xDE,
        .bracketleft => 0xDB,
        .bracketright => 0xDD,
        .grave => 0xC0,
        else => null,
    };
}

fn bindingForLatched(kind: Latched) shortcut.Binding {
    return switch (kind) {
        .shortcut => cfg.shortcut,
        .clipboard => cfg.clipboard orelse .{ .raw_code = 0 },
        .search => cfg.search orelse .{ .raw_code = 0 },
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

fn chordRequiresModifier(ch: shortcut.Shortcut, bit: u16) bool {
    return (bit == meta_bit and ch.modifiers.meta) or (bit == shift_bit and ch.modifiers.shift);
}

fn latchedRequiresModifier(kind: Latched, bit: u16) bool {
    const ch = chordOf(bindingForLatched(kind)) orelse return false;
    return chordRequiresModifier(ch, bit);
}

fn cancelChord() ?shortcut.Shortcut {
    return chordOf(cfg.cancel);
}

fn cancelChordRequiresModifier(bit: u16) bool {
    const ch = cancelChord() orelse return false;
    return chordRequiresModifier(ch, bit);
}

fn publishHeld() void {
    var bits: u16 = 0;
    if (lmeta_down or rmeta_down) bits |= meta_bit;
    if (lshift_down or rshift_down or generic_shift_down) bits |= shift_bit;
    held.store(bits, .release);
}

fn isModifierVk(vk: u16) bool {
    return vk == vk_lwin_c or vk == vk_rwin_c or vk == vk_shift_c or vk == vk_lshift_c or vk == vk_rshift_c;
}

fn modifierBitForVk(vk: u16) ?u16 {
    if (vk == vk_lwin_c or vk == vk_rwin_c) return meta_bit;
    if (vk == vk_shift_c or vk == vk_lshift_c or vk == vk_rshift_c) return shift_bit;
    return null;
}

fn setModifierVk(vk: u16, down: bool) void {
    switch (vk) {
        vk_lwin_c => lmeta_down = down,
        vk_rwin_c => rmeta_down = down,
        vk_lshift_c => lshift_down = down,
        vk_rshift_c => rshift_down = down,
        vk_shift_c => generic_shift_down = down,
        else => {},
    }
    publishHeld();
}

/// A low-level keyboard hook is delivered by sending a message to the thread
/// that installed it, so this callback runs on the hook thread. Returns 0 to
/// let the event continue to the focused app, matching Linux and macOS.
fn lowLevelKeyboardProc(code: c_int, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    if (code < 0) return c.CallNextHookEx(null, code, wparam, lparam);
    const msg: u32 = @intCast(wparam);
    if (msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN or msg == c.WM_KEYUP or msg == c.WM_SYSKEYUP) {
        const info: *const c.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @intCast(lparam)));
        if (info.flags & LLKHF_INJECTED == 0) {
            const vk: u16 = @intCast(info.vkCode);
            const is_down = msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN;
            // KBDLLHOOKSTRUCT has no repeat flag, so a held key streams key-down
            // callbacks. Report each transition once. (hotkey_linux.zig skips
            // value == 2 for the same reason.)

            if (modifierBitForVk(vk)) |bit| {
                setModifierVk(vk, is_down);
                if (is_down) {
                    if (cancel_key_down) {
                        if (cancelChord()) |ch| {
                            if (!cancel_emitted and chordModifiersSatisfied(ch)) {
                                cancel_emitted = true;
                                ring.push(.cancel_pressed);
                                return c.CallNextHookEx(null, code, wparam, lparam);
                            }
                        }
                    }
                    if (latched == null) {
                        const candidates = [_]Latched{ .shortcut, .clipboard, .search };
                        for (candidates) |kind| {
                            if (!chord_key_down[@intFromEnum(kind)]) continue;
                            const ch = chordOf(bindingForLatched(kind)) orelse continue;
                            if (!chordModifiersSatisfied(ch)) continue;
                            latched = kind;
                            ring.push(pressedEvent(kind));
                            break;
                        }
                    }
                } else {
                    if (cancel_key_down and cancelChordRequiresModifier(bit)) {
                        cancel_emitted = false;
                    }
                    if (latched) |kind| {
                        if (latchedRequiresModifier(kind, bit)) {
                            latched = null;
                            ring.push(releasedEvent(kind));
                        }
                    }
                }
                return c.CallNextHookEx(null, code, wparam, lparam);
            }

            // Cancel chord: press-only, fires even while another binding is latched.
            if (cancelChord()) |ch| {
                if (nativeCode(ch.key)) |key_code| {
                    if (vk == key_code) {
                        if (is_down) {
                            if (!cancel_key_down) {
                                cancel_key_down = true;
                                if (!cancel_emitted and chordModifiersSatisfied(ch)) {
                                    cancel_emitted = true;
                                    ring.push(.cancel_pressed);
                                }
                            }
                            // held key streams key-down callbacks; never re-emit.
                        } else if (cancel_key_down) {
                            cancel_key_down = false;
                            cancel_emitted = false;
                        }
                        return c.CallNextHookEx(null, code, wparam, lparam);
                    }
                }
            }

            const candidates = [_]Latched{ .shortcut, .clipboard, .search };
            for (candidates) |kind| {
                const b = bindingForLatched(kind);
                const ch = chordOf(b) orelse continue;
                const key_code = nativeCode(ch.key) orelse continue;
                if (vk != key_code) continue;

                if (is_down) {
                    if (!chord_key_down[@intFromEnum(kind)]) {
                        chord_key_down[@intFromEnum(kind)] = true;
                        if (latched == null and chordModifiersSatisfied(ch)) {
                            latched = kind;
                            ring.push(pressedEvent(kind));
                        }
                    }
                } else {
                    if (chord_key_down[@intFromEnum(kind)]) {
                        chord_key_down[@intFromEnum(kind)] = false;
                        if (latched == kind) {
                            latched = null;
                            ring.push(releasedEvent(kind));
                        }
                    }
                }
                return c.CallNextHookEx(null, code, wparam, lparam);
            }

            // Raw-code bindings keep today's exact behaviour.
            const hotkey_code = types.rawCode(cfg.shortcut);
            const cancel_code = types.rawCode(cfg.cancel);
            const clipboard_code: ?u16 = if (cfg.clipboard) |b| types.rawCode(b) else null;
            const search_code: ?u16 = if (cfg.search) |b| types.rawCode(b) else null;

            if (hotkey_code != null and vk == hotkey_code.?) {
                if (is_down) {
                    if (!hotkey_down) {
                        hotkey_down = true;
                        ring.push(.hotkey_pressed);
                    }
                } else if (hotkey_down) {
                    hotkey_down = false;
                    ring.push(.hotkey_released);
                }
            } else if (clipboard_code != null and vk == clipboard_code.?) {
                // Same reason hotkey_down and cancel_down exist:
                // KBDLLHOOKSTRUCT has no repeat flag, so a held key streams
                // key-down callbacks and each transition must be reported once.
                if (is_down) {
                    if (!clipboard_down) {
                        clipboard_down = true;
                        ring.push(.clipboard_pressed);
                    }
                } else if (clipboard_down) {
                    clipboard_down = false;
                    ring.push(.clipboard_released);
                }
            } else if (search_code != null and vk == search_code.?) {
                // Same transition-once logic as hotkey/clipboard/cancel:
                // KBDLLHOOKSTRUCT has no repeat flag.
                if (is_down) {
                    if (!search_down) {
                        search_down = true;
                        ring.push(.search_pressed);
                    }
                } else if (search_down) {
                    search_down = false;
                    ring.push(.search_released);
                }
            } else if (cancel_code != null and vk == cancel_code.?) {
                if (is_down) {
                    if (!cancel_down) {
                        cancel_down = true;
                        ring.push(.cancel_pressed);
                    }
                } else {
                    cancel_down = false;
                }
            }
        }
    }
    return c.CallNextHookEx(null, code, wparam, lparam);
}

/// Runs on the dedicated thread. WHY the hook is installed here and not on the
/// caller's thread: MSDN requires the installing thread to own a message loop,
/// and zhisper's main loop must stay free of one.
fn hookThread() void {
    thread_id.store(c.GetCurrentThreadId(), .release);
    hook = c.SetWindowsHookExW(WH_KEYBOARD_LL, lowLevelKeyboardProc, null, 0) orelse {
        status.store(status_failed, .release);
        return;
    };
    status.store(status_ok, .release);
    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
    // The loop only exits on WM_QUIT from destroy().
    _ = c.UnhookWindowsHookEx(hook);
    hook = null;
}

pub fn setup(config: types.HotkeyConfig) !void {
    cfg = config;
    ring = types.EventRing.init();
    hotkey_down = false;
    cancel_down = false;
    clipboard_down = false;
    search_down = false;
    lmeta_down = false;
    rmeta_down = false;
    lshift_down = false;
    rshift_down = false;
    generic_shift_down = false;
    latched = null;
    chord_key_down = [_]bool{ false, false, false };
    cancel_key_down = false;
    cancel_emitted = false;
    held.store(0, .release);
    status.store(status_pending, .release);
    thread_id.store(0, .release);

    thread = std.Thread.spawn(.{}, hookThread, .{}) catch return error.HookInstallFailed;
    // Bounded wait for the install to report in. 200 x 1ms is generous; a
    // failure here means SetWindowsHookExW itself failed. Uses the Win32 Sleep
    // because std has no io-less sleep and setup() takes no std.Io.
    var spins: usize = 0;
    while (status.load(.acquire) == status_pending and spins < 200) : (spins += 1) {
        c.Sleep(1);
    }
    if (status.load(.acquire) != status_ok) {
        const t = thread;
        thread = null;
        if (t) |tt| tt.join();
        return error.HookInstallFailed;
    }
}

pub fn pollEvent() ?types.KeyEvent {
    return ring.pop();
}

pub fn modifiersHeld() bool {
    return (held.load(.acquire) & (meta_bit | shift_bit)) != 0;
}

pub fn destroy() void {
    const t = thread orelse return;
    thread = null;
    _ = c.PostThreadMessageW(thread_id.load(.acquire), c.WM_QUIT, 0, 0);
    t.join();
    ring = types.EventRing.init();
    hotkey_down = false;
    cancel_down = false;
    clipboard_down = false;
    search_down = false;
    lmeta_down = false;
    rmeta_down = false;
    lshift_down = false;
    rshift_down = false;
    generic_shift_down = false;
    latched = null;
    chord_key_down = [_]bool{ false, false, false };
    cancel_key_down = false;
    cancel_emitted = false;
    held.store(0, .release);
}
