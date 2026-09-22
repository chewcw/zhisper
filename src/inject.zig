const std = @import("std");
const builtin = @import("builtin");

const impl = if (builtin.is_test)
    @import("inject_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("inject_linux.zig"),
    .windows => @import("inject_windows.zig"),
    .macos => @import("inject_macos.zig"),
    else => @compileError("inject: unsupported OS"),
};

pub fn setup(io: std.Io) !void {
    return impl.setup(io);
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
    try setup(std.testing.io);
    const n = try typeText("hi", std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("hi", stub.takeText());
    destroy();
    try std.testing.expectEqualStrings("", stub.takeText());
}
