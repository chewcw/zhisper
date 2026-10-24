const std = @import("std");

var last_url_buf: [2048]u8 = undefined;
var last_url_len: usize = 0;
var fail_next: bool = false;

pub fn reset() void {
    last_url_len = 0;
    fail_next = false;
}

/// Returns the recorded URL and clears it, so a test cannot read a stale URL
/// from an earlier call.
pub fn takeUrl() []const u8 {
    const out = last_url_buf[0..last_url_len];
    last_url_len = 0;
    return out;
}

pub fn failNext() void {
    fail_next = true;
}

pub fn openUrl(_: std.Io, _: std.mem.Allocator, url: []const u8) !void {
    if (fail_next) {
        fail_next = false;
        return error.LauncherFailed;
    }
    const n = @min(url.len, last_url_buf.len);
    @memcpy(last_url_buf[0..n], url[0..n]);
    last_url_len = n;
}
