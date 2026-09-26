const std = @import("std");
const builtin = @import("builtin");
const types = @import("inject_types.zig");
const log = @import("log.zig");

const c = @cImport({
    @cInclude("windows.h");
});

/// SendInput inserts events synchronously and does not coalesce them, so no
/// pacing is needed here. macOS is the platform that needs a delay.
const default_type_delay_ms: u16 = 0;

const KEYEVENTF_KEYUP: u32 = 0x0002;
const KEYEVENTF_UNICODE: u32 = 0x0004;
const VK_RETURN: u16 = 0x0D;
const VK_TAB: u16 = 0x09;

var opts: types.InjectOptions = .{};
var set_up = false;

/// True when text contains multi-byte UTF-8 (any byte > 0x7F).
pub fn needsClipboard(text: []const u8) bool {
    for (text) |b| if (b > 0x7F) return true;
    return false;
}

pub fn setup(io: std.Io, o: types.InjectOptions) !void {
    _ = io;
    opts = o;
    set_up = true;
}

pub fn destroy() void {
    set_up = false;
}

fn emit(vk: u16, scan: u16, flags: u32) !void {
    var kb: c.KEYBDINPUT = std.mem.zeroes(c.KEYBDINPUT);
    kb.wVk = vk;
    kb.wScan = scan;
    kb.dwFlags = flags;
    kb.time = 0;
    kb.dwExtraInfo = 0;
    var input: c.INPUT = std.mem.zeroes(c.INPUT);
    input.type = c.INPUT_KEYBOARD;
    // The INPUT union is anonymous in C; translate-c names it unnamed_0.
    input.unnamed_0.ki = kb;
    // SendInput returns the number of events actually inserted. Zero means the
    // call was blocked, which on Windows is almost always UIPI: the target
    // application is running elevated and zhisper is not. One event per call,
    // so the return is 1 (inserted) or 0 (blocked) — never a partial count.
    if (c.SendInput(1, &input, @sizeOf(c.INPUT)) != 1) return error.InputBlocked;
}

/// Send one codepoint. Surrogate pairs (codepoints above 0xFFFF) become four
/// events: both downs, then both ups, because wScan is a single WORD.
fn emitCodepoint(cp: u21) !usize {
    var scratch: [4]u8 = undefined;
    var utf16: [2]u16 = undefined;
    const n = std.unicode.utf8Encode(cp, scratch[0..]) catch return error.InvalidUtf8;
    const units = std.unicode.utf8ToUtf16Le(&utf16, scratch[0..n]) catch return error.InvalidUtf8;
    for (utf16[0..units]) |unit| {
        try emit(0, unit, KEYEVENTF_UNICODE);
        try emit(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
    }
    return units;
}

/// Types UTF-8 text as synthetic keystrokes carrying each codepoint as data
/// (KEYEVENTF_UNICODE), so no keyboard layout is consulted and the clipboard is
/// never touched. Returns the number of keystrokes emitted.
pub fn typeText(text: []const u8, io: std.Io) !usize {
    if (!set_up) return error.NotSetup;
    _ = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    const body = text[0 .. text.len - types.trailingCut(text, opts.trailing_newline)];
    // Iterate the trimmed body, not the original text, or stripped trailing
    // newlines would still be emitted.
    const view = std.unicode.Utf8View.init(body) catch return error.InvalidUtf8;
    const delay = if (opts.type_delay_ms == 0) default_type_delay_ms else opts.type_delay_ms;

    var count: usize = 0;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp_bytes| {
        const cp = std.unicode.utf8Decode(cp_bytes) catch return error.InvalidUtf8;
        switch (types.classify(cp) orelse continue) {
            .char => count += try emitCodepoint(cp),
            .return_key => {
                try emit(VK_RETURN, 0, 0);
                try emit(VK_RETURN, 0, KEYEVENTF_KEYUP);
                count += 1;
            },
            .tab_key => {
                try emit(VK_TAB, 0, 0);
                try emit(VK_TAB, 0, KEYEVENTF_KEYUP);
                count += 1;
            },
        }
        if (delay != 0) io.sleep(.fromMilliseconds(delay), .awake) catch {};
    }
    return count;
}
