const std = @import("std");
const builtin = @import("builtin");
const types = @import("notify_types.zig");

pub const Level = types.Level;
pub const Kind = types.Kind;
pub const Message = types.Message;
pub const Availability = types.Availability;

/// Re-exported so a backend needs one import, not two.
pub const title = types.title;

/// How many notifications can be pending between the thread that produces them
/// and the poll loop that shows them. The daemon holds at most one active and
/// one waiting job, so this can never actually fill.
pub const queue_capacity: usize = 8;

const impl = if (builtin.is_test)
    @import("notify_stub.zig")
else switch (builtin.os.tag) {
    .linux => @import("notify_linux.zig"),
    .macos => @import("notify_macos.zig"),
    .windows => @import("notify_windows.zig"),
    else => @compileError("notify: unsupported OS"),
};

pub fn check(io: std.Io) Availability {
    return impl.check(io);
}

/// The only side-effecting call in this feature. Everything else — `forEvent`,
/// `shouldNotify` — is pure. Both threads may derive and enqueue; only the poll
/// loop ever calls this.
pub fn show(io: std.Io, msg: Message) !void {
    return impl.show(io, msg);
}

pub fn shouldNotify(level: Level, kind: Kind) bool {
    return types.shouldNotify(level, kind);
}

/// Single-producer-safe handoff between the two threads that report outcomes
/// and the one that displays them. `Message` is a plain value with no borrowed
/// slices, so the queue needs no allocator and no ownership rule.
///
/// The mutex is load-bearing, not decorative. `items[idx] = msg` is a
/// field-wise copy of a ~100-byte struct, and a reader that observed `len`
/// before `bytes` finished copying would hand back a `slice()` pointing into
/// stale memory. Publishing each slot through an atomic index instead would
/// need a release-store after the copy and an acquire-load in the reader;
/// `Message` is far too large to assume a torn copy is harmless, so the lock
/// stays and the ordering question disappears.
pub const NotifyQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: [queue_capacity]Message = undefined,
    count: usize = 0,
    head: usize = 0,

    // Zig has no methods: dot syntax requires the receiver to be the FIRST
    // parameter. `self` after `io` would make these plain functions and
    // `queue.push(io, msg)` would not compile.
    pub fn push(self: *NotifyQueue, io: std.Io, msg: Message) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.count == queue_capacity) {
            // Drop the oldest, matching WorkQueue's policy: the newest status is
            // the one that describes what the user is looking at now.
            self.head = (self.head + 1) % queue_capacity;
            self.count -= 1;
        }
        const idx = (self.head + self.count) % queue_capacity;
        self.items[idx] = msg;
        self.count += 1;
    }

    pub fn drain(self: *NotifyQueue, io: std.Io, out: *[queue_capacity]Message, count: *usize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var n: usize = 0;
        while (n < self.count) : (n += 1) {
            out[n] = self.items[(self.head + n) % queue_capacity];
        }
        count.* = n;
        self.head = 0;
        self.count = 0;
    }
};

test "facade routes show through the stub" {
    const stub = @import("notify_stub.zig");
    stub.reset();
    defer stub.reset();
    try show(std.testing.io, types.forEvent(.too_short, ""));
    try std.testing.expectEqual(@as(u32, 1), stub.testShowCount());
    try std.testing.expectEqual(Kind.too_short, stub.testLast().?.kind);
}

test "facade exposes the pure level check" {
    try std.testing.expect(!shouldNotify(.off, .clipboard_ready));
    try std.testing.expect(shouldNotify(.errors, .clipboard_failed));
}

test "the notify queue preserves push order across a drain" {
    var queue = NotifyQueue{};
    queue.push(std.testing.io, types.forEvent(.too_short, ""));
    queue.push(std.testing.io, types.forEvent(.quiet_clip, ""));
    queue.push(std.testing.io, types.forEvent(.clipboard_ready, ""));
    var out: [queue_capacity]Message = undefined;
    var n: usize = 0;
    queue.drain(std.testing.io, &out, &n);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Kind.too_short, out[0].kind);
    try std.testing.expectEqual(Kind.quiet_clip, out[1].kind);
    try std.testing.expectEqual(Kind.clipboard_ready, out[2].kind);
}

test "drain empties the notify queue" {
    var queue = NotifyQueue{};
    var out: [queue_capacity]Message = undefined;
    var n: usize = 0;
    queue.push(std.testing.io, types.forEvent(.quiet_clip, ""));
    queue.drain(std.testing.io, &out, &n);
    try std.testing.expectEqual(@as(usize, 1), n);
    queue.drain(std.testing.io, &out, &n);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "the notify queue drops the oldest on overflow and keeps the newest" {
    var queue = NotifyQueue{};
    // Fill to capacity with one kind, then push one that must survive.
    for (0..queue_capacity) |_| queue.push(std.testing.io, types.forEvent(.too_short, ""));
    queue.push(std.testing.io, types.forEvent(.clipboard_ready, "newest"));
    var out: [queue_capacity]Message = undefined;
    var n: usize = 0;
    queue.drain(std.testing.io, &out, &n);
    try std.testing.expectEqual(queue_capacity, n);
    // The survivors are the last `queue_capacity` pushes.
    try std.testing.expectEqual(Kind.too_short, out[0].kind);
    try std.testing.expectEqual(Kind.clipboard_ready, out[queue_capacity - 1].kind);
}

test "a message pushed from another thread reaches the drain in order" {
    const Ctx = struct {
        queue: *NotifyQueue,
        io: std.Io,

        fn run(self: *@This()) void {
            self.queue.push(self.io, types.forEvent(.transcribe_failed, "Timeout"));
            self.queue.push(self.io, types.forEvent(.empty_transcript, ""));
        }
    };
    var queue = NotifyQueue{};
    var ctx = Ctx{ .queue = &queue, .io = std.testing.io };
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});
    thread.join();
    var out: [queue_capacity]Message = undefined;
    var n: usize = 0;
    queue.drain(std.testing.io, &out, &n);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Kind.transcribe_failed, out[0].kind);
    try std.testing.expectEqual(Kind.empty_transcript, out[1].kind);
}
