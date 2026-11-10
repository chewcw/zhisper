const std = @import("std");
const config = @import("config.zig");

pub const Live = struct {
    mutex: std.atomic.Mutex = .unlocked,
    arena: std.heap.ArenaAllocator,
    current: *const config.Config,

    pub fn init(gpa: std.mem.Allocator, cfg: config.Config) !Live {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const copy = try arena.allocator().create(config.Config);
        copy.* = try config.dupeConfig(arena.allocator(), cfg);
        return .{ .arena = arena, .current = copy };
    }

    pub fn deinit(self: *Live) void {
        self.arena.deinit();
    }

    pub fn get(self: *Live) config.Config {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        return self.current.*;
    }

    // Menu changes and the file watcher both run on the main loop thread,
    // so there is exactly one writer.
    pub fn replace(self: *Live, cfg: config.Config) !void {
        // Allocate outside the lock so a slow allocator does not block readers.
        const copy = try self.arena.allocator().create(config.Config);
        copy.* = try config.dupeConfig(self.arena.allocator(), cfg);
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        self.current = copy;
    }

    pub fn setNormalizeEnabled(self: *Live, enabled: bool) !void {
        var next = self.get();
        next.normalize.enabled = enabled;
        try self.replace(next);
    }
};

test "get returns the config that init stored" {
    const gpa = std.testing.allocator;
    var live = try Live.init(gpa, .{});
    defer live.deinit();
    const snap = live.get();
    try std.testing.expectEqualStrings("groq", snap.transcribe.provider);
    try std.testing.expectEqualStrings("semi-formal", snap.normalize.styling);
}

test "replace is visible to the next get" {
    const gpa = std.testing.allocator;
    var live = try Live.init(gpa, .{});
    defer live.deinit();
    var next = live.get();
    next.transcribe.provider = "deepgram";
    next.daemon.overlay = false;
    try live.replace(next);
    try std.testing.expectEqualStrings("deepgram", live.get().transcribe.provider);
    try std.testing.expect(!live.get().daemon.overlay);
}

test "setNormalizeEnabled flips only that field" {
    const gpa = std.testing.allocator;
    var live = try Live.init(gpa, .{});
    defer live.deinit();
    try live.setNormalizeEnabled(true);
    const snap = live.get();
    try std.testing.expect(snap.normalize.enabled);
    try std.testing.expectEqualStrings("semi-formal", snap.normalize.styling);
}

test "readers never observe a half-written snapshot" {
    const gpa = std.testing.allocator;
    var live = try Live.init(gpa, .{});
    defer live.deinit();
    var stop = std.atomic.Value(bool).init(false);
    var bad = std.atomic.Value(u32).init(0);

    const Reader = struct {
        fn run(l: *Live, done: *std.atomic.Value(bool), torn: *std.atomic.Value(u32)) void {
            while (!done.load(.acquire)) {
                const name = l.get().transcribe.provider;
                // A torn read would hand back a slice that is neither value.
                if (!std.mem.eql(u8, name, "groq") and !std.mem.eql(u8, name, "deepgram")) {
                    _ = torn.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    const readers = [_]std.Thread{
        try std.Thread.spawn(.{}, Reader.run, .{ &live, &stop, &bad }),
        try std.Thread.spawn(.{}, Reader.run, .{ &live, &stop, &bad }),
    };
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var next = live.get();
        next.transcribe.provider = if (i % 2 == 0) "deepgram" else "groq";
        try live.replace(next);
    }
    stop.store(true, .release);
    for (readers) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), bad.load(.monotonic));
}
