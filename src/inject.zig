const std = @import("std");
const builtin = @import("builtin");
const types = @import("inject_types.zig");

pub const InjectOptions = types.InjectOptions;
pub const TrailingNewline = types.TrailingNewline;

const impl = if (builtin.is_test)
    @import("inject_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("inject_linux.zig"),
    .windows => @import("inject_windows.zig"),
    .macos => @import("inject_macos.zig"),
    else => @compileError("inject: unsupported OS"),
};

pub fn setup(io: std.Io, opts: InjectOptions) !void {
    return impl.setup(io, opts);
}

pub fn typeText(text: []const u8, io: std.Io) !usize {
    return impl.typeText(text, io);
}

pub fn destroy() void {
    impl.destroy();
}

test "facade types through the stub" {
    const stub = @import("inject_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(std.testing.io, .{});
    const n = try typeText("hi", std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("hi", stub.takeText());
    destroy();
    try std.testing.expectEqualStrings("", stub.takeText());
}

test "facade strips trailing newlines by default" {
    const stub = @import("inject_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(std.testing.io, .{});
    const n = try typeText("hi\n\n", std.testing.io);
    try std.testing.expectEqualStrings("hi", stub.takeText());
    try std.testing.expectEqual(@as(usize, 2), n);
    destroy();
}

test "facade keeps trailing newlines in send mode" {
    const stub = @import("inject_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(std.testing.io, .{ .trailing_newline = .send });
    const n = try typeText("hi\n", std.testing.io);
    try std.testing.expectEqualStrings("hi\n", stub.takeText());
    try std.testing.expectEqual(@as(usize, 3), n);
    destroy();
}

test "facade keeps interior newlines in strip mode" {
    const stub = @import("inject_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(std.testing.io, .{ .trailing_newline = .strip });
    const n = try typeText("a\nb\n", std.testing.io);
    try std.testing.expectEqualStrings("a\nb", stub.takeText());
    try std.testing.expectEqual(@as(usize, 3), n);
    destroy();
}

test "facade counts UTF-8 characters not bytes" {
    const stub = @import("inject_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(std.testing.io, .{});
    // Two 3-byte CJK codepoints must count as 2, not 6.
    const n = try typeText("你好", std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("你好", stub.takeText());
    destroy();
}

test "facade rejects invalid UTF-8" {
    const stub = @import("inject_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(std.testing.io, .{});
    try std.testing.expectError(error.InvalidUtf8, typeText(&[_]u8{ 0xE4, 0xBD }, std.testing.io));
    destroy();
}
