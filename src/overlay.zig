const std = @import("std");
const builtin = @import("builtin");
const types = @import("overlay_types.zig");

pub const Position = types.Position;
pub const State = types.State;
pub const Event = types.Event;
pub const OverlayConfig = types.OverlayConfig;

// Untaken comptime branch is never analyzed, so `zig build test` never
// touches SDL headers (the SDL backend exists only in non-test builds).
const impl = if (builtin.is_test)
    @import("overlay_stub.zig")
else
    @import("overlay_sdl.zig");

pub fn setup(cfg: OverlayConfig) !void {
    return impl.setup(cfg);
}

pub fn destroy() void {
    return impl.destroy();
}

pub fn show() !void {
    return impl.show();
}

pub fn hide() void {
    return impl.hide();
}

pub fn move(pos: Position) void {
    return impl.move(pos);
}

pub fn setState(s: State) void {
    return impl.setState(s);
}

pub fn tick(t_ms: u64) void {
    return impl.tick(t_ms);
}

/// Display list in global desktop coordinates, primary first. Caller
/// owns the slice. Empty under stub/headless; SDL backend enumerates.
pub fn displayList(gpa: std.mem.Allocator) ![]types.Display {
    return impl.displayList(gpa);
}

pub fn pollEvent() ?Event {
    return impl.pollEvent();
}

/// Sibling of the config file (`overlay.pos` next to `config.toml`),
/// so it follows the same OS config-dir rules as `main.resolveConfigPath`.
pub fn overlayPosPath(gpa: std.mem.Allocator) ![]u8 {
    const builtin_os = @import("builtin");
    if (builtin_os.os.tag == .windows) {
        if (std.c.getenv("APPDATA")) |raw| {
            const base = std.mem.span(raw);
            if (base.len > 0) return try std.fmt.allocPrint(gpa, "{s}\\zhisper\\overlay.pos", .{base});
        }
        return try gpa.dupe(u8, "overlay.pos");
    }
    const home = if (std.c.getenv("HOME")) |raw| std.mem.span(raw) else "";
    if (home.len == 0) return try gpa.dupe(u8, "overlay.pos");
    if (builtin_os.os.tag == .macos) {
        return try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/zhisper/overlay.pos", .{home});
    }
    return try std.fmt.allocPrint(gpa, "{s}/.config/zhisper/overlay.pos", .{home});
}

/// Never fails: missing/corrupt files fall back to the default corner,
/// as do saved positions on a monitor that is no longer plugged in.
pub fn loadOverlayPos(io: std.Io, gpa: std.mem.Allocator, path: []const u8, displays: []const types.Display) Position {
    _ = gpa;
    const dflt = types.defaultForDisplays(displays);
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return dflt;
    defer f.close(io);
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    const n = r.interface.readSliceShort(&buf) catch return dflt;
    const pos = types.parsePosition(buf[0..n]) orelse return dflt;
    if (!types.isVisible(pos, displays)) return dflt;
    return pos;
}

pub fn saveOverlayPos(io: std.Io, path: []const u8, pos: Position) !void {
    var buf: [32]u8 = undefined;
    const text = try types.formatPosition(&buf, pos);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

test "facade replays stub drag events and records state" {
    const stub = @import("overlay_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(.{});
    stub.pushTestEvent(.{ .drag_end = .{ .x = 700, .y = 500 } });
    try std.testing.expectEqual(700, pollEvent().?.drag_end.x);
    try std.testing.expect(pollEvent() == null);
    setState(.working);
    try std.testing.expectEqual(State.working, stub.testLastState().?);
    move(.{ .x = 1, .y = 2 });
    try std.testing.expectEqual(2, stub.testLastMove().?.y);
    destroy();
}

test "facade records tick without display" {
    const stub = @import("overlay_stub.zig");
    stub.reset();
    defer stub.reset();
    try setup(.{});
    tick(1234);
    try std.testing.expectEqual(@as(?u64, 1234), stub.testLastTick());
    tick(1240);
    try std.testing.expectEqual(@as(?u64, 1240), stub.testLastTick());
    destroy();
}

test "overlay pos path lives beside the config file" {
    const gpa = std.testing.allocator;
    const p = try overlayPosPath(gpa);
    defer gpa.free(p);
    try std.testing.expect(std.mem.endsWith(u8, p, "zhisper" ++ std.fs.path.sep_str ++ "overlay.pos"));
}

test "load falls back when missing, corrupt, or unplugged; save round-trips" {
    const io = std.testing.io;
    const primary = [_]types.Display{.{ .x = 0, .y = 0, .w = 1920, .h = 1080 }};
    // Fixed /tmp names: overlay tests run in exactly one test binary
    // (sequentially), so no cross-run collision is possible.
    const missing = "/tmp/zhisper-overlay-test-missing.pos";
    std.Io.Dir.cwd().deleteFile(io, missing) catch {};
    try std.testing.expectEqual(types.defaultForDisplays(&primary), loadOverlayPos(io, std.testing.allocator, missing, &primary));
    const path = "/tmp/zhisper-overlay-test-rt.pos";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try saveOverlayPos(io, path, .{ .x = 111, .y = 222 });
    try std.testing.expectEqual(Position{ .x = 111, .y = 222 }, loadOverlayPos(io, std.testing.allocator, path, &primary));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "garbage\n" });
    try std.testing.expectEqual(types.defaultForDisplays(&primary), loadOverlayPos(io, std.testing.allocator, path, &primary));
    // Saved on a monitor that is now unplugged: back to the default corner.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "5000 100\n" });
    try std.testing.expectEqual(types.defaultForDisplays(&primary), loadOverlayPos(io, std.testing.allocator, path, &primary));
}
