const std = @import("std");

const zhisper = @import("zhisper");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    zhisper.audio.init(io, gpa);

    const path = "/tmp/test.wav";
    try zhisper.audio.setRecording(1, path);

    try io.sleep(.fromSeconds(2), .awake);

    try zhisper.audio.setRecording(2, path);
}
