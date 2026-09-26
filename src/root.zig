const std = @import("std");
const builtin = @import("builtin");

// Single entry point for the zhisper library: typing backend + audio capture
// + hotkey/inject facades. (Flat `pub usingnamespace` re-exports are not
// allowed in Zig 0.16, so the backends stay namespaced.)
pub const audio = @import("audio.zig");
pub const transcribe = @import("transcribe.zig");
pub const hotkey = @import("hotkey.zig");
pub const hotkey_types = @import("hotkey_types.zig");
pub const inject = @import("inject.zig");
pub const inject_types = @import("inject_types.zig");
pub const overlay = @import("overlay.zig");
pub const overlay_types = @import("overlay_types.zig");
pub const tray = @import("tray.zig");
pub const tray_types = @import("tray_types.zig");
pub const config = @import("config.zig");
pub const log = @import("log.zig");
pub const clipboard = @import("clipboard.zig");

test {
    std.testing.refAllDecls(@import("audio.zig"));
    std.testing.refAllDecls(@import("transcribe.zig"));
    std.testing.refAllDecls(@import("hotkey.zig"));
    std.testing.refAllDecls(@import("hotkey_types.zig"));
    std.testing.refAllDecls(@import("hotkey_stub.zig"));
    std.testing.refAllDecls(@import("inject.zig"));
    std.testing.refAllDecls(@import("inject_stub.zig"));
    std.testing.refAllDecls(@import("inject_types.zig"));
    std.testing.refAllDecls(@import("overlay_types.zig"));
    std.testing.refAllDecls(@import("overlay_stub.zig"));
    std.testing.refAllDecls(@import("overlay.zig"));
    std.testing.refAllDecls(@import("tray.zig"));
    std.testing.refAllDecls(@import("tray_types.zig"));
    std.testing.refAllDecls(@import("tray_stub.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("log.zig"));
    std.testing.refAllDecls(@import("clipboard.zig"));
    std.testing.refAllDecls(@import("clipboard_linux.zig"));
    std.testing.refAllDecls(@import("clipboard_macos.zig"));
    std.testing.refAllDecls(@import("clipboard_windows.zig"));
    if (builtin.os.tag == .linux) {
        std.testing.refAllDecls(@import("inject_linux.zig"));
        std.testing.refAllDecls(@import("hotkey_linux.zig"));
        std.testing.refAllDecls(@import("tray_linux.zig"));
    }
    if (builtin.os.tag == .windows) {
        std.testing.refAllDecls(@import("tray_windows.zig"));
        // These @cImport platform headers (windows.h), which cannot be
        // analyzed on a Linux test build. Their coverage comes from
        // `zig build -Dtarget=x86_64-windows` plus on-device testing.
        std.testing.refAllDecls(@import("hotkey_windows.zig"));
        std.testing.refAllDecls(@import("inject_windows.zig"));
    }
    if (builtin.os.tag == .macos) {
        std.testing.refAllDecls(@import("tray_macos.zig"));
        // Same reason as the Windows block above (ApplicationServices).
        std.testing.refAllDecls(@import("hotkey_macos.zig"));
        std.testing.refAllDecls(@import("inject_macos.zig"));
    }
}
