const std = @import("std");
const Io = std.Io;

const zhisper = @import("zhisper");
const audio = @import("audio");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    audio.init(io, gpa);

    const path = "/tmp/test.wav";
    try audio.setRecording(1, path);

    try io.sleep(.fromSeconds(2), .awake);

    try audio.setRecording(2, path);
}
