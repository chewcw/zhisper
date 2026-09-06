const std = @import("std");

pub const sample_rate: u32 = 16000;
pub const channels: u16 = 1;
pub const bits_per_sample: u16 = 16;
pub const header_len: usize = 44;

/// Builds a 44-byte WAV header for `sample_count` mono s16 samples at 16kHz.
pub fn header(sample_count: usize, out: *[header_len]u8) void {
    // 2 bytes per s16 sample.
    const data_bytes: u32 = @intCast(sample_count * 2);
    // RIFF marker
    out[0..4].* = "RIFF".*;
    // According to the WAV/RIFF specification RIFF Chunk Size is total file size - 8
    // bytes, thus (44 + data_bytes) - 8 = 36 + data_bytes.
    std.mem.writeInt(u32, out[4..8], 36 + data_bytes, .little);
    // WAVE marker.
    out[8..12].* = "WAVE".*;
    // format header.
    out[12..16].* = "fmt ".*;
    // Subchunk1 size, size of the format subchunk (16 bytes for PCM).
    std.mem.writeInt(u32, out[16..20], 16, .little);
    // Audio format, format code 1 specifies uncompressed PCM.
    std.mem.writeInt(u16, out[20..22], 1, .little);
    // Channel count (1 = mono, 2 = stereo).
    std.mem.writeInt(u16, out[22..24], channels, .little);
    // Sample rate in Hz, e.g., 44100.
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    // Byte rate: bytes of audio data per second (sample_rate * channels * bits / 8).
    std.mem.writeInt(u32, out[28..32], sample_rate * channels * bits_per_sample / 8, .little);
    // Block align: bytes per sample frame (channels * bits / 8)
    std.mem.writeInt(u16, out[32..34], channels * bits_per_sample / 8, .little);
    // Bits per sample (16 = s16 PCM, 16-bit).
    std.mem.writeInt(u16, out[34..36], bits_per_sample, .little);
    // Data subchunk marker. Marks the start of the audio sample payload.
    out[36..40].* = "data".*;
    // Data subchunk size in bytes (sample_count * 2).
    std.mem.writeInt(u32, out[40..44], data_bytes, .little);
}

/// Writes `samples` as a 16kHz mono s16 WAV at `dir/path`, overwriting.
pub fn writeMono16(io: std.Io, dir: std.Io.Dir, path: []const u8, samples: []const i16) !void {
    var file = try dir.createFile(io, path, .{});
    errdefer {
        file.close(io);
        dir.deleteFile(io, path) catch {};
    }
    var hdr: [header_len]u8 = undefined;
    header(samples.len, &hdr);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    const wi = &w.interface;
    try wi.writeAll(&hdr);
    try wi.writeAll(std.mem.sliceAsBytes(samples));
    try wi.flush();
    file.close(io);
}

test "wav header for 0 samples" {
    var out: [44]u8 = undefined;
    header(0, &out);
    try std.testing.expectEqualSlices(u8, "RIFF", out[0..4]);
    try std.testing.expectEqualSlices(u8, "WAVE", out[8..12]);
    try std.testing.expectEqualSlices(u8, "fmt ", out[12..16]);
    try std.testing.expectEqualSlices(u8, "data", out[36..40]);
    try std.testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, out[40..44], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[20..22], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[22..24], .little));
    try std.testing.expectEqual(@as(u32, 16000), std.mem.readInt(u32, out[24..28], .little));
    try std.testing.expectEqual(@as(u32, 32000), std.mem.readInt(u32, out[28..32], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[32..34], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, out[34..36], .little));
}

test "wav header sizes scale with sample count" {
    var out: [44]u8 = undefined;
    header(16000, &out); // 1 second
    try std.testing.expectEqual(@as(u32, 36 + 32000), std.mem.readInt(u32, out[4..8], .little));
    try std.testing.expectEqual(@as(u32, 32000), std.mem.readInt(u32, out[40..44], .little));
}

test "wav write round-trips header through a real file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const samples = [_]i16{ 0, 1000, -1000, 32767, -32768 };
    try writeMono16(io, tmp.dir, "roundtrip.wav", &samples);
    var f = try tmp.dir.openFile(io, "roundtrip.wav", .{});
    defer f.close(io);
    var rbuf: [128]u8 = undefined;
    var r = f.reader(io, &rbuf);
    var got: [44]u8 = undefined;
    try r.interface.readSliceAll(&got);
    var want: [44]u8 = undefined;
    header(samples.len, &want);
    try std.testing.expectEqualSlices(u8, &want, &got);
}
