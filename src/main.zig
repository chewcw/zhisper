const std = @import("std");

const zhisper = @import("zhisper");

// Imported so its tests run under `zig build test`; main() does not call
// into it yet (daemon-loop wiring is out of scope for the config change).
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    zhisper.audio.init(io, gpa);

    const path = "/tmp/test.wav";
    try zhisper.audio.setRecording(.start, path);

    try io.sleep(.fromSeconds(2), .awake);

    try zhisper.audio.setRecording(.stop, path);
}
