const std = @import("std");

// Single entry point for the zhisper library: typing backend + audio capture.
// (Flat `pub usingnamespace` re-exports are not allowed in Zig 0.16, so the
// backends are namespaced: `root.audio.setRecording`, `root.linux.setupUinput`.)
pub const linux = @import("linux.zig");
pub const audio = @import("audio.zig");
pub const transcribe = @import("transcribe.zig");

test {
    std.testing.refAllDecls(linux);
    std.testing.refAllDecls(audio);
    std.testing.refAllDecls(transcribe);
    std.testing.refAllDecls(@import("hotkey_types.zig"));
    std.testing.refAllDecls(@import("hotkey_linux.zig"));
}
