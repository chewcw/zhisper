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
pub const config = @import("config.zig");
pub const log = @import("log.zig");
// Linux-only headers must never be analyzed on other targets.
pub const linux = if (builtin.os.tag == .linux) @import("linux.zig") else struct {};

test {
    std.testing.refAllDecls(@import("audio.zig"));
    std.testing.refAllDecls(@import("transcribe.zig"));
    std.testing.refAllDecls(@import("hotkey.zig"));
    std.testing.refAllDecls(@import("hotkey_types.zig"));
    std.testing.refAllDecls(@import("hotkey_stub.zig"));
    std.testing.refAllDecls(@import("inject.zig"));
    std.testing.refAllDecls(@import("inject_stub.zig"));
    std.testing.refAllDecls(@import("hotkey_windows.zig"));
    std.testing.refAllDecls(@import("hotkey_macos.zig"));
    std.testing.refAllDecls(@import("inject_windows.zig"));
    std.testing.refAllDecls(@import("inject_macos.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("log.zig"));
    if (builtin.os.tag == .linux) {
        std.testing.refAllDecls(@import("linux.zig"));
        std.testing.refAllDecls(@import("hotkey_linux.zig"));
    }
}
