const std = @import("std");

const builtin = @import("builtin");
const types = @import("browser_types.zig");

pub const buildSearchUrl = types.buildSearchUrl;
pub const default_search_base_url = types.default_search_base_url;
pub const max_url_len = types.max_url_len;

const impl = if (builtin.is_test)
    @import("browser_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("browser_linux.zig"),
    .windows => @import("browser_windows.zig"),
    .macos => @import("browser_macos.zig"),
    else => @compileError("browser: unsupported OS"),
};

/// The allocator is used only for the Windows wide-string conversion.
pub fn openUrl(io: std.Io, gpa: std.mem.Allocator, url: []const u8) !void {
    return impl.openUrl(io, gpa, url);
}

const stub = @import("browser_stub.zig");

test "facade hands the url to the stub" {
    stub.reset();
    defer stub.reset();
    try openUrl(std.testing.io, std.testing.allocator, "https://example.test/?q=pizza");
    try std.testing.expectEqualStrings("https://example.test/?q=pizza", stub.takeUrl());
}

test "facade surfaces one forced launch failure and then recovers" {
    stub.reset();
    defer stub.reset();
    stub.failNext();
    try std.testing.expectError(error.LauncherFailed, openUrl(std.testing.io, std.testing.allocator, "https://example.test/"));
    try openUrl(std.testing.io, std.testing.allocator, "https://example.test/");
    try std.testing.expectEqualStrings("https://example.test/", stub.takeUrl());
}
