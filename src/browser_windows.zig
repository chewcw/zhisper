const std = @import("std");

const c = @cImport({
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

pub fn openUrl(io: std.Io, gpa: std.mem.Allocator, url: []const u8) !void {
    _ = io;
    const url_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The transcript arrives as UTF-8, so this is a corrupt-input case,
        // not a reason to distinguish the failure for the user.
        error.InvalidUtf8 => return error.LauncherFailed,
    };
    defer gpa.free(url_w);
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    // ShellExecuteW returns a value greater than 32 on success. The small
    // values are the legacy error codes documented for ShellExecute.
    const result = c.ShellExecuteW(null, verb, url_w.ptr, null, null, c.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) return error.LauncherFailed;
}
