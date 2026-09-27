const std = @import("std");
const types = @import("hotkey_types.zig");

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

var ring: types.EventRing = types.EventRing.init();
var cfg: types.HotkeyConfig = .{ .key_code = 0 };
/// Written only by the hook thread, which is also the only thread the hook
/// callback runs on, so plain bools are correct here.
var hotkey_down = false;
var cancel_down = false;
var clipboard_down = false;
var hook: c.HHOOK = null;
var thread: ?std.Thread = null;
var status: std.atomic.Value(u8) = .init(status_pending);
var thread_id: std.atomic.Value(c.DWORD) = .init(0);

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
            if (vk == cfg.key_code) {
                if (is_down) {
                    if (!hotkey_down) {
                        hotkey_down = true;
                        ring.push(.hotkey_pressed);
                    }
                } else if (hotkey_down) {
                    hotkey_down = false;
                    ring.push(.hotkey_released);
                }
            } else if (vk == cfg.clipboard_key_code) {
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
            } else if (vk == cfg.cancel_key_code) {
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

pub fn destroy() void {
    const t = thread orelse return;
    thread = null;
    _ = c.PostThreadMessageW(thread_id.load(.acquire), c.WM_QUIT, 0, 0);
    t.join();
    ring = types.EventRing.init();
}
